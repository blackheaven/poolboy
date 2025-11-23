## 0.5.0.0

* Add helpers on `WorkQueue` and `PoolboySettings` in `Data.Poolboy`
* Rename `isStopedWorkQueue` to `isStoppedWorkQueue` in `Data.Poolboy`

## 0.4.1.0

* Add helpers in `Data.Poolboy.Tactics`

## 0.4.0.1

* Fix race condition

## 0.4.0.0

* Fix race conditions
* Add command log for debugging
  * Add `PoolboyCommand`
  * Add `poolboySettingsLog`
  * Add `Monad` type parameters to `PoolboySettings` and `WorkQueue`

## 0.3.0.0

* Use `MonadUnliftIO` in functions
* Drop dedicated worker threads

## 0.2.2.0

* Rely on `unliftio` for exception handling

## 0.2.1.0

* Use `QSemN` to stop all workers at once

## 0.2.0.0

* Add `WaitingStopStrategy` and helper functions

## 0.1.0.1

* Fix missing `WorkQueue` export

## 0.1.0.0

* Initial version
