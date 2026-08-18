import SwiftUI
import TrackerCore

/// The geofence instrument.
///
/// Arranged to answer the three questions a tester actually has, in order: what is armed, what has
/// crossed while I was watching, and — the one that matters — what crossed while I was **not**.
/// The live feed and the history are deliberately separate lists rather than one merged one,
/// because the difference between them is the whole point of storing crossings: a crossing
/// delivered to a relaunched app appears only in the second.
struct GeofenceView: View {

    @State private var viewModel = GeofenceViewModel()

    /// Focus, purely so the numeric keypad can be dismissed.
    ///
    /// `.decimalPad` has no return key, so without an explicit way out the keyboard covers the
    /// half of the screen a tester came here to read — the armed list and the history.
    @FocusState private var isEditing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.section) {
                    self.armCard
                    self.fencesCard
                    self.liveCard
                    self.historyCard
                }
                .padding(Theme.Spacing.screen)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Fences")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { self.isEditing = false }
                }
            }
            .task {
                await self.viewModel.onAppear()
            }
            .refreshable {
                await self.viewModel.refresh()
            }
        }
    }

    // MARK: - Arm

    private var armCard: some View {
        DiagnosticCard(title: "Arm a fence here", systemImage: "mappin.and.ellipse") {
            HStack(spacing: Theme.Spacing.row) {
                LabelledField(
                    name: "Radius (m)",
                    text: self.$viewModel.radiusText,
                    isEditing: self.$isEditing
                )
                LabelledField(
                    name: "Dwell (min)",
                    text: self.$viewModel.dwellMinutesText,
                    placeholder: "off",
                    isEditing: self.$isEditing
                )
            }

            Button {
                self.isEditing = false
                Task { await self.viewModel.addFenceHere() }
            } label: {
                Label("Arm at current location", systemImage: "plus.circle")
                    .actionLabel()
            }
            .buttonStyle(.borderedProminent)
            .disabled(self.viewModel.isWorking)

            if let message = self.viewModel.lastMessage {
                ExplanationBox(text: message, tint: Theme.Status.idle)
            }

            Text("""
                A fence needs ready() and location authorization — not a session. Arm one, stop \
                tracking, close the app: it still fires. Below ~100 m regions fire unreliably, and \
                iOS allows 20 per app with one reserved for the SDK's own stationary fence.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Armed

    private var fencesCard: some View {
        DiagnosticCard(title: "Armed", systemImage: "circle.dashed") {
            if self.viewModel.fences.isEmpty {
                Text("Nothing armed. Read back from CoreLocation, not from a list of our own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(self.viewModel.fences) { fence in
                    VStack(spacing: Theme.Spacing.hair) {
                        FactRow(
                            name: fence.id,
                            value: "\(Int(fence.radiusM)) m"
                        )
                        FactRow(
                            name: String(
                                format: "%.5f, %.5f",
                                fence.latitude,
                                fence.longitude
                            ),
                            value: Self.dwellDescription(fence),
                            tint: fence.dwellAfterMs == nil ? .secondary : Theme.Status.good
                        )

                        Button(role: .destructive) {
                            Task { await self.viewModel.remove(fence) }
                        } label: {
                            Label("Remove", systemImage: "trash")
                                .actionLabel()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.bottom, Theme.Spacing.tight)

                    Divider()
                }

                Button(role: .destructive) {
                    Task { await self.viewModel.removeAll() }
                } label: {
                    Label("Remove all", systemImage: "trash.slash")
                        .actionLabel()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Live

    private var liveCard: some View {
        DiagnosticCard(title: "Live feed", systemImage: "dot.radiowaves.left.and.right") {
            if self.viewModel.live.isEmpty {
                Text("Crossings seen while this app was running. Empty is normal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(self.viewModel.live, id: \.self) { line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - History

    private var historyCard: some View {
        DiagnosticCard(title: "History", systemImage: "clock.arrow.circlepath") {
            Text("""
                Read from storage. A crossing delivered to a relaunched app is written before any \
                host is subscribed, so this is the only place it can be seen — if this list has \
                rows the live feed never showed, that is the SDK working as intended.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if self.viewModel.history.isEmpty {
                Text("No crossings recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(self.viewModel.history) { crossing in
                    FactRow(
                        name: "\(Self.stamp(crossing.timeMs))  \(crossing.geofenceID)",
                        value: crossing.transition.rawValue.uppercased(),
                        tint: Self.tint(for: crossing.transition)
                    )
                }

                Button(role: .destructive) {
                    Task { await self.viewModel.clearHistory() }
                } label: {
                    Label("Clear history", systemImage: "trash")
                        .actionLabel()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Formatting

    private static func dwellDescription(_ fence: Geofence) -> String {
        guard let dwellAfterMs = fence.dwellAfterMs else { return "no dwell" }
        return "dwell \(dwellAfterMs / 60_000) min"
    }

    private static func stamp(_ timeMs: Int64) -> String {
        GeofenceViewModel.time.string(from: Date(timeIntervalSince1970: Double(timeMs) / 1000))
    }

    private static func tint(for transition: GeofenceTransition) -> Color {
        switch transition {
        case .enter: Theme.Status.good
        case .exit: Theme.Status.warn
        // The one iOS does not have. Coloured distinctly because "did the dwell fire, and when"
        // is the question this screen exists to answer.
        case .dwell: Theme.Layer.filter
        @unknown default: Theme.Status.idle
        }
    }
}

// MARK: - LabelledField

/// A named numeric field. Small enough to live here rather than in the shared theme, which holds
/// the components more than one screen uses.
private struct LabelledField: View {

    let name: String
    @Binding var text: String
    var placeholder: String = ""
    @FocusState.Binding var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
            Text(self.name)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(self.placeholder, text: self.$text)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused(self.$isEditing)
        }
    }
}
