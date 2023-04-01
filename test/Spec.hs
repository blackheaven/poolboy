module Main (main) where

import Control.Concurrent
import Control.Exception (Exception (..), throw)
import Control.Monad
import Data.IORef
import Data.Maybe
import Data.Poolboy
import System.Timeout
import Test.Hspec

main :: IO ()
main = hspec spec

spec :: Spec
spec =
  describe "Poolboy" $ do
    it "threadDelay should be absorbed in mulitple threads" $ do
      computations <-
        timeout 2500 $
          withPoolboy (poolboySettingsWith 100) waitingStopFinishWorkers $ \wq -> do
            replicateM_ 100 $ enqueue wq $ threadDelay 1000
      computations `shouldSatisfy` isJust
    replicateM_ 1 $
      it "should be resilient to errors and Exceptions" $ do
        witness <- newIORef False
        computations <-
          timeout 10000 $
            withPoolboy (poolboySettingsWith 5) waitingStopFinishWorkers $ \wq -> do
              mapM_ (enqueue wq) [error "an error", throw RandomException, writeIORef witness True]
        computations `shouldSatisfy` isJust
        readIORef witness `shouldReturn` True

data RandomException = RandomException
  deriving (Show)

instance Exception RandomException
