{-# LANGUAGE StrictData #-}
{-# LANGUAGE TupleSections #-}

--- |
-- Module      :  Data.Poolboy
-- Copyright   :  Gautier DI FOLCO 2024-2025
-- License     :  ISC
--
-- Maintainer  :  foos@difolco.dev
-- Stability   :  experimental
-- Portability :  GHC
--
-- A simple work queue for bounded concurrency.
--
-- @
-- withPoolboy defaultPoolboySettings waitingStopFinishWorkers $ \workQueue ->
--    mapM_ (enqueue workQueue . execQuery insertBookQuery) books
-- @
--

module Data.Poolboy
  ( -- * Configuration
    PoolboySettings (..),
    WorkersCountSettings (..),
    PoolboyCommand (..),
    defaultPoolboySettings,
    poolboySettingsWith,
    poolboySettingsName,
    poolboySettingsLog,
    hoistPoolboySettings,

    -- * Running
    WorkQueue,
    withPoolboy,
    newPoolboy,
    hoistWorkQueue,

    -- * Driving
    changeDesiredWorkersCount,
    waitReadyQueue,

    -- * Stopping
    stopWorkQueue,
    isStoppedWorkQueue,
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
import Data.Maybe (fromMaybe, isJust, listToMaybe)
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
data PoolboySettings m = PoolboySettings
  { workersCount :: WorkersCountSettings,
    workQueueName :: String,
    logger :: PoolboyCommand -> m ()
  }

-- | Change 'PoolboySettings' monad
hoistPoolboySettings :: (forall a. m a -> n a) -> PoolboySettings m -> PoolboySettings n
hoistPoolboySettings hoist PoolboySettings {..} = PoolboySettings {logger = hoist . logger, ..}

-- | Initial number of threads
data WorkersCountSettings
  = -- | 'getNumCapabilities' based number
    CapabilitiesWCS
  | FixedWCS Int -- arbitrary number
  deriving stock (Eq, Show)

-- | Commands performed on the queue
data PoolboyCommand
  = CreatePool ThreadId
  | ChangeDesiredWorkersCount ThreadId Int
  | SetMaxWorkersCount ThreadId Int
  | AddAvailableWorkers ThreadId Int
  | WaitAvailableWorkers ThreadId Int
  | SetStoppedWorkQueue ThreadId
  | WaitingStopFinishWorkers ThreadId
  | WaitingWorkersCompletion ThreadId [ThreadId]
  | ResetMaxWorkers ThreadId
  | EmptyAvailableWorkers ThreadId Int
  | WaitReady ThreadId
  | EnqueueAfter ThreadId
  | Enqueue ThreadId
  | EnsureRunning ThreadId Bool
  | SpawnTask ThreadId
  | WaitAvailableWorker ThreadId
  | StartTask ThreadId
  | CompleteTask ThreadId
  | EnqueueRegisterTask ThreadId ThreadId
  deriving stock (Eq, Show)

-- | Usual configuration 'CapabilitiesWCS' and no name
defaultPoolboySettings :: (HasCallStack, Monad m) => PoolboySettings m
defaultPoolboySettings =
  withFrozenCallStack $
    PoolboySettings
      { workersCount = CapabilitiesWCS,
        workQueueName =
          case listToMaybe $ getCallStack callStack of
            Nothing -> "<no name>"
            Just (f, loc) -> "<no name> created in " <> f <> ", called at " <> prettySrcLoc loc,
        logger = const $ return ()
      }

-- | Arbitrary-numbered of workers settings
poolboySettingsWith :: (HasCallStack, Monad m) => Int -> PoolboySettings m
poolboySettingsWith c = defaultPoolboySettings {workersCount = FixedWCS c}

-- | Name of the work queue settings (used in error and debugging)
poolboySettingsName :: String -> PoolboySettings m -> PoolboySettings m
poolboySettingsName n s = s {workQueueName = n}

-- | Name of the work queue settings (used in error and debugging)
poolboySettingsLog :: (Functor m) => (PoolboyCommand -> m a) -> PoolboySettings m -> PoolboySettings m
poolboySettingsLog f s = s {logger = void . f}

-- | 'backet'-based usage (recommended)
withPoolboy :: (MonadUnliftIO m) => PoolboySettings m -> WaitingStopStrategy m -> (WorkQueue m -> m a) -> m a
withPoolboy settings waitStopWorkQueue =
  bracket
    (newPoolboy settings)
    (\wq -> stopWorkQueue wq >> waitStopWorkQueue wq)

-- | Standalone/manual usage
newPoolboy :: (MonadIO m) => PoolboySettings m -> m (WorkQueue m)
newPoolboy settings = do
  settings.logger . CreatePool =<< myThreadId

  count <-
    case settings.workersCount of
      CapabilitiesWCS -> getNumCapabilities
      FixedWCS x -> return x

  WorkQueue settings.workQueueName (\c -> settings.logger . c =<< myThreadId)
    <$> newQSemN count
    <*> newIORef count
    <*> newEmptyMVar
    <*> newIORef mempty

-- | Request a worker number adjustment
--
-- Warning: non-concurrent operation
changeDesiredWorkersCount :: (MonadUnliftIO m) => WorkQueue m -> Int -> m ()
changeDesiredWorkersCount wq n = do
  wq.onCommand $ flip ChangeDesiredWorkersCount n
  ensureRunning wq
  refWorkers <- readIORef wq.maxWorkers
  when (n > 0) $ do
    wq.onCommand $ flip SetMaxWorkersCount n
    writeIORef wq.maxWorkers n
    if refWorkers < n
      then do
        wq.onCommand $ flip AddAvailableWorkers $ n - refWorkers
        signalQSemN wq.availableWorkers $ n - refWorkers
      else void $
        async' wq $ do
          wq.onCommand $ flip WaitAvailableWorkers $ refWorkers - n
          waitQSemN wq.availableWorkers $
            refWorkers - n

-- | Request stopping wokers
stopWorkQueue :: (MonadIO m) => WorkQueue m -> m ()
stopWorkQueue wq = do
  stopped <- isStoppedWorkQueue wq
  unless stopped $ do
    wq.onCommand SetStoppedWorkQueue
    void $ tryPutMVar wq.stopped ()

-- | Non-blocking check of the work queue's running status
isStoppedWorkQueue :: (MonadIO m) => WorkQueue m -> m Bool
isStoppedWorkQueue wq = not <$> isEmptyMVar wq.stopped

type WaitingStopStrategy m = WorkQueue m -> m ()

-- | Block until the queue is totally stopped (no more running worker)
waitingStopFinishWorkers :: (MonadUnliftIO m) => WaitingStopStrategy m
waitingStopFinishWorkers wq =
  void $ do
    wq.onCommand WaitingStopFinishWorkers
    retryBlocked 10 $ do
      readMVar wq.stopped
      let waitWorkerCompletion = do
            workers <- readIORef wq.inflightWorkers
            unless (HM.null workers) $ do
              wq.onCommand $ flip WaitingWorkersCompletion $ HM.keys workers
              forM_ (HM.elems workers) $ mapM_ waitCatch
              atomicModifyIORef wq.inflightWorkers $ \ws ->
                (foldr HM.delete ws $ HM.keys $ HM.filter isJust workers, ())
              threadDelay 10000
              waitWorkerCompletion

      waitWorkerCompletion
      wq.onCommand ResetMaxWorkers
      workersCount <- atomicModifyIORef' wq.maxWorkers (0,)
      wq.onCommand $ flip EmptyAvailableWorkers workersCount
      waitQSemN wq.availableWorkers workersCount

-- | Block until the queue is totally stopped or deadline (in micro seconds) is reached
waitingStopTimeout :: (MonadUnliftIO m) => Int -> WaitingStopStrategy m
waitingStopTimeout delay wq = void $ timeout delay $ waitingStopFinishWorkers wq

-- | Enqueue one action in the work queue (non-blocking)
--
-- Throws 'WorkQueueStoppedException' if the work queue is stopped
enqueue :: (MonadUnliftIO m) => WorkQueue m -> m () -> m ()
enqueue wq = void . enqueueTracking wq

-- | Enqueue one action in the work queue (non-blocking)
--
-- Throws 'WorkQueueStoppedException' if the work queue is stopped
enqueueTracking :: (MonadUnliftIO m) => WorkQueue m -> m a -> m (Async a)
enqueueTracking wq f = do
  ensureRunning wq
  enqueueTrackingAfterUnsafe wq (return ()) f

-- | Block until one worker is available
waitReadyQueue :: (MonadUnliftIO m) => WorkQueue m -> m ()
waitReadyQueue wq = do
  wq.onCommand WaitReady
  ensureRunning wq
  waitQSemN wq.availableWorkers 1
  signalQSemN wq.availableWorkers 1

-- | Enqueue action and some actions to be run after it
--
-- Throws 'WorkQueueStoppedException' if the work queue is stopped
enqueueAfter :: (Traversable f, MonadUnliftIO m) => WorkQueue m -> m () -> f (m ()) -> m ()
enqueueAfter wq x xs = void $ enqueueAfterTracking wq x xs

-- | Enqueue action and some actions to be run after it
--
-- Throws 'WorkQueueStoppedException' if the work queue is stopped
enqueueAfterTracking :: (Traversable f, MonadUnliftIO m) => WorkQueue m -> m a -> f (m b) -> m (Async a, f (Async b))
enqueueAfterTracking wq x xs = do
  wq.onCommand EnqueueAfter
  mainRef <- newEmptyMVar
  st <- forM xs $ enqueueTrackingAfterUnsafe wq (wait =<< readMVar mainRef)
  rm <- enqueueTracking wq x
  putMVar mainRef rm
  return (rm, st)

-- Support (internal)
data WorkQueue m = WorkQueue
  { name :: String,
    onCommand :: (ThreadId -> PoolboyCommand) -> m (),
    availableWorkers :: QSemN,
    maxWorkers :: IORef Int,
    stopped :: MVar (),
    inflightWorkers :: IORef (HM.HashMap ThreadId (Maybe (Async ())))
  }

-- | Change 'WorkQueue' monad
hoistWorkQueue :: (forall a. m a -> n a) -> WorkQueue m -> WorkQueue n
hoistWorkQueue hoist WorkQueue {..} = WorkQueue {onCommand = hoist . onCommand, ..}

-- | Ensure the queue is stopped
--
-- Throws 'WorkQueueStoppedException' if not
ensureRunning :: (MonadUnliftIO m) => WorkQueue m -> m ()
ensureRunning wq = do
  stopped <- isStoppedWorkQueue wq
  threadId <- myThreadId
  workers <- readIORef wq.inflightWorkers
  let isRunning = not stopped || HM.member threadId workers
  wq.onCommand $ flip EnsureRunning isRunning
  unless isRunning $
    throwIO $
      WorkQueueStoppedException wq.name

newtype WorkQueueStoppedException = WorkQueueStoppedException {stoppedWorkQueue :: String}
  deriving stock (Eq, Show)

instance Exception WorkQueueStoppedException

-- | Enqueue one action in the work queue (non-blocking)
--
-- Does not check if the queue is stopping
enqueueTrackingAfterUnsafe :: forall a m i. (MonadUnliftIO m) => WorkQueue m -> m i -> m a -> m (Async a)
enqueueTrackingAfterUnsafe wq prerequisite f = do
  wq.onCommand Enqueue
  let register f' = atomicModifyIORef wq.inflightWorkers (\ws -> (f' ws, ()))
  task <-
    async' wq $ do
      wq.onCommand SpawnTask
      threadId <- myThreadId
      register $ HM.alter (Just . fromMaybe Nothing) threadId
      void prerequisite
      bracket_
        ( wq.onCommand WaitAvailableWorker
            >> waitQSemN wq.availableWorkers 1
            >> wq.onCommand StartTask
        )
        ( wq.onCommand CompleteTask
            >> atomicModifyIORef wq.inflightWorkers (\ws -> (HM.delete threadId ws, ()))
            >> signalQSemN wq.availableWorkers 1
        )
        f
  wq.onCommand $ flip EnqueueRegisterTask (asyncThreadId task)
  register $ HM.insert (asyncThreadId task) (Just $ task $> ())
  return task

-- | Start and label a thread
async' :: (MonadUnliftIO m) => WorkQueue m -> m a -> m (Async a)
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
