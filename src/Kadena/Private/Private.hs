{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Kadena.Private.Private
  (kpPublic,kpSecret,
   initEntitySession,
   initLabeler,
   initRemote,
   initSessions,
   sendPrivate,
   handlePrivate)
  where


import Control.Arrow ((&&&))
import Control.Exception (SomeException)
import Control.Lens
       ((&), (.~), (.=), (%=), use, ix, view, over, set)
import Control.Monad (forM, forM_)
import Control.Monad.Catch (MonadThrow, MonadCatch, throwM, handle)
import Control.Monad.State.Strict
       (MonadState, get, put)
import Crypto.Noise
       (defaultHandshakeOpts, HandshakeRole(..), hoLocalStatic,
        hoRemoteStatic, hoLocalEphemeral, noiseState,
        writeMessage, readMessage)
import Crypto.Noise.Cipher (Cipher(..), Plaintext)
import Crypto.Noise.DH (KeyPair, DH(..))
import Crypto.Noise.DH.Curve25519 (Curve25519)
import Crypto.Noise.HandshakePatterns
       (HandshakePattern, noiseKK, noiseK)
import Data.ByteArray.Extend (convert)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B8
import qualified Data.HashMap.Strict as HM
import Data.Monoid ((<>))
import Data.Serialize (encode, decode)
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Set as S



import Pact.Types.Orphans ()
import Pact.Types.Util (AsString(..))

import Kadena.Private.Types


noise :: HandshakePattern -> HandshakeRole
        -> EntityLocal -> PublicKey Curve25519
        -> Noise
noise pat rol EntityLocal{..} remoteStatic =
  noiseState $ defaultHandshakeOpts pat rol &
      hoLocalStatic .~ Just _elStatic &
      hoRemoteStatic .~ Just remoteStatic &
      hoLocalEphemeral .~ Just _elEphemeral

kpPublic :: KeyPair a -> PublicKey a
kpPublic = snd

kpSecret :: KeyPair a -> SecretKey a
kpSecret = fst

initEntitySession :: EntityLocal -> EntitySession
initEntitySession el@EntityLocal{..} = EntitySession
  (noise noiseK InitiatorRole el (kpPublic _elStatic))
  (noise noiseK ResponderRole el (kpPublic _elStatic))
  lblr lblr (makeLabel lblr) 0
  where lblr = initLabeler (encodeUtf8 $ asString _elName)
               (kpSecret _elStatic) (kpPublic _elStatic)

initLabeler :: ByteString -> SecretKey Curve25519 -> PublicKey Curve25519 -> Labeler
initLabeler ad sk pk = Labeler (cipherBytesToSym $ dhPerform sk pk) cipherZeroNonce (convert ad)

initRemote :: MonadThrow m => EntityLocal -> EntityRemote -> m RemoteSession
initRemote el@EntityLocal{..} EntityRemote{..} = do
  let outName = asString _elName <> ":" <> asString _erName
      inName = asString _erName <> ":" <> asString _elName
  (rol,name) <- case _elName `compare` _erName of
    LT -> return (InitiatorRole, outName)
    GT -> return (ResponderRole, inName)
    EQ -> throwM (userError $ "initRemote: local and remote names match: " ++ show (_elName,_erName))
  let sendL = initLabeler (encodeUtf8 outName) (kpSecret _elStatic) _erStatic
      recvL = initLabeler (encodeUtf8 inName) (kpSecret _elStatic) _erStatic
  return $ RemoteSession name _erName
    (noise noiseKK rol el _erStatic) rol sendL recvL (makeLabel recvL) 0



initSessions :: MonadThrow m => EntityLocal -> [EntityRemote] -> m Sessions
initSessions el ers = do
  ss <- fmap HM.fromList $ forM ers $ \er -> (_erName er,) <$> initRemote el er
  let ls = HM.fromList $ map (_rsLabel &&& _rsEntity) $ HM.elems ss
  return $ Sessions (initEntitySession el) ss ls


labelPT :: Plaintext
labelPT = convert $ B8.pack $ replicate 12 (toEnum 0)

makeLabel :: Labeler -> Label
makeLabel Labeler{..} = convert $ cipherTextToBytes $
                        cipherEncrypt _lSymKey _lNonce _lAssocData labelPT

updateLabeler :: Labeler -> Labeler
updateLabeler = over lNonce cipherIncNonce

withStateRollback :: (MonadState s m,MonadCatch m) => (s -> m a) -> m a
withStateRollback act = get >>= \s -> handle (\(e :: SomeException) -> put s >> throwM e) (act s)

lookupRemote :: EntityName -> HM.HashMap EntityName RemoteSession -> Private RemoteSession
lookupRemote to = maybe (die $ "lookupRemote: invalid entity: " ++ show to) return .
                  HM.lookup to

-- | Send updates entity outbound labeler, entity init noise, remote send labeler, remote noise.
sendPrivate :: PrivateMessage -> Private PrivateEnvelope
sendPrivate pm@PrivateMessage{..} = withStateRollback $ \(PrivateState Sessions {..}) -> do
  let pt = convert $ encode pm
  remotePayloads <- forM (S.toList _pmTo) $ \to -> do
    RemoteSession {..} <- lookupRemote to _sRemotes
    (ct,n') <- liftEither ("sendPrivate:" ++ show to) $ writeMessage _rsNoise pt
    sessions . sRemotes . ix to %= (set rsNoise n' . over rsSendLabeler updateLabeler . over rsVersion succ)
    return $ Labeled (makeLabel _rsSendLabeler) (convert ct)
  entityPayload <- do
    (ct,n') <- liftEither "sendPrivate:entity" $ writeMessage (_esInitNoise _sEntity) pt
    sessions . sEntity %= (set esInitNoise n' . over esOutLabeler updateLabeler . over esVersion succ)
    return $ Labeled (makeLabel (_esOutLabeler _sEntity)) (convert ct)
  return $ PrivateEnvelope entityPayload remotePayloads

-- | Switch on message labels to handle as same-entity or remote-inbound message.
handlePrivate :: PrivateEnvelope -> Private (Maybe PrivateMessage)
handlePrivate pe@PrivateEnvelope{..} = do
  Sessions{..} <- use sessions
  if _lLabel _peEntity == _esLabel _sEntity
    then Just <$> readEntity pe
    else let testRemote _ done@Just {} = done
             testRemote ll@Labeled{..} Nothing =
               (ll,) <$> HM.lookup _lLabel _sLabels
         in mapM readRemote $ foldr testRemote Nothing _peRemotes

-- | inbound entity updates entity inbound labeler, label, inbound entity resp noise. If not sender,
-- also retro-update entity out labeler, entity init noise, remote send labeler, remote noise.
readEntity :: PrivateEnvelope -> Private PrivateMessage
readEntity PrivateEnvelope{..} = do
  Sessions{..} <- use sessions
  (pt,n') <- liftEither "readEntity:decrypt" $ readMessage (_esRespNoise _sEntity) (_lPayload _peEntity)
  pm@PrivateMessage{..} <- liftEither "readEntity:deser" $ decode (convert pt)
  me <- view nodeAlias
  let ilblr = updateLabeler $ _esInLabeler _sEntity
      update = set esRespNoise n' . set esLabel (makeLabel ilblr) . set esInLabeler ilblr . over esVersion succ
  if _pmSender == me
    then do
    sessions . sEntity %= update
    else do
    (_,in') <- liftEither "readEntity:updateEntInit" $ writeMessage (_esInitNoise _sEntity) pt
    sessions . sEntity %= update . set esInitNoise in' . over esOutLabeler updateLabeler
    forM_ (S.toList _pmTo) $ \to -> do
      RemoteSession{..} <- lookupRemote to _sRemotes
      (_,rn') <- liftEither ("readEntity:updateRemote:" ++ show _rsName) $
                 writeMessage _rsNoise pt
      sessions . sRemotes . ix to %= set rsNoise rn' . over rsSendLabeler updateLabeler . over rsVersion succ

  return pm

-- | inbound remote updates remote label, recv labeler, remote noise.
readRemote :: (Labeled,EntityName) -> Private PrivateMessage
readRemote (Labeled{..},remoteEntName) = do
  rs@RemoteSession{..} <- lookupRemote remoteEntName =<< use (sessions . sRemotes)
  (pt,n') <- liftEither ("readRemote:decrypt:" ++ show rs) $ readMessage _rsNoise _lPayload
  let l' = updateLabeler _rsRecvLabeler
      lbl = makeLabel l'
      rs' = set rsNoise n' . set rsRecvLabeler l' . set rsLabel lbl . over rsVersion succ $ rs
  sessions . sLabels %= HM.insert lbl _rsEntity . HM.delete _lLabel
  sessions . sRemotes . ix _rsEntity .= rs'
  liftEither "readRemote:deser" $ decode (convert pt)
