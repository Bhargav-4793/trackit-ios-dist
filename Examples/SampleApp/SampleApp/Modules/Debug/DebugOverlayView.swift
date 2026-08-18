import MapKit
import SwiftUI
import TrackerCore
import TrackerGeo
import os

// MARK: - Layer identity

/// The three layers, in the order the diagnostic rule reads them.
///
/// They are drawn as three *distinct* layers rather than one merged trace on purpose: the whole
/// value of this screen is that an artefact belongs to exactly one of them, and the layer it first
/// appears in names the owner of the bug. Merging them — or deriving one from another — would
/// destroy the only signal here.
enum DebugOverlayLayer: String, CaseIterable, Identifiable {

    /// `getRawFixes` — what CoreLocation handed over, before any gate.
    case raw

    /// `decision.filterLatitude/Longitude` — the filter's own position, recorded for EVERY fix
    /// whether it was accepted, skipped or rejected. It is only visible because it was written
    /// down; there is no way to recover it afterwards from the stored track, which carries the
    /// *fix's* coordinates by design.
    case filter

    /// `getPoints` — what actually reached the database and what a host will draw.
    case stored

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .raw: "1 · Raw"
        case .filter: "2 · Filter"
        case .stored: "3 · Stored"
        }
    }

    var source: String {
        switch self {
        case .raw: "getRawFixes"
        case .filter: "decision.filter*"
        case .stored: "getPoints"
        }
    }

    var color: Color {
        switch self {
        case .raw: Color(white: 0.45)
        case .filter: .blue
        case .stored: .green
        }
    }

    /// Metres. Fixed by `docs/app/60-sample-app.md`, and the ascending order is what makes the
    /// three readable stacked: a stored point is a 6 m disc with the 4 m filter estimate and the
    /// 3 m raw fix sitting inside it, so agreement reads as concentric and disagreement reads as
    /// separation.
    var radiusMeters: CLLocationDistance {
        switch self {
        case .raw: 3
        case .filter: 4
        case .stored: 6
        }
    }
}

// MARK: - Source

/// What this screen needs out of the SDK, and nothing else.
///
/// A protocol rather than a direct `Tracker.shared` reach so the view model is constructed with
/// initializer injection and can be driven from a preview or a recorded session without a device.
protocol DebugLayerSource: Sendable {

    /// The live session, for the fallback when nothing has been pinned.
    func currentSessionID() async throws -> String?

    func rawFixes(sessionID: String) async throws -> [RawFix]

    func decisions(
        sessionID: String,
        limit: Int,
        offset: Int
    ) async throws -> [FixDecision]

    func points(_ query: PointQuery) async throws -> [TrackPoint]
}

/// The real one. Public API only — this app is a host, and a host has no other door.
struct LiveDebugLayerSource: DebugLayerSource {

    let trackIt: Tracker

    init(trackIt: Tracker = .shared) {
        self.trackIt = trackIt
    }

    func currentSessionID() async throws -> String? {
        try await self.trackIt.currentSession()?.id
    }

    func rawFixes(sessionID: String) async throws -> [RawFix] {
        try await self.trackIt.getRawFixes(sessionID: sessionID)
    }

    func decisions(
        sessionID: String,
        limit: Int,
        offset: Int
    ) async throws -> [FixDecision] {
        try await self.trackIt.getDecisions(
            sessionID: sessionID,
            limit: limit,
            offset: offset
        )
    }

    func points(_ query: PointQuery) async throws -> [TrackPoint] {
        try await self.trackIt.getPoints(query)
    }
}

// MARK: - Rendered layers

/// One drawn dot. `id` is the index within its own layer, which is enough because each layer is
/// its own `ForEach`.
struct DebugOverlayDot: Identifiable {
    let id: Int
    let coordinate: CLLocationCoordinate2D
}

/// One layer, ready to draw, with the counts the header reads.
struct DebugOverlayLayerData {

    let layer: DebugOverlayLayer
    let dots: [DebugOverlayDot]

    /// Rows read. Equal to `dots.count` unless something was dropped for being unplottable.
    let rowCount: Int

    /// The read hit its own cap, so this is the newest slice and not the whole layer. Said out
    /// loud rather than silently truncated: a layer that is quietly short looks exactly like a
    /// layer that stopped recording.
    let isTruncated: Bool
}

