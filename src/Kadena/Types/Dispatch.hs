{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Dispatch
  ( Dispatch(..), initDispatch
  , inboundAER
  , inboundCMD
  , inboundRVorRVR
  , inboundGeneral
  , outboundGeneral
  , outboundAerRvRvr
  , internalEvent
  , senderService
  , logService
  , evidence
  , commitService
  , historyChannel
  ) where

import Control.Lens

import Data.Typeable

import Kadena.Types.Comms
import Kadena.Sender.Types (SenderServiceChannel)
import Kadena.Log.Types (LogServiceChannel)
import Kadena.Evidence.Spec (EvidenceChannel)
import Kadena.Commit.Types (CommitChannel)
import Kadena.History.Types (HistoryChannel)

data Dispatch = Dispatch
  { _inboundAER      :: InboundAERChannel
  , _inboundCMD      :: InboundCMDChannel
  , _inboundRVorRVR  :: InboundRVorRVRChannel
  , _inboundGeneral  :: InboundGeneralChannel
  , _outboundGeneral :: OutboundGeneralChannel
  , _outboundAerRvRvr :: OutboundAerRvRvrChannel
  , _internalEvent   :: InternalEventChannel
  , _senderService   :: SenderServiceChannel
  , _logService   :: LogServiceChannel
  , _evidence   :: EvidenceChannel
  , _commitService :: CommitChannel
  , _historyChannel :: HistoryChannel
  } deriving (Typeable)

initDispatch :: IO Dispatch
initDispatch = Dispatch
  <$> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms

makeLenses ''Dispatch
