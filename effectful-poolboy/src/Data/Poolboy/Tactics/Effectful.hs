-- |
-- Module      : Data.Poolboy.Tactics.Effectful
-- Copyright   :  Gautier DI FOLCO 2024-2025
-- License     :  ISC
--
-- Maintainer  :  foos@difolco.dev
-- Stability   :  experimental
-- Portability :  GHC
--
-- A simple set of concurrent primitives.
module Data.Poolboy.Tactics.Effectful
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

import qualified Data.Poolboy as PB
import qualified Data.Poolboy.Tactics as PB
import Effectful

-- | Concurrently run a set of actions.
--
-- Warning: blocking
--
-- > concurrentFoldable_ defaultPoolboySettings [sendEmail, saveOrderDB, notifyUser]
concurrentFoldable_ ::
  (Foldable f, Functor f, IOE :> es) =>
  PB.PoolboySettings (Eff es) ->
  f (Eff es a) ->
  Eff es ()
concurrentFoldable_ settings actions =
  withEffToIO (ConcUnlift Ephemeral Unlimited) $ \(toIO :: forall b. Eff es b -> IO b) -> do
    PB.concurrentFoldable_ (PB.hoistPoolboySettings toIO settings) (toIO <$> actions)

-- | Concurrently run a set of actions, recursively.
--
-- Warning: blocking
--
-- > concurrentRecursive_ defaultPoolboySettings listDirectories [listDirectories "."]
concurrentRecursive_ ::
  (Foldable f, Functor f, IOE :> es) =>
  PB.PoolboySettings (Eff es) ->
  (a -> f (Eff es a)) ->
  f (Eff es a) ->
  Eff es ()
concurrentRecursive_ settings recurse actions =
  withEffToIO (ConcUnlift Ephemeral Unlimited) $ \(toIO :: forall b. Eff es b -> IO b) -> do
    PB.concurrentRecursive_ (PB.hoistPoolboySettings toIO settings) ((toIO <$>) . recurse) (toIO <$> actions)

-- | Concurrently run a dynamic set of actions until it gets a 'Nothing'.
--
-- Warning: blocking
--
-- > concurrentM_ defaultPoolboySettings waitNextRequest
concurrentM_ ::
  (IOE :> es) =>
  PB.PoolboySettings (Eff es) ->
  Eff es (Maybe (Eff es a)) ->
  Eff es ()
concurrentM_ settings fetchNextAction =
  withEffToIO (ConcUnlift Ephemeral Unlimited) $ \(toIO :: forall b. Eff es b -> IO b) -> do
    PB.concurrentM_ (PB.hoistPoolboySettings toIO settings) (toIO $ fmap toIO <$> fetchNextAction)

-- | Concurrently run a set of actions, accumulating results.
--
-- Warning: blocking
--
-- Warning: results are collected in no particular order
--
-- > concurrentFoldable defaultPoolboySettings [sendEmail, saveOrderDB, notifyUser]
concurrentFoldable ::
  (Functor f, Foldable f, IOE :> es) =>
  PB.PoolboySettings (Eff es) ->
  f (Eff es a) ->
  Eff es [a]
concurrentFoldable settings actions = do
  withEffToIO (ConcUnlift Ephemeral Unlimited) $ \(toIO :: forall b. Eff es b -> IO b) -> do
    PB.concurrentFoldable (PB.hoistPoolboySettings toIO settings) (toIO <$> actions)

-- | Concurrently run a set of actions, recursively, accumulating results.
--
-- Warning: blocking
--
-- Warning: results are collected in no particular order
--
-- > concurrentRecursive defaultPoolboySettings listDirectories [listDirectories "."]
concurrentRecursive ::
  (Functor f, Foldable f, IOE :> es) =>
  PB.PoolboySettings (Eff es) ->
  (a -> f (Eff es a)) ->
  f (Eff es a) ->
  Eff es [a]
concurrentRecursive settings recurse actions =
  withEffToIO (ConcUnlift Ephemeral Unlimited) $ \(toIO :: forall b. Eff es b -> IO b) -> do
    PB.concurrentRecursive (PB.hoistPoolboySettings toIO settings) ((toIO <$>) . recurse) (toIO <$> actions)

-- | Concurrently run a set of actions, recursively, accumulating results.
--
-- Warning: blocking
--
-- Warning: results are collected in no particular order
--
-- > concurrentRecursive' defaultPoolboySettings listDirectories [listDirectories "."]
concurrentRecursive' ::
  (Functor f, Foldable f, IOE :> es) =>
  PB.PoolboySettings (Eff es) ->
  (a -> f (Eff es (a, b))) ->
  f (Eff es (a, b)) ->
  Eff es [b]
concurrentRecursive' settings recurse actions = do
  withEffToIO (ConcUnlift Ephemeral Unlimited) $ \(toIO :: forall b. Eff es b -> IO b) -> do
    PB.concurrentRecursive' (PB.hoistPoolboySettings toIO settings) ((toIO <$>) . recurse) (toIO <$> actions)

-- | Concurrently run a dynamic set of actions until it gets a 'Nothing', accumulating results.
--
-- Warning: blocking
--
-- Warning: results are collected in no particular order
--
-- > concurrentM defaultPoolboySettings waitNextRequest
concurrentM ::
  (IOE :> es) =>
  PB.PoolboySettings (Eff es) ->
  Eff es (Maybe (Eff es a)) ->
  Eff es [a]
concurrentM settings fetchNextAction = do
  withEffToIO (ConcUnlift Ephemeral Unlimited) $ \(toIO :: forall b. Eff es b -> IO b) -> do
    PB.concurrentM (PB.hoistPoolboySettings toIO settings) (toIO $ fmap toIO <$> fetchNextAction)
