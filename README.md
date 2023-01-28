# poolboy

Simple work queue for bounded concurrency

## Example

```haskell
withPoolboy defaultPoolboySettings $ \workQueue ->
   mapM_ (enqueue workQueue . execQuery insertBookQuery) books
```

