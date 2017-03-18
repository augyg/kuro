{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Kadena.Commit.Service
  ( initCommitEnv
  , runCommitService
  , module X
  ) where

import Control.Lens hiding (Index, (|>))
import Control.Concurrent
import Control.Concurrent.Async
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.RWS.Strict

import qualified Data.HashMap.Strict as HashMap
import qualified Data.Map.Strict as Map
import Data.Thyme.Clock
import Data.Maybe (fromJust)
import Data.ByteString (ByteString)
import Data.Aeson (Value)

import System.Directory

import qualified Pact.Types.Command as Pact
import Pact.Types.Command (CommandExecInterface(..), ExecutionMode(..))
import Pact.Types.Runtime (EvalEnv(..))
import Pact.Types.RPC (PactRPC)
import Pact.Server.PactService (applyCmd)
import Pact.Types.Server (CommandConfig(..), CommandState(..))
import Pact.PersistPactDb (initDbEnv, createSchema, pactdb,DbEnv(..))
import Pact.Native (initEvalEnv)
import qualified Pact.Persist.SQLite as SQLite
import qualified Pact.Persist.Pure as Pure
import Pact.Persist.CacheAdapter
import qualified Pact.Persist.WriteBehind as WB

import Kadena.Commit.Types as X
import Kadena.Types.Dispatch (Dispatch)
import qualified Kadena.Types.Dispatch as D
import qualified Kadena.History.Types as History
import qualified Kadena.Log.Service as Log

initCommitEnv
  :: Dispatch
  -> (String -> IO ())
  -> CommandConfig
  -> (Metric -> IO ())
  -> IO UTCTime
  -> CommitEnv
initCommitEnv dispatch' debugPrint' commandConfig' publishMetric' getTimestamp' = CommitEnv
  { _commitChannel = dispatch' ^. D.commitService
  , _historyChannel = dispatch' ^. D.historyChannel
  , _commandConfig = commandConfig'
  , _debugPrint = debugPrint'
  , _publishMetric = publishMetric'
  , _getTimestamp = getTimestamp'
  }

data ReplayStatus = ReplayFromDisk | FreshCommands deriving (Show, Eq)


initPactService :: CommandConfig -> IO (CommandExecInterface PactRPC)
initPactService config@CommandConfig {..} = do
  let klog s = _ccDebugFn ("[PactService] " ++ s)
      mkCEI :: MVar (DbEnv a) -> MVar CommandState -> CommandExecInterface PactRPC
      mkCEI dbVar cmdVar = CommandExecInterface
        { _ceiApplyCmd = \eMode cmd -> applyCmd config dbVar cmdVar eMode cmd (Pact.verifyCommand cmd)
        , _ceiApplyPPCmd = applyCmd config dbVar cmdVar }
  case _ccDbFile of
    Nothing -> do
      klog "Initializing pure pact"
      ee <- initEvalEnv (initDbEnv _ccDebugFn Pure.persister Pure.initPureDb) pactdb
      rv <- newMVar (CommandState $ _eeRefStore ee)
      klog "Creating Pact Schema"
      createSchema (_eePactDbVar ee)
      return $ mkCEI (_eePactDbVar ee) rv
    Just f -> do
      dbExists <- doesFileExist f
      when dbExists $ klog "Deleting Existing Pact DB File" >> removeFile f
      sl <- SQLite.initSQLite [] putStrLn f
      wb <- initPureCacheWB SQLite.persister sl putStrLn
      link =<< async (WB.runWBService wb)
      p <- return $ initDbEnv klog WB.persister wb
      ee <- initEvalEnv p pactdb
      rv <- newMVar (CommandState $ _eeRefStore ee)
      let v = _eePactDbVar ee
      klog "Creating Pact Schema"
      createSchema v
      return $ mkCEI v rv


runCommitService :: CommitEnv -> NodeId -> KeySet -> IO ()
runCommitService env nodeId' keySet' = do
  cmdExecInter <- initPactService (env ^. commandConfig)
  initCommitState <- return $! CommitState { _nodeId = nodeId', _keySet = keySet', _commandExecInterface = cmdExecInter}
  void $ runRWST handle env initCommitState

debug :: String -> CommitService ()
debug s = do
  dbg <- view debugPrint
  liftIO $! dbg $ "[Service|Commit] " ++ s

now :: CommitService UTCTime
now = view getTimestamp >>= liftIO

logMetric :: Metric -> CommitService ()
logMetric m = do
  publishMetric' <- view publishMetric
  liftIO $! publishMetric' m

handle :: CommitService ()
handle = do
  oChan <- view commitChannel
  debug "Launch!"
  forever $ do
    q <- liftIO $ readComm oChan
    case q of
      Heart t -> liftIO (pprintBeat t) >>= debug
      ChangeNodeId{..} -> do
        prevNodeId <- use nodeId
        nodeId .= newNodeId
        debug $ "Changed NodeId: " ++ show prevNodeId ++ " -> " ++ show newNodeId
      UpdateKeySet{..} -> do
        keySet %= updateKeySet
        debug "Updated KeySet"
      CommitNewEntries{..} -> do
        debug $ (show . Log.lesCnt $ logEntriesToApply)
              ++ " new log entries to apply, up to "
              ++ show (fromJust $ Log.lesMaxIndex logEntriesToApply)
        applyLogEntries FreshCommands logEntriesToApply
      ReloadFromDisk{..} -> do
        debug $ (show . Log.lesCnt $ logEntriesToApply)
              ++ " entries loaded from disk to apply, up to "
              ++ show (fromJust $ Log.lesMaxIndex logEntriesToApply)
        applyLogEntries ReplayFromDisk logEntriesToApply
      ExecLocal{..} -> applyLocalCommand (localCmd,localResult)

applyLogEntries :: ReplayStatus -> LogEntries -> CommitService ()
applyLogEntries rs les@(LogEntries leToApply) = do
  now' <- now
  (results :: [(RequestKey, CommandResult)]) <- mapM (applyCommand now') (Map.elems leToApply)
  commitIndex' <- return $ fromJust $ Log.lesMaxIndex les
  logMetric $ MetricAppliedIndex commitIndex'
  if not (null results)
    then do
      debug $! "Applied " ++ show (length results) ++ " CMD(s)"
      hChan <- view historyChannel
      unless (rs == ReplayFromDisk) $ liftIO $! writeComm hChan (History.Update $ HashMap.fromList results)
    else debug "Applied log entries but did not send results?"

logApplyLatency :: UTCTime -> LogEntry -> CommitService ()
logApplyLatency startTime LogEntry{..} = case _leCmdLatMetrics of
  Nothing -> return ()
  Just n -> do
    logMetric $ MetricApplyLatency $ fromIntegral $ interval (_lmFirstSeen n) startTime
{-# INLINE logApplyLatency #-}

getPendingPreProcSCC :: UTCTime -> MVar SCCPreProcResult -> CommitService SCCPreProcResult
getPendingPreProcSCC startTime mvResult = liftIO (tryReadMVar mvResult) >>= \case
  Just r -> return r
  Nothing -> do
    debug $ "Blocked on Pending PreProc"
    r <- liftIO $ readMVar mvResult
    endTime <- now
    debug $ "Unblocked on Pending PreProc, took :" ++ show (interval startTime endTime) ++ "micros"
    return r

applyCommand :: UTCTime -> LogEntry -> CommitService (RequestKey, CommandResult)
applyCommand _tEnd le@LogEntry{..} = do
  apply <- Pact._ceiApplyPPCmd <$> use commandExecInterface
  startTime <- now
  logApplyLatency startTime le
  (result, ppLat) <- case _leCommand of
    SmartContractCommand{..} -> do
      (pproc, ppLat) <- case _sccPreProc of
        Unprocessed -> do
          debug $ "WARNING: non-preproccessed command found for " ++ show _leLogIndex
          case (verifyCommand _leCommand) of
            SmartContractCommand{..} -> return $! (result _sccPreProc, _leCmdLatMetrics)
        Pending{..} -> do
          PendingResult{..} <- getPendingPreProcSCC startTime pending
          return $ (_prResult, updateLatPreProc _prStartedPreProc _prFinishedPreProc _leCmdLatMetrics)
        Result{..}  -> do
          debug $ "WARNING: fully resolved command found for " ++ show _leLogIndex
          return $! (result, _leCmdLatMetrics)
      res <- liftIO $ apply (Transactional (fromIntegral _leLogIndex)) _sccCmd pproc
      return (res, ppLat)
  tEnd' <- now
  lat <- return $ updateCommitPreProc startTime tEnd' ppLat
  case _leCommand of
    SmartContractCommand{} -> return
      ( RequestKey $ getCmdBodyHash _leCommand
      , SmartContractResult
        { _scrHash = getCmdBodyHash _leCommand
        , _scrResult = result
        , _cmdrLogIndex = _leLogIndex
        , _cmdrLatMetrics = mkLatResults <$> lat
        })

applyLocalCommand :: (Pact.Command ByteString, MVar Value) -> CommitService ()
applyLocalCommand (cmd, mv) = do
  applyLocal <- Pact._ceiApplyCmd <$> use commandExecInterface
  cr <- liftIO $ applyLocal Local cmd
  liftIO $ putMVar mv (Pact._crResult cr)

updateLatPreProc :: Maybe UTCTime -> Maybe UTCTime -> Maybe CmdLatencyMetrics -> Maybe CmdLatencyMetrics
updateLatPreProc hitPreProc finPreProc = fmap update'
  where
    update' cmd = cmd {_lmHitPreProc = hitPreProc
                      ,_lmFinPreProc = finPreProc}
{-# INLINE updateLatPreProc #-}

updateCommitPreProc :: UTCTime -> UTCTime -> Maybe CmdLatencyMetrics -> Maybe CmdLatencyMetrics
updateCommitPreProc hitCommit finCommit = fmap update'
  where
    update' cmd = cmd {_lmHitCommit = Just hitCommit
                      ,_lmFinCommit = Just finCommit}
{-# INLINE updateCommitPreProc #-}
