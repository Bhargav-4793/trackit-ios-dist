import CoreLocation
import MapKit
import SwiftUI
import TrackerCore
import TrackerGeo
import TrackerMaps
import UIKit
import os

// MARK: - PathSource

/// Which geometry the Track pane's main line is drawn from.
///
/// **These are not two renderings of one thing, and the difference is the point.** `.track`
/// draws the SDK's record: the stored points, consolidated, simplified, spline-smoothed, and
/// pulled onto road geometry when a `RoadSnapProvider` answered. `.raw` draws the fix stream
/// exactly as CoreLocation delivered it, including every fix the acceptance pipeline judged
/// and threw away.
///
/// `.raw` is a diagnostic and cannot be made into anything else. Raw fixes are written only
/// when `persistRawFixes` is on — off by default — they roll off a `rawFixRingCapacity` ring
/// as a long session runs, and nothing uploads them. The line this mode draws therefore exists
/// on the recording device and nowhere else: a shape that reads correctly here and wrong on a
/// server is the expected outcome of choosing it, not a defect in either.
enum PathSource: Hashable {

    /// The built track. Speed bands, arrows and snapping all apply, and it is the same
    /// geometry the JSON export carries.
    case track

    /// The raw fix thread, unprocessed. No bands, no arrows, no snapping — none of the three
    /// exist for geometry the plotting plane never saw.
    case raw
}

// MARK: - TrackDataSource

/// Everything the Track tab asks of the SDK, and nothing else.
///
/// A protocol because that is the house rule for view models — but it earns its keep
/// here for a second reason: it is a written statement of how small the surface a map
/// screen actually needs. Five members, every one of them `public` on the facade, none of
/// them reaching past it.
protocol TrackDataSource: Sendable {

    func currentSession() async throws -> TrackSession?

    func buildTrack(
        _ query: PointQuery,
        options: TrackOptions
    ) async throws -> Track

    /// The *true* stored-point count for the session, which `buildTrack`'s paged read
    /// cannot report.
    func getCount(_ query: PointQuery) async throws -> Int

    /// Layer 1. Empty when `persistRawFixes` was off for the run — which is a fact worth
    /// showing, not an error.
    func getRawFixes(sessionID: String) async throws -> [RawFix]

    func liveTrack() -> AsyncStream<LiveTrackUpdate>
}

extension Tracker: TrackDataSource {}

// MARK: - TrackPlot

/// One session, decoded once and ready to draw.
///
/// **Everything expensive happens in this initialiser**, and it runs when a track is
/// loaded rather than when a frame is drawn. The travelling arrow re-evaluates the map
/// pane's body sixty times a second; if the polylines were decoded in `body` that would
/// be sixty decodes a second of a track that has not changed. `TrackMapView` makes the
/// same decision, in its own `init`, for the same reason.
struct TrackPlot: Sendable {

    /// One travel segment, decoded, identified by `TrackSegment.from` — unique across
    /// clusters by construction, because cluster *N*'s `to` is cluster *N+1*'s `from`.
    struct Segment: Identifiable, Sendable {
        let id: Int
        let speedBand: String?
        let coordinates: [CLLocationCoordinate2D]
    }

    init(
        sessionID: String,
        track: Track,
        rawFixes: [RawFix],
        storedPointCount: Int
    ) {
        self.sessionID = sessionID
        self.track = track
        self.storedPointCount = storedPointCount
        self.rawFixCount = rawFixes.count

        // Layer 1, in the order `getRawFixes` returns it — fix order, which is not
        // delivery order across a reboot boundary (EC-88b). Re-sorting it here would undo
        // the one thing this layer knows and the drawn track does not.
        self.rawThread = rawFixes.map { fix in
            CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
        }

        // `track.precision` travels with the data. Decoding at an assumed 5 against a
        // precision-6 string scales the whole track 10× into the wrong hemisphere and
        // nothing errors (EC-110).
        let basePath = PolylineCodec
            .decode(track.encodedPolyline, precision: track.precision)
            .map { point in
                CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            }
        self.basePath = basePath

        self.travelSegments = track.segments
            .filter { segment in
                segment.type == .travel && !segment.encodedPolyline.isEmpty
            }
            .map { segment in
                Segment(
                    id: segment.from,
                    speedBand: segment.speedBand,
                    coordinates: PolylineCodec
                        .decode(segment.encodedPolyline, precision: track.precision)
                        .map { point in
                            CLLocationCoordinate2D(
                                latitude: point.latitude,
                                longitude: point.longitude
                            )
                        }
                )
            }
    }

    let sessionID: String
    let track: Track
    let basePath: [CLLocationCoordinate2D]
    let travelSegments: [Segment]
    let rawThread: [CLLocationCoordinate2D]
    let rawFixCount: Int

    /// Every stored point in the session, not just the page the track was built from.
    let storedPointCount: Int

    var hasGeometry: Bool {
        self.basePath.count >= 2
    }

    /// `false` means the run was recorded with `persistRawFixes` off. That is a missing
    /// *input*, not a missing feature, and the chip says so by greying out.
    var hasRawLayer: Bool {
        self.rawFixCount > 0
    }

    /// Enough raw fixes to draw a line from, which is a stricter question than `hasRawLayer`.
    /// One fix is a layer with something in it and still not a route, and `PathSource.raw`
    /// needs the second answer — the same `>= 2` cardinality `hasGeometry` applies to the
    /// track.
    var hasRawGeometry: Bool {
        self.rawThread.count >= 2
    }

    var isTruncated: Bool {
        self.track.warnings.contains(TrackWarning.truncated)
    }

    /// Snapping was asked for and could not be answered. Never set when snapping was not
    /// requested — the SDK keeps those two facts apart deliberately, so this can be
    /// reported as a failure rather than as a setting.
    var isSnapUnavailable: Bool {
        self.track.warnings.contains(TrackWarning.snapUnavailable)
    }

    /// Stored points as a share of raw fixes. `nil` with no raw layer to divide by.
    var keptShare: Double? {
        guard self.rawFixCount > 0 else { return nil }
        return Double(self.storedPointCount) / Double(self.rawFixCount)
    }
}

// MARK: - TrackViewModel

/// Loads one session's plot. Owns no geometry and decides no thresholds.
@MainActor
@Observable
final class TrackViewModel {

