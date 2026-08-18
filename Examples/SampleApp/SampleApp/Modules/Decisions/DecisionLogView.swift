import Foundation
import SwiftUI
import TrackerCore
import TrackerGeo
import os

// MARK: - Reading seam

/// What this screen needs from the SDK, and nothing else.
///
/// A protocol rather than a direct reach for `Tracker.shared` so the screen can be driven from a
/// preview or a recorded session without a database — and so the surface this tab actually depends
/// on is written down in one place. Three methods wide: the sessions to pick between, which one is
/// live, and the log itself.
protocol DecisionLogReading: Sendable {

    /// Newest first, as the SDK returns them.
    func sessions() async throws -> [TrackSession]

    /// The session capture is writing into right now, if any.
    func currentSessionID() async throws -> String?

    /// The decision log for one session, newest first.
    func decisions(
        sessionID: String,
        limit: Int
    ) async throws -> [FixDecision]
}

/// The real one. A host reads exactly these three methods off the public surface.
struct SDKDecisionLog: DecisionLogReading {

    func sessions() async throws -> [TrackSession] {
        try await Tracker.shared.getSessions()
    }

    func currentSessionID() async throws -> String? {
        try await Tracker.shared.currentSession()?.id
    }

    func decisions(
        sessionID: String,
        limit: Int
    ) async throws -> [FixDecision] {
        try await Tracker.shared.getDecisions(sessionID: sessionID, limit: limit)
    }
}

// MARK: - Verdict

/// The three verdicts as a filterable value.
///
/// `Verdict` itself carries the reason string as an associated value, so it cannot be a `Set`
/// element or a chip identity. This is that enum with the reason erased — the axis the chips
/// filter on — and it is the only place in this file that pattern-matches on `Verdict`.
enum DecisionVerdict: String, CaseIterable, Identifiable, Sendable {
    case accept
    case skip
    case reject

    var id: String { self.rawValue }

    init(_ verdict: Verdict) {
        switch verdict {
        case .accept: self = .accept
        case .skip: self = .skip
        // A host compiles against a resilient (non-frozen) enum, so the SDK may add
        // a verdict this build has never seen. Folding the unknown into `.reject`
        // is the safe reading for a diagnostic: an unrecognised verdict is one this
        // UI cannot vouch for, and showing it as accepted would be a lie.
        case .reject: self = .reject
        @unknown default: self = .reject
        }
    }

    var title: String {
        switch self {
        case .accept: "Accept"
        case .skip: "Skip"
        case .reject: "Reject"
        }
    }

    /// Green stored, amber warmed-but-not-stored, red dropped.
    var colour: Color {
        switch self {
        case .accept: .green
        case .skip: .orange
        case .reject: .red
        }
    }
}

// MARK: - Rows

/// One log line, with an identity the list can hold on to.
///
/// `FixDecision` is `Equatable` but not `Identifiable`, and two decisions in a burst can be equal
/// in every field, so the index is the identity. It is stable because the page is replaced whole
/// rather than mutated.
struct DecisionRow: Identifiable {
    let id: Int
    let decision: FixDecision
    var verdict: DecisionVerdict { DecisionVerdict(self.decision.verdict) }
}

/// One page of the log, plus the fact of whether it is the whole thing.
struct DecisionLog {
    let rows: [DecisionRow]

    /// The page came back full, so older verdicts exist that this screen never read. Said out
    /// loud, because a summary computed over a page and presented as a session is a lie about the
    /// session.
    let truncated: Bool
}

// MARK: - ViewModel

@MainActor
@Observable
final class DecisionLogViewModel {

    private(set) var state: ViewState<DecisionLog> = .idle
    private(set) var sessions: [TrackSession] = []

    /// The session all three diagnostic tabs describe. Set from outside to pin a run picked
    /// elsewhere; left `nil` it resolves to the live session, then to the newest one.
    var selectedSessionID: String?

    /// All three on, so the first thing a tester sees is the whole log rather than a slice they
    /// did not ask for.
    var enabled: Set<DecisionVerdict> = Set(DecisionVerdict.allCases)

