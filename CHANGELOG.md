# Changelog

All notable changes to the Tracker iOS SDK. Newest first.

---

## 1.0.0

### Licensing

Licences are now issued by the licence server, and the SDK's relationship to
them changed accordingly.

- **Tokens carry the `TRACKIT-` prefix.** The prefix sits outside the signed
  bytes, so licences already issued remain valid. `key_id` hashes the whole
  string, so it changes with the prefix.
- **Server-issued licences are accepted without a pinned public key.** When the
  SDK holds no key for a token's `kid` it checks the payload and the bundle
  rule, then defers to the server for validity. This is a deliberate
  weakening, recorded rather than hidden: an offline device can no longer tell
  a forged token from a genuine one. Tokens whose `kid` the SDK does hold are
  still verified in full, and pinning the issuer's public key restores full
  enforcement with no other change.
- **Key ids are split by issuer.** `kid 1` is the licence server; `kid 2` is
  the local development key. Both previously signed as `kid 1` with different
  keys, so every cross-issuer token failed as though it had been tampered
  with.
- **A withdrawn licence refuses to start.** Ending the session was not enough
  — a host could call `start()` again and carry on, which made the whole
  revocation path decorative. The block lifts when the server reports `active`
  again.
- **`revoked`, `expired` and `package_mismatch` stop tracking**, each arriving
  as an `ErrorCode` as well as `licenseDeactivated`. Two new codes:
  `licenseRevoked` and `licenseExpired`.

  > `package_mismatch` also stops tracking. On the current deployment an
  > *unregistered* licence receives that same status, so a missing ledger row
  > will stop a paying customer. Register every licence you issue.

- **The `/verify` response-signing key is compiled in, not fetched.** Asking
  the server for the key that proves its own answer let anyone owning the
  connection supply both halves.
- **Revocation is re-checked every six hours during a session**, not only at
  launch. Nothing is cached: the interval limits how often the server is
  asked, and never extends how long an old verdict is trusted.
- **`start()` reports why `ready()` refused** instead of "call `ready()`
  first".
- **A bundle mismatch no longer names the licensed bundle identifier.** It
  belongs to another customer, and the message reaches end users and support
  tickets.
- **The licence exchange logs at `notice`** — request, raw response, verdict.

### Battery

- **The first reading after enabling battery monitoring is re-read as it
  settles.** iOS returns a coarse or stale level for the first few hundred
  milliseconds, and because readings publish only on a transition, a wrong
  first value was the answer every host saw until the battery moved a whole
  percent. On a parked or fully charged phone that could be hours.
- The raw float is logged beside the derived percentage.

### Compatibility

No API was removed. `licenseRevoked` and `licenseExpired` are additive; hosts
switching exhaustively over `ErrorCode` will need to handle them.

### The SDK is now Tracker

**The SDK is now Tracker.** Every module, type and identifier that carried the
old name has moved. Nothing about the engine changed — the acceptance pipeline,
the Kalman filter, the motion machine and the plotting plane are the same code
passing the same golden fixtures — but the surface a host touches is renamed
throughout, so this is a rewrite of your integration, not a version bump.

### Modules

| Was | Now |
|---|---|
| `TrackItGeo` | `TrackerGeo` |
| `TrackItCore` | `TrackerCore` |
| `TrackItMaps` | `TrackerMaps` |
| `TrackItSnap` | `TrackerSnap` |
| `TrackItSync` | `TrackerSync` |

The package itself is `Tracker`. Update your `import` lines and the product
names in `Package.swift` or in Xcode's package dependency.

### Types

`TrackIt` → `Tracker`, `TrackItConfig` → `TrackerConfig`, `TrackItResult` →
`TrackerResult`, `TrackItEvent` → `TrackerEvent`, `TrackItState` →
`TrackerState`, `TrackItConfigError` → `TrackerConfigError`. The rule is
mechanical: the `TrackIt` prefix becomes `Tracker` and nothing else moves.