    init(source: any TrackDataSource = Tracker.shared) {
        self.source = source
    }

    private(set) var state: ViewState<TrackPlot> = .idle


    /// - Parameters:
    ///   - sessionID: the shared selection, or `nil` to follow the live session.
    ///     `selectedSessionID ?? currentSession()?.id` is the rule all three diagnostic
    ///     tabs resolve by, which is what keeps them describing the same run.
    ///   - snapToRoad: the shared render flag. Snapping happens inside `buildTrack`, not
    ///     in the renderer, so changing it is a rebuild rather than a redraw.
    /// - Parameter showLoading: `false` for a rebuild behind a camera move. A zoom that blanked
    ///   the map to a spinner every time it settled would make the track flicker on every pinch,
    ///   for a change that only moves the arrows.
    func load(
        sessionID: String?,
        snapToRoad: Bool,
        showLoading: Bool = true
    ) async {
        if showLoading {
            self.state = .loading
        }
        do {
            guard let resolved = try await self.resolvedSessionID(sessionID) else {
                self.state = .failed("No session has been recorded yet. Start one from Home.")
                return
            }

            var options = TrackOptions()
            options.snapToRoad = snapToRoad

            let track = try await self.source.buildTrack(
                PointQuery(sessionID: resolved, limit: TrackViewModel.pageSize),
                options: options
            )

            // The count is a separate read on purpose: `buildTrack` sees one page, and
            // the ratio at the top of this screen is worthless if its right-hand side
            // silently means "up to 5000".
            let storedPointCount = try await self.source.getCount(
                PointQuery(sessionID: resolved)
            )
            let rawFixes = await self.rawFixes(sessionID: resolved)

            guard !Task.isCancelled else { return }
            self.state = .loaded(
                TrackPlot(
                    sessionID: resolved,
                    track: track,
                    rawFixes: rawFixes,
                    storedPointCount: storedPointCount
                )
            )
        } catch is CancellationError {
            // A newer load replaced this one; the screen belongs to that one now.
            return
        } catch {
            TrackViewModel.logger.error(
                "Track build failed: \(error.localizedDescription, privacy: .public)"
            )
            self.state = .failed(error.localizedDescription)
        }
    }

    /// The live feed, forwarded rather than reached for, so the live pane is injected
    /// through the same seam as everything else on this screen.
    ///
    /// `nonisolated` because `.task` may run the collector off the main actor: the stream
    /// is handed over synchronously and `source` is an immutable `Sendable` reference, so
    /// there is nothing isolated to touch.
    nonisolated func liveTrack() -> AsyncStream<LiveTrackUpdate> {
        self.source.liveTrack()
    }

    private func resolvedSessionID(_ sessionID: String?) async throws -> String? {
        if let sessionID {
            return sessionID
        }
        return try await self.source.currentSession()?.id
    }