    private let reader: any DecisionLogReading
    private var loadTask: Task<Void, Never>?

    private static let logger = Logger(
        subsystem: "com.fieldtrack360.tracker.sample",
        category: "decisions"
    )

    /// The newest slice of the log. Deep enough that a 30-minute drive fits whole — the shapes
    /// below are stated per-run, and a summary over 200 rows of a 4,000-row session cannot be
    /// compared against them.
    private static let pageLimit = 2_000

    init(
        reader: any DecisionLogReading = SDKDecisionLog(),
        sessionID: String? = nil
    ) {
        self.reader = reader
        self.selectedSessionID = sessionID
    }

    // MARK: Loading

    /// Sessions first, then the log for whichever one is selected.
    ///
    /// A retained task rather than a detached one, so leaving the tab mid-read cancels the read
    /// instead of racing the next one to `state`.
    func load() {
        self.loadTask?.cancel()
        self.loadTask = Task { [weak self] in
            await self?.performLoad()
        }
    }

    func onDisappear() {
        self.loadTask?.cancel()
        self.loadTask = nil
    }

    private func performLoad() async {
        self.state = .loading

        do {
            self.sessions = try await self.reader.sessions()
        } catch {
            Self.logger.error("Session list failed: \(error.localizedDescription, privacy: .public)")
            self.state = .failed("The session list could not be read: \(error.localizedDescription)")
            return
        }

        guard Task.isCancelled == false else { return }

        // The live session wins, then the newest. Resolved rather than defaulted to `nil` so the
        // tab lands on something the moment it opens.
        if self.selectedSessionID == nil {
            let live = try? await self.reader.currentSessionID()
            self.selectedSessionID = live ?? self.sessions.first?.id
        }

        guard let sessionID = self.selectedSessionID else {
            self.state = .loaded(DecisionLog(rows: [], truncated: false))
            return
        }

        do {
            let decisions = try await self.reader.decisions(
                sessionID: sessionID,
                limit: Self.pageLimit
            )
            guard Task.isCancelled == false else { return }
            self.state = .loaded(
                DecisionLog(
                    rows: decisions.enumerated().map { DecisionRow(id: $0.offset, decision: $0.element) },
                    truncated: decisions.count >= Self.pageLimit
                )
            )
        } catch {
            Self.logger.error("Decision log failed: \(error.localizedDescription, privacy: .public)")
            self.state = .failed("The decision log could not be read: \(error.localizedDescription)")
        }
    }

    // MARK: Filtering

    func toggle(_ verdict: DecisionVerdict) {
        if self.enabled.contains(verdict) {
            self.enabled.remove(verdict)
        } else {
            self.enabled.insert(verdict)
        }
    }

    func showAllVerdicts() {
        self.enabled = Set(DecisionVerdict.allCases)
    }

    func visibleRows(in log: DecisionLog) -> [DecisionRow] {
        log.rows.filter { self.enabled.contains($0.verdict) }
    }

    /// How many rows each chip stands for, over the whole page rather than the filtered view —
    /// a count that changed when you filtered would be useless for deciding what to filter to.
    func count(of verdict: DecisionVerdict, in log: DecisionLog) -> Int {
        log.rows.reduce(into: 0) { total, row in
            if row.verdict == verdict { total += 1 }
        }
    }

    /// The top four reasons among the rows on screen, descending.
    ///
    /// Computed over the *visible* rows on purpose: filtering to Reject and reading the top four
    /// reject reasons is the fastest route from "the track stopped" to the stage that stopped it.
    /// Ties break on the reason string so the line does not reshuffle between reads.
    func topReasons(
        in rows: [DecisionRow],
        limit: Int = 4
    ) -> [(reason: String, count: Int)] {
        var counts: [String: Int] = [:]
        for row in rows {
            counts[row.decision.reason, default: 0] += 1
        }
        return counts
            .sorted { left, right in
                left.value == right.value ? left.key < right.key : left.value > right.value
            }
            .prefix(limit)
            .map { (reason: $0.key, count: $0.value) }
    }

