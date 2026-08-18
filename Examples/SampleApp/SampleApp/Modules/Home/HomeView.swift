import SwiftUI
import TrackerCore
import TrackerGeo
import UIKit

/// The instrument's front panel.
///
/// Everything on this screen answers a question a field tester asks in the first thirty seconds of a
/// run: is it recording, what does it think the device is doing, which rung of the ladder are we on,
/// which session is this, how big is the log, and what is the last thing that went wrong. There is
/// no decoration — a control that is not answering one of those is not here.
struct HomeView: View {

    @Bindable var viewModel: TrackingViewModel

    /// Guards the Start/Stop pair against a second tap while the first is in flight. `start()` is
    /// idempotent in the SDK, but a button that stays tappable through a two-second authorization
    /// check reads as unresponsive.
    @State private var isSwitching = false

    @State private var isConfirmingClear = false

    /// Set once the view model has flushed the log and handed back the file. Presenting the sheet
    /// off the prepared URL rather than off a `ShareLink` built at layout time is deliberate: the
    /// unflushed tail is exactly the part somebody sharing after a termination needs.
    @State private var shareItem: ShareItem?

    @State private var isPreparingShare = false

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.section) {
                    self.statusCard
                    self.sessionCard

                    PermissionLadderView(permissions: Tracker.shared.permissions()) {
                        // The tier just moved, so the status card is stale. The ladder does not know
                        // that, and should not.
                        await self.viewModel.refresh()
                    }

                    self.uploadCard
                    self.captureLogCard
                    self.eventFeedCard
                }
                .padding(Theme.Spacing.screen)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Tracker")
            .task {
                // `onAppear()` opens the event stream and runs for the life of the screen. It is the
                // view model's own retained loop; this only starts it.
                await self.viewModel.onAppear()
            }
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        DiagnosticCard(title: "Status", systemImage: "dot.radiowaves.left.and.right") {
            switch self.viewModel.state {
            case .idle:
                Text("ready() has not completed yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .loading:
                HStack(spacing: Theme.Spacing.row) {
                    ProgressView()
                    Text("Resolving configuration and restoring filter state…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .failed(let message):
                ExplanationBox(text: message, tint: Theme.Status.bad)

            case .loaded(let snapshot):
                self.facts(snapshot)
            }

            self.controls
        }
    }

    @ViewBuilder
    private func facts(_ snapshot: TrackingSnapshot) -> some View {
        VStack(spacing: Theme.Spacing.tight) {
            FactRow(
                name: "Tracking",
                value: snapshot.isTracking ? "RECORDING" : "STOPPED",
                tint: snapshot.isTracking ? Theme.Status.good : Theme.Status.idle
            )

            FactRow(
                name: "Motion state",
                value: snapshot.motionState.rawValue,
                tint: Self.tint(for: snapshot.motionState)
            )

            FactRow(
                name: "Authorization",
                value: snapshot.tier.rawValue,
                tint: Self.tint(for: snapshot.tier)
            )

            FactRow(
                name: "Session",
                value: snapshot.sessionID.map(SessionPicker.shortID) ?? "—"
            )

            FactRow(
                name: "Accepted points",
                value: "\(snapshot.pointCount)"
            )

            if let error = snapshot.lastError {
                Divider()
                // Kept on screen rather than flashed as a toast. A `.backgroundPermissionMissing`
                // is a degradation the run continues under, and the tester needs to still be able
                // to read it an hour later when the track has a hole in it.
                FactRow(name: "Last error", value: error, tint: Theme.Status.bad)
            }
        }
    }

    private var controls: some View {
        ActionRow {
            Button {
                self.switching { await self.viewModel.start() }
            } label: {
                Label("Start", systemImage: "play.fill")
                    .actionLabel()
            }
            .buttonStyle(.borderedProminent)
            .disabled(self.isSwitching || self.isTracking)

            Button {
                self.switching { await self.viewModel.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .actionLabel()
            }
            .buttonStyle(.bordered)
            .disabled(self.isSwitching || !self.isTracking)
        }
    }

    // MARK: - Session

    private var sessionCard: some View {
        DiagnosticCard(title: "Session", systemImage: "clock.arrow.circlepath") {
            SessionPicker(
                sessions: self.viewModel.sessions,
                selection: self.$viewModel.selectedSessionID,
                resolvedSessionID: self.resolvedSessionID
            )

            Text("""
                Track, Debug and Decisions all read this selection, so all three always describe the \
                same run. Leaving it on Live follows the session that is recording now.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Upload

    /// The way into `TrackerSync`.
    ///
    /// A card with a link rather than a sixth tab: iOS collapses the sixth into "More", and
    /// hiding the permission ladder or the decision log behind that would cost more than upload
    /// gains from being one tap closer. It sits on Home because configuring an endpoint is a
    /// lifecycle decision, next to permissions and the session, rather than an instrument.
    private var uploadCard: some View {
        DiagnosticCard(title: "Upload", systemImage: "arrow.up.circle") {
            NavigationLink {
                SyncView()
            } label: {
                HStack {
                    Text("Endpoint, queue and the HTTP feed")
                        .font(.footnote)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Text("Optional. Points are stored and queued whether or not an uploader is " +
                 "configured, so wiring this later loses nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Capture log

    private var captureLogCard: some View {
        DiagnosticCard(title: "Capture log", systemImage: "doc.text") {
            FactRow(
                name: "Size",
                value: "\(self.viewModel.captureLogSizeKB) KB"
            )

            ActionRow {
                // Disabled rather than hidden: a control that vanishes reads as a missing feature,
                // one that greys out reads as a missing input. Same rule as the Track tab's `Raw`
                // chip.
                Button {
                    self.isPreparingShare = true
                    Task {
                        if let url = await self.viewModel.prepareCaptureLogForSharing() {
                            self.shareItem = ShareItem(url: url)
                        }
                        self.isPreparingShare = false
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .actionLabel()
                }
                .buttonStyle(.bordered)
                .disabled(self.viewModel.captureLogSizeKB == 0 || self.isPreparingShare)

                Button(role: .destructive) {
                    self.isConfirmingClear = true
                } label: {
                    Label("Clear", systemImage: "trash")
                        .actionLabel()
                }
                .buttonStyle(.bordered)
                .disabled(self.viewModel.captureLogSizeKB == 0)
            }

            ActionRow {
                Button {
                    Task { await self.viewModel.dumpSession() }
                } label: {
                    Label("Dump", systemImage: "square.and.arrow.down")
                        .actionLabel()
                }
                .buttonStyle(.bordered)
                .disabled(self.resolvedSessionID == nil)

                // Not disabled on the session, unlike every other button here: one fix needs
                // `ready()` and nothing else, and being able to press this while stopped is the
                // whole point of the API.
                Button {
                    Task { await self.viewModel.showCurrentLocation() }
                } label: {
                    Label("One fix", systemImage: "location.viewfinder")
                        .actionLabel()
                }
                .buttonStyle(.bordered)

                // Step 4 of the field-run protocol. No longer gated on `TRACKER_SDK_DEBUG`: the
                // recorder ships in the release frameworks, because the anomaly worth recording
                // happens in the field, on the build the user actually has.
                Button {
                    Task {
                        if let url = await self.viewModel.recordFixture() {
                            self.shareItem = ShareItem(url: url)
                        }
                    }
                } label: {
                    Label("Fixture", systemImage: "shippingbox")
                        .actionLabel()
                }
                .buttonStyle(.bordered)
                .disabled(self.resolvedSessionID == nil)
            }

            Text("""
                One file, appended across runs, with a banner per launch. Clear it before a field \
                run and share it after — the cross-session comparison is where permission and OEM \
                problems show up.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(
            "Clear the capture log?",
            isPresented: self.$isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task { await self.viewModel.clearCaptureLog() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every run banner and every recorded decision in the file is deleted. Share it first if this run is not finished being explained.")
        }
        .sheet(item: self.$shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    // MARK: - Event feed

    private var eventFeedCard: some View {
        DiagnosticCard(title: "Events", systemImage: "list.bullet.indent") {
            if self.viewModel.log.isEmpty {
                Text("No events yet. The stream starts at ready() and carries the full vocabulary — locations, rejections, motion and provider changes, heartbeats and errors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Pill(text: "\(self.viewModel.log.count) LINES", tint: Theme.Status.idle)
                    Spacer()
                    Text("newest first")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // The durable record is the capture log; this is the convenience copy, capped by the
                // view model. Rendered in a fixed-height pane so a busy drive cannot push the rest
                // of the screen off the bottom.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.hair) {
                        ForEach(Array(self.viewModel.log.enumerated()), id: \.offset) { entry in
                            Text(entry.element)
                                .font(Theme.Typography.log)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(height: 260)
            }
        }
    }

    // MARK: - Derived

    private var isTracking: Bool {
        if case .loaded(let snapshot) = self.viewModel.state {
            return snapshot.isTracking
        }
        return false
    }

    private var resolvedSessionID: String? {
        if let selected = self.viewModel.selectedSessionID {
            return selected
        }
        if case .loaded(let snapshot) = self.viewModel.state {
            return snapshot.sessionID
        }
        return nil
    }

    // MARK: - Helpers

    /// Runs a lifecycle call with the pair disabled around it.
    private func switching(_ work: @escaping @MainActor () async -> Void) {
        self.isSwitching = true
        Task {
            await work()
            self.isSwitching = false
        }
    }

    private static func tint(for state: MotionState) -> Color {
        switch state {
        case .moving: Theme.Status.good
        case .stopPending: Theme.Status.warn
        case .stopped, .stationary: Theme.Status.idle
        @unknown default: Theme.Status.idle
        }
    }

    private static func tint(for tier: AuthorizationTier) -> Color {
        switch tier {
        case .always: Theme.Status.good
        case .whenInUse: Theme.Status.warn
        case .none: Theme.Status.bad
        // An unrecognised tier is treated as the weakest one. Tinting it green
        // would tell the user background capture is safe on the strength of a
        // value this build cannot interpret.
        @unknown default: Theme.Status.bad
        }
    }
}