Types named after the *domain* rather than the product are unchanged —
`TrackFix`, `TrackPoint`, `TrackSession`, `Track`, `LiveTrackUpdate`,
`GeoPoint`, `Geofence` and the rest keep their names.

### Things you must change outside Swift

- **Background task identifiers.** `Info.plist` →
  `BGTaskSchedulerPermittedIdentifiers` must now list
  `com.fieldtrack360.tracker.backstop` and `com.fieldtrack360.tracker.sync`.
  Miss this and background work stops registering, silently — iOS refuses the
  registration and the SDK never gets its wake-ups.
- **Licence key.** The `Info.plist` key is now `TrackerLicense`, and the build
  setting in the README example is `TRACKER_LICENSE`.
- **Log subsystem.** `log stream --subsystem com.fieldtrack360.tracker`.

### Licence tokens must be reissued

Tokens now begin `TRACKER-` instead of `TRACKIT-`. **Every token issued before
this release is rejected**, with `licenseInvalid`. Ask for a replacement before
you ship a distributed build; development builds — the simulator, and anything
run from Xcode — still need no token at all.

### Your users' data is carried across

Three pieces of state outlive the app and were named after the old product.
Each is migrated on first launch, once, with no action from you:

- The database moves from `trackit.sqlite` to `tracker.sqlite`, with its `-wal`
  and `-shm` sidecars, so no committed write is lost.
- Persisted configuration and the "Always was already requested" flag are
  adopted from their old `UserDefaults` keys.
- The stationary fence is re-registered under a new region identifier, and the
  old region is released rather than left monitored against your 20-region
  budget.

Downgrading after upgrading is not supported: the old build cannot read the new
names, and it will start from an empty database.

### Sync configuration survives a cold start

`SyncEngine` holds the endpoint, the auth headers and the upload policy in
memory only, and nothing wrote them down. A force-kill left the app relaunching
with `isConfigured == false`, `endpoint == nil`, and a queue still full of points
that would never drain — no teardown called, no event emitted, nothing in the log
to explain it. A host that configured sync once at login silently stopped
uploading after every cold start.

`SyncConfig` is now `Codable`, so you can persist it yourself:

```swift
// At configure time
let data = try JSONEncoder().encode(config)   // → Keychain

// In your App initialiser, on every launch
let config = try JSONDecoder().decode(SyncConfig.self, from: data)
SyncEngine.shared.configure(config, store: store)
```

Decoding needs `url` and nothing else; every other key falls back to its
documented default, so a config stored by one version of the SDK still decodes
under another.

Two things to get right:

- **Keychain, not `UserDefaults`.** `headers` is encoded verbatim, bearer token
  included, and `UserDefaults` is a plist in the app container.
- **Delete your stored copy when you see `SyncEvent.authExpired`.** That event
  means a 401 tore the uploader down against a credential the server has already
  rejected; restoring it next launch earns the same 401 for the life of the
  install. It is also the only way to tell a teardown by 401 from a teardown by
  process death.

Persistence is deliberately not automatic — where a credential is stored is the
host's decision, and a token resurrected from disk would contradict the 401
teardown it is supposed to respect.

### Licences are now checked for revocation

`ready()` is unchanged: the licence is verified offline, the app starts without
touching the network, and that is still what licenses it. But a token carries no
expiry — it is a signed statement about an app id, not a lease — so it cannot say
whether a licence has been *withdrawn* since it was issued.

The SDK now asks, on every `ready()`, on a background task that blocks nothing:

```swift
case .licenseDeactivated(let status, let reason):
    // Tracking has already stopped by the time this arrives.
    showAlert("Your licence is \(status). \(reason ?? "")")
```

`status` is `revoked` or `expired`. The SDK calls `stop()` first and emits the
event second, so a host reacting to it never finds a tracker still running.

**Every other outcome keeps the tracker running** — no network, a signature that
fails, a reply about a different licence, a server error, a rate limit. A phone
in a tunnel is not a piracy problem, and stopping there would discard location
data no retry can recover.

