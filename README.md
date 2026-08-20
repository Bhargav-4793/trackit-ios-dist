# Tracker for iOS

Background location tracking and track plotting. iOS 17+, Swift 6.

Tracker records a location trace that survives backgrounding and termination,
filters it through a Kalman filter and a staged acceptance pipeline, and turns
the result into a plotted track you can render. It ships as five binary
frameworks; hosts never receive source.

```
TrackerSync → TrackerCore → TrackerGeo ← TrackerMaps, TrackerSnap
```

| Product | Required? | Purpose |
|---|---|---|
| `TrackerCore` | yes | Capture, storage, background execution, permissions. The SDK. |
| `TrackerGeo` | comes with every product | The engine's public types — `TrackPoint`, `Track`, `MotionState` |
| `TrackerMaps` | optional | MapKit rendering for a finished track and a live one |
| `TrackerSnap` | optional | OSRM map matching behind `RoadSnapProvider` |
| `TrackerSync` | optional | Upload with a retry queue and 401 teardown |

---

## Install

In Xcode: **File ▸ Add Package Dependencies…**, then paste

```
https://github.com/fieldtrack360/tracker-ios
```

Or in a `Package.swift`:

```swift
.package(url: "https://github.com/fieldtrack360/tracker-ios", from: "1.0.0")
```

Add only the products you need. Because these are binary targets, each product
already carries the targets it depends on — adding `TrackerCore` gives you
`TrackerGeo` too.

## Host configuration

**This is not optional.** Without it the SDK cannot capture in the background,
and `BGTaskScheduler.register` raises an Objective-C exception no Swift `catch`
can reach.

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Records your route while you are using the app.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Records your route in the background so your trips are complete even when the app is closed.</string>
<key>NSMotionUsageDescription</key>
<string>Detects when you start and stop moving, to save battery.</string>

<key>UIBackgroundModes</key>
<array>
    <string>location</string>
    <string>processing</string>
</array>

<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.fieldtrack360.tracker.backstop</string>
    <string>com.fieldtrack360.tracker.sync</string>
</array>
```

The identifiers must appear **verbatim**. A mismatch is not a degraded backstop;
it is an exception at registration.

---

## Quick start

`ready()` belongs in your `App` initialiser, not in a view's `.task`. It
registers the background task handler, and registering after launch completes
throws.

```swift
import SwiftUI
import TrackerCore

