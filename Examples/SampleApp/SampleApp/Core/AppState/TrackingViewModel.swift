import Foundation
import Observation
import TrackerCore
import TrackerGeo
import os

// MARK: - ViewState

/// Screen state, for every screen in this app. `docs/04-conventions.md`.
///
/// Four cases rather than a `Bool` and an optional error, because "loaded with nothing in it" and
/// "never asked" are different facts and the Decisions tab has to tell them apart: *no decisions
/// recorded* and *all N hidden by the filters* mean opposite things.
enum ViewState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
}

extension ViewState {

    var value: Value? {
        guard case .loaded(let value) = self else { return nil }
        return value
    }

    var isLoading: Bool {
        guard case .loading = self else { return false }
        return true
    }

    var failure: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

// MARK: - TrackingSnapshot

/// Everything the status card shows, resolved once so the four tabs cannot disagree about it.
struct TrackingSnapshot: Equatable, Sendable {

    var isReady: Bool
    var isTracking: Bool
    var motionState: MotionState
    var detectedActivity: ActivityType?

    var tier: AuthorizationTier
    var accuracy: LocationAccuracy
    var motionAuthorization: MotionAuthorization
    var provider: ProviderState
    var sensors: DeviceSensors

    /// `selectedSessionID ?? currentSession()?.id`. **The session every diagnostic tab describes.**
    var sessionID: String?

    /// The session was picked on Home rather than being the live one.
    var isPinnedSession: Bool

    /// Accepted points stored against `sessionID`.
    var pointCount: Int

    /// The last error the SDK reported, kept until something replaces it. A cleared error is a
    /// field report nobody can answer.
    var lastError: String?

    /// The first eight characters, which is what a status card has room for and what a field tester
    /// reads back over the phone.
    var shortSessionID: String {
        TrackingSnapshot.short(self.sessionID)
    }

    static func short(_ sessionID: String?) -> String {
        guard let sessionID, !sessionID.isEmpty else { return "—" }
        return String(sessionID.prefix(8))
    }
}

// MARK: - TrackingViewModel

/// The app's core state: the SDK's event stream on one side, the four tabs on the other.
///
/// It owns three things nothing else may own — the event subscription, the resolved session, and
/// the capture log — because all three have to be single. Two subscriptions would double every
/// line in the log; two session resolutions would let Track and Decisions describe different runs,
/// which is the exact failure the shared `SessionPicker` exists to prevent.
@MainActor
@Observable
final class TrackingViewModel {

    // MARK: - Published state

    private(set) var state: ViewState<TrackingSnapshot> = .idle

    /// The live event feed, newest first, capped. A convenience — `CaptureLog` is the record.
    private(set) var log: [String] = []

    private(set) var sessions: [TrackSession] = []

    /// **Session pinning.** A session picked here wins over the live one, and all three diagnostic
    /// tabs read this single selection — so Track, Debug and Decisions always describe the same run.
    ///
    /// A computed property over private storage rather than a stored one with `didSet`: the setter
    /// has to kick a refresh so the status card's point count follows the selection, and an
    /// `@Observable` stored property is not the place to hang side effects.
    var selectedSessionID: String? {
        get { self.pinnedSessionID }
        set {
            guard newValue != self.pinnedSessionID else { return }
            self.pinnedSessionID = newValue
            self.scheduleRefresh()
        }
    }

    /// Track-tab render flags. Pure presentation; the tabs re-read them, nothing here recomputes.
    var snapToRoad = true
    var showRawLayer = true

    /// Which geometry the Track pane draws its main line from. Presentation only — it changes
    /// what is drawn, never what was built, so it is deliberately not part of `LoadKey`.
    var pathSource: PathSource = .track

    private(set) var captureLogSizeKB = 0

    /// Raised on `.error(.backgroundPermissionMissing, _)` and on a mid-session downgrade.
    ///
    /// **A degradation, not a failure.** The SDK keeps capturing in the foreground with only
    /// When-In-Use, and a sample that treated this as fatal would teach hosts to throw away the
    /// case where the user has the app open on a walk.
    var showsAlwaysRationale = false

