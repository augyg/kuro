module Juno.Consensus.Server
  ( runRaftServer
  ) where

import Control.Concurrent (newEmptyMVar, forkIO, threadDelay)
import qualified Control.Concurrent.Lifted as CL
import Control.Lens
import Control.Monad

import qualified Data.Set as Set
import Data.IORef

import Juno.Consensus.Api (apiReceiver)
import Juno.Consensus.Handle
import Juno.Runtime.MessageReceiver
import Juno.Runtime.Timer
import Juno.Types
import Juno.Util.Util

runRaftServer :: ReceiverEnv -> Config -> RaftSpec -> IO ()
runRaftServer renv rconf spec = do
  let csize = 1 + Set.size (rconf ^. otherNodes)
      qsize = getQuorumSize csize
  void $ runMessageReceiver renv
  rconf' <- newIORef rconf
  timerTarget' <- newEmptyMVar
  ls <- initLogState
  -- This helps for testing, we'll send tocks every second to inflate the logs when we see weird pauses right before an election
  void $ forkIO $ forever (writeComm (_internalEvent $ _dispatch renv) (InternalEvent Tock) >> threadDelay 1000000)
  runRWS_
    raft
    (mkRaftEnv rconf' ls csize qsize spec (_dispatch renv) timerTarget')
    (initialRaftState timerTarget')

-- THREAD: SERVER MAIN
raft :: Raft ()
raft = do
  logStaticMetrics
  void $ CL.fork apiReceiver     -- THREAD: waits for cmds from API, signs and sends to leader.
  resetElectionTimer
  handleEvents