/// Everything the screen draws for one session.
struct DebugOverlayLayers {

    let sessionID: String

    /// The pin came from another tab rather than from the live session.
    let isPinned: Bool

    let raw: DebugOverlayLayerData
    let filter: DebugOverlayLayerData
    let stored: DebugOverlayLayerData

    /// Frames all three layers together. `nil` when nothing has been recorded yet.
    let region: MKCoordinateRegion?

    func data(for layer: DebugOverlayLayer) -> DebugOverlayLayerData {
        switch layer {
        case .raw: self.raw
        case .filter: self.filter
        case .stored: self.stored
        }
    }
}

// MARK: - View model

@MainActor
@Observable
final class DebugOverlayViewModel {

    private(set) var state: ViewState<DebugOverlayLayers> = .idle

    /// Per-layer visibility. Isolating a layer is how the diagnostic rule is actually applied —
    /// turn two off and the question "is the artefact already here" answers itself.
    var visibleLayers: Set<DebugOverlayLayer> = Set(DebugOverlayLayer.allCases)

    /// Re-read on a timer while on screen, so the counts track a running session.
    var isLive = true

    private let source: any DebugLayerSource

    /// The session the camera was framed on. Re-framing on every refresh would fight the user's
    /// zoom, which is the one gesture this screen exists to support.
    private var framedSessionID: String?

    private static let logger = Logger(
        subsystem: "com.fieldtrack360.tracker.sample",
        category: "debug-overlay"
    )

    init(source: any DebugLayerSource = LiveDebugLayerSource()) {
        self.source = source
    }

    // MARK: Loading

    /// - Parameter pinnedSessionID: the shared selection. `nil` falls back to the live session,
    ///   which is the same resolution the other diagnostic tabs use so all of them describe the
    ///   same run.
    func load(pinnedSessionID: String?) async {
        self.state = .loading
        await self.read(pinnedSessionID: pinnedSessionID, isReload: true)
    }

    /// A quiet re-read that leaves the previous layers on screen until the new ones are ready.
    func refresh(pinnedSessionID: String?) async {
        await self.read(pinnedSessionID: pinnedSessionID, isReload: false)
    }

    func isVisible(_ layer: DebugOverlayLayer) -> Bool {
        self.visibleLayers.contains(layer)
    }

    func toggle(_ layer: DebugOverlayLayer) {
        if self.visibleLayers.contains(layer) {
            self.visibleLayers.remove(layer)
        } else {
            self.visibleLayers.insert(layer)
        }
    }

    /// True once the camera has been framed on this session, so the view frames once per session
    /// and never steals a zoom afterwards.
    func shouldFrame(_ layers: DebugOverlayLayers) -> Bool {
        self.framedSessionID != layers.sessionID
    }

    func didFrame(_ layers: DebugOverlayLayers) {
        self.framedSessionID = layers.sessionID
    }

