{-# LANGUAGE TupleSections #-}

module Data.Poolboy
  ( -- * Configuration
    PoolboySettings (..),
    WorkersCountSettings (..),
    defaultPoolboySettings,
    poolboySettingsWith,
    poolboySettingsName,

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
    enqueueTracking,
    enqueueAfter,
    enqueueAfterTracking,
    WorkQueueStoppedException,
  )
where

import Control.Exception (BlockedIndefinitelyOnMVar (BlockedIndefinitelyOnMVar))
import Control.Monad
import Data.Functor (($>))
import qualified Data.HashMap.Strict as HM
import Data.Maybe (listToMaybe)
import GHC.Conc (labelThread)
import GHC.Stack (HasCallStack, callStack, getCallStack, prettySrcLoc, withFrozenCallStack)
import UnliftIO (MonadIO (liftIO), MonadUnliftIO)
import UnliftIO.Async
import UnliftIO.Concurrent
import UnliftIO.Exception
import UnliftIO.IORef
import UnliftIO.QSemN
import UnliftIO.Timeout (timeout)

-- | Initial settings
data PoolboySettings = PoolboySettings
  { workersCount :: WorkersCountSettings,
    workQueueName :: String
  }
  deriving stock (Eq, Show)

-- | Initial number of threads
data WorkersCountSettings
  = -- | 'getNumCapabilities' based number
    CapabilitiesWCS
  | FixedWCS Int -- arbitrary number
  deriving stock (Eq, Show)

-- | Usual configuration 'CapabilitiesWCS' and no name
defaultPoolboySettings :: (HasCallStack) => PoolboySettings
defaultPoolboySettings =
  withFrozenCallStack $
    PoolboySettings
      { workersCount = CapabilitiesWCS,
        workQueueName =
          case listToMaybe $ getCallStack callStack of
            Nothing -> "<no name>"
            Just (f, loc) -> "<no name> created in " <> f <> ", called at " <> prettySrcLoc loc
      }

-- | Arbitrary-numbered of workers settings
poolboySettingsWith :: Int -> PoolboySettings
poolboySettingsWith c = defaultPoolboySettings {workersCount = FixedWCS c}

-- | Name of the work queue settings (used in error and debugging)
poolboySettingsName :: String -> PoolboySettings -> PoolboySettings
poolboySettingsName n s = s {workQueueName = n}

-- | 'backet'-based usage (recommended)
withPoolboy :: (MonadUnliftIO m) => PoolboySettings -> WaitingStopStrategy m -> (WorkQueue -> m a) -> m a
withPoolboy settings waitStopWorkQueue =
  bracket
    (newPoolboy settings)
    (\wq -> stopWorkQueue wq >> waitStopWorkQueue wq)

-- | Standalone/manual usage
newPoolboy :: (MonadUnliftIO m) => PoolboySettings -> m WorkQueue
newPoolboy settings = do
  count <-
    case settings.workersCount of
      CapabilitiesWCS -> getNumCapabilities
      FixedWCS x -> return x

  WorkQueue settings.workQueueName
    <$> newQSemN count
    <*> newIORef count
    <*> newEmptyMVar
    <*> newIORef mempty

-- | Request a worker number adjustment
--
-- Warning: non-concurrent operation
changeDesiredWorkersCount :: (MonadUnliftIO m) => WorkQueue -> Int -> m ()
changeDesiredWorkersCount wq n = do
  ensureRunning wq
  refWorkers <- readIORef wq.maxWorkers
  when (n > 0) $ do
    writeIORef wq.maxWorkers n
    if refWorkers < n
      then signalQSemN wq.availableWorkers $ n - refWorkers
      else
        void $
          async' wq $
            waitQSemN wq.availableWorkers $
              refWorkers - n

-- | Request stopping wokers
stopWorkQueue :: (MonadUnliftIO m) => WorkQueue -> m ()
stopWorkQueue wq = do
  stopped <- isStopedWorkQueue wq
  unless stopped $ do
    void $ tryPutMVar wq.stopped ()

-- | Non-blocking check of the work queue's running status
isStopedWorkQueue :: (MonadUnliftIO m) => WorkQueue -> m Bool
isStopedWorkQueue wq = not <$> isEmptyMVar wq.stopped

type WaitingStopStrategy m = WorkQueue -> m ()

-- | Block until the queue is totally stopped (no more running worker)
waitingStopFinishWorkers :: (MonadUnliftIO m) => WaitingStopStrategy m
waitingStopFinishWorkers wq =
  void $
    retryBlocked 10 $ do
      readMVar wq.stopped
      let waitWorkerCompletion = do
            workers <- readIORef wq.inflightWorkers
            unless (HM.null workers) $ do
              forM_ (HM.elems workers) waitCatch
              atomicModifyIORef wq.inflightWorkers $ \ws ->
                (foldr HM.delete ws $ HM.keys workers, ())
              threadDelay 10000
              waitWorkerCompletion

      waitWorkerCompletion
      workersCount <- atomicModifyIORef' wq.maxWorkers (0,)
      waitQSemN wq.availableWorkers workersCount

-- | Block until the queue is totally stopped or deadline (in micro seconds) is reached
waitingStopTimeout :: (MonadUnliftIO m) => Int -> WaitingStopStrategy m
waitingStopTimeout delay wq = void $ timeout delay $ waitingStopFinishWorkers wq

-- | Enqueue one action in the work queue (non-blocking)
--
-- Throws 'WorkQueueStoppedException' if the work queue is stopped
enqueue :: (MonadUnliftIO m) => WorkQueue -> m () -> m ()
enqueue wq = void . enqueueTracking wq

-- | Enqueue one action in the work queue (non-blocking)
--
-- Throws 'WorkQueueStoppedException' if the work queue is stopped
enqueueTracking :: (MonadUnliftIO m) => WorkQueue -> m a -> m (Async a)
enqueueTracking wq f = do
  ensureRunning wq
  enqueueTrackingAfterUnsafe wq (return ()) f

-- | Block until one worker is available
waitReadyQueue :: (MonadUnliftIO m) => WorkQueue -> m ()
waitReadyQueue wq = do
  ensureRunning wq
  waitQSemN wq.availableWorkers 1
  signalQSemN wq.availableWorkers 1

-- | Enqueue action and some actions to be run after it
--
-- Throws 'WorkQueueStoppedException' if the work queue is stopped
enqueueAfter :: (Traversable f, MonadUnliftIO m) => WorkQueue -> m () -> f (m ()) -> m ()
enqueueAfter wq x xs = void $ enqueueAfterTracking wq x xs

-- | Enqueue action and some actions to be run after it
--
-- Throws 'WorkQueueStoppedException' if the work queue is stopped
enqueueAfterTracking :: (Traversable f, MonadUnliftIO m) => WorkQueue -> m a -> f (m b) -> m (Async a, f (Async b))
enqueueAfterTracking wq x xs = do
  rm <- enqueueTracking wq x
  st <- forM xs $ enqueueTrackingAfterUnsafe wq (wait rm)
  return (rm, st)

-- Support (internal)
data WorkQueue = WorkQueue
  { name :: String,
    availableWorkers :: QSemN,
    maxWorkers :: IORef Int,
    stopped :: MVar (),
    inflightWorkers :: IORef (HM.HashMap ThreadId (Async ()))
  }

-- | Ensure the queue is stopped
--
-- Throws 'WorkQueueStoppedException' if not
ensureRunning :: (MonadUnliftIO m) => WorkQueue -> m ()
ensureRunning wq = do
  stopped <- isStopedWorkQueue wq
  when stopped $
    throwIO $
      WorkQueueStoppedException wq.name

newtype WorkQueueStoppedException = WorkQueueStoppedException {stoppedWorkQueue :: String}
  deriving stock (Eq, Show)

instance Exception WorkQueueStoppedException

-- | Enqueue one action in the work queue (non-blocking)
--
-- Does not check if the queue is stopping
enqueueTrackingAfterUnsafe :: forall a m i. (MonadUnliftIO m) => WorkQueue -> m i -> m a -> m (Async a)
enqueueTrackingAfterUnsafe wq prerequisite f = do
  task <-
    async' wq $ do
      threadId <- myThreadId
      void prerequisite
      bracket_
        (waitQSemN wq.availableWorkers 1)
        ( signalQSemN wq.availableWorkers 1
            >> atomicModifyIORef wq.inflightWorkers (\ws -> (HM.delete threadId ws, ()))
        )
        f
  atomicModifyIORef wq.inflightWorkers (\ws -> (HM.insert (asyncThreadId task) (task $> ()) ws, ()))
  return task

-- | Start and label a thread
async' :: (MonadUnliftIO m) => WorkQueue -> m a -> m (Async a)
async' wq f = do
  t <- async f
  liftIO $ labelThread (asyncThreadId t) wq.name
  return t

retryBlocked :: (MonadUnliftIO m) => Int -> m a -> m (Either BlockedIndefinitelyOnMVar a)
retryBlocked n f = do
  r <- try f
  case r of
    Left BlockedIndefinitelyOnMVar
      | n > 0 -> threadDelay 1000 >> retryBlocked (n - 1) f
      | otherwise -> try f
    Right x -> return $ Right x
