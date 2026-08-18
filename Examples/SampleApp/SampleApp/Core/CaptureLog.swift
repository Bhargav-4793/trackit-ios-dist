import Foundation
import TrackerCore
import TrackerGeo
import os

// MARK: - CaptureLog

/// A file-backed, append-only session log. **The durable record the field matrix rests on.**
///
/// `docs/app/61-diagnostics.md` — instrument before you tune. The single most expensive mistake
/// available on this project is changing a constant to fix a field report without first knowing
/// which layer the artefact appeared in, and this file is what makes that knowable a week later,
/// on a device nobody has a debugger attached to.
///
/// Five design constraints, each with a reason:
///
/// | Constraint | Reason |
/// |---|---|
/// | **Never blocks the caller** | An `actor` with a bounded buffer and a separate drain. A logger that back-pressures the event stream changes the behaviour it is measuring |
/// | **Flushes every line** | The unflushed tail is exactly the data you need after a termination |
/// | **Fixed locale everywhere** | `en_US_POSIX`. A decimal comma corrupts every coordinate in the file |
/// | **Reopens on write failure** | The handle is dropped on error so the next line re-opens, rather than failing silently forever |
/// | **One file, appended, with run banners** | A per-session file loses the cross-session comparison, which is where OEM and permission problems show up |
///
/// It lives in the app's Documents directory so it can be shared off the device without Xcode.
/// Sharing it is a Phase 7 exit criterion: the log is only worth writing if it can leave.
actor CaptureLog {

    // MARK: - Storage

    /// `nonisolated` so a `ShareLink` can name the file without an `await`. It is a `let` of a
    /// `Sendable` type, so there is nothing to isolate.
    nonisolated let fileURL: URL

    /// Dropped and re-opened on any write failure. A handle that has gone bad stays bad, and a
    /// logger that fails silently forever is worse than one that fails loudly once.
    private var handle: FileHandle?

    /// The bounded buffer. Appends land here and return; the drain does the I/O.
    private var pending: [String] = []

    /// The retained drain. One at a time, never detached, never started in a `deinit`.
    private var drainTask: Task<Void, Never>?

    /// Reported in the file rather than swallowed: a log with a hole in it that says so is
    /// diagnosable, and one that lies about being complete is not.
    private var droppedLines = 0

    /// The run banner, kept in memory so `clear()` can re-emit it.
    ///
    /// Step 2 of the field-run protocol is "clear the capture log", immediately before a run.
    /// Losing the device, iOS version and permission context at exactly that moment would make the
    /// run that follows uninterpretable.
    private var headerLines: [String] = []

    private static let logger = Logger(
        subsystem: "com.fieldtrack360.tracker.sample",
        category: "capture-log"
    )

    // MARK: - Not thresholds

    /// How many unwritten lines the buffer will hold before it starts dropping.
    ///
    /// A buffer depth, not a tuning constant: nothing compares it and nothing decides on it. It is
    /// the point past which this logger would have to slow the event stream down to keep up, and
    /// slowing the event stream down is the one thing it may never do.
    private static let bufferCapacity = 4096

    /// Consecutive stored points further apart than this are reported in the `JUMP` block.
    ///
    /// **Distance, not time, is the trigger**: a 300 m hop is a defect whether it took 12 s or
    /// 12 min. This is a reporting threshold in a host app, not an engine constant — nothing in the
    /// pipeline reads it.
    private static let jumpThresholdM: Double = 250

    /// The width of the line-kind column. Purely cosmetic; it is what makes the file scannable by
    /// eye in a mail client with no syntax highlighting.
    private static let kindWidth = 8

    /// Bounded so `flush()` cannot spin forever against a caller that is still appending.
    private static let flushAttempts = 8

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// One file, appended across launches. A per-session file loses the cross-session comparison,
    /// which is where OEM and permission problems show up.
    ///
    /// Not `private`, because it is a default argument of an internal initialiser and Swift will
    /// not let one reference a less visible declaration.
    static let defaultFileName = "tracker-capture.log"

    // MARK: - Formatters

    private let stamp: DateFormatter = CaptureLog.makeFormatter("yyyy-MM-dd HH:mm:ss.SSS")

    private let bannerStamp: DateFormatter = CaptureLog.makeFormatter("yyyy-MM-dd HH:mm:ss")

    /// `en_US_POSIX` is required, not cosmetic. Under a locale with a decimal comma every
    /// coordinate, sigma and gate in the file becomes unparseable and, worse, plausible.
    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = CaptureLog.posix
        formatter.dateFormat = format
        return formatter
    }

    // MARK: - Init

    init(fileName: String = CaptureLog.defaultFileName) {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
        // A fallback rather than a force unwrap. Documents is always present on iOS; a sample app
        // that traps on the one device where it is not would lose the run it was recording.
        let directory = documents ?? FileManager.default.temporaryDirectory
        self.fileURL = directory.appendingPathComponent(fileName)
    }

    // MARK: - Append

    /// Queues one line. Returns as soon as the buffer has it — the write happens in the drain.
    func append(_ line: String) {
        guard self.pending.count < CaptureLog.bufferCapacity else {
            self.droppedLines += 1
            return
        }
        self.pending.append(line)
        self.scheduleDrain()
    }

    /// Something the app itself wants on the record: a button press, a refused start, a scenario
    /// label. `kind` is the caller's own column name so a field tester can grep for it.
    func note(
        kind: String,
        detail: String
    ) {
        self.append(self.line(kind, detail))
    }

    // MARK: - Run header

    /// Emitted at every launch. Carries the context that makes the rest of the file interpretable.
    ///
    /// Without it a log is a list of verdicts with no way to tell whether the device had Always
    /// authorization, full accuracy, a pedometer, or a wake path at all — and those four facts
    /// explain most of what the verdicts below will say.
    ///
    /// - Note: `motion` is not in the sketch in `docs/app/61-diagnostics.md` but the `PERM` line it
    ///   specifies ends in `motion=authorized`, so the value has to arrive from somewhere. It comes
    ///   from `PermissionManager.motionAuthorization()`.
    func runHeader(
        sensors: DeviceSensors,
        tier: AuthorizationTier,
        accuracy: LocationAccuracy,
        motion: MotionAuthorization,
        provider: ProviderState
    ) {
        let rule = String(repeating: "=", count: 78)
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let system = ProcessInfo.processInfo.operatingSystemVersion

        var lines = [rule]
        lines.append(CaptureLog.banner("RUN", self.bannerStamp.string(from: Date())))
        lines.append(CaptureLog.banner("APP", "\(short) (\(build))"))
        lines.append(CaptureLog.banner("DEVICE", CaptureLog.deviceModel()))
        lines.append(CaptureLog.banner(
            "IOS",
            "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        ))
        lines.append(CaptureLog.banner(
            "PERM",
            "tier=\(tier.rawValue) accuracy=\(accuracy.rawValue) motion=\(motion.rawValue)"
        ))
        lines.append(CaptureLog.banner(
            "PROVIDER",
            "services=\(CaptureLog.onOff(provider.locationServicesEnabled))"
                + " slc=\(CaptureLog.yesNo(provider.significantLocationChangeAvailable))"
                + " region=\(CaptureLog.yesNo(provider.regionMonitoringAvailable))"
                + " lowPower=\(CaptureLog.yesNo(provider.lowPowerMode))"
        ))
        lines.append(CaptureLog.banner(
            "SENSORS",
            "activity=\(CaptureLog.yesNo(sensors.activityRecognition))"
                + " steps=\(CaptureLog.yesNo(sensors.stepCounting))"
                + " quality=\(sensors.motionQuality.rawValue)"
        ))
        lines.append(contentsOf: CaptureLog.legend)
        lines.append(rule)

        self.headerLines = lines
        for line in lines {
            self.append(line)
        }
    }

    /// The embedded "HOW TO READ THIS FILE" legend.
    ///
    /// The log gets mailed to people who have never seen the codebase, and a file of key=value
    /// pairs with no units is a file nobody outside the project can act on.
    private static let legend: [String] = [
        CaptureLog.banner("HOWTO", "HOW TO READ THIS FILE"),
        CaptureLog.banner("HOWTO", "Every event line is: <local time> | KIND | key=value …"),
        CaptureLog.banner("HOWTO", "Units: distances m, speeds m/s, times s, angles deg, accuracy m."),
        CaptureLog.banner("HOWTO", "POINT    a fix that WAS stored. odo=session odometer. spd/brg=n/a means the platform flagged them invalid — that is not zero."),
        CaptureLog.banner("HOWTO", "DECISION a fix that was NOT stored. moved=distance from the last stored point, sigma=filter innovation, gate=the threshold it was compared against."),
        CaptureLog.banner("HOWTO", "MOTION   capture state machine: stopped/moving/stopPending/stationary. It gates the sampling rate, never capture itself."),
        CaptureLog.banner("HOWTO", "ACTIVITY CoreMotion's label with confidence 0=low 1=medium 2=high."),
        CaptureLog.banner("HOWTO", "PROVIDER authorization, precise location, Location Services and Low Power Mode, as they changed."),
        CaptureLog.banner("HOWTO", "ERROR    an SDK error code and message. backgroundPermissionMissing is a DEGRADATION, not a failure — capture continues in the foreground."),
        CaptureLog.banner("HOWTO", "DIAG     an SDK diagnostic. SESSION a session left open by termination. ENABLED tracking on/off. POWER Low Power Mode. HEART the health loop is alive."),
        CaptureLog.banner("HOWTO", "NOTE     something this app recorded. DROP lines lost because the buffer was full."),
        CaptureLog.banner("HOWTO", "HIST     verdict histogram, descending. A wall of Drift Suppressed is a departure-ladder problem; a wall of Sigma Gate Outlier is a filter-lag problem. THEY HAVE OPPOSITE FIXES."),
        CaptureLog.banner("HOWTO", "ACCEPTBY accepted points grouped by the reason that accepted them."),
        CaptureLog.banner("HOWTO", "CADENCE  seconds between stored points. The ceiling on turn fidelity: a 60 s median while driving is a tier-gate problem, and no filter change will help."),
        CaptureLog.banner("HOWTO", "JUMP     consecutive stored points more than 250 m apart, then the decisions inside that window. 'No fixes offered' is a capture gap, not a filter gap — a different bug entirely."),
        CaptureLog.banner("HOWTO", "TRACK    the built track's summary numbers."),
        CaptureLog.banner("HOWTO", "Read HIST first, then JUMP. Between them they name most problems before anyone opens Xcode."),
    ]

    // MARK: - Events

    /// One line per SDK event, in the file's own vocabulary.
    ///
    /// Every case of `TrackerEvent` is handled. A log that records four of fourteen is a log whose
    /// silence means nothing, because nobody can tell "it did not happen" from "we do not write
    /// that one down".
    func event(_ event: TrackerEvent) {
        switch event {
        case .location(let point):
            self.append(self.line("POINT", CaptureLog.describe(point)))

        case .locationRejected(let decision):
            self.append(self.line("DECISION", CaptureLog.describe(decision)))

        case .motionChange(let state, let point):
            let at = point.map { CaptureLog.coordinate($0.latitude, $0.longitude) } ?? "n/a"
            self.append(self.line("MOTION", "state=\(state.rawValue) at=\(at)"))

        case .activityChange(let activity, let confidence):
            self.append(self.line("ACTIVITY", "type=\(activity.rawValue) confidence=\(confidence)"))

        case .enabledChange(let isEnabled):
            self.append(self.line("ENABLED", "tracking=\(isEnabled)"))

        case .providerChange(let provider):
            self.append(self.line("PROVIDER", CaptureLog.describe(provider)))

        case .heartbeat(let atMs):
            self.append(self.line("HEART", "at=\(self.bannerStamp.string(from: CaptureLog.date(atMs)))"))

        // The centre and radius travel with the line, because a crossing read back a week later
        // has to be interpretable after the fence itself has been removed.
        case .geofenceEnter(let crossing):
            self.append(self.line("FENCE", CaptureLog.describe(crossing, "enter")))

        case .geofenceExit(let crossing):
            self.append(self.line("FENCE", CaptureLog.describe(crossing, "exit")))

        case .geofenceDwell(let crossing):
            self.append(self.line("FENCE", CaptureLog.describe(crossing, "dwell")))

        case .powerSaveChange(let isOn):
            self.append(self.line("POWER", "lowPower=\(isOn)"))

        case .sessionInterrupted(let session):
            self.append(self.line(
                "SESSION",
                "interrupted id=\(session.id)"
                    + " started=\(self.bannerStamp.string(from: CaptureLog.date(session.startedAtMs)))"
                    + " tag=\(session.tag ?? "none")"
            ))

        case .diagnostic(let text):
            self.append(self.line("DIAG", text))

        case .error(let code, let message):
            self.append(self.line("ERROR", "code=\(code.rawValue) message=\(message)"))

        // See the note above: a log that silently drops an unrecognised event is a
        // log whose silence no longer means anything.
        @unknown default:
            self.append(self.line("EVENT", "unrecognised event — SDK is newer than this build"))
        }
    }

    // MARK: - Session dump

    /// The part that turns a log into an answer.
    ///
    /// Four analysis blocks, each justified by a question somebody actually asks after a field run,
    /// preceded by the layer counts and the **raw fixes → stored points** ratio. A wide gap in that
    /// ratio is the thing to go and explain.
    func sessionDump(
        sessionID: String,
        rawFixes: [RawFix],
        decisions: [FixDecision],
        points: [TrackPoint]
    ) {
        self.append(CaptureLog.banner("DUMP", String(repeating: "-", count: 66)))
        self.append(CaptureLog.banner("DUMP", "session=\(sessionID) at=\(self.bannerStamp.string(from: Date()))"))
        self.append(CaptureLog.banner(
            "DUMP",
            "layers: rawFixes=\(rawFixes.count) decisions=\(decisions.count)"
                + " storedPoints=\(points.count) ratio=\(CaptureLog.ratio(rawFixes.count, points.count))"
        ))
        if rawFixes.isEmpty {
            self.append(CaptureLog.banner(
                "DUMP",
                "the raw-fix layer is empty — enable persistRawFixes before the run, or layer 1 cannot answer anything"
            ))
        }

        self.histogram(decisions)
        self.acceptedBy(points)
        self.cadence(points)
        self.jumps(points: points, decisions: decisions)
        self.append(CaptureLog.banner("DUMP", String(repeating: "-", count: 66)))
    }

    /// `HIST` — verdicts grouped by `VERDICT/reason`, descending.
    ///
    /// The single highest-value block in the file. A wall of `Drift Suppressed` and a wall of
    /// `Sigma Gate Outlier` look equally alarming and have opposite fixes; this tells you which
    /// one you have.
    private func histogram(_ decisions: [FixDecision]) {
        guard !decisions.isEmpty else {
            self.append(CaptureLog.banner("HIST", "no decisions recorded — no fix was ever offered to the pipeline"))
            return
        }
        var counts: [String: Int] = [:]
        for decision in decisions {
            counts[CaptureLog.verdictKey(decision), default: 0] += 1
        }
        for entry in CaptureLog.descending(counts) {
            self.append(CaptureLog.banner("HIST", CaptureLog.tally(
                label: entry.key,
                count: entry.value,
                total: decisions.count
            )))
        }
    }

    /// `ACCEPTBY` — stored points grouped by the reason that accepted them.
    private func acceptedBy(_ points: [TrackPoint]) {
        guard !points.isEmpty else {
            self.append(CaptureLog.banner("ACCEPTBY", "no points were stored for this session"))
            return
        }
        var counts: [String: Int] = [:]
        for point in points {
            counts[point.acceptReason, default: 0] += 1
        }
        for entry in CaptureLog.descending(counts) {
            self.append(CaptureLog.banner("ACCEPTBY", CaptureLog.tally(
                label: entry.key,
                count: entry.value,
                total: points.count
            )))
        }
    }

    /// `CADENCE` — the seconds between stored points.
    ///
    /// The ceiling on turn fidelity. If the median is 60 s while driving, no filter change will
    /// help — the tier gate is the problem, and the constant somebody was about to change is not.
    private func cadence(_ points: [TrackPoint]) {
        // Points arrive ordered by id and are deliberately not re-sorted: `PointQuery` documents
        // that ordering by `timeMs` is a correctness mistake, not a preference.
        var deltas: [Double] = []
        for index in 1..<max(points.count, 1) {
            let delta = Double(points[index].timeMs - points[index - 1].timeMs) / 1000
            if delta >= 0 {
                deltas.append(delta)
            }
        }
        guard !deltas.isEmpty else {
            self.append(CaptureLog.banner("CADENCE", "fewer than two stored points — no cadence to report"))
            return
        }
        let sorted = deltas.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
        self.append(CaptureLog.banner(
            "CADENCE",
            "points=\(points.count) median=\(CaptureLog.number(median, 1))s"
                + " min=\(CaptureLog.number(sorted[0], 1))s"
                + " max=\(CaptureLog.number(sorted[sorted.count - 1], 1))s"
        ))
    }

    /// `JUMP` — consecutive stored points more than 250 m apart, and what was offered in between.
    ///
    /// The `└─` line is the whole point of the block. "Fixes were offered and rejected" and "no
    /// fix was offered at all" look identical on a map and are different bugs: the first is the
    /// pipeline's, the second is background execution's. Getting that distinction wrong costs days.
    private func jumps(
        points: [TrackPoint],
        decisions: [FixDecision]
    ) {
        guard points.count >= 2 else {
            self.append(CaptureLog.banner("JUMP", "fewer than two stored points — nothing to compare"))
            return
        }

        var found = 0
        for index in 1..<points.count {
            let from = points[index - 1]
            let to = points[index]
            let distanceM = CaptureLog.metres(from, to)
            guard distanceM > CaptureLog.jumpThresholdM else { continue }

            found += 1
            let durationSec = max(Double(to.timeMs - from.timeMs) / 1000, 0)
            let implied = durationSec > 0 ? distanceM / durationSec : 0
            self.append(CaptureLog.banner(
                "JUMP",
                "#\(found) dist=\(CaptureLog.number(distanceM, 1))m"
                    + " dt=\(CaptureLog.number(durationSec, 1))s"
                    + " implied=\(CaptureLog.number(implied, 1))m/s"
                    + " from=\(CaptureLog.coordinate(from.latitude, from.longitude))"
                    + " to=\(CaptureLog.coordinate(to.latitude, to.longitude))"
            ))

            let window = decisions.filter { decision in
                decision.fix.timeMs > from.timeMs && decision.fix.timeMs < to.timeMs
            }
            guard !window.isEmpty else {
                self.append(CaptureLog.banner(
                    "JUMP",
                    "└─ no fixes were offered in this window — a capture gap, not a filter gap"
                ))
                continue
            }
            var counts: [String: Int] = [:]
            for decision in window {
                counts[CaptureLog.verdictKey(decision), default: 0] += 1
            }
            let breakdown = CaptureLog.descending(counts)
                .map { "\($0.key)×\($0.value)" }
                .joined(separator: "  ")
            self.append(CaptureLog.banner(
                "JUMP",
                "└─ \(window.count) fixes were offered inside this window: \(breakdown)"
            ))
        }

        if found == 0 {
            self.append(CaptureLog.banner(
                "JUMP",
                "none — no consecutive stored points more than \(Int(CaptureLog.jumpThresholdM)) m apart"
            ))
        }
    }

    // MARK: - Track summary

    /// The built track's numbers, so the log carries what the Track tab was showing.
    func trackSummary(_ track: Track) {
        self.append(CaptureLog.banner(
            "TRACK",
            "dist=\(CaptureLog.number(track.stats.totalDistanceMeters, 1))m"
                + " total=\(track.stats.totalDurationSec)s"
                + " moving=\(track.stats.movingDurationSec)s"
                + " stopped=\(track.stats.stoppedDurationSec)s"
                + " points=\(track.points.count)"
                + " segments=\(track.segments.count)"
                + " stops=\(track.stops.count)"
                + " arrows=\(track.arrows.count)"
        ))
        let activity = track.stats.activityBreakdownSec
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key)=\($0.value)s" }
            .joined(separator: " ")
        self.append(CaptureLog.banner("TRACK", "activity: \(activity.isEmpty ? "none" : activity)"))
        self.append(CaptureLog.banner(
            "TRACK",
            "warnings: \(track.warnings.isEmpty ? "none" : track.warnings.joined(separator: ", "))"
        ))
    }

    // MARK: - Size, flush and clear

    func sizeBytes() -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: self.fileURL.path)
        guard let size = attributes?[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    /// Rounded up, so a file with anything in it never reports 0 KB and reads as missing.
    func sizeKB() -> Int {
        Int((self.sizeBytes() + 1023) / 1024)
    }

    /// Waits until everything queued has reached the file. Call before sharing.
    ///
    /// Bounded rather than "until empty": a caller that is still appending must not be able to hold
    /// a share sheet open forever.
    func flush() async {
        for _ in 0..<CaptureLog.flushAttempts {
            if self.pending.isEmpty, self.drainTask == nil { return }
            if let task = self.drainTask {
                // The actor is released while this suspends, which is exactly what lets the drain
                // it is waiting on make progress. Actor re-entrancy is the mechanism here, not a
                // hazard.
                await task.value
            } else {
                self.scheduleDrain()
            }
        }
    }

    /// Empties the file and re-emits the run banner.
    ///
    /// **The drain is deliberately not cancelled.** It is actor-isolated, so it can only be between
    /// batches while this runs; leaving it alive means the header lines queued below are written by
    /// the drain that is already scheduled, rather than racing a second one against a handle this
    /// method just closed.
    func clear() {
        self.pending.removeAll(keepingCapacity: true)
        self.droppedLines = 0
        self.closeHandle()

        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do {
                try FileManager.default.removeItem(at: self.fileURL)
            } catch {
                CaptureLog.logger.warning(
                    "Capture log not cleared; it will keep growing: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        for line in self.headerLines {
            self.append(line)
        }
        self.append(self.line("NOTE", "capture log cleared"))
    }

    // MARK: - The drain

    private func scheduleDrain() {
        guard self.drainTask == nil else { return }
        self.drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        defer { self.drainTask = nil }

        while !self.pending.isEmpty {
            // A suspension point per batch, so an append that arrived during the last write is
            // taken up here rather than waiting behind the whole queue.
            await Task.yield()

            let batch = self.pending
            self.pending.removeAll(keepingCapacity: true)
            let dropped = self.droppedLines
            self.droppedLines = 0

            var text = batch.joined(separator: "\n") + "\n"
            if dropped > 0 {
                text += self.line("DROP", "\(dropped) lines dropped — the log buffer was full") + "\n"
            }
            self.write(text)
        }
    }

    private func write(_ text: String) {
        guard let handle = self.openHandle() else { return }
        do {
            try handle.write(contentsOf: Data(text.utf8))
            // Flush every line: the unflushed tail is exactly the data you need after a
            // termination, which is the case this file exists to explain.
            try handle.synchronize()
        } catch {
            CaptureLog.logger.error(
                "Capture log write failed; the handle will be reopened for the next line: \(error.localizedDescription, privacy: .public)"
            )
            self.closeHandle()
        }
    }

    private func openHandle() -> FileHandle? {
        if let handle = self.handle { return handle }

        let manager = FileManager.default
        if !manager.fileExists(atPath: self.fileURL.path) {
            manager.createFile(atPath: self.fileURL.path, contents: nil)
        }
        do {
            let opened = try FileHandle(forWritingTo: self.fileURL)
            // `forWritingTo` opens at offset 0. Without this every launch would overwrite the file
            // it is supposed to be appending to, and the cross-session comparison — which is where
            // OEM and permission problems show up — would be gone.
            _ = try opened.seekToEnd()
            self.handle = opened
            return opened
        } catch {
            CaptureLog.logger.error(
                "Capture log could not be opened at \(self.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func closeHandle() {
        do {
            try self.handle?.close()
        } catch {
            CaptureLog.logger.warning(
                "Capture log handle did not close cleanly: \(error.localizedDescription, privacy: .public)"
            )
        }
        self.handle = nil
    }

    // MARK: - Line formatting

    private func line(
        _ kind: String,
        _ payload: String
    ) -> String {
        "\(self.stamp.string(from: Date())) | \(CaptureLog.pad(kind, to: CaptureLog.kindWidth)) | \(payload)"
    }

    /// A line with no timestamp column: banners and analysis blocks, which describe a span rather
    /// than an instant.
    private static func banner(
        _ kind: String,
        _ payload: String
    ) -> String {
        "\(CaptureLog.pad(kind, to: CaptureLog.kindWidth)) | \(payload)"
    }

    private static func describe(_ point: TrackPoint) -> String {
        "at=\(CaptureLog.coordinate(point.latitude, point.longitude))"
            + " acc=\(CaptureLog.number(Double(point.accuracyM), 1))"
            // Validity travels as a flag: `n/a` is not `0`, and printing 0 here would teach a
            // reader that the device was stationary when the platform simply did not know.
            + " spd=\(point.hasSpeed ? CaptureLog.number(Double(point.speedMps), 1) : "n/a")"
            + " brg=\(point.hasBearing ? CaptureLog.number(Double(point.bearingDeg), 1) : "n/a")"
            + " odo=\(CaptureLog.number(point.odometerM, 1))"
            + " status=\(point.movementStatus.rawValue)"
            + " act=\(point.detectedActivity?.rawValue ?? "none")"
            + " stop=\(CaptureLog.yesNo(point.isSignificantStop))"
            + " batt=\(point.batteryPct.map { "\($0)%" } ?? "n/a")"
            + " reason=\(point.acceptReason)"
    }

    private static func describe(_ decision: FixDecision) -> String {
        "verdict=\(CaptureLog.verdictWord(decision.verdict))"
            + " reason=\(decision.reason)"
            + " moved=\(CaptureLog.number(decision.distanceMovedM, 1))"
            + " sigma=\(CaptureLog.number(Double(decision.sigma), 1))"
            + " gate=\(CaptureLog.number(Double(decision.threshold), 1))"
            + " spd=\(CaptureLog.number(Double(decision.effectiveSpeedMps), 1))"
            + " acc=\(CaptureLog.number(Double(decision.fix.accuracyM), 1))"
            + " motion=\(decision.motionState.rawValue)"
            // Layer 2. The filter's opinion is invisible unless it is written down for every fix,
            // accepted or not — the stored point carries the RAW coordinates by design.
            + " filter=\(CaptureLog.coordinate(decision.filterLatitude, decision.filterLongitude))"
    }

    private static func describe(_ provider: ProviderState) -> String {
        "services=\(CaptureLog.onOff(provider.locationServicesEnabled))"
            + " auth=\(provider.authorization.rawValue)"
            + " accuracy=\(provider.accuracyAuthorization.rawValue)"
            + " slc=\(CaptureLog.yesNo(provider.significantLocationChangeAvailable))"
            + " region=\(CaptureLog.yesNo(provider.regionMonitoringAvailable))"
            + " lowPower=\(CaptureLog.yesNo(provider.lowPowerMode))"
    }

    // MARK: - Values

    /// **Coordinates are redacted outside DEBUG, and this file is why.**
    ///
    /// A capture log is mailed, AirDropped and pasted into tickets. A release build of the sample
    /// still writes the shape of the run — verdicts, gaps, cadence, distances — which is what the
    /// analysis blocks read; it does not write where the user was.
    /// One crossing, with the fence it describes.
    ///
    /// `at=` is the moment the transition happened, which for a dwell is when the condition was
    /// met rather than when the SDK noticed — the two can be hours apart on a suspended app, and
    /// the log has to say the true one.
    private static func describe(
        _ crossing: GeofenceEvent,
        _ kind: String
    ) -> String {
        "\(kind) id=\(crossing.geofenceID) "
            + "centre=\(CaptureLog.coordinate(crossing.latitude, crossing.longitude)) "
            + "r=\(Int(crossing.radiusM))m"
    }

    private static func coordinate(
        _ latitude: Double,
        _ longitude: Double
    ) -> String {
        #if DEBUG
        return "\(CaptureLog.number(latitude, 6)),\(CaptureLog.number(longitude, 6))"
        #else
        return "redacted"
        #endif
    }

    /// Fixed locale on every number in the file. Under a locale with a decimal comma, `41,7`
    /// silently becomes two fields and every parser downstream is wrong.
    private static func number(
        _ value: Double,
        _ places: Int
    ) -> String {
        guard value.isFinite else { return "n/a" }
        return String(format: "%.\(places)f", locale: CaptureLog.posix, value)
    }

    private static func verdictWord(_ verdict: Verdict) -> String {
        switch verdict {
        case .accept: "ACCEPT"
        case .skip: "SKIP"
        case .reject: "REJECT"
        @unknown default: "UNKNOWN"
        }
    }

    private static func verdictKey(_ decision: FixDecision) -> String {
        "\(CaptureLog.verdictWord(decision.verdict))/\(decision.reason)"
    }

    private static func ratio(
        _ rawFixes: Int,
        _ storedPoints: Int
    ) -> String {
        guard storedPoints > 0 else { return "n/a" }
        return "\(CaptureLog.number(Double(rawFixes) / Double(storedPoints), 1)):1"
    }

    /// Descending by count, then ascending by name — so two runs of the same session produce
    /// byte-identical blocks and a diff between them means something.
    private static func descending(_ counts: [String: Int]) -> [(key: String, value: Int)] {
        counts.sorted { left, right in
            left.value == right.value ? left.key < right.key : left.value > right.value
        }
    }

    private static func tally(
        label: String,
        count: Int,
        total: Int
    ) -> String {
        let share = total > 0 ? 100 * Double(count) / Double(total) : 0
        return CaptureLog.pad(label, to: 34)
            + CaptureLog.padLeft("\(count)", to: 6)
            + "  \(CaptureLog.number(share, 1))%"
    }

    private static func date(_ millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    private static func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    private static func pad(
        _ text: String,
        to width: Int
    ) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func padLeft(
        _ text: String,
        to width: Int
    ) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    /// The hardware identifier — `iPhone15,3`, not `iPhone`.
    ///
    /// `UIDevice.model` answers "iPhone" for every iPhone ever made, which is useless in a file
    /// whose whole job is cross-device comparison. On a simulator the sysctl reports the host
    /// architecture, so the simulator's own environment variable is preferred when it is present.
    private static func deviceModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !simulated.isEmpty {
            return "\(simulated) (simulator)"
        }
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return model.isEmpty ? "unknown" : model
    }

    /// Straight-line metres between two stored points.
    ///
    /// The engine's `Haversine` is `package`, so it does not cross the package boundary into a host
    /// target — which is correct for distribution and means a host computing its own distances
    /// writes its own formula. The odometer delta was the alternative and is wrong for exactly the
    /// case this block exists to catch: after a filter reseed the odometer does not advance, so the
    /// one teleport that matters most would report as a 0 m jump.
    private static func metres(
        _ from: TrackPoint,
        _ to: TrackPoint
    ) -> Double {
        let earthRadiusM: Double = 6_371_000
        let toRadians = Double.pi / 180
        let lat1 = from.latitude * toRadians
        let lat2 = to.latitude * toRadians
        let deltaLat = (to.latitude - from.latitude) * toRadians
        let deltaLng = (to.longitude - from.longitude) * toRadians

        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLng / 2) * sin(deltaLng / 2)
        return 2 * earthRadiusM * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}
