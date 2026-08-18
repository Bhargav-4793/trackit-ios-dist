import SwiftUI

/// The five tabs, in diagnostic order.
///
/// Home is where a run is started and where the permission ladder lives. Track, Debug and
/// Decisions are instruments and they all read the same session selection, so all three always
/// describe the same run.
///
/// Fences is the exception, and deliberately so: geofences are independent of tracking in the SDK,
/// so the screen reads no session and owns its own view model. A tester can arm a fence with no
/// run ever having been started, which is exactly the case a host will ship.
struct RootView: View {

    /// One view model for the whole app, owned here.
    ///
    /// It owns the event subscription and the capture log, and `onAppear()` is idempotent
    /// precisely because `TabView` re-runs a `.task` every time a tab reappears. A second instance
    /// would open a second subscription and double every line in the log — which is the same class
    /// of bug as a second `FixIngestor`, one layer up.
    @State private var viewModel = TrackingViewModel()

    var body: some View {
        TabView {
            HomeView(viewModel: self.viewModel)
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            TrackView(viewModel: self.viewModel)
                .tabItem {
                    Label("Track", systemImage: "map")
                }

            GeofenceView()
                .tabItem {
                    Label("Fences", systemImage: "mappin.and.ellipse")
                }

            DebugOverlayView()
                .tabItem {
                    Label("Debug", systemImage: "circle.hexagongrid")
                }

            DecisionLogView()
                .tabItem {
                    Label("Decisions", systemImage: "list.bullet.rectangle")
                }
        }
        .task {
            await self.viewModel.onAppear()
        }
    }
}