The request carries the token, your bundle identifier, `ios`, the SDK version and
a random nonce. **No location data leaves the device** — there is no endpoint
that would accept a coordinate.

`TrackerEvent` gained one case, so a `switch` over it still needs
`@unknown default` — which it already did.

### Battery readings

Three ways to the same fact, so a diagnostics screen can answer "did tracking
stop because the OS killed us, or because the phone was at 3 %?":

```swift
let battery = Tracker.shared.batteryInfo()          // now — no ready() needed
for await b in Tracker.shared.batteryState() { }    // every transition
case .batteryChange(let battery):                   // or off events()
```

`BatteryInfo` carries `percent`, `isCharging`, `powerSource` and a derived
`isLow`. **`percent` and `isCharging` are optional, and that is the contract** —
`nil` means the platform will not say (simulator, monitoring disabled), not zero
and not `false`. Coalescing `percent ?? 0` renders an unknown battery as a flat
one.

`batteryChange` is not `powerSaveChange`: the first is the battery, the second is
the Low Power Mode switch. A user at 80 % who enabled it by hand is not low, so
`isLow` ignores it.

Emitted on transition only and deduped, because iOS posts a notification per 1 %
step.

### Tracking gaps are named, not drawn over

iOS never relaunches a force-quit app for location events. A user who swipes the
app away and then drives leaves a hole in the track, and until now the map joined
the two ends with a straight line that read as a driven route — on the capture
that motivated this, a 1.5 km line across a city the device was never observed on,
with a stop pin invented at its midpoint 750 m from anywhere real.

The hole is now a fact the SDK reports:

```swift
case .trackingGap(let durationSec, let distanceMeters):
    banner("Tracking was off for \(durationSec / 60) min. "
         + "Please don't swipe the app away.")
```

Emitted once, on the first stored point after the silence, when capture was quiet
for **≥ 10 minutes** and resumed **≥ 250 m away**. Both are required, which is
what keeps an ordinary parked night out of it — twelve hours of stillness is
drift suppression working, and on the motivating log that night measured 25 m.

`SegmentType` gained `.gap` alongside `.travel` and `.stop`. `TrackMapView` draws
a gap dashed and grey and splits the solid route around it; a `.gap` carries no
speed band, no activity, no arrows and no stop node, and adds nothing to
`TrackStats.totalDistanceMeters`, which sums what was observed.

`TrackPoint.odometerM` makes the opposite choice deliberately: it credits the
straight-line leg, because distance travelled is still distance travelled. The
two numbers answer different questions and forcing them to agree would falsify
one of them.

Both `TrackerEvent` and `SegmentType` are non-frozen, so a `switch` over either
needs `@unknown default` — which yours already has.

### The raw-fix buffer holds three days, not seven hours

`persistence.rawFixRingCapacity` went from 5 000 to **50 000**. The old ceiling
was about seven hours of delivery, and CoreLocation keeps delivering while the
device is stationary — so one parked night evicted every earlier trip, and a
diagnostic read of a multi-day session came back holding only the last one. Layer
1 is off by default and costs a few MB at the new ceiling.

### The revocation check is live

The licence server is configured and answering: the endpoint, the Ed25519
response key, the `key_id` binding and the canonical form the signature covers
have all been verified against the deployment with the SDK's own crypto path.
Builds before this one carried a placeholder host, so the check described above
skipped itself and never dialled.

Nothing about the offline gate changed — `ready()` still starts without the
network, and every inconclusive outcome still leaves the tracker running.

### Versioning

This release restarts at `1.0.0` under the new name. The `1.0.0` and `1.0.1`
entries below were published as **TrackIt** and describe the same codebase
before the rename.

---

# Previously released as TrackIt

Versions followed semantic versioning, with one exception: `1.0.1` was
republished in place more than once during initial rollout, so a host that
resolved it early may hold older binaries. If anything below is missing from
your build, purge SPM's cache and re-resolve:

```
rm -rf ~/Library/Caches/org.swift.swiftpm
# Xcode: File → Packages → Reset Package Caches
```

Module and type names in the entries below have been rewritten to their current
spelling, so the features are searchable under the names you will actually type.
What shipped at the time carried the old ones.

---

## TrackIt 1.0.1

### Added

- **Geofences.** Circular regions under your own identifier, independent of
  tracking: a fence needs `ready()` and location authorization, fires with no
  session open, keeps firing after `stop()`, and survives termination and
  reboot because iOS owns the monitoring.

  ```swift
  addGeofence(_:)                              // arms one; re-using an id replaces it
  getGeofences()                               // what is actually armed
  removeGeofence(id:) / removeAllGeofences()   // disarm
  getGeofenceEvents(geofenceID:limit:offset:)  // crossing history, newest first
  deleteGeofenceEvents(geofenceID:)            // drop that history
  ```

  Crossings arrive two ways and you need both: `.geofenceEnter` /
  `.geofenceExit` on `events()` while your app runs, and the stored history for
  the crossing that relaunched a terminated app — at that moment nothing is
  subscribed yet, so a live-only API would lose exactly the crossing that paid
  for the wake-up.

  A fence armed around where the device already is fires `enter` immediately.
  CoreLocation reports transitions only, so without that a fence created at your
  current position would report nothing until you left and came back.

  Platform limits, all reported rather than silent: 20 regions per app with one
  reserved for the SDK's stationary fence (19 available); radii below ~100 m are
  armed but emit `.diagnostic("geofence_radius_below_reliable_minimum")` because
  the hardware fires them unreliably; a fence added under When-In-Use works in
  the foreground and emits `.backgroundPermissionMissing`.

- **Geofence dwell** — `Geofence(dwellAfterMs:)` and `.geofenceDwell`, for
  "still there after N minutes".

  iOS has no dwell transition and no service outside your process to hold a
  loitering timer, so this one is synthesised and what it costs you is timing,
  not truth:

  | App state | When it fires |
  |---|---|
  | Foreground, or background with a session | On time |
  | Suspended | Late — when iOS next runs the background task |
  | Terminated | At the next launch, or when the exit crossing relaunches it |

  **The recorded event is accurate even when delivery is late.** Its `timeMs` is
  the moment the condition was met — entry plus your delay — not the moment the
  SDK noticed. Fires once per visit; leaving and returning starts it again. On
  the paths that may run long after the fact, a one-shot fix confirms the device
  really is still inside before reporting.

- **`SyncEvent.httpResponse(statusCode:count:)`** — what your server actually
  said. One line per HTTP exchange, before the outcome, for success, failure and
  401 alike; a queue larger than `batchSize` reports every round trip rather than
  a summary of the last. The status was previously logged inside the SDK and
  dropped, so a 500, a 422 and a timeout all reached you as an identical retry —
  three failures with three different fixes.

  `statusCode` is `nil` when the request never reached a server: offline, DNS,
  TLS. That is a different fact from a 5xx and stays distinct.

  The response body is not included. It can be megabytes and is rarely wanted —
  and if you need it, implement `SyncTransport`, which hands you the request as
  well.

- **`SyncEngine.endpoint`** and **`SyncEngine.isConfigured`** — read back where
  uploads are going, and whether they are going anywhere. Necessary because
  **the engine can un-configure itself**: a 401 tears the whole configuration
  down, so a host that called `configure` an hour ago and was not watching the
  event stream had no way to know it was no longer wired up. A settings screen
  reading "connected" against a dead credential is worse than one that says
  nothing. Headers are deliberately not exposed — they carry your credential.

- **Cross-platform config keys.** `motion.motionTriggerDelayMs` and
  `service.healthLoopMs` are now accepted on decode as aliases for the `…Sec`
  fields, rounded up. Nothing is renamed: the Swift names differ, so a host
  cannot set the wrong one. What this fixes is the silent case — a team feeding
  both platforms from a single JSON config, whose key decoded to this SDK's
  default with nothing to say so.

