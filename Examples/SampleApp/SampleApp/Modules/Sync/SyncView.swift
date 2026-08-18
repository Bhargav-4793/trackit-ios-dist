import SwiftUI
import TrackerCore

/// The upload instrument.
///
/// Reached from Home rather than given a tab of its own: iOS collapses a sixth tab into "More",
/// and burying the permission ladder or the decision log behind that would cost more than this
/// screen gains from being one tap closer.
///
/// The order answers the questions a host has while wiring an endpoint: where am I sending,
/// how much is waiting, and what did the server actually say.
struct SyncView: View {

    @State private var viewModel = SyncViewModel()

    @FocusState private var isEditing: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.section) {
                self.endpointCard
                self.queueCard
                self.feedCard
            }
            .padding(Theme.Spacing.screen)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Upload")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { self.isEditing = false }
            }
        }
        .task {
            await self.viewModel.onAppear()
        }
    }

    // MARK: - Endpoint

    private var endpointCard: some View {
        DiagnosticCard(title: "Endpoint", systemImage: "link") {
            TextField("https://your.server/track", text: self.$viewModel.endpoint)
                .textFieldStyle(.roundedBorder)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused(self.$isEditing)

            TextField("bearer token (optional)", text: self.$viewModel.bearerToken)
                .textFieldStyle(.roundedBorder)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(self.$isEditing)

            Toggle("Auto-sync on every accepted point", isOn: self.$viewModel.autoSync)
                .font(.caption)

            Button {
                self.isEditing = false
                Task { await self.viewModel.configure() }
            } label: {
                Label("Configure", systemImage: "checkmark.circle")
                    .actionLabel()
            }
            .buttonStyle(.borderedProminent)

            FactRow(
                name: "Status",
                value: self.viewModel.isConfigured ? "CONFIGURED" : "NOT CONFIGURED",
                tint: self.viewModel.isConfigured ? Theme.Status.good : Theme.Status.idle
            )

            // Where it is *actually* sending, which is not necessarily what is typed above: the
            // two diverge the moment the field is edited without pressing Configure.
            if let endpoint = self.viewModel.configuredEndpoint {
                FactRow(name: "Sending to", value: endpoint.absoluteString)
            }

            Text("""
                The uploader is given the SDK's own queue — `Tracker.shared.pendingUploads` — \
                rather than reaching for it, which is what keeps TrackerCore free of any \
                knowledge that an uploader exists. Points are queued whether or not this is \
                configured, so nothing is lost by wiring it later.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Queue

    private var queueCard: some View {
        DiagnosticCard(title: "Queue", systemImage: "tray.full") {
            FactRow(
                name: "Pending",
                value: self.viewModel.pending.map(String.init) ?? "—"
            )

            ActionRow {
                Button {
                    Task { await self.viewModel.syncNow() }
                } label: {
                    Label("Sync now", systemImage: "arrow.up.circle")
                        .actionLabel()
                }
                .buttonStyle(.bordered)

                // Both triggers, deliberately: they differ in whether the caller learns the
                // outcome, and a host choosing between them should see that difference.
                Button {
                    self.viewModel.requestSync()
                } label: {
                    Label("Request", systemImage: "paperplane")
                        .actionLabel()
                }
                .buttonStyle(.bordered)
            }

            if let result = self.viewModel.lastResult {
                ExplanationBox(text: result, tint: Theme.Status.idle)
            }

            Text("""
                `syncNow()` awaits the outcome and reports it; `requestSync()` returns \
                immediately and coalesces repeated calls. Rows are only marked uploaded on a \
                confirmed success, so a dropped response costs a duplicate rather than a point.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Feed

    private var feedCard: some View {
        DiagnosticCard(title: "Feed", systemImage: "waveform.path.ecg") {
            Text("""
                One HTTP line per exchange, before the outcome — a queue larger than the batch \
                size reports every round trip. "no response" means the request never reached a \
                server: offline, DNS, TLS.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if self.viewModel.feed.isEmpty {
                Text("Nothing yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(self.viewModel.feed, id: \.self) { line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
