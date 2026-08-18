import SwiftUI
import TrackerCore
import TrackerSnap
import os

/// The sample host.
///
/// This app is not a demo. It is the diagnostic instrument the field matrix runs on, so its entry
/// point is written the way a host's entry point has to be written rather than the way a demo's
/// usually is.
@main
struct SampleApp: App {

    private static let logger = Logger(subsystem: "com.fieldtrack360.tracker.sample", category: "app")

    init() {
        // `ready()` in the App initialiser, NOT in a view's `.task`.
        //
        // It restores filter state and reports an interrupted session, and both must happen before
        // any UI exists to observe them. It is also the only place that works on a background
        // relaunch, where there is no view at all — and it is where `BGTaskScheduler` registration
        // has to happen, because registering after the app finishes launching traps (EC-207).
        Task {
            let result = await Tracker.shared.ready(
                TrackerConfig.builder()
                    .accuracyProfile(.balanced)
                    .trackingMode(.adaptive)
                    // 1 s, against a default of 60 s.
                    //
                    // The default is a battery figure, and it is the right one for a delivery
                    // day: `.normal` is every non-vehicular tier, so walking samples once a
                    // minute. That makes short movement invisible — 10 m of walking takes about
                    // 8 seconds and falls entirely inside one interval, so the engine sees the
                    // same position before and after and correctly calls it stationary.
                    //
                    // The engine already resolves 10 m (`distMinMove`); it just has to be given
                    // fixes often enough to see it. A sample whose whole purpose is diagnosis
                    // should sample at the rate the thing being diagnosed happens.
                    .intervalMs(1_000)
                    // Off by default in the SDK because they are diagnostics, not production
                    // behaviour. The sample turns them on because the sample exists to diagnose:
                    // layer 1 and layer 3 of the three-layer overlay have no other source.
                    .persistRawFixes(true)
                    .persistRawPoints(true)
                    .buildUnchecked()
            )

            // `ready()` is `@discardableResult` and the specification's snippet drops it. Do not.
            // Everything downstream is gated on the runtime it builds — `ProviderStateMonitor` is
            // started in its step 5, and `Tracker.start()` refuses on the snapshot that monitor
            // publishes. So a silent failure here presents as `permissionDenied` on a Start tap
            // long afterwards, with a granted permission ladder sitting directly beneath it.
            // A sample that swallows this teaches the wrong integration.
            if case .failure(let code, let message) = result {
                Self.logger.error("ready() failed: \(String(describing: code), privacy: .public) — \(message, privacy: .public)")
            } else {
                Self.logger.notice("ready() succeeded")
            }
        }
        Self.installRoadSnapping()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }

    // MARK: - Road snapping

    /// Installs the road-snap provider, for real.
    ///
    /// ↔ Android (G-28): the equivalent there is an empty stub, so the snap module is never
    /// exercised anywhere in that repository and the Snap toggle is inert while looking wired.
    ///
    /// The endpoint comes from `OSRM_BASE_URL`, which an uncommitted xcconfig supplies and which
    /// has no default. Absent, nothing is installed: `buildTrack` keeps returning raw geometry and
    /// the Snap toggle is honestly inert rather than silently pointed at a server somebody else
    /// pays the rate limit on. The URL itself is never logged — this app's capture log gets mailed
    /// to people outside the project.
    private static func installRoadSnapping() {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "OSRM_BASE_URL") as? String,
              !raw.isEmpty,
              let url = URL(string: raw) else {
            Self.logger.info("OSRM_BASE_URL is unset; road snapping is disabled and tracks stay raw")
            return
        }
        Tracker.shared.setRoadSnapProvider(OSRMSnapProvider(baseURL: url))
        Self.logger.info("Road snapping installed")
    }
}