    private(set) var alwaysRationale: String?

    // MARK: - Dependencies

    @ObservationIgnored private let trackIt: Tracker
    @ObservationIgnored private let captureLog: CaptureLog

    // MARK: - Internal state

    /// Backing storage for `selectedSessionID`. **Deliberately observed**, not ignored: a
    /// `SessionPicker` bound to the computed property reads this through it, and an ignored store
    /// would leave the picker showing the previous selection after the user changed it.
    private var pinnedSessionID: String?

    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    @ObservationIgnored private var tier: AuthorizationTier = .none
    @ObservationIgnored private var accuracy: LocationAccuracy = .reduced
    @ObservationIgnored private var motionAuthorization: MotionAuthorization = .notDetermined
    @ObservationIgnored private var provider = ProviderState()
    @ObservationIgnored private var sensors = TrackingViewModel.unknownSensors
    @ObservationIgnored private var detectedActivity: ActivityType?
    @ObservationIgnored private var lastError: String?

    @ObservationIgnored private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let logger = Logger(
        subsystem: "com.fieldtrack360.tracker.sample",
        category: "state"
    )

    // MARK: - Not thresholds

    /// How many lines the on-screen feed keeps. A list bound, not a decision: nothing compares it,
    /// and the durable record is the capture log.
    private static let logCapacity = 300

    /// The page a session dump reads. `buildTrack` raises `truncated` when a page comes back full,
    /// so both reads use the same bound and the warning stays honest.
    private static let dumpPageSize = 5000

    /// Before the probe has run, nothing is known. Reported as absent rather than as present, so a
    /// status card cannot claim a capability the app has not confirmed.
    private static let unknownSensors = DeviceSensors(
        activityRecognition: false,
        stepCounting: false,
        significantLocationChange: false,
        regionMonitoring: false,
        motionQuality: .poor
    )

    // MARK: - Init

    init(
        trackIt: Tracker = .shared,
        captureLog: CaptureLog = CaptureLog()
    ) {
        self.trackIt = trackIt
        self.captureLog = captureLog
    }

    // MARK: - Lifecycle

    /// Permissions, then the run header, then the sessions, then the event stream.
    ///
    /// The order is the content. The run header carries the permission and sensor context that
    /// makes every line after it interpretable, so it has to be written before the first event can
    /// arrive — and the events have to be consumed last, because a subscription opened first would
    /// deliver lines into a file with no banner above them.
    ///
    /// Idempotent: `TabView` re-runs a `.task` every time its tab reappears, and a second
    /// subscription would double every line in the log and in the feed. The flag is set before the
    /// first `await`, which on the main actor is what makes the guard airtight against two tabs
    /// calling this in the same turn.
    func onAppear() async {
        guard !self.hasStarted else { return }
        self.hasStarted = true

        self.state = .loading
        self.refreshPermissions()

        await self.captureLog.runHeader(
            sensors: self.sensors,
            tier: self.tier,
            accuracy: self.accuracy,
            motion: self.motionAuthorization,
            provider: self.provider
        )

        await self.loadSessions()
        await self.refresh()
        self.startObserving()
    }

    /// Cancels the event subscription.
    ///
    /// Deliberately **not** named `onDisappear`: a tab going off screen must not stop the stream,
    /// or the feed loses everything that happened while the user was reading the map. Called from a
    /// scene teardown, never from a `deinit`.
    func teardown() {
        self.eventTask?.cancel()
        self.eventTask = nil
        self.refreshTask?.cancel()
        self.refreshTask = nil
        self.hasStarted = false
    }

    // MARK: - Reads

