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
    stopWorkQueue,
    isStopWorkQueue,

    -- * Driving
    changeDesiredWorkersCount,
    waitReadyQueue,

    -- * Enqueueing
    enqueue,
    enqueueAfter,
  )
where

import Control.Concurrent
import Control.Concurrent.STM.TQueue
import Control.Exception.Safe (bracket, tryAny)
import Control.Monad
import Control.Monad.STM
import Data.IORef

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
withPoolboy :: PoolboySettings -> (WorkQueue -> IO a) -> IO a
withPoolboy settings = bracket (newPoolboy settings) (\wq -> stopWorkQueue wq >> waitStopWorkQueue wq)

-- | Standalone/manual usage
newPoolboy :: PoolboySettings -> IO WorkQueue
newPoolboy settings = do
  wq <-
    WorkQueue
      <$> newTQueueIO
      <*> newTQueueIO
      <*> newIORef 0
      <*> newEmptyMVar
      <*> return settings.log

  count <-
    case settings.workersCount of
      CapabilitiesWCS -> getNumCapabilities
      FixedWCS x -> return x

  changeDesiredWorkersCount wq count
  void $ forkIO $ controller wq

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
isStopWorkQueue :: WorkQueue -> IO Bool
isStopWorkQueue wq =
  not <$> isEmptyMVar wq.stopped

-- | Block until the queue is totally stopped (no more running worker)
waitStopWorkQueue :: WorkQueue -> IO ()
waitStopWorkQueue wq =
  void $ tryAny $ readMVar wq.stopped

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
    currentWorkersCount :: IORef Int,
    stopped :: MVar (),
    log :: String -> IO ()
  }

data Commands
  = ChangeDesiredWorkersCount Int
  | Stop
  deriving stock (Show)

controller :: WorkQueue -> IO ()
controller wq = do
  command <- atomically $ readTQueue wq.commands
  let stopOneWorker = atomically $ writeTQueue wq.queue $ Left ()
  wq.log $ "Command: " <> show command
  case command of
    ChangeDesiredWorkersCount n -> do
      currentCount <- readIORef wq.currentWorkersCount
      let diff = currentCount - n
      if diff > 0
        then replicateM_ diff stopOneWorker
        else replicateM_ (abs diff) $ do
          wq.log "Pre-fork"
          forkIO $ worker wq
      controller wq
    Stop -> do
      currentCount <- readIORef wq.currentWorkersCount
      wq.log $ "Stopping " <> show currentCount <> " workers"
      replicateM_ currentCount stopOneWorker

worker :: WorkQueue -> IO ()
worker wq = do
  wq.log "New worker"
  newCount <- atomicModifyIORef' wq.currentWorkersCount $ \n -> (n + 1, n + 1)
  wq.log $ "New worker count " <> show newCount
  let loop = do
        command <- atomically $ readTQueue wq.queue
        case command of
          Left () -> do
            wq.log "Stopping"
            remaining <-
              atomicModifyIORef' wq.currentWorkersCount $ \n ->
                let count = max 0 (n - 1) in (count, count)
            wq.log $ "Remaining: " <> show remaining
            when (remaining == 0) $
              void $
                tryPutMVar wq.stopped ()
          Right act -> wq.log "pop" >> void (tryAny act) >> wq.log "poped" >> loop
  loop