    private func read(
        pinnedSessionID: String?,
        isReload: Bool
    ) async {
        do {
            let resolved: String?
            if let pinnedSessionID {
                resolved = pinnedSessionID
            } else {
                resolved = try await self.source.currentSessionID()
            }

            guard let sessionID = resolved else {
                self.state = .failed(
                    "No session selected and none is open. Start a run on Home, or pick a session."
                )
                return
            }

            // Three independent reads, issued together: they answer one question and a serial
            // read would show a raw layer half a second older than the stored one, which on a
            // running session is a disagreement the map would attribute to the pipeline.
            async let rawFixesTask = self.source.rawFixes(sessionID: sessionID)
            async let decisionsTask = self.loadDecisions(sessionID: sessionID)
            async let pointsTask = self.loadPoints(sessionID: sessionID)

            let rawFixes = try await rawFixesTask
            let decisions = try await decisionsTask
            let points = try await pointsTask

            self.state = .loaded(
                self.assemble(
                    sessionID: sessionID,
                    isPinned: pinnedSessionID != nil,
                    rawFixes: rawFixes,
                    decisions: decisions,
                    points: points
                )
            )
        } catch {
            Self.logger.error(
                "Debug layers could not be read: \(error.localizedDescription, privacy: .public)"
            )
            // A failed refresh must not blank a screen that is already showing usable layers.
            if isReload {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Newest first from the SDK, paged up to the draw cap.
    private func loadDecisions(sessionID: String) async throws -> [FixDecision] {
        var collected: [FixDecision] = []
        var offset = 0
        while collected.count < Self.drawCap {
            let page = try await self.source.decisions(
                sessionID: sessionID,
                limit: Self.pageSize,
                offset: offset
            )
            collected.append(contentsOf: page)
            if page.count < Self.pageSize { break }
            offset += Self.pageSize
        }
        return collected
    }

    private func loadPoints(sessionID: String) async throws -> [TrackPoint] {
        var collected: [TrackPoint] = []
        var offset = 0
        while collected.count < Self.drawCap {
            let page = try await self.source.points(
                PointQuery(
                    sessionID: sessionID,
                    limit: Self.pageSize,
                    offset: offset
                )
            )
            collected.append(contentsOf: page)
            if page.count < Self.pageSize { break }
            offset += Self.pageSize
        }
        return collected
    }

    private func assemble(
        sessionID: String,
        isPinned: Bool,
        rawFixes: [RawFix],
        decisions: [FixDecision],
        points: [TrackPoint]
    ) -> DebugOverlayLayers {
        let raw = Self.layer(
            .raw,
            rowCount: rawFixes.count,
            coordinates: Self.newest(rawFixes).map { fix in
                CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
            }
        )

        // A decision recorded before the filter ever seeded carries (0, 0) — the state's own
        // default, not a position. Drawn, it would put Null Island in the frame and throw the
        // camera into the Atlantic, so it is dropped from the dots while still being counted as a
        // row that exists.
        let filterCoordinates = Self.newest(decisions)
            .filter { decision in
                Self.isPlottable(
                    latitude: decision.filterLatitude,
                    longitude: decision.filterLongitude
                )
            }
            .map { decision in
                CLLocationCoordinate2D(
                    latitude: decision.filterLatitude,
                    longitude: decision.filterLongitude
                )
            }
        let filter = Self.layer(
            .filter,
            rowCount: decisions.count,
            coordinates: filterCoordinates
        )

        let stored = Self.layer(
            .stored,
            rowCount: points.count,
            coordinates: Self.newest(points).map { point in
                CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            }
        )

        return DebugOverlayLayers(
            sessionID: sessionID,
            isPinned: isPinned,
            raw: raw,
            filter: filter,
            stored: stored,
            region: Self.region(framing: [raw, filter, stored])
        )
    }

    private static func layer(
        _ layer: DebugOverlayLayer,
        rowCount: Int,
        coordinates: [CLLocationCoordinate2D]
    ) -> DebugOverlayLayerData {
        DebugOverlayLayerData(
            layer: layer,
            dots: coordinates.enumerated().map { index, coordinate in
                DebugOverlayDot(id: index, coordinate: coordinate)
            },
            rowCount: rowCount,
            isTruncated: rowCount >= Self.drawCap
        )
    }

    /// The newest slice of a layer, which is the slice a field report is about. Order within the
    /// slice does not matter: these are discs, not a path.
    private static func newest<Element>(_ rows: [Element]) -> [Element] {
        rows.count <= Self.drawCap ? rows : Array(rows.suffix(Self.drawCap))
    }

    private static func isPlottable(
        latitude: Double,
        longitude: Double
    ) -> Bool {
        guard latitude.isFinite, longitude.isFinite else { return false }
        guard abs(latitude) <= 90, abs(longitude) <= 180 else { return false }
        return !(latitude == 0 && longitude == 0)
    }

    /// A box around every dot in every layer, whether or not that layer is currently visible:
    /// hiding a layer is a reading gesture and must not move the map underneath it.
    private static func region(framing layers: [DebugOverlayLayerData]) -> MKCoordinateRegion? {
        let coordinates = layers.flatMap { data in
            data.dots.map(\.coordinate)
        }
        guard let first = coordinates.first else { return nil }

        var minLatitude = first.latitude
        var maxLatitude = first.latitude
        var minLongitude = first.longitude
        var maxLongitude = first.longitude
        for coordinate in coordinates {
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLatitude - minLatitude) * Self.framePadding, Self.minimumSpan),
                longitudeDelta: max((maxLongitude - minLongitude) * Self.framePadding, Self.minimumSpan)
            )
        )
    }

