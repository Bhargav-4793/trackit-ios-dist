import Foundation
import Observation
import TrackerCore
import TrackerGeo
import os

/// The geofence instrument.
///
/// Its own view model rather than more surface on `TrackingViewModel`, because geofences are
/// independent of tracking in the SDK and the screen has to be able to demonstrate that: you can
/// arm a fence, close the app, walk out of it and come back to a crossing recorded with no session
/// ever having been started. A view model that hung off the tracking state would quietly imply the
/// opposite.
@MainActor
@Observable
final class GeofenceViewModel {

    private let trackIt = Tracker.shared

    private static let logger = Logger(subsystem: "com.fieldtrack360.tracker.sample", category: "geofence")

    // MARK: State

    private(set) var fences: [Geofence] = []

    /// The stored crossing history — the read that matters most on this screen.
    ///
    /// A crossing delivered to a relaunched app is written before any host is subscribed, so this
    /// list is the only place it can be seen afterwards. If the live feed is empty and this is
    /// not, that is the SDK working exactly as designed.
    private(set) var history: [GeofenceEvent] = []

    /// Crossings seen live, newest first. Cleared on every launch, unlike `history`.
    private(set) var live: [String] = []

    private(set) var lastMessage: String?

    private(set) var isWorking = false

    // MARK: Form

    var radiusText = "200"
    var dwellMinutesText = ""

    @ObservationIgnored private var eventTask: Task<Void, Never>?

    private static let historyLimit = 100
    private static let liveLimit = 40
    private static let msPerMinute: Int64 = 60_000

    // MARK: - Lifecycle

    /// Idempotent: `TabView` re-runs a `.task` every time the tab reappears, and a second
    /// subscription would double every line in the live feed.
    func onAppear() async {
        await self.refresh()
        guard self.eventTask == nil else { return }
        self.eventTask = Task { [weak self] in
            for await event in Tracker.shared.events() {
                await self?.handle(event)
            }
        }
    }

    func refresh() async {
        self.fences = await self.trackIt.getGeofences()
        do {
            self.history = try await self.trackIt.getGeofenceEvents(limit: Self.historyLimit)
        } catch {
            self.lastMessage = "history unavailable: \(error.localizedDescription)"
        }
    }

    // MARK: - Commands

    /// Arms a fence around wherever the device is now.
    ///
    /// Uses `getCurrentLocation()` rather than the last stored point on purpose: a fence has to be
    /// armable with no session ever having run, and reaching for a stored point would make this
    /// screen depend on the tracking one.
    func addFenceHere() async {
        self.isWorking = true
        defer { self.isWorking = false }

        let fix: TrackFix
        switch await self.trackIt.getCurrentLocation() {
        case .success(let value):
            fix = value
        case .failure(_, let message):
            self.lastMessage = "no fix: \(message)"
            return
        @unknown default:
            self.lastMessage = "no fix: unrecognised result"
            return
        }

        guard let radiusM = Double(self.radiusText), radiusM > 0 else {
            self.lastMessage = "radius must be a positive number of metres"
            return
        }

        // Empty means no dwell, which is the SDK's default and a different thing from zero.
        let dwellAfterMs: Int64?
        if self.dwellMinutesText.isEmpty {
            dwellAfterMs = nil
        } else if let minutes = Double(self.dwellMinutesText), minutes > 0 {
            dwellAfterMs = Int64(minutes * Double(Self.msPerMinute))
        } else {
            self.lastMessage = "dwell must be blank or a positive number of minutes"
            return
        }

        let fence = Geofence(
            id: "fence-\(Int(Date().timeIntervalSince1970))",
            latitude: fix.latitude,
            longitude: fix.longitude,
            radiusM: radiusM,
            dwellAfterMs: dwellAfterMs
        )

        switch await self.trackIt.addGeofence(fence) {
        case .success(let armed):
            // The radius comes back clamped to what the OS will actually monitor, so the message
            // reports what exists rather than what was asked for.
            self.lastMessage = "armed \(armed.id) at \(Int(armed.radiusM)) m"
        case .failure(_, let message):
            self.lastMessage = message
        @unknown default:
            self.lastMessage = "unrecognised result"
        }

        await self.refresh()
    }

    func remove(_ fence: Geofence) async {
        let removed = await self.trackIt.removeGeofence(id: fence.id)
        self.lastMessage = removed ? "removed \(fence.id)" : "\(fence.id) was not armed"
        await self.refresh()
    }

    func removeAll() async {
        let count = await self.trackIt.removeAllGeofences()
        self.lastMessage = "removed \(count) fence\(count == 1 ? "" : "s")"
        await self.refresh()
    }

    /// Clears the crossing history and leaves the fences armed — the two are deliberately separate
    /// calls in the SDK, and this screen should show that.
    func clearHistory() async {
        do {
            try await self.trackIt.deleteGeofenceEvents()
            self.lastMessage = "history cleared"
        } catch {
            self.lastMessage = "clear failed: \(error.localizedDescription)"
        }
        await self.refresh()
    }

    // MARK: - Events

    private func handle(_ event: TrackerEvent) async {
        switch event {
        case .geofenceEnter(let crossing):
            self.record("ENTER", crossing)
        case .geofenceExit(let crossing):
            self.record("EXIT", crossing)
        case .geofenceDwell(let crossing):
            // Worth calling out on screen: this is the one iOS does not have, and the timestamp is
            // when the condition was met rather than when it arrived.
            self.record("DWELL", crossing)
        default:
            return
        }
        await self.refresh()
    }

    private func record(
        _ kind: String,
        _ crossing: GeofenceEvent
    ) {
        let stamp = Self.time.string(from: Date(timeIntervalSince1970: Double(crossing.timeMs) / 1000))
        self.live.insert("\(stamp)  \(kind)  \(crossing.geofenceID)", at: 0)
        if self.live.count > Self.liveLimit {
            self.live.removeLast(self.live.count - Self.liveLimit)
        }
        Self.logger.debug("\(kind, privacy: .public) \(crossing.geofenceID, privacy: .public)")
    }

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
