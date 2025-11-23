--- |
-- Module      :  Data.Poolboy.Effectful
-- Copyright   :  Gautier DI FOLCO 2025
-- License     :  ISC
--
-- Maintainer  :  foos@difolco.dev
-- Stability   :  experimental
-- Portability :  GHC
--
-- Thin Effectful wrapper around the existing poolboy library (Data.Poolboy).
--
-- @
-- withPoolboy defaultPoolboySettings waitingStopFinishWorkers $ \workQueue ->
--    mapM_ (enqueue workQueue . execQuery insertBookQuery) books
-- @
--

module Data.Poolboy.Effectful
  ( -- * Configuration
    PB.PoolboySettings (..),
    PB.WorkersCountSettings (..),
    PB.PoolboyCommand (..),
    PB.defaultPoolboySettings,
    PB.poolboySettingsWith,
    PB.poolboySettingsName,
    PB.poolboySettingsLog,

    -- * Running
    WorkQueue,
    withPoolboy,
    newPoolboy,
    PB.hoistWorkQueue,

    -- * Driving
    changeDesiredWorkersCount,
    waitReadyQueue,

    -- * Stopping
    stopWorkQueue,
    isStoppedWorkQueue,
    PB.WaitingStopStrategy,
    waitingStopTimeout,
    waitingStopFinishWorkers,

    -- * Enqueueing
    enqueue,
    enqueueTracking,
    enqueueAfter,
    enqueueAfterTracking,
    PB.WorkQueueStoppedException,
  )
where

import Control.Concurrent.Async (Async)
import qualified Data.Poolboy as PB
import Effectful

-- | Local wrapper type: hides the underlying PB.WorkQueue IO inside Eff.
newtype WorkQueue (es :: [Effect]) = WorkQueue (PB.WorkQueue IO)

--------------------------------------------------------------------------------
-- Bracket / creation
--------------------------------------------------------------------------------

-- | Bracket-like helper that runs poolboy's `withPoolboy` in IO while presenting
--   a `WorkQueue es` to the provided Eff callbacks.
withPoolboy ::
  forall es a.
  (IOE :> es) =>
  PB.PoolboySettings (Eff es) ->
  PB.WaitingStopStrategy (Eff es) ->
  (WorkQueue es -> Eff es a) ->
  Eff es a
withPoolboy settings waitStrat inner = do
  -- acquire a conversion Eff -> IO so we can run library code in IO threads
  withEffToIO (ConcUnlift Ephemeral Unlimited) $ \(toIO :: forall b. Eff es b -> IO b) -> do
    -- convert PoolboySettings (Eff es) -> PoolboySettings IO
    let settingsIO :: PB.PoolboySettings IO
        settingsIO = PB.hoistPoolboySettings toIO settings

    -- convert WaitingStopStrategy: PB.WorkQueue IO -> IO ()
    let waitStratIO :: PB.WorkQueue IO -> IO ()
        waitStratIO wqIO = toIO (waitStrat $ PB.hoistWorkQueue liftIO wqIO)

    -- run poolboy's withPoolboy in IO and convert the provided inner callback
    PB.withPoolboy settingsIO waitStratIO $ \wqIO -> do
      let wqEff = WorkQueue wqIO
      toIO (inner wqEff)

-- | Standalone/manual usage
newPoolboy ::
  forall es.
  (IOE :> es) =>
  PB.PoolboySettings (Eff es) ->
  Eff es (WorkQueue es)
newPoolboy settings = do
  withEffToIO (ConcUnlift Ephemeral Unlimited) $ \(toIO :: forall b. Eff es b -> IO b) -> do
    let settingsIO = PB.hoistPoolboySettings toIO settings
    wqIO <- liftIO $ PB.newPoolboy settingsIO
    pure (WorkQueue wqIO)

-- | Request a worker number adjustment
--
-- Warning: non-concurrent operation
changeDesiredWorkersCount :: (IOE :> es) => WorkQueue es -> Int -> Eff es ()
changeDesiredWorkersCount (WorkQueue wq) n = liftIO $ PB.changeDesiredWorkersCount wq n