    /// Rows per read. The SDK pages by design — an unpaged read of a fortnight-long session is a
    /// memory spike waiting to happen.
    private static let pageSize = 500

    /// The most dots one layer will draw. Three layers of a long session is tens of thousands of
    /// overlays, and a map that drops to three frames a second is not an instrument.
    private static let drawCap = 3_000

    /// Leaves the outermost dots off the edge of the view.
    private static let framePadding: Double = 1.4

    /// Degrees. A session that never left one spot still needs a span the camera can accept, and
    /// this one is roughly 90 m — close enough to see 3 m and 6 m discs apart.
    private static let minimumSpan: Double = 0.0008
}

// MARK: - View

/// The three-layer overlay: raw fixes, filter output and stored points drawn as three distinct
/// layers over the same ground.
///
/// The single most useful diagnostic in the system. Nearly every accuracy complaint is answered in
/// seconds by seeing which layer the artefact first appears in — which is why the rule that maps a
/// layer to an owner is printed on the screen rather than left in a document nobody reads at
/// 2 a.m. in a car park.
struct DebugOverlayView: View {

    /// The shared session selection. `nil` falls back to the live session, so this tab works
    /// standalone and still pins to whatever Home selected when it is handed one.
    let sessionID: String?

    @State private var model: DebugOverlayViewModel
    @State private var camera: MapCameraPosition = .automatic