    /// Forced resets over the whole page, filtered or not.
    ///
    /// Surfaced on its own because zero is the expected value on every healthy run, and a non-zero
    /// count names its own fix — the drift-tolerance scaling — rather than inviting the sigma gate
    /// to be widened, which is the wrong repair for this symptom.
    func forcedResetCount(in log: DecisionLog) -> Int {
        log.rows.reduce(into: 0) { total, row in
            if row.decision.reason == Reasons.sigmaForcedReset { total += 1 }
        }
    }
}

// MARK: - View

/// The decision log: why each fix was accepted, skipped or rejected, and the numbers it was judged
/// on.
///
/// The first of the four instruments, and the one that turns "the track is wrong here" into the
/// name of a pipeline stage.
struct DecisionLogView: View {

    @State private var model: DecisionLogViewModel

    init(model: DecisionLogViewModel = DecisionLogViewModel()) {
        self._model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = self.model

        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    SessionPicker(
                        sessions: self.model.sessions,
                        selection: $model.selectedSessionID
                    )
                    self.chips
                }
                .padding(.horizontal)
                .padding(.vertical, 12)

                Divider()

                self.content
            }
            .navigationTitle("Decisions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        self.model.load()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .task {
            self.model.load()
        }
        .onChange(of: self.model.selectedSessionID) {
            self.model.load()
        }
        .onDisappear {
            self.model.onDisappear()
        }
    }

    // MARK: Chips

    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(DecisionVerdict.allCases) { verdict in
                VerdictChip(
                    verdict: verdict,
                    count: self.chipCount(verdict),
                    isOn: self.model.enabled.contains(verdict)
                ) {
                    self.model.toggle(verdict)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// `nil` while the page is not loaded, so a chip shows no count rather than a wrong one.
    private func chipCount(_ verdict: DecisionVerdict) -> Int? {
        guard case .loaded(let log) = self.model.state else { return nil }
        return self.model.count(of: verdict, in: log)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch self.model.state {
        case .idle, .loading:
            Spacer()
            ProgressView("Reading the decision log")
            Spacer()

        case .failed(let message):
            Spacer()
            ContentUnavailableView {
                Label("Log unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") {
                    self.model.load()
                }
            }
            Spacer()

        case .loaded(let log):
            self.loaded(log)
        }
    }

    @ViewBuilder
    private func loaded(_ log: DecisionLog) -> some View {
        let visible = self.model.visibleRows(in: log)

        if log.rows.isEmpty {
            // Nothing was ever written. A different fact entirely from everything being filtered
            // out, and pointed at the capture side rather than at this screen.
            ContentUnavailableView {
                Label("No decisions recorded", systemImage: "tray")
            } description: {
                Text(
                    """
                    Nothing was judged in this session. That is a capture question, not a filter \
                    one: either no fix ever reached the pipeline, or persistDecisions is off in \
                    the configuration this session was opened with.
                    """
                )
            }
        } else if visible.isEmpty {
            // Everything was written and everything is hidden. Says so, with the number, because
            // a tester who reads this as "no decisions" goes looking for a capture bug that is
            // not there.
            ContentUnavailableView {
                Label("All \(log.rows.count) hidden by the filters", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("\(log.rows.count) decisions were recorded. Every verdict chip is off, so none of them is shown.")
            } actions: {
                Button("Show all verdicts") {
                    self.model.showAllVerdicts()
                }
            }
        } else {
            List {
                Section {
                    SummaryLine(reasons: self.model.topReasons(in: visible))
                    if log.truncated {
                        Label(
                            "Newest \(log.rows.count) verdicts only — older ones are not in this summary.",
                            systemImage: "clock.arrow.circlepath"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Top reasons — \(visible.count) shown of \(log.rows.count)")
                }

                Section {
                    ExpectedShapes(forcedResets: self.model.forcedResetCount(in: log))
                } header: {
                    Text("What healthy looks like")
                }

                Section {
                    ForEach(visible) { row in
                        DecisionRowView(row: row)
                    }
                } header: {
                    Text("Log — newest first")
                }
            }
            .listStyle(.plain)
            .refreshable {
                self.model.load()
            }
        }
    }
}

// MARK: - Chip

private struct VerdictChip: View {

    let verdict: DecisionVerdict
    let count: Int?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(self.verdict.colour)
                    .frame(width: 8, height: 8)
                Text(self.verdict.title)
                if let count = self.count {
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(self.isOn ? self.verdict.colour.opacity(0.18) : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(self.isOn ? self.verdict.colour : Color.secondary.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(self.verdict.title) filter")
        .accessibilityValue(self.isOn ? "on" : "off")
    }
}

// MARK: - Summary

private struct SummaryLine: View {

    let reasons: [(reason: String, count: Int)]

    var body: some View {
        if self.reasons.isEmpty {
            Text("—")
                .foregroundStyle(.secondary)
        } else {
            Text(self.reasons.map { "\($0.reason)×\($0.count)" }.joined(separator: "  ·  "))
                .font(.system(.footnote, design: .monospaced))
        }
    }
}

// MARK: - Expected shapes

/// The two shapes worth memorising, printed where the numbers are, so a tester can compare without
/// leaving the screen or opening a document.
///
/// The reason strings come from `Reasons` rather than being retyped here: they are API, they are
/// byte-identical to the golden files, and a sample app quietly disagreeing with the vocabulary by
/// one character is a debugging session nobody planned for.
private struct ExpectedShapes: View {

    let forcedResets: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("A parked hour is dominated by \(Reasons.driftSuppressed), \(Reasons.heartbeatSkipped) and \(Reasons.sigmaGateOutlier), with almost no accepts. Many accepts while parked means broken speed-validity flags or a missing wobble guard.")
            } icon: {
                Image(systemName: "parkingsign.circle")
            }

            Label {
                Text("A healthy 30-minute drive is 25–35 \(Reasons.vehicular) accepts, a handful of rejects at signal-poor spots, and no \(Reasons.sigmaForcedReset) at all.")
            } icon: {
                Image(systemName: "car")
            }

            if self.forcedResets > 0 {
                Label {
                    Text("\(Reasons.sigmaForcedReset)×\(self.forcedResets) on this page. Repeated forced resets mean the drift-tolerance scaling is not doing its job — do not widen the sigma gate to hide it.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
            }
        }
        .font(.footnote)
    }
}

// MARK: - Row

/// One verdict, with the numbers it was argued from.
///
/// `moved`, `σ`, `gate`, `spd` and `acc` are the arguable numbers: every rejection in the pipeline
/// is one of them failing a comparison, so a row without them says what happened and hides why.
private struct DecisionRowView: View {

    let row: DecisionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(self.row.verdict.title.uppercased())
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4).fill(self.row.verdict.colour.opacity(0.20))
                    )
                    .foregroundStyle(self.row.verdict.colour)

                Text(self.row.decision.reason)
                    .font(.subheadline.weight(.medium))

                Spacer(minLength: 0)

                Text(DecisionFormat.time(self.row.decision.fix.timeMs))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(DecisionFormat.numbers(self.row.decision))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Text("motion \(self.row.decision.motionState.rawValue) · \(self.row.decision.fix.provider)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Formatting

/// One place for the two formats this screen prints.
///
/// Fixed `en_US_POSIX`, and `String(format:)` for the numbers, because both are locale-independent:
/// a decimal comma on a device set to a European locale makes every number on this screen
/// un-greppable against a capture log written by the same run.
private enum DecisionFormat {

    static func numbers(_ decision: FixDecision) -> String {
        String(
            format: "moved %.1fm · σ %.1f · gate %.1f · spd %.1f · acc %.1f",
            decision.distanceMovedM,
            Double(decision.sigma),
            Double(decision.threshold),
            Double(decision.effectiveSpeedMps),
            Double(decision.fix.accuracyM)
        )
    }

    static func time(_ timeMs: Int64) -> String {
        Self.formatter.string(from: Date(timeIntervalSince1970: Double(timeMs) / 1_000))
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
