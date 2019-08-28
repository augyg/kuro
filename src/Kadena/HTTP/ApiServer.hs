{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE BangPatterns #-}

module Kadena.HTTP.ApiServer
  ( runApiServer
  ) where

import Prelude hiding (log)
import Control.Lens
import Control.Concurrent
import Control.Exception.Lifted
import Control.Monad.Reader

import Data.Aeson hiding (defaultOptions, Result(..))
import Data.ByteString.Lazy (toStrict)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as BSL
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import Data.Text.Encoding
import Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Set as Set
import qualified Data.Serialize as SZ

-- Cabal version info
import Paths_kadena (version)
import Data.Version (showVersion)

import Snap.Core
import Snap.Http.Server as Snap
import Snap.Util.CORS
import System.FilePath
import System.Directory
import System.Time.Extra (sleep)
import Data.Thyme.Clock

import qualified Pact.Types.Runtime as Pact
import qualified Pact.Types.Command as Pact
import qualified Pact.Types.API as Pact

import Kadena.Command (SubmitCC(..))
import Kadena.Config.TMVar as KCfg
import Kadena.Consensus.Publish
import Kadena.Types.Command
import Kadena.Types.Base
import Kadena.Types.Comms
import Kadena.Types.Dispatch
import Kadena.Types.Entity
import qualified Kadena.Types.HTTP as K
import Kadena.HTTP.Static
import qualified Kadena.Types.Execution as Exec
import Kadena.Types.History (History(..), PossiblyIncompleteResults(..))
import qualified Kadena.Types.History as History
import Kadena.Types.Private (PrivatePlaintext(..),PrivateCiphertext(..),Labeled(..))
import Kadena.Types.Spec
import Kadena.Private.Service (encrypt)
import Kadena.Util.Util

data ApiEnv = ApiEnv
  { _aiLog :: String -> IO ()
  , _aiDispatch :: Dispatch
  , _aiConfig :: GlobalConfigTMVar
  , _aiPublish :: Publish
  }

makeLenses ''ApiEnv

type Api a = ReaderT ApiEnv Snap a

runApiServer :: Dispatch -> KCfg.GlobalConfigTMVar -> (String -> IO ())
             -> Int -> MVar PublishedConsensus -> IO UTCTime -> IO ()
runApiServer dispatch gcm logFn port mPubConsensus' timeCache' = do
  logFn $ "[Service|API]: starting on port " ++ show port
  rconf <- readCurrentConfig gcm
  let conf' = ApiEnv logFn dispatch gcm $
        Publish
        mPubConsensus'
        dispatch
        timeCache'
        (_nodeId rconf)
  let logFilePrefix = _logDir rconf </> show (_alias (_nodeId rconf))
      hostStaticDir' = _hostStaticDir rconf
  serverConf' <- serverConf port logFn logFilePrefix
  httpServe serverConf' $
    applyCORS defaultOptions $ methods [GET, POST] $
    route $ ("", runReaderT api conf'):(staticRoutes hostStaticDir')

serverConf :: MonadSnap m => Int -> (String -> IO ()) -> String -> IO (Snap.Config m a)
serverConf port dbgFn logFilePrefix = do
  let errorLog =  logFilePrefix ++ "-snap-error.log"
  let accessLog = logFilePrefix ++ "-snap-access.log"
  doesFileExist errorLog >>= \x -> when x $ dbgFn ("Creating " ++ errorLog) >> writeFile errorLog ""
  doesFileExist accessLog >>= \x -> when x $ dbgFn ("Creating " ++ accessLog) >> writeFile accessLog ""
  return $ setErrorLog (ConfigFileLog errorLog) $
    setAccessLog (ConfigFileLog accessLog) $
    setPort port defaultConfig

apiVer :: BS.ByteString
apiVer = "/api/v1/"

api :: Api ()
api = route [
       (apiVer `BS.append` "send",sendPublicBatch)
      ,(apiVer `BS.append` "poll",pactPoll)
      ,(apiVer `BS.append` "pollSBFT",poll)
      ,(apiVer `BS.append` "listen",registerPactListener)
      ,(apiVer `BS.append` "listenCC",registerListener)
      ,(apiVer `BS.append` "listenSBFT", registerListener)
      ,(apiVer `BS.append` "local",sendLocal)
      ,(apiVer `BS.append` "private",sendPrivateBatch)
      ,(apiVer `BS.append` "config", sendClusterChange)
      ,("version", sendVersionInfo)
      ]

sendLocal :: Api ()
sendLocal = catch (do
    Pact.SubmitBatch neCmds <- readSubmitBatchJSON
    if length neCmds /= 1
      then do
        let msg = "Batches of more than one local commands is not currently supported"
        log msg >> die msg
      else do
        let cmd = fmap encodeUtf8 (NE.head neCmds)
        mv <- liftIO newEmptyMVar
        c <- view $ aiDispatch . dispExecService
        liftIO $ writeComm c (Exec.ExecLocal cmd mv)
        r <- liftIO $ takeMVar mv -- :: PactResult
        writeResponse r)
    (\e -> liftIO $ putStrLn $ "Exception caught in the handler 'sendLocal' : "
                            ++ show (e :: SomeException))

-- retries here are due to leader election startup time
sendPublicBatch :: Api ()
sendPublicBatch = do
    let retryCount = 30 :: Int
    Pact.SubmitBatch neCmds <- readSubmitBatchJSON
    log $ "public: received batch of " ++ show (NE.length neCmds)
    go neCmds retryCount
  where
    go _ 0 = die "timeout waiting for a valid leader"
    go cmds count = catches
        (do
            rpcs <- return $ fmap buildCmdRpc cmds
            queueRpcs rpcs)
        [ Handler (\ (_e :: NotReadyException) -> do
            liftIO $ sleep 1
            log $ "sendPublicBatch - Current retry-until-ready count = " ++ show count
               ++ ", trying again..."
            go cmds (count - 1))
        , Handler (\e -> liftIO $ putStrLn $ "Exception caught in the handler 'sendPublicBatch': "
                                ++ show (e :: SomeException)) ]

sendClusterChange :: Api ()
sendClusterChange = catch (do
    log $ "ApiServer - Cluster Change command received"
    SubmitCC ccCmds <- readSubmitCCJSON
    when (null ccCmds) $ die "Empty cluster change batch"
    when (length ccCmds /= 2) $ die "Exactly two cluster change commands required -- one Transitional, one Final"
    let transCmd = head ccCmds
    let finalCmd = head $ tail $ ccCmds
    let transRpc = buildCCCmdRpc transCmd
    log $ "ApiServer - queuing RPC for transitional CC request"

    queueRpcsNoResp (transRpc :| []) -- NonEmpty List
    let transListenerReq = Pact.ListenerRequest (fst transRpc) --listen for the result of the transitional command
    ccTransResult <- listenFor transListenerReq
    case ccTransResult of
      ClusterChangeSuccess -> do
        log "Transitional CC was sucessful, now ok to send the Final"
        let finalRpc = buildCCCmdRpc finalCmd
        log $ "ApiServer - queuing RPC for final CC request"
        queueRpcs (finalRpc :| []) -- NonEmpty List
        let finalListenerReq = Pact.ListenerRequest (fst finalRpc)
        ccFinalResult <- listenFor finalListenerReq
        case ccFinalResult of
          ClusterChangeSuccess -> log "Final CC was sucessful, Config change complete"
          ClusterChangeFailure eFinal -> log $ "Final cluster change failed: " ++ eFinal
      ClusterChangeFailure eTrans  -> do
        log $ "Transitional cluster change failed: " ++ eTrans
  )
  (\e -> liftIO $ putStrLn $ "Exception caught in the handler 'sendClusterChange': " ++ show (e :: SomeException))

queueRpcs :: NonEmpty (RequestKey,CMDWire) -> Api ()
queueRpcs rpcs = do
  p <- view aiPublish
  rks <- publish p die rpcs
  log $ "queueRpcs - writing reponse: " ++ show rks
  writeResponse rks

queueRpcsNoResp :: NonEmpty (RequestKey,CMDWire) -> Api ()
queueRpcsNoResp rpcs = do
    p <- view aiPublish
    _rks <- publish p die rpcs
    return ()

sendPrivateBatch :: Api ()
sendPrivateBatch = catch sendBatch (\e -> liftIO $ putStrLn $
    "Exception caught in the handler 'sendPrivateBatch': " ++ show (e :: SomeException))
  where
    sendBatch = do
      conf <- view aiConfig >>= liftIO . readCurrentConfig
      unless (_ecSending $ _entity conf) $ die "Node is not configured as private sending node"
      Pact.SubmitBatch cmds <- readJSON
      log $ "private: received batch of " ++ show (length cmds)
      when (null cmds) $ die "Empty Batch"
      rpcs <- mapM (cmdToWire conf) cmds
      queueRpcs rpcs

cmdToWire :: KCfg.Config -> Pact.Command T.Text -> Api (RequestKey, CMDWire)
cmdToWire config cmd = do
  let cb@Pact.Command{..} = fmap encodeUtf8 cmd
  case eitherDecodeStrict' _cmdPayload of
    Left e -> die $ "JSON payload decode failed: " ++ show e
    Right (Pact.Payload{..} :: Pact.Payload Pact.PrivateMeta T.Text) -> do
      addr@Pact.Address{..} <- addressFromMeta _pMeta cmd
      if _aFrom `Set.member` _aTo || _aFrom /= (_elName $ _ecLocal$ _entity config)
        then die $ "sendPrivateBatch: invalid address in payload: " ++ show cmd
        else do
          pc@PrivateCiphertext{..} <- addressToCipher addr cb config
          let hsh = Pact.pactHash $ _lPayload $ _pcEntity
              hc = Hashed pc $ Pact.hash $ _lPayload $ _pcEntity
          return (RequestKey hsh, PCWire $ SZ.encode hc)

addressToCipher :: Pact.Address -> Pact.Command BS.ByteString -> KCfg.Config -> Api PrivateCiphertext
addressToCipher Pact.Address{..} cmd config = do
  pchan <- view (aiDispatch.dispPrivateChannel)
  plainTxt <- liftIO $ encrypt pchan $
    PrivatePlaintext _aFrom (_alias (_nodeId config)) _aTo (SZ.encode cmd)
  case plainTxt of
    Left e -> die $ "sendPrivateBatch: encrypt failed: " ++ show e ++ "\n"
                  ++ show plainTxt ++ ", command: " ++ show cmd
    Right pc -> return pc

addressFromMeta :: Pact.PrivateMeta -> Pact.Command T.Text -> Api Pact.Address
addressFromMeta (Pact.PrivateMeta (Just addr)) _cmd = return addr
addressFromMeta (Pact.PrivateMeta Nothing) cmd =
  die $ "sendPrivateBatch: missing address in payload: " ++ show cmd

pactPoll :: Api ()
pactPoll = catch (do
    (Pact.Poll rks) <- readJSON
    PossiblyIncompleteResults{..} <- checkHistoryForResult (HashSet.fromList (NE.toList rks))

    --this endpoint is Pact-Web compatible, so need to return the inner Pact result type
    let responses = Pact.PollResponses $ fmap (_pcrResult . _scrPactResult) possiblyIncompleteResults
    writeResponse responses)
  (\e -> liftIO $ putStrLn $ "Exception caught in the handler pactPoll" ++ show (e :: SomeException))

poll :: Api ()
poll = catch (do
    (Pact.Poll rks) <- readJSON
    PossiblyIncompleteResults{..} <- checkHistoryForResult (HashSet.fromList (NE.toList rks))
    writeResponse $ K.PollResponses possiblyIncompleteResults)
  (\e -> liftIO $ putStrLn $ "Exception caught in the handler poll: " ++ show (e :: SomeException))

checkHistoryForResult :: HashSet RequestKey -> Api PossiblyIncompleteResults
checkHistoryForResult rks = do
  hChan <- view (aiDispatch.dispHistoryChannel)
  m <- liftIO $ newEmptyMVar
  liftIO $ writeComm hChan $ QueryForResults (rks,m)
  liftIO $ readMVar m

log :: String -> Api ()
log s = view aiLog >>= \f -> liftIO (f $ "[Service|Api]: " ++ s)

die :: String -> Api t
die res = do
  _ <- getResponse -- chuck what we've done so far
  setJSON
  log res
  writeLBS $ encode (Left ("Kadena.HTTP.ApiServer" ++ res) :: Either String ())
  finishWith =<< getResponse

readJSON :: (Show t, FromJSON t) => Api t
readJSON = do
  b  <- readRequestBody 1000000000
  snd <$> tryParseJSON b

readSubmitBatchJSON :: Api Pact.SubmitBatch
readSubmitBatchJSON = do
  b  <- readRequestBody 1000000000
  snd <$> parseSubmitBatch b

readSubmitCCJSON :: Api SubmitCC
readSubmitCCJSON = do
  b  <- readRequestBody 1000000000
  snd <$> parseSubmitCC b

tryParseJSON
  :: (Show t, FromJSON t) =>
     BSL.ByteString -> Api (BS.ByteString, t)
tryParseJSON b = do
  case eitherDecode b of
    Right v -> return (toStrict b,v)
    Left e -> die $ "Left from tryParseJson: " ++ e

parseSubmitBatch :: BSL.ByteString -> Api (BS.ByteString, Pact.SubmitBatch)
parseSubmitBatch b = do
  let z = eitherDecode b :: Either String Pact.SubmitBatch
  case eitherDecode b of
    (Right v :: Either String Pact.SubmitBatch) -> return (toStrict b,v)
    Left e -> error ( "Left from parseSubmitBatch?: "
                    ++ "\n\t trying to decode: " ++ show b
                    ++ "\n\t decoded: " ++ show z
                    ++ "\n\terror: " ++ show e )

parseSubmitCC :: BSL.ByteString -> Api (BS.ByteString, SubmitCC)
parseSubmitCC b = case eitherDecode b of
    (Right v :: Either String SubmitCC) -> return (toStrict b,v)
    Left e -> die $ "Left from parseSubmitCC: " ++ e

setJSON :: Api ()
setJSON = modifyResponse $ setHeader "Content-Type" "application/json"

writeResponse :: forall j. (ToJSON j) => j -> Api ()
writeResponse r = setJSON >> writeLBS (encode r)

listenFor :: Pact.ListenerRequest -> Api ClusterChangeResult
listenFor (Pact.ListenerRequest rk) = do
  hChan <- view (aiDispatch.dispHistoryChannel)
  m <- liftIO $ newEmptyMVar
  liftIO $ writeComm hChan $ RegisterListener (HashMap.fromList [(rk,m)])
  log $ "listenFor -- registered Listener for: " ++ show rk
  res <- liftIO $ readMVar m
  case res of
    History.GCed msg -> do
      let errStr = "Listener GCed for: " ++ show rk ++ " because " ++ msg
      return $ ClusterChangeFailure errStr
    History.ListenerResult cr -> do
      log $ "listenFor -- Listener Serviced for: " ++ show rk
      return $ _concrResult cr

registerPactListener :: Api ()
registerPactListener = do
  (theEither :: Either SomeException ()) <- try $ do
    (Pact.ListenerRequest rk) <- readJSON
    hChan <- view (aiDispatch.dispHistoryChannel)
    m <- liftIO $ newEmptyMVar
    liftIO $ writeComm hChan $ RegisterListener (HashMap.fromList [(rk,m)])
    log $ "Registered Listener for: " ++ show rk
    res <- liftIO $ readMVar m
    case res of
      History.GCed msg -> do
        log $ "Listener GCed for: " ++ show rk ++ " because " ++ msg
        die msg
      History.ListenerResult cr -> do
        log $ "Listener Serviced for: " ++ show rk
        setJSON
        let pactCr = _pcrResult $ _scrPactResult cr
        writeResponse $ Pact.ListenResponse pactCr
  case theEither of
    Left e -> do
      let errStr = "Exception in registerListener: " ++ show e
      log errStr
      liftIO $ putStrLn errStr
      throw e
    Right y -> return y

registerListener :: Api ()
registerListener = do
  (theEither :: Either SomeException ()) <- try $ do
    (Pact.ListenerRequest rk) <- readJSON
    hChan <- view (aiDispatch.dispHistoryChannel)
    m <- liftIO $ newEmptyMVar
    liftIO $ writeComm hChan $ RegisterListener (HashMap.fromList [(rk,m)])
    log $ "Registered Listener for: " ++ show rk
    res <- liftIO $ readMVar m
    case res of
      History.GCed msg -> do
        log $ "Listener GCed for: " ++ show rk ++ " because " ++ msg
        die msg
      History.ListenerResult cr -> do
        log $ "Listener Serviced for: " ++ show rk
        setJSON
        writeResponse $ K.ListenResponse cr
  case theEither of
    Left e -> do
      let errStr = "Exception in registerListener: " ++ show e
      log errStr
      liftIO $ putStrLn errStr
      throw e
    Right y -> return y

-- | Require just to respond with an HTTP 200 for pact-web, but some more useful info can be added..
sendVersionInfo :: Api ()
sendVersionInfo = do
  writeResponse cabalVersion

-- | Get version info from cabal
cabalVersion :: String
cabalVersion = showVersion version
