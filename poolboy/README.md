# poolboy

Simple work queue for bounded concurrency

## Example

```haskell
withPoolboy defaultPoolboySettings waitingStopFinishWorkers $ \workQueue ->
   mapM_ (enqueue workQueue . execQuery insertBookQuery) books
```

