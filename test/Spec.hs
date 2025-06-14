module Main (main) where

import Control.Concurrent
import Control.Exception (Exception (..), throw)
import Control.Monad
import Data.IORef
import Data.Maybe
import Data.Poolboy
import System.TimeIt
import System.Timeout
import Test.Hspec

main :: IO ()
main = hspec spec

spec :: Spec
spec =
  describe "Poolboy" $ do
    replicateM_ 1 $
      it "threadDelay should be absorbed in mulitple threads" $ do
        (duration, computations) <-
          timeItT $
            timeout 250000 $
              withPoolboy (poolboySettingsWith 100) waitingStopFinishWorkers $ \wq -> do
                replicateM_ 100 $ enqueue wq $ threadDelay 1000
        computations `shouldSatisfy` isJust
        duration `shouldSatisfy` (< 20000)
    replicateM_ 1 $
      it "should be resilient to errors and Exceptions" $ do
        witness <- newIORef False
        (duration, computations) <-
          timeItT $
            timeout 1000000 $
              withPoolboy (poolboySettingsWith 5) waitingStopFinishWorkers $ \wq -> do
                mapM_ (enqueue wq) [error "an error", throw RandomException, writeIORef witness True]
        computations `shouldSatisfy` isJust
        duration `shouldSatisfy` (< 20000)
        readIORef witness `shouldReturn` True
    replicateM_ 1 $
      it "enqueueing when working on a stopping work queue should run all jobs" $ do
        counter <- newIORef @Int 0
        let incr = do
              threadDelay 100
              atomicModifyIORef' counter (\n -> (n + 1, ()))
        (duration, computations) <-
          timeItT $
            timeout 100000000 $
              withPoolboy (poolboySettingsWith 10) waitingStopFinishWorkers $ \wq -> do
                replicateM_ 10 $
                  enqueueAfter wq incr $
                    replicate 10 incr
        computations `shouldSatisfy` isJust
        duration `shouldSatisfy` (< 2000)
        readIORef counter `shouldReturn` 110

data RandomException = RandomException
  deriving (Show)

instance Exception RandomException