-- | Request stopping wokers
stopWorkQueue :: (IOE :> es) => WorkQueue es -> Eff es ()
stopWorkQueue (WorkQueue wq) =
  -- underlying API expects m ~ IO, so just call in IO
  liftIO $ PB.stopWorkQueue wq

-- | Non-blocking check of the work queue's running status
isStoppedWorkQueue :: (IOE :> es) => WorkQueue es -> Eff es Bool
isStoppedWorkQueue (WorkQueue wq) = liftIO $ PB.isStoppedWorkQueue wq

-- | Block until the queue is totally stopped (no more running worker)
waitingStopFinishWorkers :: (IOE :> es) => PB.WaitingStopStrategy (Eff es)
waitingStopFinishWorkers wq =
  withEffToIO (ConcUnlift Ephemeral Unlimited) $ \(toIO :: forall b. Eff es b -> IO b) -> do
    PB.waitingStopFinishWorkers $ PB.hoistWorkQueue toIO wq

-- | Block until the queue is totally stopped or deadline (in micro seconds) is reached
waitingStopTimeout :: (IOE :> es) => Int -> PB.WaitingStopStrategy (Eff es)
waitingStopTimeout delay wq =
  withEffToIO (ConcUnlift Ephemeral Unlimited) $ \(toIO :: forall b. Eff es b -> IO b) -> do
    PB.waitingStopTimeout delay $ PB.hoistWorkQueue toIO wq

-- | Enqueue one action in the work queue (non-blocking)
--
-- Throws 'WorkQueueStoppedException' if the work queue is stopped
enqueue :: forall es. (IOE :> es) => WorkQueue es -> Eff es () -> Eff es ()
enqueue (WorkQueue wq) eff = do
  withEffToIO (ConcUnlift Ephemeral Unlimited) $ \(toIO :: forall b. Eff es b -> IO b) -> do
    -- PB.enqueue :: WorkQueue m -> m () -> m (); here m ~ IO
    liftIO $ PB.enqueue wq (toIO eff)

-- | Enqueue one action in the work queue (non-blocking)
--
-- Throws 'WorkQueueStoppedException' if the work queue is stopped
enqueueTracking :: forall es a. (IOE :> es) => WorkQueue es -> Eff es a -> Eff es (Async a)
enqueueTracking (WorkQueue wq) eff = do
  withEffToIO (ConcUnlift Ephemeral Unlimited) $ \(toIO :: forall b. Eff es b -> IO b) -> do
    -- PB.enqueueTracking :: WorkQueue m -> m a -> m (Async a)
    liftIO $ PB.enqueueTracking wq (toIO eff)

-- | Block until one worker is available
waitReadyQueue :: (IOE :> es) => WorkQueue es -> Eff es ()
waitReadyQueue (WorkQueue wq) = liftIO $ PB.waitReadyQueue wq

-- | Enqueue action and some actions to be run after it
--
-- Throws 'WorkQueueStoppedException' if the work queue is stopped
enqueueAfter ::
  forall t es.
  (Traversable t, IOE :> es) =>
  WorkQueue es ->
  Eff es () ->
  t (Eff es ()) ->
  Eff es ()
enqueueAfter (WorkQueue wq) before afters = do
  withEffToIO (ConcUnlift Ephemeral Unlimited) $ \(toIO :: forall b. Eff es b -> IO b) -> do
    liftIO $ PB.enqueueAfter wq (toIO before) (fmap toIO afters)

-- | Enqueue action and some actions to be run after it
--
-- Throws 'WorkQueueStoppedException' if the work queue is stopped
enqueueAfterTracking ::
  forall t a b es.
  (Traversable t, IOE :> es) =>
  WorkQueue es ->
  Eff es a ->
  t (Eff es b) ->
  Eff es (Async a, t (Async b))
enqueueAfterTracking (WorkQueue wq) before afters = do
  withEffToIO (ConcUnlift Ephemeral Unlimited) $ \(toIO :: forall c. Eff es c -> IO c) -> do
    liftIO $ PB.enqueueAfterTracking wq (toIO before) (fmap toIO afters)
