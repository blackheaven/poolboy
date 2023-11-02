module Data.Poolboy
  ( -- * Configuration
    PoolboySettings (..),
    WorkersCountSettings (..),
    defaultPoolboySettings,
    poolboySettingsWith,
    simpleSerializedLogger,

    -- * Running
    WorkQueue,
    withPoolboy,
    newPoolboy,

    -- * Driving
    changeDesiredWorkersCount,
    waitReadyQueue,

    -- * Stopping
    stopWorkQueue,
    isStopedWorkQueue,
    WaitingStopStrategy,
    waitingStopTimeout,
    waitingStopFinishWorkers,

    -- * Enqueueing
    enqueue,
    enqueueAfter,
  )
where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM.TQueue
import Control.Monad
import Control.Monad.STM
import Data.Maybe (isNothing)
import System.Timeout (timeout)
import UnliftIO.Exception (bracket, tryAny)

-- | Initial settings
data PoolboySettings = PoolboySettings
  { workersCount :: WorkersCountSettings,
    log :: String -> IO ()
  }

-- | Initial number of threads
data WorkersCountSettings
  = -- | 'getNumCapabilities' based number
    CapabilitiesWCS
  | FixedWCS Int -- arbitrary number
  deriving stock (Eq, Show)

-- | Usual configuration 'CapabilitiesWCS' and no log
defaultPoolboySettings :: PoolboySettings
defaultPoolboySettings =
  PoolboySettings
    { workersCount = CapabilitiesWCS,
      log = \_ -> return ()
    }

-- | Arbitrary-numbered settings
poolboySettingsWith :: Int -> PoolboySettings
poolboySettingsWith c = defaultPoolboySettings {workersCount = FixedWCS c}

-- | Simple (but not particularly performant) serialized logger
simpleSerializedLogger :: IO (String -> IO ())
simpleSerializedLogger = do
  logLock <- newMVar ()
  return $ \x ->
    withMVar logLock $ \() -> do
      putStrLn x
      return ()

-- | 'backet'-based usage (recommended)
withPoolboy :: PoolboySettings -> WaitingStopStrategy -> (WorkQueue -> IO a) -> IO a
withPoolboy settings waitStopWorkQueue = bracket (newPoolboy settings) (\wq -> stopWorkQueue wq >> waitStopWorkQueue wq)

-- | Standalone/manual usage
newPoolboy :: PoolboySettings -> IO WorkQueue
newPoolboy settings = do
  wq <-
    WorkQueue
      <$> newTQueueIO
      <*> newTQueueIO
      <*> newEmptyMVar
      <*> newQSemN 0

  count <-
    case settings.workersCount of
      CapabilitiesWCS -> getNumCapabilities
      FixedWCS x -> return x

  changeDesiredWorkersCount wq count
  void $
    forkIO $
      controller $
        WorkQueueControllerState
          { commands = wq.commands,
            queue = wq.queue,
            stopped = wq.stopped,
            log = settings.log,
            workers = [],
            waitingWorkers = wq.waitingWorkers,
            capabilityCount = 0
          }

  return wq

-- | Request a worker number adjustment
changeDesiredWorkersCount :: WorkQueue -> Int -> IO ()
changeDesiredWorkersCount wq =
  atomically . writeTQueue wq.commands . ChangeDesiredWorkersCount

-- | Request stopping wrokers
stopWorkQueue :: WorkQueue -> IO ()
stopWorkQueue wq =
  atomically $ writeTQueue wq.commands Stop

-- | Non-blocking check of the work queue's running status
isStopedWorkQueue :: WorkQueue -> IO Bool
isStopedWorkQueue wq =
  not <$> isEmptyMVar wq.stopped

type WaitingStopStrategy = WorkQueue -> IO ()

-- | Block until the queue is totally stopped (no more running worker)
waitingStopFinishWorkers :: WaitingStopStrategy
waitingStopFinishWorkers wq =
  void $ tryAny $ readMVar wq.stopped

