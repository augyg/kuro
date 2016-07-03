module Juno.Consensus.Server
  ( runRaftServer
  ) where

import Control.Concurrent (newEmptyMVar, forkIO)
import qualified Control.Concurrent.Lifted as CL
import Control.Lens
import Control.Monad

import qualified Data.Set as Set
import Data.IORef

import Juno.Consensus.Api (apiReceiver)
import Juno.Consensus.Handle
import Juno.Runtime.MessageReceiver
import qualified Juno.Runtime.MessageReceiver as RENV
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
  -- forever (writeComm (_internalEvent $ _dispatch renv) (InternalEvent $ Tock $ t) >> threadDelay 1000000)
  void $ forkIO $ foreverTickDebugWriteDelay (renv ^. RENV.debugPrint) (_internalEvent $ _dispatch renv) 1000000 (InternalEvent . Tick)
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