    init(
        sessionID: String? = nil,
        model: DebugOverlayViewModel = DebugOverlayViewModel()
    ) {
        self.sessionID = sessionID
        self._model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch self.model.state {
                case .idle, .loading:
                    ProgressView("Reading layers…")

                case .failed(let message):
                    ContentUnavailableView {
                        Label("No layers to draw", systemImage: "circle.hexagongrid")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Reload") {
                            Task { await self.model.load(pinnedSessionID: self.sessionID) }
                        }
                    }

                case .loaded(let layers):
                    self.content(layers)
                }
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle("Live", isOn: Binding(
                        get: { self.model.isLive },
                        set: { self.model.isLive = $0 }
                    ))
                    .toggleStyle(.button)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await self.model.load(pinnedSessionID: self.sessionID) }
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        // Owned by the view, so it is cancelled when the tab goes away or the session changes.
        .task(id: self.sessionID) {
            await self.model.load(pinnedSessionID: self.sessionID)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshSeconds))
                guard !Task.isCancelled, self.model.isLive else { continue }
                await self.model.refresh(pinnedSessionID: self.sessionID)
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ layers: DebugOverlayLayers) -> some View {
        VStack(spacing: 0) {
            self.map(layers)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    self.header(layers)
                    self.chips(layers)
                    self.emptyLayerNotes(layers)
                    DiagnosticRuleCard()
                }
                .padding(16)
            }
            .frame(maxHeight: 340)
            .background(.bar)
        }
    }

    private func map(_ layers: DebugOverlayLayers) -> some View {
        Map(position: self.$camera) {
            // Largest first, so the three sit concentric when they agree and separate visibly
            // when they do not. Reversing this would let a 6 m stored disc hide the 3 m raw fix
            // underneath it, which is the exact comparison the screen exists to make.
            self.dots(layers.stored)
            self.dots(layers.filter)
            self.dots(layers.raw)
        }
        .mapControls {
            MapScaleView()
            MapCompass()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: layers.sessionID, initial: true) {
            guard self.model.shouldFrame(layers), let region = layers.region else { return }
            self.camera = .region(region)
            self.model.didFrame(layers)
        }
    }

    @MapContentBuilder
    private func dots(_ data: DebugOverlayLayerData) -> some MapContent {
        if self.model.isVisible(data.layer) {
            ForEach(data.dots) { dot in
                MapCircle(center: dot.coordinate, radius: data.layer.radiusMeters)
                    .foregroundStyle(data.layer.color.opacity(0.45))
                    .stroke(data.layer.color, lineWidth: 1)
            }
        }
    }

    // MARK: Header

    private func header(_ layers: DebugOverlayLayers) -> some View {
        HStack(spacing: 6) {
            Text(layers.sessionID.prefix(8))
                .font(.system(.footnote, design: .monospaced))
            Text(layers.isPinned ? "pinned" : "live session")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func chips(_ layers: DebugOverlayLayers) -> some View {
        HStack(spacing: 8) {
            ForEach(DebugOverlayLayer.allCases) { layer in
                let data = layers.data(for: layer)
                Button {
                    self.model.toggle(layer)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(layer.color)
                                .frame(width: 9, height: 9)
                            Text(layer.title)
                                .font(.caption.weight(.semibold))
                        }
                        Text("\(data.rowCount)\(data.isTruncated ? "+" : "")")
                            .font(.system(.title3, design: .monospaced))
                        Text(layer.source)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(layer.color.opacity(self.model.isVisible(layer) ? 0.14 : 0.0))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(layer.color.opacity(self.model.isVisible(layer) ? 0.8 : 0.25))
                    )
                    .opacity(self.model.isVisible(layer) ? 1 : 0.5)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Empty-layer notes

    /// An empty layer and a *disabled* layer look identical on a map, and confusing the two sends
    /// somebody hunting a capture bug that never happened. Both cases get a sentence.
    @ViewBuilder
    private func emptyLayerNotes(_ layers: DebugOverlayLayers) -> some View {
        if layers.raw.rowCount == 0 {
            EmptyLayerNote(
                layer: .raw,
                text: """
                    Layer 1 recorded nothing. An empty layer and a disabled one look identical \
                    here — enable persistRawFixes in TrackerConfig, which is off by default \
                    because it is a diagnostic, then record again.
                    """
            )
        }

        if layers.filter.rowCount == 0 {
            EmptyLayerNote(
                layer: .filter,
                text: """
                    Layer 2 recorded nothing. Enable persistDecisions in TrackerConfig — with the \
                    decision log off there is no record of where the filter believed it was, and \
                    that belief cannot be recovered afterwards.
                    """
            )
        }

        if layers.stored.rowCount == 0, layers.raw.rowCount > 0 {
            EmptyLayerNote(
                layer: .stored,
                text: """
                    Fixes arrived and nothing was stored. Read the decision log for this session: \
                    a wall of Drift Suppressed is a departure-ladder problem, a wall of Sigma Gate \
                    Outlier is a filter-lag problem, and they have opposite fixes.
                    """
            )
        }

        if layers.raw.isTruncated || layers.filter.isTruncated || layers.stored.isTruncated {
            EmptyLayerNote(
                layer: nil,
                text: """
                    A layer hit the draw cap, so the map is showing its newest rows only. The \
                    counts marked + are lower bounds.
                    """
            )
        }
    }

    /// Seconds between quiet re-reads while `Live` is on. A poll rather than an observation
    /// because all three layers move independently and only one of them is observable.
    private static let refreshSeconds: Double = 3
}

// MARK: - Diagnostic rule

/// The highest-value sentence in `docs/app/61-diagnostics.md`, on the screen where it is used.
///
/// It stays visible rather than living behind an info button: the person reading it is usually in
/// a car park with a field report, and a rule that has to be found is a rule that gets guessed at.
private struct DiagnosticRuleCard: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOW TO READ THIS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            self.rule(
                layer: .raw,
                claim: "Artefact already in RAW",
                owner: "an OS or configuration problem — check distanceFilter, pausesLocationUpdatesAutomatically, authorization and accuracy authorization."
            )
            self.rule(
                layer: .filter,
                claim: "Raw clean but FILTER wrong",
                owner: "a pipeline stage or a mis-tuned constant — go to the decision log for that timestamp."
            )
            self.rule(
                layer: .stored,
                claim: "Filter right but STORED disagrees",
                owner: "a persistence or dedup bug — check the uuid derivation and the query ordering."
            )

            Text(
                "The layer an artefact first appears in names the owner. Never soften a stage to fix a symptom another stage owns."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    private func rule(
        layer: DebugOverlayLayer,
        claim: String,
        owner: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(layer.color)
                .frame(width: 9, height: 9)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(claim)
                    .font(.caption.weight(.semibold))
                Text("→ \(owner)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Empty-layer note

private struct EmptyLayerNote: View {

    /// The layer the note is about, or `nil` when it concerns all three.
    let layer: DebugOverlayLayer?
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(self.text)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke((self.layer?.color ?? .orange).opacity(0.35))
        )
    }
}

// MARK: - Preview

#Preview {
    DebugOverlayView()
}
