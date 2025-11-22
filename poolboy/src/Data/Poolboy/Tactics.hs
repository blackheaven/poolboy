--- |
-- Module      :  Data.Poolboy.Tactics
-- Copyright   :  Gautier DI FOLCO 2024-2025
-- License     :  ISC
--
-- Maintainer  :  foos@difolco.dev
-- Stability   :  experimental
-- Portability :  GHC
--
-- A simple set of concurrent primitives.
--

module Data.Poolboy.Tactics
  ( -- * Do not accumulate
    concurrentFoldable_,
    concurrentRecursive_,
    concurrentM_,

    -- * Accumulate
    concurrentFoldable,
    concurrentRecursive,
    concurrentRecursive',
    concurrentM,
  )
where

import Control.Monad (forM_, void)
import Data.Poolboy
import UnliftIO (MonadUnliftIO)
import UnliftIO.IORef

-- | Concurrently run a set of actions.
--
-- Warning: blocking
--
-- > concurrentFoldable_ defaultPoolboySettings [sendEmail, saveOrderDB, notifyUser]
concurrentFoldable_ ::
  (Foldable f, MonadUnliftIO m) =>
  PoolboySettings m ->
  f (m a) ->
  m ()
concurrentFoldable_ settings actions =
  withPoolboy settings waitingStopFinishWorkers $ \workQueue ->
    mapM_ (enqueue workQueue . void) actions

-- | Concurrently run a set of actions, recursively.
--
-- Warning: blocking
--
-- > concurrentRecursive_ defaultPoolboySettings listDirectories [listDirectories "."]
concurrentRecursive_ ::
  (Foldable f, MonadUnliftIO m) =>
  PoolboySettings m ->
  (a -> f (m a)) ->
  f (m a) ->
  m ()
concurrentRecursive_ settings recurse actions =
  withPoolboy settings waitingStopFinishWorkers $ \workQueue ->
    let wrap action = action >>= go . recurse
        go = mapM_ (enqueue workQueue . wrap)
     in go actions

-- | Concurrently run a dynamic set of actions until it gets a 'Nothing'.
--
-- Warning: blocking
--
-- > concurrentM_ defaultPoolboySettings waitNextRequest
concurrentM_ ::
  (MonadUnliftIO m) =>
  PoolboySettings m ->
  m (Maybe (m a)) ->
  m ()
concurrentM_ settings fetchNextAction =
  withPoolboy settings waitingStopFinishWorkers $ \workQueue ->
    let go = do
          mNextAction <- fetchNextAction
          forM_ mNextAction $ \nextAction -> do
            enqueue workQueue $ void nextAction
            go
     in go

-- | Concurrently run a set of actions, accumulating results.
--
-- Warning: blocking
--
-- Warning: results are collected in no particular order
--
-- > concurrentFoldable defaultPoolboySettings [sendEmail, saveOrderDB, notifyUser]
concurrentFoldable ::
  (Functor f, Foldable f, MonadUnliftIO m) =>
  PoolboySettings m ->
  f (m a) ->
  m [a]
concurrentFoldable settings actions = do
  accumulator <- newIORef mempty
  let accumulate action = do
        result <- action
        atomicModifyIORef' accumulator $ \acc -> (result : acc, ())
  concurrentFoldable_ settings $ accumulate <$> actions
  readIORef accumulator

-- | Concurrently run a set of actions, recursively, accumulating results.
--
-- Warning: blocking
--
-- Warning: results are collected in no particular order
--
-- > concurrentRecursive defaultPoolboySettings listDirectories [listDirectories "."]
concurrentRecursive ::
  (Functor f, Foldable f, MonadUnliftIO m) =>
  PoolboySettings m ->
  (a -> f (m a)) ->
  f (m a) ->
  m [a]
concurrentRecursive settings recurse actions =
  let dup x = (x, x)
      dups = fmap (fmap dup)
   in concurrentRecursive' settings (dups . recurse) (dups actions)

-- | Concurrently run a set of actions, recursively, accumulating results.
--
-- Warning: blocking
--
-- Warning: results are collected in no particular order
--
-- > concurrentRecursive' defaultPoolboySettings listDirectories [listDirectories "."]
concurrentRecursive' ::
  (Functor f, Foldable f, MonadUnliftIO m) =>
  PoolboySettings m ->
  (a -> f (m (a, b))) ->
  f (m (a, b)) ->
  m [b]
concurrentRecursive' settings recurse actions = do
  accumulator <- newIORef mempty
  let accumulate action = do
        (resultNext, resultAccumulate) <- action
        atomicModifyIORef' accumulator $ \acc -> (resultAccumulate : acc, ())
        return resultNext
  concurrentRecursive_ settings (fmap accumulate . recurse) $ accumulate <$> actions
  readIORef accumulator

-- | Concurrently run a dynamic set of actions until it gets a 'Nothing', accumulating results.
--
-- Warning: blocking
--
-- Warning: results are collected in no particular order
--
-- > concurrentM defaultPoolboySettings waitNextRequest
concurrentM ::
  (MonadUnliftIO m) =>
  PoolboySettings m ->
  m (Maybe (m a)) ->
  m [a]
concurrentM settings actions = do
  accumulator <- newIORef mempty
  let accumulate action = do
        result <- action
        atomicModifyIORef' accumulator $ \acc -> (result : acc, ())
  concurrentM_ settings $ fmap accumulate <$> actions
  readIORef accumulator