@main
struct MyApp: App {
    init() {
        Task { _ = await Tracker.shared.ready() }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

Then ask for permission and start a run:

```swift
import TrackerCore

@MainActor
func beginTracking() async {
    // The ladder is ordered. Always can only be requested from When-In-Use.
    let tier = await Tracker.shared.permissions().requestWhenInUse()
    guard tier != .none else { return }

    switch await Tracker.shared.permissions().requestAlways() {
    case .alreadyGranted, .granted:
        break
    case .needsWhenInUseFirst, .denied:
        return                      // capture still works in the foreground
    case .needsSettings(let url):
        await UIApplication.shared.open(url)
        return
    @unknown default:
        return
    }

    switch await Tracker.shared.start(tag: "delivery-run") {
    case .success(let session):
        print("recording \(session.id)")
    case .failure(let code, let message):
        print("refused — \(code.rawValue): \(message)")
    @unknown default:
        break
    }
}
```

Stop when the run ends:

```swift
_ = await Tracker.shared.stop()
```

### `TrackerResult`, and why `@unknown default`

The SDK never throws into your task from a fallible entry point; it returns
`TrackerResult<T>`, which is `.success(T)` or `.failure(code:message:)`.

Every public enum is **non-frozen**, because this ships as a binary with library
evolution enabled. Your `switch` needs `@unknown default` so a newer SDK adding
a case does not break your build. Fold the unknown into the conservative branch —
an outcome you cannot read is not evidence that something succeeded.

---

## Observing what happens

`events()` is the live stream. Handling every case is the point: a handler that
covers four of eleven makes silence meaningless.

```swift
import TrackerCore
import TrackerGeo

func observe() async {
    for await event in Tracker.shared.events() {
        switch event {
        case .location(let point):
            print("accepted \(point.latitude),\(point.longitude) ±\(point.accuracyM)m")
        case .locationRejected(let decision):
            print("rejected — \(decision.reason)")
        case .motionChange(let state, _):
            print("motion \(state)")
        case .activityChange(let activity, let confidence):
            print("activity \(activity) @\(confidence)")
        case .providerChange(let state):
            print("authorization \(state.authorization.rawValue)")
        case .batteryChange(let battery):
            print("battery \(battery.percent ?? -1)%")
        case .enabledChange, .heartbeat, .powerSaveChange, .diagnostic:
            break
        case .sessionInterrupted(let session):
            print("interrupted \(session.id)")
        case .licenseDeactivated(let status, let reason):
            // Tracking has ALREADY stopped. Show your message here.
            print("licence \(status): \(reason ?? "no reason given")")
        case .trackingGap(let durationSec, let distanceMeters):
            // Capture was off while the device moved — usually a force-quit.
            print("tracking gap: \(durationSec)s, moved at least \(Int(distanceMeters))m")
        case .error(let code, let message):
            print("error \(code.rawValue): \(message)")
        @unknown default:
            break
        }
    }
}
```

`decision.reason` is a stable vocabulary, not free text — it is what makes a
field report diagnosable. Treat it as API.

### Permission and device state, on demand

The event stream tells you when things change; these answer "what is true
right now" — for a settings or tracking-health screen:

```swift
// The rung the app is on: .none / .whenInUse / .always.
let tier = await Tracker.shared.authorizationTier()

// The full snapshot: authorization, precise location, Location Services,
// Low Power Mode.
let provider = await Tracker.shared.currentProviderState()

// Or subscribe to every change of that snapshot as a stream.
for await state in Tracker.shared.providerState() {
    print("authorization now \(state.authorization.rawValue)")
}

// What the hardware and granted permissions actually make possible —
// re-probed on every call, because motion consent moves under a running app.
let sensors = Tracker.shared.getSensors()
```

---

## Reading the data

```swift
import TrackerCore
import TrackerGeo

func summarise(sessionID: String) async throws {
    let points: [TrackPoint] = try await Tracker.shared.getPoints(
        PointQuery(sessionID: sessionID)
    )
    let count = try await Tracker.shared.getCount(PointQuery(sessionID: sessionID))
    let metres = try await Tracker.shared.getOdometerMeters()

    print("\(count) points, \(metres) m")
    print("first: \(points.first?.timeMs ?? 0)")

    let sessions = try await Tracker.shared.getSessions()
    print("\(sessions.count) sessions, open: \(sessions.filter(\.isOpen).count)")
}
```

`PointQuery` pages by default, so pass `limit`/`offset` for long runs rather
than pulling everything into memory.

Two more reads worth knowing:

```swift
// The session currently recording, or nil.
let open = try await Tracker.shared.currentSession()

// A fresh list on every change to a session's points — drive SwiftUI from this
// while recording, instead of polling getPoints.
for await points in Tracker.shared.observePoints(sessionID: sessionID) {
    print("now \(points.count) points")
}
```

---

## One fix, without tracking

`getCurrentLocation()` answers "where am I now" without opening a session — for
a map centre, an address lookup or a check-in. It needs `ready()` and nothing
else; `start()` is not required.

```swift
import TrackerCore

func centreOnUser() async {
    switch await Tracker.shared.getCurrentLocation() {
    case .success(let fix):
        print("\(fix.latitude), \(fix.longitude) ±\(fix.accuracyM) m")
    case .failure(_, let message):
        // The message names the cause: authorization, location services,
        // reduced accuracy, low-power mode, or a capture already running.
        print(message)
    // Required: TrackerResult is non-frozen across the binary boundary.
    @unknown default:
        print("unrecognised result")
    }
}
```

It runs on a second `CLLocationManager`, so calling it during a session cannot
disturb the live stream. The fix is returned and nothing else — pass
`feedIngestor: true` only if you also want it judged by the pipeline and stored
as a point on the track that is recording.

Three consecutive failures open a circuit and further calls fail immediately,
until location authorization is granted, location services come back, or a
session starts.

---

## Geofences

Circular regions with your own identifier. `addGeofence` needs `ready()` and
location authorization — **not** a session: a fence fires whether or not you are
recording a track, and keeps firing after `stop()`.

```swift
import TrackerCore

func watchTheDepot() async {
    let depot = Geofence(
        id: "depot-7",                  // yours; it comes back on every crossing
        latitude: 23.0225,
        longitude: 72.5714,
        radiusM: 200,
        notifyOnEntry: true,
        notifyOnExit: true
    )

    switch await Tracker.shared.addGeofence(depot) {
    case .success(let armed):
        // The radius comes back clamped to what the OS will monitor, so this
        // describes the fence that exists rather than the one you asked for.
        print("armed \(armed.id) at \(armed.radiusM) m")
    case .failure(_, let message):
        print(message)
    @unknown default:
        break
    }
}
```

**A fence armed around where you already are fires `enter` immediately.**
CoreLocation reports transitions only, so without this a fence created at your
current position would report nothing until you left and came back — and its
dwell, which hangs off the entry, could never start.

Managing them:

```swift
let fences = await Tracker.shared.getGeofences()          // read back from the OS
await Tracker.shared.removeGeofence(id: "depot-7")        // false if not found
await Tracker.shared.removeAllGeofences()                 // returns how many
```

### Crossings arrive two ways, and you need both

While your app is running, `events()` carries them live:

```swift
for await event in Tracker.shared.events() {
    switch event {
    case .geofenceEnter(let crossing):
        print("entered \(crossing.geofenceID) at \(crossing.timeMs)")
    case .geofenceExit(let crossing):
        print("left \(crossing.geofenceID)")
    default:
        break
    }
}
```

**iOS relaunches a terminated app to deliver a crossing**, and at that moment
nothing is subscribed yet — the event stream has no replay. Every crossing is
therefore also written to disk. Read it at launch:

```swift
// Everything since you last looked, newest first.
let crossings = try await Tracker.shared.getGeofenceEvents(limit: 50)

// Or one fence's history.
let depotVisits = try await Tracker.shared.getGeofenceEvents(geofenceID: "depot-7")

// History is kept when a fence is removed. Drop it explicitly:
try await Tracker.shared.deleteGeofenceEvents(geofenceID: "depot-7")
```

### What the platform imposes

| | |
|---|---|
| **20 regions per app** | Shared with anything you monitor yourself; the SDK reserves one for its own stationary fence, so 19 are available. Going over returns a failure naming the cap. |
| **~100 m minimum radius** | Smaller regions fire unreliably or not at all. A smaller fence is accepted and emits `.diagnostic("geofence_radius_below_reliable_minimum")`. |
| **Always authorization** | Needed to wake a terminated app. Under When-In-Use a fence still works in the foreground and emits `.backgroundPermissionMissing`. |
| **Re-using an id replaces** | Adding under an identifier already in use moves that fence, with no window where neither exists. |

Geofences survive termination and reboot because iOS owns the monitoring, not
this SDK. `getGeofences()` reads them back from the system rather than from a
list of our own, so what you see is what is actually armed.


### Dwell — "still there after N minutes"

iOS has no dwell transition: `CLCircularRegion` reports entry and exit and
nothing else, and unlike Android there is no service outside your process
holding a loitering timer. The SDK synthesises it, and what that costs you is
timing rather than truth.

```swift
let site = Geofence(
    id: "site-42",
    latitude: 23.0225,
    longitude: 72.5714,
    radiusM: 200,
    dwellAfterMs: 10 * 60_000        // nil = no dwell
)
_ = await Tracker.shared.addGeofence(site)

for await event in Tracker.shared.events() {
    if case .geofenceDwell(let dwell) = event {
        print("on site since \(dwell.timeMs)")
    }
}
```

The condition is evaluated at every moment the SDK is already awake — a timer
while the app lives, the health tick, the background task, and at the next
launch:

| App state | When the dwell fires |
|---|---|
| Foreground, or background with a session | On time |
| Suspended | Late — when iOS next runs the background task |
| Terminated | At the next launch, or when the exit crossing relaunches it |

**The recorded event is accurate even when delivery is late.** Its `timeMs` is
the moment the condition was met — entry plus your delay — not the moment the
SDK noticed. A dwell reported at 15:10 for a condition met at 14:32 says 14:32,
because "how long has the driver been on site" has one true answer.

It fires **once per visit**; leaving and returning starts it again. On the
paths that may run long after the fact, the SDK takes a one-shot fix to confirm
the device really is still inside before reporting — an exit iOS failed to
deliver would otherwise become a dwell that never happened.

---

## Plotting a track

`buildTrack` runs the whole plotting plane — consolidation, simplification,
smoothing, arrow placement — and returns a `Track` ready to draw.

```swift
import TrackerCore
import TrackerGeo

func exportRun(sessionID: String) async throws {
    let track: Track = try await Tracker.shared.buildTrack(
        PointQuery(sessionID: sessionID)
    )
    let geoJSON: String = try await Tracker.shared.exportGeoJSON(
        PointQuery(sessionID: sessionID)
    )
    print("track v\(track.version), \(geoJSON.count) bytes of GeoJSON")
}
```

`exportPolylineJSON` is the sibling export: the same `Track`, JSON-encoded
with its polyline intact, for a backend that decodes polylines itself.

### Rendering it (`TrackerMaps`)

`TrackMapView` consumes the placement the engine already computed rather than
recomputing it, so what you see is what the engine decided.

```swift
import SwiftUI
import TrackerGeo
import TrackerMaps

struct TrackScreen: View {
    let track: Track

    var body: some View {
        TrackMapView(track: track)
            .ignoresSafeArea()
    }
}
```

### When tracking was off — capture gaps

iOS never relaunches a force-quit app for location events. If the user swipes
your app away and then drives, capture resumes only when they next open it, and
the track has a hole in it that no filter change can fill.

The SDK names the hole rather than papering over it:

```swift
case .trackingGap(let durationSec, let distanceMeters):
    banner("Tracking was off for \(durationSec / 60) min. "
         + "Please don't swipe the app away.")
```

Emitted once, on the first stored point after the silence, when capture was
quiet for **at least 10 minutes** and resumed **at least 250 m away**. Both
conditions are required, and that is what keeps an ordinary parked night out of
it: sitting still for twelve hours is drift suppression working, not an outage.

The same span appears on the built track as a third segment type:

```swift
for segment in track.segments where segment.type == .gap {
    // durationSec: how long nothing was captured
    // distanceMeters: the straight line between the last point before
    //                 and the first point after — a LOWER BOUND
}
```

`TrackMapView` draws it dashed and grey, and splits the solid route line around
it, because a span nobody observed must not read as a driven route. A `.gap`
carries no speed band, no activity, no arrows and no stop node, and it
contributes nothing to `TrackStats.totalDistanceMeters` — that number sums what
was observed.

**The odometer makes the opposite choice on purpose.** `TrackPoint.odometerM`
credits the straight-line leg across a gap, because distance travelled is still
distance travelled. The two numbers answer different questions — "how far has
this device gone" versus "how far did we watch it go" — and forcing them to
agree would falsify one of them.

`SegmentType` is not frozen, so a `switch` over it needs `@unknown default`.

### Following a run as it happens

```swift
import SwiftUI
import TrackerCore
import TrackerGeo
import TrackerMaps

struct LiveScreen: View {
    @State private var update: LiveTrackUpdate?

    var body: some View {
        LiveTrackMapView(update: update)
            .ignoresSafeArea()
            .task {
                for await next in Tracker.shared.liveTrack() {
                    self.update = next
                }
            }
    }
}
```

### Navigating a planned route

If your app is navigating a route it already knows, hand it to the SDK and
the live puck snaps to it — stored points and `buildTrack` are untouched:

```swift
await Tracker.shared.setActiveRoute(routePoints)   // [GeoPoint]; empty clears it

// True once the position has missed the route for enough consecutive fixes
// to be a wrong turn rather than a GPS spike.
if await Tracker.shared.isOffRoute() {
    recalculate()
}
```

---

## Optional: snapping to roads (`TrackerSnap`)

Give it an OSRM endpoint you control. There is no default URL on purpose — a
URL that "just works" is worth very little next to a rate limit somebody else
pays for.

```swift
import TrackerCore
import TrackerSnap

func enableSnapping(endpoint: URL) {
    Tracker.shared.setRoadSnapProvider(
        OSRMSnapProvider(baseURL: endpoint, profile: "driving")
    )
}
```

Snapping applies when a track is built; capture is unaffected.

## Optional: uploading (`TrackerSync`)

Configure it in your `App` initialiser alongside `ready()`, so the retry trigger
is registered before launch completes.

```swift
import TrackerCore
import TrackerSync

func configureSync(endpoint: URL, token: String) async {
    var config = SyncConfig(url: endpoint)
    config.headers["Authorization"] = "Bearer \(token)"
    config.autoSync = true
    config.batchSize = 200

    SyncEngine.shared.configure(config, store: Tracker.shared.pendingUploads)

    // The third trigger: rows left queued by a failed upload, with no new
    // point coming to wake anything else. Without it, a parked queue stays
    // parked until the next fix arrives.
    await Tracker.shared.setSyncTrigger(SyncEngine.shared.healthLoopTrigger())
}
```

Uploading is not tracking: no failure here stops capture or closes a session.
The single exception is opt-in and off by default —
`SyncConfig.stopTrackingOnAuthExpiry`.

### Surviving a cold start

**`SyncEngine` holds the configuration in memory only.** The queued points are on
disk and survive anything, but the endpoint, the headers and the policy do not —
so after a force-kill the app relaunches with `isConfigured == false`, a full
queue and nothing to explain it. Call `configure` on every launch.

`SyncConfig` is `Codable` so the argument can come back from wherever you keep
it, rather than from a login the user has to repeat:

```swift
// When you first configure — or whenever the token is refreshed.
let data = try JSONEncoder().encode(config)
// → your Keychain wrapper

// In your App initialiser, every launch.
if let data = try? myKeychain.read("sync-config"),
   let config = try? JSONDecoder().decode(SyncConfig.self, from: data) {
    SyncEngine.shared.configure(config, store: Tracker.shared.pendingUploads)
}
```

Decoding needs `url` and nothing else — every other key falls back to its
documented default, so a config stored by one version of the SDK still decodes
under the next.

Two things to get right:

- **Keychain, not `UserDefaults`.** `headers` is encoded verbatim, bearer token
  and all, and `UserDefaults` is a plist inside the app container.
- **Delete your stored copy when you see `.authExpired`.** That event means a 401
  tore the uploader down against a credential the server has already rejected;
  restoring it on the next launch earns the same 401 for the life of the install.
  It is also the only way to tell a teardown by 401 from a teardown by process
  death — one is an event you were told about.

Persisting is deliberately left to you. Where a credential lives is your
decision, not the SDK's, and a token the SDK resurrected from disk on its own
would contradict the 401 teardown it is supposed to respect.

Watch it:

```swift
import TrackerSync

func observeSync() async {
    for await event in SyncEngine.shared.events() {
        switch event {
        // One per HTTP exchange, before the outcome below — success, failure and
        // 401 alike. `statusCode` is nil when the request never reached a server:
        // offline, DNS, TLS.
        case .httpResponse(let statusCode, let count):
            print("server said \(statusCode.map(String.init) ?? "nothing") for \(count) points")

        case .uploaded(let count):
            print("\(count) points uploaded")

        case .retryScheduled(let afterSec, let reason):
            print("retrying in \(afterSec)s — \(reason)")

        case .authExpired:
            // Terminal. Refresh the credential and configure again — and throw
            // away any stored SyncConfig, or the next launch restores a token
            // the server has already rejected.
            print("credential is dead; the uploader has torn itself down")

        @unknown default:
            break
        }
    }
}
```

Triggering an upload by hand:

```swift
// Awaits the outcome — .uploaded(count:), .empty, .retry(reason:) or .authExpired.
let result = await SyncEngine.shared.syncNow()

// Or fire and forget; repeated calls coalesce.
SyncEngine.shared.requestSync()
```

**For the full request and response, own the exchange.** `SyncTransport` is a
protocol you can implement — your `URLSession`, your headers, your auth refresh,
the whole `HTTPURLResponse` and body — and hand to `configure(transport:)`. The
event stream reports what happened; the transport lets you decide what happens.

```swift
struct MyTransport: SyncTransport {
    func upload(_ request: SyncRequest) async -> SyncResponse {
        // request.url, request.headers, request.body are yours
        // return .success(code:) / .unauthorized / .failure(code:message:)
    }
}
```

---

## Configuration

Defaults are field-tuned; change them only with a reason. Pass a config to
`ready()`:

```swift
import TrackerCore

func readyWithConfig() async {
    var config = TrackerConfig()
    config.geolocation.accuracy.profile = .balanced
    config.geolocation.adaptiveCadence = true
    config.motion.stopTimeoutMin = 2
    config.persistence.maxDaysToPersist = 30
    config.persistence.persistDecisions = true

    _ = await Tracker.shared.ready(config)
}
```

Tune accuracy through `AccuracyProfile` rather than raw thresholds. The
thresholds themselves are internal on purpose: they are the field-tuned part,
and a profile is the supported way to move them.

`stopTimeoutMin` is stated in **minutes**. A config persisted by an earlier
version under `stopTimeoutSec` still decodes — the seconds are converted and
rounded up to whole minutes.

Six optional switches, all defaulting to the behaviour the SDK already had:

| Field | Default | What turning it on does |
|---|---|---|
| `motion.stopOnStationary` | `false` | Ends the session itself when the machine settles — a real `stop()`, for a job-per-trip app |
| `motion.disableStopDetection` | `false` | Never settles to stationary, for a host that must keep a live position while parked |
| `persistence.persistHeartbeat` | `false` | Stores the stationary heartbeat instead of discarding it — proof of presence, at ~32 rows per 8-hour stop |
| `sensors.useAccelerometerVeto` | `false` | Second stillness signal for devices with no pedometer (iPads, older hardware) |
| `sensors.useBarometer` | `false` | Reports vertical motion, so a lift is not read as standing still |
| `sensors.activityRecognitionIntervalMs` | `0` | Throttles activity updates. Saves no battery — iOS classifies regardless; it is for hosts whose own handler is expensive |

---

## Diagnostics

When a track looks wrong, the question is *which layer* it first went wrong
in. Three reads answer it, each gated by a `persistence` flag:

```swift
// Layer 1 — unfiltered fixes exactly as CoreLocation delivered them.
// Populated when persistence.persistRawFixes is on.
let raw = try await Tracker.shared.getRawFixes(sessionID: id)

// Layer 3 — every judged fix in point form, accepted or not.
// Populated when persistence.persistRawPoints is on.
let judged = try await Tracker.shared.getRawPoints(sessionID: id)

// The decision log: verdict + reason per fix, with the filter's own estimate
// on each row. Populated when persistence.persistDecisions is on.
let decisions = try await Tracker.shared.getDecisions(sessionID: id, limit: 200)
```

Layer 1 is a ring buffer — `persistence.rawFixRingCapacity`, 50 000 fixes by
default, roughly three days. It is sized so that one parked night cannot evict
the day's driving: CoreLocation keeps delivering while stationary, so a stop
costs rows at the same rate as a drive.


And one write: `offerFix(_:)` feeds a fix from a source the SDK does not own
(an external GPS, a replay). It is judged by the same pipeline as every other
fix — a host cannot inject an unvalidated point:

```swift
await Tracker.shared.offerFix(fix)   // TrackFix
```

---

## API reference

Everything on the `Tracker.shared` facade, in one place:

| Member | Purpose |
|---|---|
| `ready(_:)` | Resolve config, restore state, register background tasks. Call once, from the `App` initialiser |
| `start(tag:)` | Open a session and start capturing |
| `stop()` | Close the session and stop capturing |
| `state` | `@Observable` snapshot for SwiftUI: `isReady`, `isTracking`, `motionState`, `providerState`, `currentSessionID` |
| `events()` | Every SDK event, as an `AsyncStream` |
| `permissions()` | The authorization ladder: `requestWhenInUse()`, `requestAlways()` |
| `authorizationTier()` | Current rung, on demand |
| `providerState()` / `currentProviderState()` | Authorization + power snapshot, as stream / on demand |
| `getSensors()` | What hardware and permissions make possible right now |
| `batteryInfo()` / `batteryState()` | The battery now, and every transition. No `ready()` required |
| `getPoints(_:)` / `getCount(_:)` / `observePoints(sessionID:)` | Stored points: paged read, count, live stream |
| `getOdometerMeters()` | Total distance across all sessions |
| `getCurrentLocation(feedIngestor:)` | One fix now, without a session — map centre, check-in, address lookup |
| `addGeofence(_:)` / `getGeofences()` | Arm a circular region under your own id / read back what is armed |
| `removeGeofence(id:)` / `removeAllGeofences()` | Disarm one / all |
| `getGeofenceEvents(geofenceID:limit:offset:)` | Crossing history — the API that makes a background crossing usable |
| `deleteGeofenceEvents(geofenceID:)` | Drop that history |
| `getSessions(fromMs:toMs:)` / `currentSession()` | Session list / the one recording now |
| `buildTrack(_:options:)` | Points → plotted `Track` (consolidation, smoothing, arrows) |
| `exportGeoJSON(_:options:)` / `exportPolylineJSON(_:options:)` | The same track, serialised for a backend |
| `liveTrack()` | One frame per processed fix, conflated for rendering |
| `setActiveRoute(_:)` / `isOffRoute()` | Snap the live puck to a known route / wrong-turn detection |
| `setRoadSnapProvider(_:)` | Install `TrackerSnap`'s OSRM provider (or your own) |
| `getRawFixes` / `getRawPoints` / `getDecisions` | The three diagnostic layers |
| `offerFix(_:)` | Feed a fix from a source the SDK does not own |
| `pendingUploads` / `setSyncTrigger(_:)` | The two seams `TrackerSync` plugs into |

---

### Battery

Three ways in, all answering the same first question of any field gap: *did
tracking stop because the OS killed us, or because the phone was at 3 %?*

```swift
// One reading, right now. No ready(), no session, no permission needed —
// a diagnostics screen asks this before anything is running.
let battery = Tracker.shared.batteryInfo()

// Every transition, current value replayed immediately on attach.
for await battery in Tracker.shared.batteryState() {
    print("\(battery.percent ?? -1)% charging=\(battery.isCharging as Any)")
}

// Or off the main event stream.
case .batteryChange(let battery):
    print("battery \(battery.percent ?? -1)%")
```

`BatteryInfo`:

| Field | Type | Notes |
|---|---|---|
| `percent` | `Int?` | 0…100, or `nil` when the platform will not say |
| `isCharging` | `Bool?` | `nil` when the platform will not say |
| `powerSource` | `PowerSource` | `.none` on battery, `.unknown` otherwise. iOS never reports `.ac`, `.usb` or `.wireless` |
| `isLow` | `Bool` | Derived from `percent` by the SDK, so no host hardcodes the threshold. `false` when `percent` is `nil` |

**`nil` is not zero, and `nil` is not `false`.** The simulator, a Mac running
your tests, and a device with battery monitoring off all report `nil`. Writing
`percent ?? 0` renders an unknown battery as a flat one — the single most
misleading thing this type can be made to say.

**`batteryChange` and `powerSaveChange` are different facts.** The first is the
battery itself; the second is the Low Power Mode switch, which also appears as
`ProviderState.lowPowerMode`. A user at 80 % who turned Low Power Mode on by
hand is not low, so `isLow` deliberately ignores it.

Events arrive on transition only, deduped on `Equatable`. iOS posts a
notification for every 1 % step and again whenever a cable moves; forwarding
that raw would flood a bridge.

## Licensing

The SDK is licensed per app. A licence token is issued for your bundle
identifier (plus its `.dev`/`.staging` variants) and checked once, in
`ready()`, entirely offline — the app starts without ever reaching the
network. A separate background check asks whether the licence has since
been withdrawn; it blocks nothing and never sends location data. See
[The revocation check](#the-revocation-check). Licences are
permanent: one purchase, no renewals.

**Development needs no token.** The simulator and any build run from Xcode
skip the check, so you can evaluate the whole SDK before buying. A token is
required only in distributed builds: App Store, TestFlight, ad-hoc and
enterprise.

### Getting a licence

Send us the bundle identifier of the app that will ship (for example
`com.acme.delivery`), plus any dev/staging variants. You receive a one-line
token back:

```
TRACKER-eyJ…
```

### Installing it

Two ways. Pick one — the SDK checks the token in `ready()` either way.

**Option A — Info.plist (recommended).** Open your target's **Info.plist**,
add a row with key `TrackerLicense`, and paste the whole token as its value:

```xml
<key>TrackerLicense</key>
<string>TRACKER-eyJ…</string>
```

Your `ready()` call then stays exactly as it is — no code change:

```swift
await Tracker.shared.ready()

// or with a config — no .license() needed, the plist key is found automatically:
await Tracker.shared.ready(
    TrackerConfig.builder()
        .accuracyProfile(.balanced)
        .buildUnchecked()
)
```

**Option B — in code, no Info.plist entry.** Pass the token with the config:

```swift
await Tracker.shared.ready(
    TrackerConfig.builder()
        .license("TRACKER-eyJ…")
        .buildUnchecked()
)
```

Use this when the token arrives at runtime — from your own backend, or a
build system that injects it. When both are set, `.license()` wins over the
plist.

The token is not a secret — it only works for the bundle identifiers it was
issued for — so committing it in the plist is fine. Each app needs its own.

<details>
<summary>Keeping it in an xcconfig (optional refinement of Option A)</summary>

If you prefer build settings over a literal in the plist — for example, a
different token per configuration — put it in a Configuration Settings File:

1. **File ▸ New ▸ File… ▸ Configuration Settings File**, name it
   `Config.xcconfig`.
2. In it, one line: `TRACKER_LICENSE = TRACKER-eyJ…`
3. Select the project (blue icon) ▸ **Info** tab ▸ **Configurations** →
   expand Debug and Release → set your app target's configuration file to
   `Config`.
4. In Info.plist, set `TrackerLicense` to `$(TRACKER_LICENSE)` — Xcode
   substitutes the real value at build time.

</details>

### If `ready()` refuses

| Code | Meaning | What to do |
|---|---|---|
| `licenseMissing` | No token found | Purchase a licence for this app |
| `licenseInvalid` | Token malformed or altered | Re-copy the token from the issue email; the message says what failed |
| `licenseBundleMismatch` | Genuine token, different app | The message names both bundle identifiers — check which target you built |

A refused `ready()` never crashes: it returns the code and message in
`TrackerResult`, and your app decides what to show.

---

### The revocation check

The gate above is offline and stays offline — `ready()` never waits on the
network to start, because an SDK that does will not start on a train. But a
token carries no expiry and never will: it is a signed statement about an app
id, not a lease. So it cannot answer "has this licence been withdrawn since it
was issued?"

That question goes to the licence server, on **every** `ready()`, on a
background task that blocks nothing:

```swift
case .licenseDeactivated(let status, let reason):
    // Tracking has already stopped by the time this arrives.
    showAlert("Your licence is \(status). \(reason ?? "")")
```

`status` is `revoked` (withdrawn by an admin) or `expired` (a trial past its end
date). The SDK calls `stop()` first and emits second, so a host reacting to the
event never finds a tracker still running behind it.

**Everything else keeps running.** No network, a reply that fails its signature
check, a reply about somebody else's licence, a server error, a rate limit — all
of them leave the tracker recording. The offline gate already proved the licence
was genuine, and a phone in a tunnel is not a piracy problem: stopping there
would throw away location data that no retry can recover.

Nothing about your location data goes to the licence server. The request is the
token, your bundle identifier, `ios`, the SDK version and a random nonce — there
is no endpoint that would accept a coordinate.

## The example app

`Examples/SampleApp` is a complete diagnostic host: the permission ladder, a
live map, a decision log, and a three-layer overlay that shows raw fixes, the
filter's estimate and what was actually stored.

```bash
git clone https://github.com/fieldtrack360/tracker-ios
open tracker-ios/Examples/SampleApp/SampleApp.xcodeproj
```

It resolves the frameworks from the repository you just cloned, so it always
matches the version you checked out — nothing is downloaded a second time.

Before it will run on a device:

1. Select the **SampleApp** target ▸ Signing & Capabilities
2. Pick your team, and change the bundle identifier from
   `com.example.tracker.sample` to one you own
3. Update `BGTaskSchedulerPermittedIdentifiers` in
   `SampleApp/Resources/Info.plist` if you change the identifier prefix

The simulator runs it without signing, but background relaunch, region
monitoring and the motion sensors only behave correctly on a real device.

### Road snapping in the example

The Snap toggle stays inert until you supply an endpoint. There is no default
on purpose.

```bash
cd Examples/SampleApp/SampleApp/Resources
cp Sample.xcconfig.example Sample.xcconfig    # then set OSRM_BASE_URL
```

### What to read first

| If you want | Open |
|---|---|
| Correct `ready()` placement | `App/SampleApp.swift` |
| The permission ladder, in order | `Modules/Home/PermissionLadderView.swift` |
| Consuming `events()` | `Core/AppState/TrackingViewModel.swift` |
| Rendering a finished track | `Modules/Track/TrackView.swift` |
| Field logging you can read a week later | `Core/CaptureLog.swift` |

---

## Support

Open an issue on this repository. A `CaptureLog` export from the run
(**Home ▸ Dump session**) makes almost any report diagnosable; a description of
the route usually does not.
