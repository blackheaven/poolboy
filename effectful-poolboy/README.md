# effectful-poolboy

Simple work queue for bounded concurrency (effectful-style)

## Example

```haskell
runEff $ runIOE $ withPoolboyEff mySettings PB.waitingStopFinishWorkers $ \wq -> do
  enqueueEff wq (putStrLn "hello from an Eff job")
  a <- enqueueTrackingEff wq (pure (42 :: Int))
  r <- liftIO $ wait a
  liftIO $ print r
```