- **`LiveTrackMapView(initialCentre:)`** — where the live map should point before
  the first frame arrives. Without it the map opens on MapKit's contentless
  default, which is a view of the whole world, and stays there until a frame
  lands — a second during a live session, and indefinitely when no session is
  running. Applied once and only while nothing has been rendered, so the first
  frame takes the camera and it can neither fight `followMode` nor undo a pan.
  `getCurrentLocation()` is the natural source.

- **`changePace(isMoving:)`** — force the motion machine into moving or
  stationary when your app knows better than the sensors do. Indoors, in a car
  park, CoreMotion can sit on `.still` while the user has just tapped "Start
  trip". `true` commits to moving immediately, bypassing the trigger delay.
  Idempotent, and requires an open session.

- **`motion.stillConfidenceMin`**, default `100`. CoreMotion reports `.still`
  constantly inside ordinary movement — between strides, at a gear change, at a
  red light — and each of those readings used to drive the motion state to
  "stop pending" and straight back, so `motionChange` flapped at walking cadence
  and the decision log filled with stops that never happened. Only a
  high-confidence still may now start a stop; a real stop still arrives through
  the fix path and the stop timeout a second or two later. Set it to
  `activityConfidenceMin` for the previous behaviour.

- **`getCurrentLocation(feedIngestor:)`** — one fix, without opening a session.
  For a map centre, an address lookup or a check-in. Needs `ready()`; `start()`
  is not required. Captures on a second `CLLocationManager`, so calling it
  during a session cannot disturb the live stream. Returns
  `TrackerResult<TrackFix>`; failures name their own cause rather than
  reporting a bare timeout.
- **`exportFixture(sessionID:name:)` now ships in release builds.** Previously
  `#if DEBUG`, which meant the only build able to see a field anomaly was the
  one build with no recorder in it. Returns the fixture JSON as a `String`.
  Requires `persistence.persistRawFixes`.
- **`TrackerState.providerState` is now written.** It was declared and
  documented but never updated, so a host binding to it saw a permanent
  default.
- **`TrackerEvent.heartbeat(atMs:)` is now emitted**, by `HealthLoop`.
- Six optional config switches, each defaulting to the behaviour the SDK
  already had:

  | Field | Default | Turning it on |
  |---|---|---|
  | `motion.stopOnStationary` | `false` | Ends the session itself when the machine settles — a real `stop()` |
  | `motion.disableStopDetection` | `false` | Never settles to stationary; keeps a live position while parked |
  | `persistence.persistHeartbeat` | `false` | Stores the stationary heartbeat instead of discarding it |
  | `sensors.useAccelerometerVeto` | `false` | Second stillness signal for devices with no pedometer |
  | `sensors.useBarometer` | `false` | Reports vertical motion, so a lift is not read as standing still |
  | `sensors.activityRecognitionIntervalMs` | `0` | Throttles activity updates. Saves no battery — iOS classifies regardless |

### Fixed

- **`getCurrentLocation()` reported every failure as a timeout.** All four
  causes — the timeout itself, a capture already in flight, the circuit opened
  by three consecutive failures, and a fix refused at the mapping boundary —
  arrived as `ErrorCode.fixTimeout`, so the only way to tell them apart was to
  parse the message. The name reads "transient, retry later" and three of the
  four are nothing of the kind: retrying a busy capture collides with the one
  in flight, and retrying into an open circuit fails instantly until
  authorization, location services or a session start closes it. Three codes
  join `fixTimeout`, which keeps its exact meaning: `oneShotBusy`,
  `oneShotCircuitOpen` and `fixRejected`. Messages are unchanged.
- **The accelerometer veto measured a single instant, not the interval.**
  `sensors.useAccelerometerVeto` sampled one accelerometer reading per fix and
  treated it as a mean over the time since the last stored point. A carried
  phone reads near 1 g at plenty of individual instants, so a real movement
  could be read as "the device did not move" and the fix rejected as drift —
  on exactly the devices (no pedometer) the feature exists to serve. It now
  accumulates every sample at 10 Hz and reports nothing until it has enough of
  them.
