{-# LANGUAGE NumericUnderscores #-}

module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait)
import Data.IORef
import qualified Data.Poolboy as PB
import Data.Poolboy.Effectful
import Effectful
import Test.Hspec

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "Effectful Poolboy Wrapper" $ do
    it "enqueueEff runs an Eff action" $ do
      res <-
        runEff $
          withPoolboy
            PB.defaultPoolboySettings
            PB.waitingStopFinishWorkers
            ( \wq -> do
                r <- newIORefEff (0 :: Int)
                enqueue wq (writeIORefEff r 42)
                liftIO $ threadDelay 100_000
                readIORefEff r
            )
      res `shouldBe` 42

    it "enqueueTrackingEff returns Async with correct result" $ do
      res <-
        runEff $
          withPoolboy
            PB.defaultPoolboySettings
            PB.waitingStopFinishWorkers
            ( \wq -> do
                a <- enqueueTracking wq (pure @(Eff _) (99 :: Int))
                liftIO (wait a)
            )
      res `shouldBe` 99

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

newIORefEff :: (IOE :> es) => a -> Eff es (IORef a)
newIORefEff = liftIO . newIORef

writeIORefEff :: (IOE :> es) => IORef a -> a -> Eff es ()
writeIORefEff r x = liftIO $ writeIORef r x

readIORefEff :: (IOE :> es) => IORef a -> Eff es a
readIORefEff r = liftIO $ readIORef r