    /// Layer 1 is a diagnostic, so losing it must never lose the track with it.
    private func rawFixes(sessionID: String) async -> [RawFix] {
        do {
            return try await self.source.getRawFixes(sessionID: sessionID)
        } catch {
            TrackViewModel.logger.warning(
                "Raw-fix layer unavailable; the Raw chip will read empty: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    private let source: any TrackDataSource

    /// The page this tab reads, matching the one `TrackingViewModel` dumps with.
    ///
    /// A page, not a cap: `buildTrack` raises `TrackWarning.truncated` when a read comes
    /// back full and this screen prints it, so a long session is reported as clipped
    /// rather than drawn short and called complete.
    private static let pageSize = 5000

    private static let logger = Logger(
        subsystem: "com.fieldtrack360.tracker.sample",
        category: "track"
    )
}

// MARK: - TrackView

/// The plotting output, drawn the way a host would draw it.
///
/// **Why this does not wrap `TrackMapView`.** It draws the same values, from the same
/// public types, in the same palette — but two of this screen's three jobs need map
/// content the SDK's view cannot be handed: the raw-fix thread and the travelling arrow.
/// `TrackMapView` takes a `Track` and returns a finished `Map`; there is no content
/// builder to add to and no camera to share, so layering a second `Map` over it would
/// mean two cameras that desynchronise on the first pan. Rendering here keeps one camera
/// and one set of gestures, and everything that *can* come from the SDK does:
/// `PolylineCodec` decodes, `RenderOptions` supplies the palette and the metrics,
/// `TrackIcons` draws the pins and the chevron, and the engine's stop nudge and speed
/// bands are consumed rather than recomputed. The live surface, which needs no extra
/// layers, is `LiveTrackMapView` untouched.
///
/// `@MainActor` on the type rather than only on `body`, because the initialiser builds a
/// main-actor view model.
@MainActor
struct TrackView: View {

    /// - Parameters:
    ///   - sessionID: the resolved shared selection. `nil` falls back to the live
    ///     session, so this tab works standalone.
    ///   - viewModel: the app's shared state. Read for the two render flags and for the
    ///     session list behind the picker — **not** copied, because a second copy of
    ///     `showRawLayer` is a second answer to "is the raw layer on".
    ///   - model: this tab's loader.
    init(
        sessionID: String? = nil,
        viewModel: TrackingViewModel,
        model: TrackViewModel = TrackViewModel()
    ) {
        self.sessionID = sessionID
        self.viewModel = viewModel
        self._model = State(initialValue: model)
    }

    let sessionID: String?
    let viewModel: TrackingViewModel

    var body: some View {
        @Bindable var viewModel = self.viewModel

        NavigationStack {
            VStack(spacing: 0) {
                self.mapArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                        SessionPicker(
                            sessions: self.viewModel.sessions,
                            selection: $viewModel.selectedSessionID,
                            resolvedSessionID: self.model.state.value?.sessionID
                        )

                        self.chips

                        if let plot = self.model.state.value {
                            self.notes(for: plot)
                            TrackSummaryCard(plot: plot)
                            TrackTimelineSection(plot: plot)
                        }
                    }
                    .padding(Theme.Spacing.screen)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .frame(maxHeight: 420)
            }
            .navigationTitle("Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if self.isTracking {
                    ToolbarItem(placement: .principal) {
                        Picker("Surface", selection: self.$mode) {
                            Text("Plot").tag(PaneMode.plot)
                            Text("Live").tag(PaneMode.live)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        self.rebuildToken += 1
                    } label: {
                        Label("Rebuild", systemImage: "arrow.clockwise")
                    }
                }
            }
            .task(id: self.loadKey) {
                await self.model.load(
                    sessionID: self.selection,
                    snapToRoad: self.viewModel.snapToRoad
                )
            }
            .onChange(of: self.isTracking, initial: true) { _, tracking in
                // A run in progress has a live surface worth watching; a finished one has
                // a plot. Either is still reachable by hand from the picker.
                // When a specific session is pinned (sessionID non-nil), keep plot mode —
                // the caller wants to view a particular historical session, not the live feed.
                let pinned = self.sessionID != nil || self.viewModel.selectedSessionID != nil
                self.mode = (tracking && !pinned) ? .live : .plot
            }
        }
    }

    // MARK: Map

    @ViewBuilder
    private var mapArea: some View {
        // The live surface is checked first and does not wait on a build: a run that has
        // just started has nothing to plot yet, and a screen that showed "nothing to
        // draw" over a session actively recording would be lying about the one thing the
        // tester is watching.
        if self.mode == .live {
            LiveMapPane(model: self.model)
        } else {
            switch self.model.state {
            case .idle, .loading:
                ProgressView("Building the track…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failed(let message):
                ContentUnavailableView {
                    Label("Nothing to draw", systemImage: "map")
                } description: {
                    Text(message)
                }

            case .loaded(let plot):
                // Either geometry is enough to open the pane, and they fail independently: a
                // session whose fixes were all rejected has a raw thread and no track, which is
                // precisely the session `PathSource.raw` is worth having for.
                if plot.hasGeometry
                    || (self.viewModel.pathSource == .raw && plot.hasRawGeometry) {
                    TrackMapPane(
                        plot: plot,
                        showRawLayer: self.viewModel.showRawLayer,
                        pathSource: self.viewModel.pathSource
                    )
                } else {
                    ContentUnavailableView {
                        // A single stored point is not "no points stored". The map cannot
                        // draw it, which is a different fact and gets a different title.
                        Label(
                            plot.storedPointCount > 0 ? "Not enough to draw" : "No points stored",
                            systemImage: "map"
                        )
                    } description: {
                        Text(self.emptyExplanation(for: plot))
                    }
                }
            }
        }
    }

    /// A session with fixes and no points is not an empty screen — it is the most
    /// interesting screen in the app, and it names the tab that explains it.
    /// Three different situations produce this screen, and they need three different
    /// sentences.
    ///
    /// The old copy told the first story in all three cases — so a session with one stored
    /// point was told that none of its fixes was stored, directly contradicting the summary
    /// card six inches below it. A diagnostic screen that disagrees with itself is worse
    /// than one that says nothing, because the tester now has to work out which half to
    /// believe.
    private func emptyExplanation(for plot: TrackPlot) -> String {
        guard plot.storedPointCount == 0 else {
            // Stored, but a line needs two ends. Common at the very start of a run and for
            // a session that never moved.
            let stored = plot.storedPointCount == 1
                ? "1 point was stored"
                : "\(plot.storedPointCount) points were stored"
            return "\(stored) for this session, and a track needs two to draw a line. "
                + "The Decisions tab names the stage that rejected the rest."
        }

        return plot.hasRawLayer
            ? "\(plot.rawFixCount) raw fixes were captured for this session and none of them was stored. The Decisions tab names the stage that rejected them."
            : "Nothing was captured for this session."
    }

    // MARK: Chips

    private var chips: some View {
        let plot = self.model.state.value

        return HStack(spacing: Theme.Spacing.tight) {
            // The source switch. Needs two fixes rather than one, because this chip promises a
            // *line* — `hasRawLayer` would light it up for a session holding a single fix and
            // then draw nothing.
            TrackChip(
                title: "Draw raw",
                systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                isOn: self.viewModel.pathSource == .raw && plot?.hasRawGeometry == true,
                isEnabled: plot?.hasRawGeometry == true
            ) {
                self.viewModel.pathSource = self.viewModel.pathSource == .raw ? .track : .raw
            }

            // Disabled, never hidden. A control that vanishes reads as a missing feature;
            // one that greys out reads as a missing input — which is precisely what an
            // empty raw layer is.
            //
            // Also disabled while the raw thread *is* the line: the overlay would then draw
            // the same coordinates a second time on top of themselves, and a chip whose only
            // effect is invisible is worse than one that is off.
            TrackChip(
                title: "Raw (\(plot?.rawFixCount ?? 0))",
                systemImage: "scribble",
                isOn: self.viewModel.showRawLayer
                    && plot?.hasRawLayer == true
                    && self.viewModel.pathSource == .track,
                isEnabled: plot?.hasRawLayer == true && self.viewModel.pathSource == .track
            ) {
                self.viewModel.showRawLayer.toggle()
            }

            TrackChip(
                title: "Snap",
                systemImage: "road.lanes",
                isOn: self.viewModel.snapToRoad,
                isEnabled: true
            ) {
                self.viewModel.snapToRoad.toggle()
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func notes(for plot: TrackPlot) -> some View {
        // Stated every time this mode is on, and deliberately not dismissible. The drawn line
        // is the most convincing thing on the screen and it is the one thing here that no
        // server will ever agree with.
        if self.viewModel.pathSource == .raw {
            ExplanationBox(
                text: "The line is the raw fix thread, not the track. Every fix the pipeline rejected is drawn, and speed bands, arrows and snapping do not apply — none of the three exists for geometry the plotting plane never saw. Raw fixes are a device-only diagnostic and are never uploaded, so this shape exists here and nowhere else. The summary and timeline below still describe the track."
            )
        }
        if !plot.hasRawLayer {
            ExplanationBox(
                text: "No raw fixes were stored for this session, so the Raw layer has nothing to draw. Turn on persistRawFixes before the run — it is off by default because it is a diagnostic, not production behaviour."
            )
        }
        if plot.isSnapUnavailable {
            ExplanationBox(
                text: "Road snapping was requested and could not be answered, so this line is raw geometry. Check OSRM_BASE_URL and the network before reading anything into the shape."
            )
        }
        if plot.isTruncated {
            ExplanationBox(
                text: "This session is longer than one read, so the drawn track stops early. The counts below still cover the whole session."
            )
        }
    }

    // MARK: State

    /// The pin wins over whatever was handed in, which is the shared resolution rule
    /// stated the other way round: a session picked here is a session all four tabs move
    /// to on the next refresh.
    private var selection: String? {
        self.viewModel.selectedSessionID ?? self.sessionID
    }

    private var isTracking: Bool {
        self.viewModel.state.value?.isTracking == true
    }

    /// Every input that forces a rebuild, in one value `.task(id:)` can compare. Toggling the
    /// raw layer or the path source is deliberately absent: both change what is drawn, not what
    /// was built, and rebuilding a track to stop drawing it would be a database read and a full
    /// plotting pass to change nothing.
    private var loadKey: LoadKey {
        LoadKey(
            sessionID: self.selection,
            snapToRoad: self.viewModel.snapToRoad,
            rebuildToken: self.rebuildToken
        )
    }

    @State private var model: TrackViewModel
    @State private var mode: PaneMode = .plot
    @State private var rebuildToken = 0
}

// MARK: - PaneMode

private enum PaneMode: Hashable {
    case plot, live
}

private struct LoadKey: Equatable {
    let sessionID: String?
    let snapToRoad: Bool
    let rebuildToken: Int
}

// MARK: - TrackMapPane

/// The map, and nothing else.
///
/// Its own view so that the walking arrow's sixty state changes a second re-evaluate this
/// body alone: the picker, the chips and the summary sit outside it and are never touched
/// by the animation. Inside it, every polyline is an array `TrackPlot` built once, so a
/// frame costs array references rather than a decode.
private struct TrackMapPane: View {

    let plot: TrackPlot
    let showRawLayer: Bool
    let pathSource: PathSource

    var body: some View {
        Map(position: self.$camera, interactionModes: .all) {
            if self.pathSource == .raw {
                // The raw thread promoted from hairline to route. `contourStyle: .straight`
                // survives the promotion and matters more here than it did as an overlay:
                // the whole claim of this mode is that nothing between two fixes was
                // invented, and a geodesic contour would invent exactly that.
                MapPolyline(coordinates: self.plot.rawThread, contourStyle: .straight)
                    .stroke(self.options.basePathColor, lineWidth: self.casingWidth)

                // One colour, and deliberately not a speed-band one. A raw fix carries no
                // band — the ladder that assigns them runs over stored points in
                // `TrackerGeo` — so drawing this green would invent a verdict the engine
                // never reached, on the one line whose selling point is that nothing was
                // added to it.
                MapPolyline(coordinates: self.plot.rawThread, contourStyle: .straight)
                    .stroke(
                        TrackMapPane.rawPathColor
                            .opacity(self.options.speedOverlayOpacity),
                        lineWidth: self.pathWidth
                    )
            } else {
                // One dark line under everything, so a seam between two speed segments never
                // shows the map through the route.
                MapPolyline(coordinates: self.plot.basePath)
                    .stroke(self.options.basePathColor, lineWidth: self.casingWidth)

                // One polyline per TRAVEL segment, coloured by the band the engine assigned.
                // This view does not know what speed produced the band, and must not: the
                // ladder that decided it lives in `TrackerGeo` and feeds the JSON export from
                // the same array.
                ForEach(self.plot.travelSegments) { segment in
                    MapPolyline(coordinates: segment.coordinates)
                        .stroke(
                            self.colour(for: segment.speedBand)
                                .opacity(self.options.speedOverlayOpacity),
                            lineWidth: self.pathWidth
                        )
                }
            }

            // Layer 1, drawn OVER the finished track and hairline-thin, because the
            // question it answers is "how far is the drawn line from what arrived".
            //
            // `contourStyle: .straight` is this layer's whole claim: no geodesic
            // interpolation, no smoothing, no processing of any kind. Two consecutive
            // fixes are joined by the shortest thing the renderer can draw and nothing in
            // between is invented. Stated rather than left to the default, because a
            // default that changed would quietly turn this layer into a lie.
            //
            // Suppressed under `.raw`, where the comparison has no two sides to it: the
            // overlay and the route would be the same coordinates drawn twice.
            if self.pathSource == .track, self.showRawLayer, self.plot.rawThread.count >= 2 {
                MapPolyline(coordinates: self.plot.rawThread, contourStyle: .straight)
                    .stroke(.black, lineWidth: TrackMapPane.rawThreadWidth)
            }

            // `TrackBuilder` has already applied the co-located-marker nudge (EC-109).
            // Applying it again here would double the offset and walk a stack of pins off
            // the building they sit on.
            ForEach(self.plot.track.stops, id: \.index) { stop in
                Annotation(
                    "",
                    coordinate: CLLocationCoordinate2D(
                        latitude: stop.latitude,
                        longitude: stop.longitude
                    ),
                    anchor: .bottom
                ) {
                    Image(
                        uiImage: TrackIcons.numberedPin(
                            number: stop.index + 1,
                            size: self.options.stopPinSize
                        )
                    )
                    .onTapGesture {
                        self.selectedStop = (self.selectedStop?.index == stop.index) ? nil : stop
                    }
                }
            }

            // §23.3 — pulse the last stop when the session is still open
            if let ongoing = self.plot.track.stops.last(where: { $0.isOngoing }) {
                Annotation(
                    "",
                    coordinate: CLLocationCoordinate2D(
                        latitude: ongoing.latitude,
                        longitude: ongoing.longitude
                    ),
                    anchor: .center
                ) {
                    Circle()
                        .fill(Color.blue.opacity(0.25))
                        .frame(width: self.pulseSize, height: self.pulseSize)
                        .animation(
                            .easeInOut(duration: 2).repeatForever(autoreverses: true),
                            value: self.pulseSize
                        )
                }
            }

            if let stop = self.selectedStop {
                Annotation(
                    "",
                    coordinate: CLLocationCoordinate2D(
                        latitude: stop.latitude,
                        longitude: stop.longitude
                    ),
                    anchor: .bottom
                ) {
                    StopTooltip(stop: stop, timezone: self.plot.track.timezone)
                        .padding(.bottom, self.options.stopPinSize + 4)
                        .onTapGesture { self.selectedStop = nil }
                }
            }

            // Anchored to the line actually on screen, not to `basePath`. Under `.raw` the two
            // differ by every fix the pipeline dropped, and a finish flag floating off the end
            // of the drawn route is the kind of detail that makes a tester distrust the whole
            // pane.
            if let start = self.drawnPath.first {
                Annotation("", coordinate: start, anchor: .center) {
                    EndpointMarker(
                        systemImage: "smallcircle.filled.circle",
                        tint: Theme.Status.good
                    )
                }
            }
            if let end = self.drawnPath.last {
                Annotation("", coordinate: end, anchor: .center) {
                    EndpointMarker(systemImage: "flag.checkered", tint: .primary)
                }
            }

            // §23.2 — static direction arrows at pre-computed positions from TrackBuilder.
            ForEach(Array(self.visibleArrows.enumerated()), id: \.offset) { _, anchor in
                Annotation(
                    "",
                    coordinate: CLLocationCoordinate2D(latitude: anchor.latitude, longitude: anchor.longitude),
                    anchor: .center
                ) {
                    TravellingArrow(headingDeg: anchor.bearing, size: self.arrowSize)
                }
            }

        }
        // `.onEnd`, deliberately, not `.continuous`.
        //
        // Every camera callback re-evaluates this body, and this body rebuilds the whole
        // map content — a 141-point base path, a polyline per travel segment, a 175-point
        // raw thread and every pin. Doing that on each frame of a pinch is what makes the
        // gesture feel like it is fighting back. The width settles the instant the fingers
        // lift, which costs one reflow per gesture instead of sixty.
        .onMapCameraChange(frequency: .onEnd) { context in
            self.cameraDistance = context.camera.distance
            self.visibleSpanM = TrackMapPane.spanMetres(of: context.region)
        }
        .background {
            // Measured rather than assumed. `GeometryReader` in a background so it reports the
            // pane's size without taking part in its layout.
            GeometryReader { proxy in
                Color.clear
                    .onAppear { self.paneWidthPoints = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in self.paneWidthPoints = width }
            }
        }
        // **No map-wide tap gesture.** A `.simultaneousGesture(TapGesture())` here fires on
        // the same tap that hits a pin — simultaneously, by definition — so selecting a stop
        // and clearing the selection raced on every tap and the tooltip flickered or never
        // appeared. A tooltip is dismissed by tapping its pin again or the tooltip itself,
        // both of which are unambiguous.
        .overlay(alignment: .top) {
            // Shown rather than logged: a map sitting on a continental view because
            // authorization was never granted looks exactly like a broken map, and the
            // difference is the first thing a tester needs.
            if let note = self.locationNote {
                Text(note)
                    .font(.caption2)
                    .padding(.horizontal, Theme.Spacing.row)
                    .padding(.vertical, Theme.Spacing.tight)
                    .background(.thinMaterial, in: Capsule())
                    .padding(Theme.Spacing.row)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                self.fit()
            } label: {
                Label("Fit", systemImage: "arrow.down.left.and.arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .labelStyle(.iconOnly)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(.secondarySystemBackground))
            .foregroundStyle(Color.primary)
            .padding(Theme.Spacing.row)
        }
        .onAppear {
            self.fit()
            self.pulseSize = 70
        }
        .onChange(of: self.plot.sessionID) {
            // A different session is a different camera.
            self.fit()
        }
        .onChange(of: self.pathSource) {
            // So is a different line. The two geometries have different extents — that is the
            // whole reason for looking at them — so keeping the old rectangle would frame the
            // new line on the bounds of the one it replaced.
            self.fit()
        }
    }

    // MARK: The camera

    /// Frames the whole track, start marker to finish flag.
    ///
    /// **Explicitly, rather than by leaving the camera on `.automatic`.** `.automatic`
    /// reframes from whatever map content currently exists, and this pane's content
    /// changes sixty times a second — the travelling arrow is map content — so an
    /// automatic camera is re-derived continuously and a pinch is undone before the
    /// fingers leave the glass. Setting a rectangle once makes the camera a thing the
    /// user owns until they ask for it back with Fit.
    ///
    /// The rectangle comes from `Track.bounds`, which `TrackBuilder` computed from the
    /// same points the polyline is drawn from. Deriving it here from `basePath` instead
    /// would be a second answer to "where is this track", and the two would disagree the
    /// first time one of them was changed.
    private func fit() {
        // `Track.bounds` does not describe the raw thread, and cannot be made to: it is
        // computed from the stored points, so the fixes that were never stored — the ones this
        // mode exists to show — fall outside it by definition. Framing on it would crop off
        // exactly the excursion the tester switched modes to look at.
        if self.pathSource == .raw,
           let rect = TrackMapPane.boundingRect(of: self.plot.rawThread) {
            self.frame(rect)
            return
        }

        guard let bounds = self.plot.track.bounds else {
            // **Nothing to frame is not nothing to show.** This guard used to return and
            // leave the camera on `.automatic`, which with no map content means a
            // continental default — so a session with no geometry yet opened looking like a
            // map bug rather than an empty session. The device's own position is the one
            // sensible thing to show instead.
            Task { await self.frameCurrentLocation() }
            return
        }
        self.frame(bounds.mapRect())
    }

    /// Sets the camera to a rectangle, inset so the line does not run to the glass.
    ///
    /// Framed by expanding the rectangle rather than padding the view.
    ///
    /// `.safeAreaPadding` used to do this, and MapKit anchors its own attribution to the
    /// safe area — so an 80-point inset floated the Apple Maps logo and Legal link 80 points
    /// up from the bottom edge, into the middle of the track. The logo's placement is not
    /// ours to move, and Apple's terms are specific about it staying visible and unobstructed.
    private func frame(_ rect: MKMapRect) {
        let fraction = self.paneWidthPoints > 0
            ? Double(self.framingPadding) / self.paneWidthPoints
            : TrackMapPane.fallbackFramingFraction
        self.camera = .rect(
            rect.insetBy(dx: -rect.width * fraction, dy: -rect.height * fraction)
        )
    }

    /// The rectangle enclosing a coordinate list, or `nil` for fewer than two.
    ///
    /// Only ever asked about the raw thread. The track has `Track.bounds`, computed by
    /// `TrackBuilder` from the points the polyline is drawn from, and deriving a second answer
    /// for it here is what the `fit()` comment warns against.
    private static func boundingRect(of coordinates: [CLLocationCoordinate2D]) -> MKMapRect? {
        guard coordinates.count >= 2 else { return nil }
        return coordinates.reduce(MKMapRect.null) { rect, coordinate in
            rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize()))
        }
    }

    /// Centres on the device, for the case there is no track to frame.
    ///
    /// `Tracker.getCurrentLocation()` rather than MapKit's own `.userLocation` camera: the
    /// sample exists to demonstrate the SDK, and a blue dot managed by a second
    /// `CLLocationManager` would be a position this app got from somewhere other than the
    /// thing it is meant to be showing off. It also needs no session, which is the whole
    /// point of that API.
    ///
    /// Silent on failure by design — `locationNote` carries the reason to the panel below
    /// rather than leaving the map on a continental view with no explanation.
    private func frameCurrentLocation() async {
        switch await Tracker.shared.getCurrentLocation() {
        case .success(let fix):
            self.camera = .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: fix.latitude,
                        longitude: fix.longitude
                    ),
                    // A street-level box, matching the floor `Bounds.mapRect` applies to a
                    // single-point track — so an empty session and a one-point session open
                    // at the same scale instead of jumping when the first point lands.
                    latitudinalMeters: TrackMapPane.emptyFrameSpanM,
                    longitudinalMeters: TrackMapPane.emptyFrameSpanM
                )
            )
            self.locationNote = nil

        case .failure(_, let message):
            self.locationNote = message

        @unknown default:
            self.locationNote = "unrecognised result"
        }
    }

    // MARK: Palette

    private func colour(for speedBand: String?) -> Color {
        switch speedBand {
        case SpeedBandName.green:
            return self.options.speedBandGreen
        case SpeedBandName.yellow:
            return self.options.speedBandYellow
        default:
            // `SpeedBandName.red`, and anything a future engine emits that this build
            // does not recognise. A band it cannot name is still a band.
            return self.options.speedBandRed
        }
    }

    /// Used before the pane has reported its width — one layout pass, at most.
    private static let fallbackFramingFraction: Double = 0.2

    private var framingPadding: CGFloat {
        self.drawnPath.count <= 2
            ? self.options.twoPointCameraPadding
            : self.options.cameraPadding
    }

    /// The coordinates the main line is drawn from — the one geometry every decoration on this
    /// pane has to agree with. Read it rather than `plot.basePath` anywhere the answer must
    /// follow what is on screen.
    private var drawnPath: [CLLocationCoordinate2D] {
        self.pathSource == .raw ? self.plot.rawThread : self.plot.basePath
    }

    // MARK: Stored

    /// The SDK's own palette and metrics, so the sample and `TrackMapView` cannot drift
    /// apart on colour or line weight.
    private let options = RenderOptions()

    /// A hairline: thick enough to follow, thin enough that it never hides the band it is
    /// there to be compared against.
    private static let rawThreadWidth: CGFloat = 1

    /// The raw route's colour under `PathSource.raw`.
    ///
    /// Outside the speed-band palette on purpose, and the one colour on this pane that does not
    /// come from `RenderOptions`. Green, yellow and red are verdicts the engine reached about
    /// stored points; a raw fix has no verdict, so borrowing one of the three to draw it would
    /// state a speed the ladder never assigned. Distinct enough that a screenshot of this mode
    /// cannot be mistaken for a screenshot of the track, which is the failure this whole mode
    /// invites.
    private static let rawPathColor = Color.cyan

    @State private var selectedStop: StopNode?
    @State private var pulseSize: CGFloat = 40
    @State private var camera: MapCameraPosition = .automatic

    /// Why the map could not centre on the device, or `nil` when it did.
    @State private var locationNote: String?

    /// The span used when there is no track to frame. Matches `Bounds.mapRect`'s own
    /// minimum, so an empty session and a one-point session open at the same scale.
    private static let emptyFrameSpanM: CLLocationDistance = 200

    /// Camera altitude in metres, from `onMapCameraChange`. Drives the stroke width.
    @State private var cameraDistance: Double = 0

    /// The pane's own width, for the framing inset.
    @State private var paneWidthPoints: Double = 0

    /// Metres across the visible region, from the last settled camera. `0` until one settles,
    /// which draws every anchor — correct for a first frame that has not been zoomed yet.
    @State private var visibleSpanM: Double = 0

    // MARK: Arrows

    /// The engine's anchors, thinned to what the current camera can show without overlap.
    ///
    /// **Selects from `track.arrows`; it never computes a position.** That distinction is the
    /// SDK's rule and it matters: `Arrows.place` slices the snapped, pre-smoothing path, so
    /// deriving new anchors from the rendered polyline would let vertex density decide arrow
    /// density and the drawn arrows would stop matching the exported ones. Dropping some of the
    /// engine's own anchors changes neither the track nor the export — only how many are drawn.
    ///
    /// The alternative was rebuilding the track on every camera settle, which is what
    /// `TrackMapView.onArrowZoomChange` offers a host and what this pane did until it turned out
    /// to cost a full `buildTrack` — database read, plotting plane, snapping — mid-pinch, with
    /// every polyline and annotation re-rendered on arrival. That is the same continuous
    /// invalidation that starved MapKit's own gesture recognisers when a travelling arrow was
    /// animating here, and it presented the same way: a map that fights back when you zoom out.
    /// A host that wants exact ladder spacing still has the rebuild; a diagnostics screen does
    /// not need it.
    private var visibleArrows: [ArrowAnchor] {
        // None under `.raw`. `Arrows.place` anchored these to the snapped pre-smoothing path,
        // so every one of them sits on the track — draw them over a raw line and they float
        // beside it, pointing along a route that is not the one on screen.
        guard self.pathSource == .track else { return [] }

        let arrows = self.plot.track.arrows
        guard self.visibleSpanM > 0, arrows.count > 1 else { return arrows }

        let minSpacingM = self.visibleSpanM / TrackMapPane.arrowsAcrossScreen

        var kept: [ArrowAnchor] = []
        var lastDrawn: MKMapPoint?
        for anchor in arrows {
            let point = MKMapPoint(
                CLLocationCoordinate2D(latitude: anchor.latitude, longitude: anchor.longitude)
            )
            if let lastDrawn, lastDrawn.distance(to: point) < minSpacingM { continue }
            kept.append(anchor)
            lastDrawn = point
        }
        return kept
    }

    /// Metres across the visible region, measured with MapKit's own projection rather than a
    /// degrees-to-metres constant of ours.
    private static func spanMetres(of region: MKCoordinateRegion) -> Double {
        let west = MKMapPoint(
            CLLocationCoordinate2D(
                latitude: region.center.latitude,
                longitude: region.center.longitude - region.span.longitudeDelta / 2
            )
        )
        let east = MKMapPoint(
            CLLocationCoordinate2D(
                latitude: region.center.latitude,
                longitude: region.center.longitude + region.span.longitudeDelta / 2
            )
        )
        return west.distance(to: east)
    }

    // MARK: Arrow size

    /// Tied to `pathWidth`, not fixed.
    ///
    /// `RenderOptions.arrowSize` is 30 points and the stroke ranges from 10 down to 3, so a
    /// fixed glyph is three times the line at street level and **ten times** it across a city —
    /// which is what turned a 15 km commute into a chain of chevrons with the route invisible
    /// underneath. MapKit annotations do not scale with the camera, so anything that must stay
    /// in proportion to the route has to be scaled by hand, on the same curve, or it will not
    /// stay in proportion at all.
    ///
    /// The ratio is taken from the near-zoom pair the palette was designed against — a 30-point
    /// arrow on a 10-point line — so the close-in look is unchanged and only the wide views are
    /// corrected.
    private var arrowSize: CGFloat {
        self.pathWidth * TrackMapPane.arrowToPathRatio
    }

    // MARK: Stroke width

    /// **MapKit strokes in screen POINTS, not metres**, so a fixed width is a different
    /// road at every zoom. At 16 pt — the SDK's `RenderOptions` default, chosen for a
    /// street-level frame — a whole-city view draws the route as a ribbon wider than the
    /// motorway under it, which is what made the line unreadable in the field screenshot.
    ///
    /// Interpolated on the LOG of camera distance, because zoom is logarithmic: a linear
    /// ramp spends almost its entire range on the last two zoom steps and looks like a
    /// step change everywhere else.
    private var pathWidth: CGFloat {
        guard self.cameraDistance > 0 else { return TrackMapPane.maxPathWidth }

        let t = (log(self.cameraDistance) - log(TrackMapPane.nearDistanceM))
            / (log(TrackMapPane.farDistanceM) - log(TrackMapPane.nearDistanceM))
        let clamped = min(max(t, 0), 1)

        return TrackMapPane.maxPathWidth
            - (TrackMapPane.maxPathWidth - TrackMapPane.minPathWidth) * clamped
    }

    /// The dark line under the bands. Two points wider so it reads as a casing rather than
    /// a second route, and it is what stops the map showing through a seam between two
    /// speed segments.
    private var casingWidth: CGFloat {
        self.pathWidth + TrackMapPane.casingInset
    }

    /// Street level: the route should read as a road-width ribbon.
    private static let nearDistanceM: Double = 400

    /// City level: a 15 km track fits the screen and the line must stay a line.
    private static let farDistanceM: Double = 30_000

    /// How many arrows a full screen width may hold before they start reading as a chain rather
    /// than as direction marks. A display density, not a rule about the route: the engine's
    /// spacing ladder is the rule, and this only decides how much of it fits on the glass.
    private static let arrowsAcrossScreen: Double = 6

    /// 30 ÷ 10: `RenderOptions.arrowSize` over `maxPathWidth`, the pair the SDK's palette was
    /// drawn for. A proportion, not a threshold.
    private static let arrowToPathRatio: CGFloat = 3

    private static let maxPathWidth: CGFloat = 10
    private static let minPathWidth: CGFloat = 3
    private static let casingInset: CGFloat = 2
}

// MARK: - StopTooltip

/// §23.3 info window — shown above the tapped stop pin.
private struct StopTooltip: View {

    let stop: StopNode
    /// Timezone string from Track, forwarded by TrackMapPane.
    var timezone: String = "UTC"

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 📍 Stop number
            Label("Stop \(self.stop.index + 1)", systemImage: "mappin.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            // ⏰ Arrival time
            if !self.arrivalText.isEmpty {
                Label(self.arrivalText, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // ⏳ Dwell
            Text(self.dwellText)
                .font(.system(.title3, design: .monospaced).weight(.bold))
            // 🗺️ Address
            if let addr = self.stop.address, !addr.isEmpty {
                Label(addr, systemImage: "map")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    private var arrivalText: String {
        guard self.stop.arrivalMs > 0 else { return "" }
        let fmt = DateFormatter()
        fmt.timeZone = TimeZone(identifier: self.timezone) ?? .current
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: Date(timeIntervalSince1970: Double(self.stop.arrivalMs) / 1000))
    }

    private var dwellText: String {
        let sec = self.stop.dwellSec
        if sec < 60 { return "\(sec)s stopped" }
        let m = sec / 60; let s = sec % 60
        return s == 0 ? "\(m) min" : "\(m) min \(s)s"
    }
}

// MARK: - LiveMapPane

/// The live surface, straight out of `TrackerMaps`.
///
/// Nothing to add to it but the camera policy: `LiveTrackMapView` owns its overlays and
/// its puck animation, and it needs no extra layers — which is exactly why this one *is*
/// wrapped rather than reimplemented. The feed is collected with `.task`, so the loop is
/// cancelled with the view rather than outliving it.
///
/// **`followMode` is `.none` in `LiveOptions`, and that default is right for the SDK.**
/// It means "the camera is never touched", which is what a host wants when it has its own
/// idea of where the camera should be. It is not what this screen wants: a tester watching
/// a run wants the map to keep up with the device. So the sample opts in — the same shape
/// as its `persistRawFixes` opt-in, and for the same reason.
///
/// `.follow` rather than `.followBearing`: north-up survives a noisy or sparse feed, where
/// a chase camera spins on every heading wobble. `.followBearing` also fixes the camera
/// distance on every frame, so it takes zoom away permanently rather than temporarily.
private struct LiveMapPane: View {

    let model: TrackViewModel

    var body: some View {
        LiveTrackMapView(
            update: self.update,
            options: LiveMapPane.options,
            isFollowing: self.$isFollowing,
            initialCentre: self.initialCentre
        )
        .overlay(alignment: .bottomTrailing) {
            // Only while suspended. A permanently visible button would be a control that
            // does nothing for the entire time the map is already following.
            if !self.isFollowing {
                Button {
                    self.isFollowing = true
                } label: {
                    Label("Resume", systemImage: "location.fill")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .padding(Theme.Spacing.row)
            }
        }
        .task {
            // Before the feed, not instead of it. With no session running no frame ever
            // arrives, and the map would otherwise sit on MapKit's contentless default —
            // a view of the whole world — for as long as the screen is open. One fix is
            // the cheapest honest answer to "where should this map be looking".
            if case .success(let fix) = await Tracker.shared.getCurrentLocation() {
                self.initialCentre = GeoPoint(
                    latitude: fix.latitude,
                    longitude: fix.longitude
                )
            }

            for await frame in self.model.liveTrack() {
                self.update = frame
            }
        }
    }

    private static var options: LiveOptions {
        var options = LiveOptions()
        options.followMode = .follow
        return options
    }

    @State private var update: LiveTrackUpdate?

    /// Where to look until the first frame arrives. Read once by the map and then ignored,
    /// so it cannot pull the camera back once the feed is driving it.
    @State private var initialCentre: GeoPoint?

    /// Starts engaged, and the first pan or pinch hands the camera back to the user.
    @State private var isFollowing = true
}

// MARK: - TrackSummaryCard

/// The numbers, with the one that matters at the top.
private struct TrackSummaryCard: View {

    let plot: TrackPlot

    var body: some View {
        DiagnosticCard(title: "Summary", systemImage: "chart.bar.doc.horizontal") {
            // THE RATIO. The most useful number on this screen: a wide gap is the thing
            // to go and explain, and which side of it the loss happened on is the
            // difference between "the pipeline discarded them" and "the OS never offered
            // them" — a Decisions-tab question and a background-execution question
            // respectively.
            VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
                Text("RAW FIXES → STORED POINTS")
                    .font(Theme.Typography.pill)
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.row) {
                    Text("\(self.plot.rawFixCount)")
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("\(self.plot.storedPointCount)")
                        .font(.system(.title2, design: .monospaced).weight(.semibold))

                    Spacer(minLength: Theme.Spacing.tight)

                    Pill(text: self.keptText, tint: Theme.Status.idle)
                }
                .textSelection(.enabled)
            }

            Divider()

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), alignment: .leading),
                    count: 3
                ),
                alignment: .leading,
                spacing: Theme.Spacing.row
            ) {
                TrackStat(label: "Distance", value: self.distanceText)
                TrackStat(label: "Tracked",  value: Self.durationText(self.plot.track.stats.totalDurationSec))
                TrackStat(label: "Moving",   value: Self.durationText(self.plot.track.stats.movingDurationSec))
                TrackStat(label: "Stopped",  value: Self.durationText(self.plot.track.stats.stoppedDurationSec))
                TrackStat(label: "Points",   value: "\(self.plot.storedPointCount)")
                TrackStat(label: "Stops",    value: "\(self.plot.track.stops.count)")
                TrackStat(label: "Session",  value: SessionPicker.shortID(self.plot.sessionID))
            }

            // §25 activity breakdown
            if !self.activityBreakdown.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
                    Text("COMMUTE BREAKDOWN")
                        .font(Theme.Typography.pill)
                        .foregroundStyle(.secondary)
                    ForEach(self.activityBreakdown, id: \.0) { name, sec in
                        HStack {
                            Text(name)
                                .font(Theme.Typography.factName)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Self.durationText(sec))
                                .font(Theme.Typography.factValue)
                        }
                    }
                }
            }
        }
    }

    /// `—` rather than `0 %` when there is no raw layer: nothing was measured, which is a
    /// different fact from "nothing survived", and they have different fixes.
    private var keptText: String {
        guard let share = self.plot.keptShare else { return "NO RAW LAYER" }
        return String(format: "%.0f%% KEPT", share * 100)
    }

    private var distanceText: String {
        let metres = self.plot.track.stats.totalDistanceMeters
        return metres >= 1000
            ? String(format: "%.2f km", metres / 1000)
            : String(format: "%.0f m", metres)
    }

    /// §25 — `"1hr 5mins"` / `"25mins"` / `"0mins"`
    private static func durationText(_ seconds: Int64) -> String {
        let m = seconds / 60
        if m == 0 { return "0mins" }
        if m < 60 { return "\(m)mins" }
        let h = m / 60; let rm = m % 60
        return rm == 0 ? "\(h)hr" : "\(h)hr \(rm)mins"
    }

    /// Sorted descending by duration, skipping zero values.
    private var activityBreakdown: [(String, Int64)] {
        self.plot.track.stats.activityBreakdownSec
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    private static func minutesText(_ seconds: Int64) -> String {
        "\(seconds / 60) min"
    }
}

private struct TrackStat: View {

    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
            Text(self.label)
                .font(Theme.Typography.factName)
                .foregroundStyle(.secondary)
            Text(self.value)
                .font(Theme.Typography.factValue)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Small parts

/// A toggle that greys out rather than disappearing.
private struct TrackChip: View {

    let title: String
    let systemImage: String
    let isOn: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Label(self.title, systemImage: self.systemImage)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, Theme.Spacing.card)
                .padding(.vertical, Theme.Spacing.tight)
                .background(
                    Capsule().fill(
                        self.isOn
                            ? Color.accentColor.opacity(0.16)
                            : Color.secondary.opacity(0.12)
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        self.isOn ? Color.accentColor : Color.secondary.opacity(0.35),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(!self.isEnabled)
        .opacity(self.isEnabled ? 1 : 0.4)
    }
}

/// Start and end. Small, because they mark the ends of a line rather than a place — the
/// numbered pins are what mark places.
private struct EndpointMarker: View {

    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: self.systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(self.tint)
            .padding(3)
            .background(Circle().fill(.background))
            .allowsHitTesting(false)
    }
}