- **`sensors.useBarometer` could hold a stale rate indefinitely.** If the
  altimeter stopped delivering, the last computed vertical speed kept
  suppressing the stillness checks for the rest of the session. Readings older
  than five seconds are now treated as absent.
- **The pedometer query could hold up a fix indefinitely.** Step corroboration
  awaited CoreMotion with nothing bounding it, on the path that judges a fix.
  Woken in the background your app has seconds before iOS suspends it again, and
  spending them inside CoreMotion is how an accepted point fails to be written
  at all. Capped at 1.5 s, after which the fix is judged without step data —
  the same path a device with no pedometer already takes.
- **`motion.stopOnStationary` re-armed machinery for the session it had just
  closed.** Ending a session from inside the motion callback re-entered the
  motion controller, which then carried on configuring a stream that had
  already been torn down.

### Changed — action required

- **`motion.stopTimeoutSec` is now `motion.stopTimeoutMin`**, stated in minutes.
  The old name said seconds while the value it described was a stop timeout
  measured in minutes everywhere else it appears, and a field whose unit has to
  be remembered rather than read is one that only goes wrong in the field.

  **This breaks source compatibility.** If you set it in code, rename it and
  convert:

  ```swift
  // before
  config.motion.stopTimeoutSec = 120
  // after
  config.motion.stopTimeoutMin = 2
  ```

  `TrackerConfig.Builder.stopTimeoutSec(_:)` is likewise now
  `stopTimeoutMin(_:)`.

  **A persisted config needs no migration.** A config written under the old key
  still decodes: the seconds are converted and rounded up to whole minutes,
  with a floor of one, so a host that chose two minutes is not silently
  reverted to the default.

- A licence token that fails its signature check no longer reports tampering as
  the only cause. A payload altered after issue and a payload signed by a key
  this SDK version does not carry are indistinguishable to the verifier, and
  naming only the first sent readers hunting an attack when the ordinary cause
  is a rotated signing key.

### Not available on iOS

- `useSignificantMotion` — iOS exposes no equivalent hardware wake path.
- `stepBatchLatencyMs` — `CMPedometer` has no batch-latency parameter.

---

### Example app

`Examples/SampleApp` is rebuilt against this release and now exercises the whole
surface: a **Fences** tab for geofences and dwell, an **Upload** screen for
`TrackerSync` — endpoint, queue, both manual triggers and the HTTP feed — a
one-shot location button, a fixture recorder that works in both package modes,
and maps that open on your position rather than on a continent.

The Track tab's **Draw raw** chip switches the drawn line between the built
track and the raw fix thread, for answering "is the polyline wrong, or did those
fixes never become points". Under the raw line there are no speed bands, no
arrows and no snapping — none of the three exists for geometry the plotting
plane never saw — and the pane opens even when the track has no geometry at all,
which is the session the mode is worth having for.

Raw fixes are a device-only diagnostic: they are written only when
`persistRawFixes` is on, they roll off `rawFixRingCapacity`, and nothing uploads
them. The raw line therefore exists on the recording device and nowhere else, and
the screen says so while the mode is on.

Buttons no longer hyphenate their labels, direction arrows scale and space with
the camera, the Apple Maps attribution sits in its own corner again, and zooming
out no longer pulls the camera back toward the track.

It ships **without a licence token**, deliberately. Development builds — the
simulator, and anything run from Xcode — need none. Add your own to
`Info.plist` under `TrackerLicense` when you build a distributed copy.

---

## TrackIt 1.0.0

First release. Background location capture, the seven-stage acceptance
pipeline, GRDB storage, track plotting, and the optional `TrackerMaps`,
`TrackerSnap` and `TrackerSync` products. Per-app offline licensing, checked
once in `ready()`.
