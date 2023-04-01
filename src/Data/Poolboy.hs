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
import Control.Exception.Safe (bracket, tryAny)
import Control.Monad
import Control.Monad.STM
import Data.Maybe (isNothing)
import System.Timeout (timeout)

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
      <*> return settings.log

  count <-
    case settings.workersCount of
      CapabilitiesWCS -> getNumCapabilities
      FixedWCS x -> return x

  changeDesiredWorkersCount wq count
  void $ forkIO $ controller wq []

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
  ready <- newEmptyMVar
  enqueue wq $ putMVar ready ()
  readMVar ready

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
    log :: String -> IO ()
  }

data Commands
  = ChangeDesiredWorkersCount Int
  | Stop
  deriving stock (Show)

controller :: WorkQueue -> [Async ()]  -> IO ()
controller wq workers = do
  command <- atomically $ readTQueue wq.commands
  let stopOneWorker = atomically $ writeTQueue wq.queue $ Left ()
      getLiveWorkers = filterM (fmap isNothing . poll) workers
  wq.log $ "Command: " <> show command
  case command of
    ChangeDesiredWorkersCount n -> do
      liveWorkers <- getLiveWorkers
      let diff = length liveWorkers - n
      newWorkers <-
        if diff > 0
          then do
            replicateM_ diff stopOneWorker
            return []
          else replicateM (abs diff) $ do
            wq.log "Pre-fork"
            async $ worker wq
      controller wq $ newWorkers <> liveWorkers
    Stop -> do
      liveWorkers <- getLiveWorkers
      let currentCount = length liveWorkers
      wq.log $ "Stopping " <> show currentCount <> " workers"
      replicateM_ currentCount stopOneWorker
      forM_ liveWorkers waitCatch
      void $ tryPutMVar wq.stopped ()

worker :: WorkQueue -> IO ()
worker wq = do
  wq.log "New worker"
  let loop = do
        command <- atomically $ readTQueue wq.queue
        case command of
          Left () -> do
            wq.log "Stopping"
          Right act -> wq.log "pop" >> void (tryAny act) >> wq.log "poped" >> loop
  loop