    /// Rebuilds the snapshot, resolving the session the whole app is describing.
    func refresh() async {
        do {
            // SESSION PINNING: a session picked on Home wins over the live one.
            let sessionID: String?
            if let pinned = self.pinnedSessionID {
                sessionID = pinned
            } else {
                sessionID = try await self.trackIt.currentSession()?.id
            }

            // A `nil` session id would count every point in the database, which reads as a wildly
            // wrong number for a run that has not started yet.
            let pointCount: Int
            if let sessionID {
                pointCount = try await self.trackIt.getCount(PointQuery(sessionID: sessionID))
            } else {
                pointCount = 0
            }

            self.state = .loaded(self.makeSnapshot(sessionID: sessionID, pointCount: pointCount))
            self.captureLogSizeKB = await self.captureLog.sizeKB()
        } catch {
            Self.logger.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
            await self.captureLog.note(
                kind: "NOTE",
                detail: "refresh failed: \(error.localizedDescription)"
            )
            self.state = .failed(error.localizedDescription)
        }
    }

    func loadSessions() async {
        do {
            self.sessions = try await self.trackIt.getSessions()
        } catch {
            // Never swallowed: an empty picker and a failed query look identical on screen.
            Self.logger.error("Sessions not loaded: \(error.localizedDescription, privacy: .public)")
            await self.captureLog.note(
                kind: "NOTE",
                detail: "sessions could not be loaded: \(error.localizedDescription)"
            )
            self.record("SESSIONS", "could not be loaded — \(error.localizedDescription)")
        }
    }

    /// Re-reads the authorization tier, accuracy, motion consent, provider snapshot and sensors.
    ///
    /// Synchronous because every read behind it is: the SDK publishes these rather than polling
    /// them, so this costs nothing and can be called from any button that might have changed one.
    func refreshPermissions() {
        let permissions = self.trackIt.permissions()
        self.tier = permissions.tier()
        self.accuracy = permissions.accuracy()
        self.motionAuthorization = permissions.motionAuthorization()
        self.provider = self.trackIt.currentProviderState()
        self.sensors = self.trackIt.getSensors()
        self.rebuildSnapshot()
    }

    // MARK: - Tracking

    func start(tag: String? = nil) async {
        await self.captureLog.note(kind: "NOTE", detail: "start requested tag=\(tag ?? "none")")

        switch await self.trackIt.start(tag: tag) {
        case .success(let session):
            // Starting a run releases the pin: the instruments follow the run that was just
            // started, which is what somebody pressing Start is asking for.
            self.pinnedSessionID = nil
            self.lastError = nil
            self.record("START", "session \(TrackingSnapshot.short(session.id))")
            await self.loadSessions()
            await self.refresh()

        case .failure(let code, let message):
            // A refusal is not a crash and not a silent no-op. `start()` refuses for exactly two
            // reasons — no authorization at all, and reduced accuracy — and both are fixable by
            // the user, so both have to reach the screen.
            self.lastError = "\(code.rawValue): \(message)"
            self.record("START", "refused — \(code.rawValue): \(message)")
            await self.captureLog.note(
                kind: "NOTE",
                detail: "start refused code=\(code.rawValue) message=\(message)"
            )
            self.rebuildSnapshot()

        // `TrackerResult` is resilient like every other public enum in a binary
        // distribution, so a host has to answer for a third case even though
        // today there are two. Treated as a refusal: an outcome this build cannot
        // read is not evidence that a run started.
        @unknown default:
            self.lastError = "start returned an unrecognised result"
            self.record("START", "refused — unrecognised result")
            self.rebuildSnapshot()
        }
    }

    func stop() async {
        await self.captureLog.note(kind: "NOTE", detail: "stop requested")

        switch await self.trackIt.stop() {
        case .success(let session):
            self.record("STOP", "session \(TrackingSnapshot.short(session?.id))")
        case .failure(let code, let message):
            self.lastError = "\(code.rawValue): \(message)"
            self.record("STOP", "failed — \(code.rawValue): \(message)")
        @unknown default:
            self.lastError = "stop returned an unrecognised result"
            self.record("STOP", "failed — unrecognised result")
        }
        await self.loadSessions()
        await self.refresh()
    }

    // MARK: - The permission ladder