-- | Block until the queue is totally stopped or deadline (in micro seconds) is reached
waitingStopTimeout :: Int -> WaitingStopStrategy
waitingStopTimeout delay wq = void $ timeout delay $ waitingStopFinishWorkers wq

-- | Enqueue one action in the work queue (non-blocking)
enqueue :: WorkQueue -> IO () -> IO ()
enqueue wq =
  atomically . writeTQueue wq.queue . Right

-- | Block until one worker is available
waitReadyQueue :: WorkQueue -> IO ()
waitReadyQueue wq = do
  waitQSemN wq.waitingWorkers 1
  signalQSemN wq.waitingWorkers 1

-- | Enqueue action and some actions to be run after it
enqueueAfter :: Foldable f => WorkQueue -> IO () -> f (IO ()) -> IO ()
enqueueAfter wq x xs =
  enqueue wq $ do
    x
    forM_ xs $ enqueue wq

-- Support (internal)
data WorkQueue = WorkQueue
  { commands :: TQueue Commands,
    queue :: TQueue (Either () (IO ())),
    stopped :: MVar (),
    waitingWorkers :: QSemN
  }

data Commands
  = ChangeDesiredWorkersCount Int
  | Stop
  deriving stock (Show)

data WorkQueueControllerState = WorkQueueControllerState
  { commands :: TQueue Commands,
    queue :: TQueue (Either () (IO ())),
    stopped :: MVar (),
    log :: String -> IO (),
    workers :: [Async ()],
    waitingWorkers :: QSemN,
    capabilityCount :: Int
  }

controller :: WorkQueueControllerState -> IO ()
controller wq = do
  command <- atomically $ readTQueue wq.commands
  let stopOneWorker = atomically $ writeTQueue wq.queue $ Left ()
      getLiveWorkers = filterM (fmap isNothing . poll) wq.workers
      prefix = "Controller: "
  wq.log $ prefix <> "Command: " <> show command
  case command of
    ChangeDesiredWorkersCount n -> do
      liveWorkers <- getLiveWorkers
      let diff = length liveWorkers - n
      (newWorkers, newCapabilityCount) <-
        if diff > 0
          then do
            replicateM_ diff stopOneWorker
            return ([], wq.capabilityCount)
          else do
            let newWorkersCount = abs diff
            newWorkers <- forM [1 .. newWorkersCount] $ \capability -> do
              wq.log $ prefix <> "Pre-fork"
              asyncOn (capability - 1) $ worker $ WorkQueueWorkerState {queue = wq.queue, waitingWorkers = wq.waitingWorkers, log = wq.log}
            return (newWorkers, wq.capabilityCount + newWorkersCount)
      controller $ wq {workers = newWorkers <> liveWorkers, capabilityCount = newCapabilityCount}
    Stop -> do
      liveWorkers <- getLiveWorkers
      let currentCount = length liveWorkers
      wq.log $ prefix <> "Stopping " <> show currentCount <> " workers"
      waitQSemN wq.waitingWorkers currentCount
      replicateM_ currentCount stopOneWorker
      void $ tryPutMVar wq.stopped ()

data WorkQueueWorkerState = WorkQueueWorkerState
  { queue :: TQueue (Either () (IO ())),
    waitingWorkers :: QSemN,
    log :: String -> IO ()
  }

worker :: WorkQueueWorkerState -> IO ()
worker wq = do
  workerId <- show <$> myThreadId
  let prefix = "Worker [" <> workerId <> "]: "
  wq.log $ prefix <> "Starting"
  let loop = do
        signalQSemN wq.waitingWorkers 1
        command <- atomically $ readTQueue wq.queue
        case command of
          Left () -> do
            wq.log $ prefix <> "Stopping"
          Right act -> do
            waitQSemN wq.waitingWorkers 1
            wq.log (prefix <> "pop")
            void (tryAny act)
            wq.log (prefix <> "poped")
            loop
  loop
