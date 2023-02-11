module Main (main) where

import Control.Concurrent
import Control.Concurrent.STM.TQueue
import Control.Exception (Exception (..), throw)
import Control.Exception.Safe (bracket, tryAny)
import Control.Monad
import Control.Monad.STM
import Data.IORef
import Data.Maybe
import System.Timeout
import Test.Hspec

main :: IO ()
main = hspec spec

spec :: Spec
spec =
  describe "Poolboy" $ do
    xit "threadDelay should be absorbed in mulitple threads" $ do
      computations <-
        timeout 100000 $
          withPoolboy (poolboySettingsWith 100) $ \wq ->
            replicateM_ 1000 $ enqueue wq $ threadDelay 1000
      computations `shouldSatisfy` isJust
    it "should be resilient to errors and Exceptions" $ do
      witness <- newIORef False
      computations <-
        timeout 10000 $
          withPoolboy (poolboySettingsWith 1) $ \wq -> do
            mapM_ (enqueue wq) [error "an error", throw RandomException, writeIORef witness True]
            threadDelay 100
      computations `shouldSatisfy` isJust
      readIORef witness `shouldReturn` True

data RandomException = RandomException
  deriving (Show)

instance Exception RandomException

-- Public
newtype PoolboySettings = PoolboySettings
  { workersCount :: WorkersCountSettings
  }

data WorkersCountSettings
  = CapabilitiesWCS
  | FixedWCS Int
  deriving stock (Eq, Show)

_defaultPoolboySettings :: PoolboySettings
_defaultPoolboySettings =
  PoolboySettings
    { workersCount = CapabilitiesWCS
    }

poolboySettingsWith :: Int -> PoolboySettings
poolboySettingsWith = PoolboySettings . FixedWCS

withPoolboy :: PoolboySettings -> (WorkQueue -> IO a) -> IO a
withPoolboy settings = bracket (newPoolboy settings) (\wq -> stopWorkQueue wq >> waitStopWorkQueue wq)

newPoolboy :: PoolboySettings -> IO WorkQueue
newPoolboy settings = do
  logLock <- newMVar ()
  let log x =
        withMVar logLock $ \() -> do
          putStrLn x
          return ()

  wq <-
    WorkQueue
      <$> newTQueueIO
      <*> newTQueueIO
      <*> newIORef 0
      <*> newEmptyMVar
      <*> return log

  count <-
    case settings.workersCount of
      CapabilitiesWCS -> getNumCapabilities
      FixedWCS x -> return x
  changeDesiredWorkersCount wq count
  void $ forkIO $ controller wq

  return wq

changeDesiredWorkersCount :: WorkQueue -> Int -> IO ()
changeDesiredWorkersCount wq =
  atomically . writeTQueue wq.commands . ChangeDesiredWorkersCount

stopWorkQueue :: WorkQueue -> IO ()
stopWorkQueue wq =
  atomically $ writeTQueue wq.commands Stop

_isStopWorkQueue :: WorkQueue -> IO Bool
_isStopWorkQueue wq =
  not <$> isEmptyMVar wq.stopped

waitStopWorkQueue :: WorkQueue -> IO ()
waitStopWorkQueue wq =
  readMVar wq.stopped

enqueue :: WorkQueue -> IO () -> IO ()
enqueue wq =
  atomically . writeTQueue wq.queue . Right

-- private
data WorkQueue = WorkQueue
  { commands :: TQueue Commands,
    queue :: TQueue (Either () (IO ())),
    workersCount :: IORef Int,
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
  print command
  case command of
    ChangeDesiredWorkersCount n -> do
      currentCount <- readIORef wq.workersCount
      let diff = currentCount - n
      if diff > 0
        then replicateM_ diff stopOneWorker
        else replicateM_ (abs diff) $ do
          wq.log "Pre-fork"
          forkIO $ worker wq
      controller wq
    Stop -> do
      currentCount <- readIORef wq.workersCount
      wq.log $ "Stopping " <> show currentCount <> " workers"
      replicateM_ currentCount stopOneWorker

worker :: WorkQueue -> IO ()
worker wq = do
  wq.log "New worker"
  newCount <- atomicModifyIORef' wq.workersCount $ \n -> (n + 1, n + 1)
  wq.log $ "New worker count " <> show newCount
  let loop = do
        command <- atomically $ readTQueue wq.queue
        case command of
          Left () -> do
            wq.log "Stopping"
            remaining <-
              atomicModifyIORef' wq.workersCount $ \n ->
                let newCount = max 0 (n - 1) in (newCount, newCount)
            print remaining
            when (remaining == 0) $
              void $ tryPutMVar wq.stopped ()
          Right act -> wq.log "pop" >> void (tryAny act) >> wq.log "poped" >> loop
  loop