    /// Step 1. Always first — asking for Always from `.notDetermined` permanently loses background
    /// tracking on first launch.
    ///
    /// Routed through here rather than called straight off `Tracker.permissions()` so the outcome
    /// reaches the capture log. Authorization is the single largest variable between two field runs
    /// of the same scenario, and a log that does not record when it changed cannot explain them.
    @discardableResult
    func requestWhenInUse() async -> AuthorizationTier {
        let tier = await self.trackIt.permissions().requestWhenInUse()
        await self.captureLog.note(kind: "PERM", detail: "requestWhenInUse -> \(tier.rawValue)")
        self.record("PERM", "when-in-use → \(tier.rawValue)")
        self.refreshPermissions()
        return tier
    }

    /// Step 2. Only after When-In-Use is granted **and the host has shown its own rationale**.
    ///
    /// `.needsSettings` is handed back with its URL rather than opened: presenting it, and saying
    /// in the app's own words what "Allow all the time" buys the user, is the host's job.
    @discardableResult
    func requestAlways() async -> BackgroundRequest {
        let result = await self.trackIt.permissions().requestAlways()
        let outcome: String
        switch result {
        case .alreadyGranted: outcome = "alreadyGranted"
        case .granted: outcome = "granted"
        case .denied: outcome = "denied"
        case .needsWhenInUseFirst: outcome = "needsWhenInUseFirst"
        case .needsSettings: outcome = "needsSettings"
        @unknown default: outcome = "unrecognised"
        }
        await self.captureLog.note(kind: "PERM", detail: "requestAlways -> \(outcome)")
        self.record("PERM", "always → \(outcome)")
        self.refreshPermissions()
        return result
    }

    /// Step 3. Optional. Denial removes one wake path and the activity labels; it is not fatal.
    @discardableResult
    func requestMotion() async -> MotionAuthorization {
        let result = await self.trackIt.permissions().requestMotion()
        await self.captureLog.note(kind: "PERM", detail: "requestMotion -> \(result.rawValue)")
        self.record("PERM", "motion → \(result.rawValue)")
        self.refreshPermissions()
        return result
    }

    /// Where a host sends a user whose answer only Settings can change.
    var settingsURL: URL {
        self.trackIt.permissions().settingsURL
    }

    // MARK: - The capture log

    /// Flushes the queue and hands back the file, or `nil` when there is nothing in it yet.
    ///
    /// Flushing first is not optional: the tail that has not reached disk is exactly the part
    /// somebody sharing the log after a termination needs.
    func prepareCaptureLogForSharing() async -> URL? {
        await self.captureLog.flush()
        self.captureLogSizeKB = await self.captureLog.sizeKB()
        guard await self.captureLog.sizeBytes() > 0 else {
            self.record("LOG", "nothing to share yet")
            return nil
        }
        return self.captureLog.fileURL
    }

    /// Step 2 of the field-run protocol, immediately before a run. The run banner is re-emitted, so
    /// clearing does not cost the device and permission context the run is about to be read against.
    func clearCaptureLog() async {
        await self.captureLog.clear()
        await self.captureLog.flush()
        self.captureLogSizeKB = await self.captureLog.sizeKB()
        self.record("LOG", "cleared")
    }

    /// Writes the four analysis blocks and the track summary for the resolved session.
    ///
    /// This is the "After" half of the field-run protocol, and without a caller `HIST` never exists
    /// — which would leave the most useful block in the file unreachable from the device that
    /// recorded it.
    func dumpSession() async {
        guard let sessionID = self.state.value?.sessionID else {
            self.record("DUMP", "no session selected")
            return
        }
        do {
            let query = PointQuery(sessionID: sessionID, limit: Self.dumpPageSize)
            let rawFixes = try await self.trackIt.getRawFixes(sessionID: sessionID)
            let decisions = try await self.trackIt.getDecisions(
                sessionID: sessionID,
                limit: Self.dumpPageSize
            )
            let points = try await self.trackIt.getPoints(query)

            await self.captureLog.sessionDump(
                sessionID: sessionID,
                rawFixes: rawFixes,
                decisions: decisions,
                points: points
            )

            var options = TrackOptions()
            options.snapToRoad = self.snapToRoad
            let track = try await self.trackIt.buildTrack(query, options: options)
            await self.captureLog.trackSummary(track)

            self.captureLogSizeKB = await self.captureLog.sizeKB()
            self.record(
                "DUMP",
                "\(TrackingSnapshot.short(sessionID)) — \(rawFixes.count) raw → \(points.count) stored"
            )
        } catch {
            Self.logger.error("Session dump failed: \(error.localizedDescription, privacy: .public)")
            self.lastError = error.localizedDescription
            self.record("DUMP", "failed — \(error.localizedDescription)")
            self.rebuildSnapshot()
        }
    }

