# Lifecycle and responsibility ownership

`ServerLifecycle` is the only owner of lifecycle decisions. It is a value with
no I/O or clock reads. `ServerManager` queues events, commits the resulting
state, publishes its presentation, then executes ordered effects. A synchronous
adapter completion joins the queue rather than recursively changing state
midway through the current effect batch.

Initial launching and readiness waiting are represented by `starting` with an
optional PID. Both display Starting; replacement attempts display Restarting.
Stopping stores its next action in the phase rather than in independent flags.
The automatic restart allowance is retained across replacement attempts and
reset by a manual start or the current healthy run's stability event.

## Transition table

All completion events require the current identity. A stale identity is ignored.
An event not accepted in its listed phase is ignored without effects. Start and
Restart are ignored after Quit. Quit is irreversible within an app lifetime.

| Event | Accepted phase | Result / effects |
| --- | --- | --- |
| Start | stopped, failed | starting without PID; launch |
| Restart | stopped, failed | starting with restart source; launch |
| Restart | starting, running | stopping(next: restart); cancel monitoring, terminate |
| Stop | starting, running, stopping | stopping(next: stop); cancel monitoring, terminate; pending Quit retains quit intent |
| Stop | stopped, failed, waiting | stopped; cancel monitoring and port wait |
| Quit | starting, running, stopping | stopping(next: quit); cancel monitoring, terminate |
| Quit | stopped, failed, waiting | stopped; cancel monitoring and complete queued quit callers |
| Launched | starting without PID | starting with PID; begin readiness polling |
| Launch failed | starting | failed; cancel monitoring, report once |
| Ready | starting with PID | running; stop progress sampling, arm stability timer, deliver pending restart notice |
| Unhealthy | running | stopping(next: failure); cancel monitoring, terminate |
| Exited | starting | failed; report launch failure once |
| Exited | stopping(next: stop) | stopped; cancel monitoring |
| Exited | stopping(next: quit) | stopped; cancel monitoring, complete queued quit callers |
| Exited | stopping(next: restart) | waiting; cancel monitoring, begin bounded port probe |
| Exited | running, stopping(next: failure) | waiting and consume restart allowance, or failed and report reason |
| Port available / wait elapsed | waiting | starting replacement under a new identity; launch |
| Stable | running | reset restart allowance |

A second readiness event, duplicate exit, or an old launch, health, timer, or
port result cannot advance a replacement. Readiness also requires that the
process driver still reports a live child. Launch checks that the requested
port is available before spawning, preventing an existing listener from being
mistaken for the new child. The probe uses `SO_REUSEADDR`, matching Splash, so
closed TIME_WAIT connections do not prevent restart. A bounded connection probe
also rejects overlapping wildcard/specific listeners that a reusable bind alone
can miss on macOS. There remains a race if a different process takes
the port after that probe; HTTP status alone does not prove socket ownership.
The child's eventual bind failure is handled as an exit.

The launch's port check runs on the main actor. An address is probed without a
lookup; only a host name is resolved, and a host name that resolves slowly can
hold the interface for that long. Moving the check off the main actor needs a
preflight event in the lifecycle and is not done.

## Resource and presentation boundaries

- `ProcessManager` validates and launches the child, retains the process handle,
  signals it, and reports exit only after the asynchronous log drain completes.
  Its run identity protects OS resources; it has no restart/failure intent flags.
- `ServerLogSession` opens the append descriptor, monitors and drains the serial
  reader, rotates/clears logs, and reports activity and performance. Rotation
  suspends the exact child whose descriptor is being copied; termination cancels
  rotation and resumes that child. Old drain/copy completions cannot mutate a
  replacement. `ServerLogDiagnostics` interprets bounded tails independently.
- `PortWaiter` owns the bounded probe timer, not restart policy. Cancellation
  invalidates its generation before removing the timer. The lifecycle decides
  whether its completion still permits a launch.
- `HealthChecker` owns HTTP polling and consecutive-failure aggregation. Events
  reaching the lifecycle are bound to the launch identity. Startup has no timeout.
- `StartupProgressMonitor` samples the captured launch configuration off the main
  actor. Cancellation and generation checks reject old results. Its timestamp
  belongs to that launch, including download-byte accounting.
- `ServerPresentation` owns performance scheduling and unloaded-weight display.
  Weight state is meaningful only while running and resets on transitions. Timer
  generations prevent canceled work from publishing into a later display state.
- `ServerPowerController` reconciles power, preference, and lifecycle presentation.
- `ServerReporter` delivers notifications. It does not own a deduplication or
  restart state machine; the lifecycle determines when a notice is due.
- `SettingsEditor` owns the draft, baseline, validation and asynchronous Apply.
  Closing/reverting invalidates pending Apply; edits and inspection identities
  reject stale results. The applied baseline cannot change underneath a draft.
  Pane files and shared rows render state and invoke editor actions. Window
  geometry, panels, clipboard operations and scene navigation remain in the view.

Force-kill timing remains an OS-resource detail in `ProcessManager`: repeated
termination requests do not extend its grace and it checks exact process/run
identity before signaling. Stability timing is executed by the facade; the
transition model decides whether the corresponding event is valid. Neither
adapter decides whether to restart.

## Validation and limits

Pure transition tests cover cancellation, stale events, restart budget,
notification timing, failure deduplication and irreversible Quit. Subprocess
integration tests retain coverage of signals, forced termination, descriptor
lifetime, rotation and final usage. Editor and progress tests control delayed
results instead of depending on inspection/network speed.

The real-Splash tests require explicit environment inputs. A skipped real-engine
test is not compatibility evidence. Interactive AppKit behavior and logout must
still be checked by the user; those checks do not block implementation of
independent refactor work.