    /// One fix, without a session — the `getCurrentLocation()` path.
    ///
    /// Deliberately callable while stopped, because that is the case it exists for: a host asking
    /// "where am I" before any track is being recorded. Calling it *during* a session is also
    /// worth exercising by hand — it must not disturb the live stream, and the only way to see
    /// that is to watch the point count keep climbing while this returns.
    ///
    /// `feedIngestor` is left at its default, so the fix is reported and never stored: a button
    /// on a diagnostics screen must not add points to the track being measured.
    func showCurrentLocation() async {
        switch await self.trackIt.getCurrentLocation() {
        case .success(let fix):
            let detail = String(
                format: "%.5f, %.5f ±%.0f m",
                fix.latitude,
                fix.longitude,
                Double(fix.accuracyM)
            )
            await self.captureLog.note(kind: "ONESHOT", detail: detail)
            self.captureLogSizeKB = await self.captureLog.sizeKB()
            self.record("ONESHOT", detail)
        case .failure(let code, let message):
            // The message carries the diagnostic — authorization, master switch, accuracy grant,
            // low-power mode. Logged whole rather than summarised, because summarising it is what
            // turns a settings problem into a bug report.
            await self.captureLog.note(kind: "ONESHOT", detail: "\(code.rawValue) — \(message)")
            self.captureLogSizeKB = await self.captureLog.sizeKB()
            self.record("ONESHOT", "\(code.rawValue) — \(message)")

        // Same rule as `start()`: `TrackerResult` is resilient across a binary boundary, so a
        // host answers for a case this build cannot read. Treated as no fix — an outcome that
        // cannot be interpreted is not a position.
        @unknown default:
            self.record("ONESHOT", "unrecognised result")
        }
    }

    /// Step 4 of the field-run protocol: export a fixture for anything anomalous, **before**
    /// proposing a constant change.
    ///
    /// Written to a temporary file rather than handed back as a string so it leaves the device with
    /// a filename the T1 corpus can keep.
    ///
    /// **No longer gated on `TRACKER_SDK_DEBUG`.** `exportFixture` used to be `#if DEBUG` in the
    /// SDK, so this had to be too — and the consequence was that the only build able to see a
    /// field anomaly was the one build with no recorder in it. The recorder now ships in the
    /// release frameworks and this works in both package modes.
    func recordFixture() async -> URL? {
        guard let sessionID = self.state.value?.sessionID else {
            self.record("FIXTURE", "no session selected")
            return nil
        }
        let name = "session-\(TrackingSnapshot.short(sessionID))-\(Int(Date().timeIntervalSince1970))"
        do {
            let json = try await self.trackIt.exportFixture(sessionID: sessionID, name: name)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).json")
            try json.write(to: url, atomically: true, encoding: .utf8)
            await self.captureLog.note(kind: "FIXTURE", detail: "recorded \(name)")
            self.captureLogSizeKB = await self.captureLog.sizeKB()
            self.record("FIXTURE", "recorded \(name)")
            return url
        } catch {
            Self.logger.error("Fixture export failed: \(error.localizedDescription, privacy: .public)")
            self.record("FIXTURE", "failed — \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - The event stream

    /// A retained, cancellable `Task`. Never detached, never started in a `deinit`.
    private func startObserving() {
        let events = self.trackIt.events()
        self.eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
    }

    /// **The capture log is written first, every time.**
    ///
    /// It is the durable record; the on-screen feed below is a convenience capped at 300 lines. An
    /// order that formatted the UI line first would put the cheap, disposable half of this method
    /// ahead of the half a field report depends on.
    ///
    /// Every case of `TrackerEvent` is handled. A sample that handles four of fourteen teaches the
    /// wrong integration.
    private func handle(_ event: TrackerEvent) async {
        await self.captureLog.event(event)

        switch event {
        case .location(let point):
            self.mutate { snapshot in
                snapshot.pointCount += 1
            }
            self.record("POINT", "\(Self.metresText(point.accuracyM)) · \(point.acceptReason)")

        case .locationRejected(let decision):
            self.record(
                Self.verdictWord(decision.verdict),
                "\(decision.reason) · moved \(Self.metresText(Float(decision.distanceMovedM)))"
                    + " · σ\(Self.oneDecimal(decision.sigma))/\(Self.oneDecimal(decision.threshold))"
            )

        case .motionChange(let motionState, _):
            self.mutate { snapshot in
                snapshot.motionState = motionState
            }
            self.record("MOTION", motionState.rawValue)

        case .activityChange(let activity, let confidence):
            self.detectedActivity = activity
            self.mutate { snapshot in
                snapshot.detectedActivity = activity
            }
            self.record("ACTIVITY", "\(activity.rawValue) · confidence \(confidence)")

        case .enabledChange(let isEnabled):
            self.mutate { snapshot in
                snapshot.isTracking = isEnabled
            }
            self.record("ENABLED", isEnabled ? "tracking" : "stopped")
            // A session has just opened or closed: the picker and the resolved session both move.
            await self.loadSessions()
            await self.refresh()

        case .providerChange(let provider):
            self.handleProviderChange(provider)

        case .heartbeat(let atMs):
            self.record("HEART", self.clock.string(from: Date(timeIntervalSince1970: Double(atMs) / 1000)))

        // Recorded here as well as on the Fences screen: a tester reading one feed should not have
        // to know which screen owns which event, and a crossing is often the explanation for what
        // the tracking feed did next.
        case .geofenceEnter(let crossing):
            self.record("FENCE", "enter \(crossing.geofenceID)")

        case .geofenceExit(let crossing):
            self.record("FENCE", "exit \(crossing.geofenceID)")

        case .geofenceDwell(let crossing):
            self.record("FENCE", "dwell \(crossing.geofenceID)")

        case .powerSaveChange(let isOn):
            self.record("POWER", isOn ? "low power on" : "low power off")
            // The provider snapshot carries `lowPowerMode`; re-read rather than patching one field
            // of an immutable struct from an event that only carries the one bit.
            self.refreshPermissions()

        case .sessionInterrupted(let session):
            // Reported, not adopted. `start()` opens a fresh session; this row is the evidence that
            // the OS terminated the process mid-run.
            self.record("SESSION", "interrupted \(TrackingSnapshot.short(session.id))")
            await self.loadSessions()

        case .diagnostic(let text):
            self.record("DIAG", text)

        case .error(let code, let message):
            self.handleError(code: code, message: message)

        // The SDK ships as a resilient binary, so a newer TrackerCore can emit an
        // event this build has no case for. Recorded rather than ignored: the point
        // of handling every case is that silence in the log means "it did not
        // happen", and a silently dropped event breaks that guarantee.
        @unknown default:
            self.record("EVENT", "unrecognised event — SDK is newer than this build")
        }
    }

    /// Authorization moves underneath a running app, and both directions matter.
    ///
    /// A mid-session downgrade is the case hosts forget: iOS may confirm a provisional Always grant
    /// with the user days later and take it away, and the tracker keeps running with less than it
    /// started with. The rationale is raised rather than the session torn down.
    private func handleProviderChange(_ provider: ProviderState) {
        let previous = self.provider
        self.provider = provider
        self.tier = provider.authorization
        self.accuracy = provider.accuracyAuthorization
        self.rebuildSnapshot()
        self.record(
            "PROVIDER",
            "auth \(provider.authorization.rawValue) · accuracy \(provider.accuracyAuthorization.rawValue)"
                + " · services \(provider.locationServicesEnabled ? "on" : "off")"
        )

        if previous.authorization == .always, provider.authorization != .always {
            self.alwaysRationale = "Background authorization was withdrawn while a run was in "
                + "progress. Tracking continues while the app is open; it stops as soon as the app "
                + "is backgrounded. Allow \"Always\" again to record complete trips."
            self.showsAlwaysRationale = true
            self.record("PERM", "downgraded from always to \(provider.authorization.rawValue)")
        }

        if provider.authorization == .none {
            self.lastError = "Location authorization was withdrawn; no fix can be delivered."
            self.rebuildSnapshot()
        }

        if !provider.locationServicesEnabled {
            self.lastError = "Location Services is switched off for this device."
            self.rebuildSnapshot()
        }
    }

    /// `.backgroundPermissionMissing` is a **degradation**, not a failure.
    ///
    /// The SDK emits it and keeps capturing rather than refusing to start, because refusing throws
    /// away the foreground case entirely — a user with the app open on a walk would get nothing.
    /// The sample's job here is to show the rationale and carry on, which is the handling a host
    /// should copy.
    private func handleError(
        code: ErrorCode,
        message: String
    ) {
        switch code {
        case .backgroundPermissionMissing:
            self.alwaysRationale = message
            self.showsAlwaysRationale = true
            self.record("DEGRADED", "\(code.rawValue) — foreground tracking continues")

        default:
            self.lastError = "\(code.rawValue): \(message)"
            self.record("ERROR", "\(code.rawValue) — \(message)")
        }
        self.rebuildSnapshot()
    }

    // MARK: - Snapshot plumbing

    private func makeSnapshot(
        sessionID: String?,
        pointCount: Int
    ) -> TrackingSnapshot {
        TrackingSnapshot(
            isReady: self.trackIt.state.isReady,
            isTracking: self.trackIt.state.isTracking,
            motionState: self.trackIt.state.motionState,
            detectedActivity: self.detectedActivity,
            tier: self.tier,
            accuracy: self.accuracy,
            motionAuthorization: self.motionAuthorization,
            provider: self.provider,
            sensors: self.sensors,
            sessionID: sessionID,
            isPinnedSession: self.pinnedSessionID != nil,
            pointCount: pointCount,
            lastError: self.lastError
        )
    }

    /// Rebuilds everything except the two numbers that cost a database read.
    private func rebuildSnapshot() {
        self.mutate { snapshot in
            snapshot = self.makeSnapshot(
                sessionID: snapshot.sessionID,
                pointCount: snapshot.pointCount
            )
        }
    }

    /// Mutates in place, or does nothing before the first load. Nothing here is the source of
    /// truth — the next `refresh()` rebuilds from storage regardless.
    private func mutate(_ change: (inout TrackingSnapshot) -> Void) {
        guard case .loaded(var snapshot) = self.state else { return }
        change(&snapshot)
        self.state = .loaded(snapshot)
    }

    private func scheduleRefresh() {
        self.refreshTask?.cancel()
        self.refreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    // MARK: - The on-screen feed

    /// One monospaced line, newest first, capped at `logCapacity`.
    private func record(
        _ kind: String,
        _ detail: String
    ) {
        let padded = kind.count >= 9 ? kind : kind + String(repeating: " ", count: 9 - kind.count)
        self.log.insert("\(self.clock.string(from: Date()))  \(padded) \(detail)", at: 0)
        if self.log.count > Self.logCapacity {
            self.log.removeLast(self.log.count - Self.logCapacity)
        }
    }

    private static func verdictWord(_ verdict: Verdict) -> String {
        switch verdict {
        case .accept: "ACCEPT"
        case .skip: "SKIP"
        case .reject: "REJECT"
        @unknown default: "UNKNOWN"
        }
    }

    private static func metresText(_ value: Float) -> String {
        "\(Self.oneDecimal(value))m"
    }

    private static func oneDecimal(_ value: Float) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }
}
