import Observation
import SwiftUI
import TrackerCore

// MARK: - RungState

/// What one rung of the ladder can be in.
///
/// Five states rather than a `Bool`, because "not asked yet", "cannot be asked yet", "asked and
/// refused" and "asked and iOS will never ask again" need four different sentences on screen and
/// three different buttons. A ladder that renders them all as a greyed-out row is the reason hosts
/// ship apps that silently never get background tracking.
enum RungState: Equatable {

    /// A predecessor is unsatisfied. Carries what to do about it.
    case blocked(String)

    /// Askable now.
    case ready

    case satisfied(String)

    /// Answered, unfavourably, but still askable or recoverable in-app.
    case refused(String)

    /// iOS will not prompt again. Only Settings can move this, and the user needs telling what to
    /// tap when they get there.
    case needsSettings(String)

    var isSatisfied: Bool {
        if case .satisfied = self {
            return true
        }
        return false
    }

    var tint: Color {
        switch self {
        case .blocked: Theme.Status.idle
        case .ready: Theme.Status.warn
        case .satisfied: Theme.Status.good
        case .refused: Theme.Status.bad
        case .needsSettings: Theme.Status.bad
        }
    }

    var symbol: String {
        switch self {
        case .blocked: "lock.fill"
        case .ready: "circle"
        case .satisfied: "checkmark.circle.fill"
        case .refused: "exclamationmark.triangle.fill"
        case .needsSettings: "gearshape.fill"
        }
    }

    var detail: String? {
        switch self {
        case .blocked(let text), .satisfied(let text), .refused(let text), .needsSettings(let text):
            text
        case .ready:
            nil
        }
    }
}

// MARK: - PermissionLadderModel

/// The ladder's own state, kept out of the view so the ordering rules are readable in one place.
///
/// **The order is the entire content of this file.** When-In-Use, then the host's own rationale,
/// then Always, then motion. iOS shows the Always escalation *at most once* and only *from*
/// When-In-Use, so a host that asks out of order — or asks for both in the same breath — loses
/// background tracking for that install permanently and has no way to recover it except by
/// convincing the user to visit Settings (EC-04).
@MainActor
@Observable
final class PermissionLadderModel {

    // MARK: Observed

    private(set) var tier: AuthorizationTier = .none
    private(set) var accuracy: LocationAccuracy = .reduced
    private(set) var motion: MotionAuthorization = .notDetermined

    /// The host owns the prompt counters, because the host owns the prompts —
    /// `PermissionManager.shouldStopAsking(attempts:)` takes them as a parameter for exactly that
    /// reason. iOS silently no-ops a repeated request once the user has answered, so a button that
    /// keeps calling `requestAlways()` looks broken rather than persistent (EC-14).
    private(set) var whenInUseAttempts = 0
    private(set) var alwaysAttempts = 0

    private(set) var alwaysResult: AlwaysResult?

    /// Rung 2. Set by the sheet's own Continue button and never by the sheet being dismissed: a
    /// swipe-down is not a rationale the user read.
    private(set) var hasShownRationale = false

    var isRationalePresented = false

    /// In flight, so the buttons can be disabled rather than re-entered. Two `requestAlways()`
    /// calls in flight is two continuations against one delegate callback, and the second one is
    /// answered with an unchanged status.
    private(set) var isRequesting = false

    // MARK: Dependencies

    private let permissions: PermissionManager

    init(permissions: PermissionManager) {
        self.permissions = permissions
        self.refresh()
    }

    // MARK: - Reads

    /// Re-read every rung from CoreLocation.
    ///
    /// Called after every request and whenever Home reappears, because all three answers move
    /// underneath a running app: the user can revoke location in Settings, downgrade Always to
    /// When-In-Use days after a provisional grant (EC-200), or switch off Precise Location without
    /// touching the tier at all.
    func refresh() {
        self.tier = self.permissions.tier()
        self.accuracy = self.permissions.accuracy()
        self.motion = self.permissions.motionAuthorization()
    }

    var settingsURL: URL {
        self.permissions.settingsURL
    }

    // MARK: - The rungs

    /// Step 1. **Always first.**
    func requestWhenInUse() async {
        guard !self.isRequesting else { return }
        self.isRequesting = true
        defer { self.isRequesting = false }

        self.whenInUseAttempts += 1
        self.tier = await self.permissions.requestWhenInUse()
        self.refresh()
    }

    /// Step 2. The host's own words, shown before the escalation and never instead of it.
    func acknowledgeRationale() {
        self.hasShownRationale = true
        self.isRationalePresented = false
    }

    /// Step 3. Only from `.whenInUse`, and only after the rationale.
    func requestAlways() async {
        guard !self.isRequesting else { return }
        self.isRequesting = true
        defer { self.isRequesting = false }

        self.alwaysAttempts += 1
        switch await self.permissions.requestAlways() {
        case .alreadyGranted, .granted:
            self.alwaysResult = .granted
        case .denied:
            self.alwaysResult = .denied
        case .needsWhenInUseFirst:
            self.alwaysResult = .needsWhenInUseFirst
        case .needsSettings(let url):
            self.alwaysResult = .needsSettings(url)
        @unknown default:
            self.alwaysResult = .denied
        }
        self.refresh()
    }

    /// Step 4. Optional, and last. Denial costs one background wake path and the activity labels;
    /// it costs nothing in the capture plane, which is why it is not allowed to block the screen.
    func requestMotion() async {
        guard !self.isRequesting else { return }
        self.isRequesting = true
        defer { self.isRequesting = false }

        self.motion = await self.permissions.requestMotion()
        self.refresh()
    }

    /// Whether the UI should offer Settings instead of another prompt.
    func shouldStopAsking(attempts: Int) -> Bool {
        self.permissions.shouldStopAsking(attempts: attempts)
    }

    // MARK: - Derived states

    var whenInUseState: RungState {
        switch self.tier {
        case .always:
            return .satisfied("Always — the strongest rung, granted")
        case .whenInUse:
            return .satisfied("When-In-Use granted")
        case .none:
            guard self.whenInUseAttempts > 0 else { return .ready }
            // The tier collapses `.denied` and `.restricted` into `.none`, so an attempt that came
            // back `.none` means the user answered no — iOS will not raise this prompt again.
            return .needsSettings(Self.locationDeniedExplanation)
        @unknown default:
            return .needsSettings(Self.locationDeniedExplanation)
        }
    }

    var rationaleState: RungState {
        guard self.tier != .none else {
            return .blocked("Grant When-In-Use first — the Always prompt can only be raised from it")
        }
        if self.hasShownRationale {
            return .satisfied("Rationale shown")
        }
        if self.tier == .always {
            return .satisfied("Already on Always; no escalation to explain")
        }
        return .ready
    }

    var alwaysState: RungState {
        if self.tier == .always {
            return .satisfied("Background tracking is authorized")
        }

        guard self.tier == .whenInUse else {
            return .blocked("Rung 1 first. Asking for Always from a not-determined state is how an app loses background tracking permanently")
        }

        guard self.hasShownRationale else {
            return .blocked("Show the rationale first. iOS raises this prompt once, and a user who has not been told what it is for taps Keep Only While Using")
        }

        switch self.alwaysResult {
        case .none:
            return .ready
        case .granted:
            // Reachable if the grant was provisional and has since been confirmed down. The tier is
            // the truth, not the result we recorded.
            return .refused(Self.alwaysDowngradedExplanation)
        case .denied:
            return .needsSettings(Self.alwaysDeniedExplanation)
        case .needsWhenInUseFirst:
            return .refused("The SDK refused to ask: the app is not on When-In-Use. Climb rung 1 and try again")
        case .needsSettings:
            return .needsSettings(Self.alwaysKeptWhileUsingExplanation)
        }
    }

    var motionState: RungState {
        guard self.tier != .none else {
            return .blocked("Location first — motion is the optional rung and asking for it during the location prompts stacks two system alerts")
        }
        guard self.tier == .always || self.alwaysResult != nil else {
            return .blocked("Answer the Always prompt first, so the two system alerts do not overlap")
        }

        switch self.motion {
        case .authorized:
            return .satisfied("Activity recognition and the pedometer are available")
        case .notDetermined:
            return .ready
        case .denied:
            return .refused(Self.motionDeniedExplanation)
        case .restricted:
            return .refused("Motion is unavailable on this device. Tracking is unaffected; the pedometer corroboration in stage 2a is simply skipped")
        @unknown default:
            return .refused("Motion authorization reported a state this build does not recognise. Tracking is unaffected; stage 2a corroboration is skipped")
        }
    }

    /// The orthogonal axis. Not a rung — the user sets it independently of the tier, and it can be
    /// off while Always is on.
    var accuracyState: RungState {
        switch self.accuracy {
        case .full:
            return .satisfied("Precise Location is on")
        case .reduced:
            return .needsSettings(Self.reducedAccuracyExplanation)
        @unknown default:
            return .needsSettings(Self.reducedAccuracyExplanation)
        }
    }

    // MARK: - Copy

    /// The explanations. Long on purpose: `docs/app/60-sample-app.md` asks for `.needsSettings` to
    /// be handled "with an explanation rather than a bare link", and a user sent to Settings without
    /// being told which of the four options to pick comes back having picked the wrong one.
    private static let locationDeniedExplanation = """
        Location is denied or restricted for this app, and iOS will not show the prompt again. \
        Open Settings, choose Location, and pick "While Using the App" — that is rung 1, and the \
        Always option only becomes reachable afterwards.
        """

    private static let alwaysDeniedExplanation = """
        The Always prompt was answered "Keep Only While Using", and iOS shows it once. Tracking \
        still works while the app is on screen — the SDK degrades rather than refusing — but every \
        background leg will be missing. Open Settings, choose Location, and pick "Always".
        """

    private static let alwaysKeptWhileUsingExplanation = """
        iOS will not raise the Always prompt again on this install. Open Settings, choose Location, \
        and pick "Always". If the list shows "While Using the App" with a checkmark, that is the \
        rung the app is on and tapping "Always" is the whole change.
        """

    private static let alwaysDowngradedExplanation = """
        Always was granted and has since been downgraded — iOS confirms a provisional grant with \
        the user days later, and this is what declining that confirmation looks like. Open Settings \
        and choose "Always" to restore background legs.
        """

    private static let motionDeniedExplanation = """
        Motion & Fitness is denied. Location capture, filtering and plotting are untouched; what is \
        lost is one of the three background wake paths and the activity labels on the timeline. \
        Settings, then Motion & Fitness, if you want it back.
        """

    private static let reducedAccuracyExplanation = """
        Precise Location is off, which gives a 1–3 km error circle. That defeats every gate in the \
        acceptance pipeline, so start() refuses continuous and adaptive tracking under it. Open \
        Settings, choose Location, and turn on Precise Location.
        """
}

// MARK: - AlwaysResult

/// `BackgroundRequest`, minus the associated `URL` on the cases that do not need it.
///
/// A stored copy rather than the SDK enum itself because `BackgroundRequest` is not `Equatable` —
/// it carries a `URL` — and `@Observable` change tracking on a non-equatable value republishes on
/// every assignment.
enum AlwaysResult: Equatable {
    case granted
    case denied
    case needsWhenInUseFirst
    case needsSettings(URL)
}

// MARK: - PermissionLadderView

/// The four rungs, in order, each disabled until its predecessor is satisfied.
///
/// **This is the part hosts copy.** It is one file, it depends on nothing but
/// `Tracker.shared.permissions()`, and every disabled control says why it is disabled — a rung that
/// simply greys out teaches the reader nothing about the ordering rule that greyed it.
struct PermissionLadderView: View {

    @State private var model: PermissionLadderModel

    /// Fired after every answer so the status card re-reads the tier. The ladder does not know what
    /// else on the screen depends on authorization, and should not.
    private let onChange: @MainActor () async -> Void

    /// `@MainActor` because `PermissionManager` is, and because the model it builds reads
    /// `CLLocationManager` in its own initialiser. Every call site is a `body`, which is already
    /// there.
    @MainActor
    init(
        permissions: PermissionManager,
        onChange: @escaping @MainActor () async -> Void
    ) {
        self._model = State(initialValue: PermissionLadderModel(permissions: permissions))
        self.onChange = onChange
    }

    var body: some View {
        DiagnosticCard(title: "Permission ladder", systemImage: "figure.stairs") {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                self.rung(
                    number: 1,
                    title: "When-In-Use",
                    state: self.model.whenInUseState,
                    actionTitle: "Request When-In-Use"
                ) {
                    await self.model.requestWhenInUse()
                    await self.onChange()
                }

                self.rung(
                    number: 2,
                    title: "Background rationale",
                    state: self.model.rationaleState,
                    actionTitle: "Why background access?"
                ) {
                    self.model.isRationalePresented = true
                }

                self.rung(
                    number: 3,
                    title: "Always",
                    state: self.model.alwaysState,
                    actionTitle: "Request Always"
                ) {
                    await self.model.requestAlways()
                    await self.onChange()
                }

                self.rung(
                    number: 4,
                    title: "Motion & Fitness",
                    state: self.model.motionState,
                    actionTitle: "Request Motion"
                ) {
                    await self.model.requestMotion()
                    await self.onChange()
                }

                Divider()

                self.accuracyRow
            }
        }
        .sheet(isPresented: self.$model.isRationalePresented) {
            BackgroundRationaleSheet {
                self.model.acknowledgeRationale()
            }
        }
        .task {
            // Every answer can move while the app is backgrounded — Settings is one swipe away from
            // this screen — so the ladder re-reads on appearance rather than trusting what it last
            // recorded.
            self.model.refresh()
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rung(
        number: Int,
        title: String,
        state: RungState,
        actionTitle: String,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            HStack(spacing: Theme.Spacing.row) {
                Image(systemName: state.symbol)
                    .foregroundStyle(state.tint)
                    .frame(width: 18)

                Text("\(number). \(title)")
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(state.isSatisfied ? .secondary : .primary)

                Spacer(minLength: 0)
            }

            if let detail = state.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch state {
            case .ready, .refused:
                Button(actionTitle) {
                    Task { await action() }
                }
                .buttonStyle(.bordered)
                .disabled(self.model.isRequesting)

            case .needsSettings:
                Link("Open Settings", destination: self.model.settingsURL)
                    .buttonStyle(.bordered)

            case .blocked, .satisfied:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Precise Location, which is not a rung: the user sets it independently of the tier, so it
    /// gates nothing below it and nothing below it gates it.
    private var accuracyRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            HStack(spacing: Theme.Spacing.row) {
                Image(systemName: self.model.accuracyState.symbol)
                    .foregroundStyle(self.model.accuracyState.tint)
                    .frame(width: 18)

                Text("Precise Location")
                    .font(Theme.Typography.cardTitle)

                Spacer(minLength: 0)

                Pill(
                    text: self.model.accuracy.rawValue.uppercased(),
                    tint: self.model.accuracyState.tint
                )
            }

            if let detail = self.model.accuracyState.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .needsSettings = self.model.accuracyState {
                Link("Open Settings", destination: self.model.settingsURL)
                    .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - BackgroundRationaleSheet

/// Rung 2, in the host's own words.
///
/// The SDK shows no UI on purpose: a location prompt is product copy, and the sentence that decides
/// whether a user taps "Change to Always" belongs to the app, not to a library. This is that
/// sentence, written for a sample whose users are field testers — a shipping app would say the same
/// thing in its own voice.
struct BackgroundRationaleSheet: View {

    let onContinue: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    Text("iOS is about to ask once")
                        .font(.title3.weight(.semibold))

                    Text("""
                        The next system alert is the only one you will see. It offers "Keep Only \
                        While Using" and "Change to Always", and iOS will not raise it a second \
                        time on this install.
                        """)

                    Text("""
                        Tracker records a route as a continuous line. With "While Using", capture \
                        stops the moment the app leaves the screen — the SDK degrades rather than \
                        refusing, so foreground legs are still recorded, but a drive with the phone \
                        in a pocket produces a straight line between where you locked the screen \
                        and where you unlocked it.
                        """)

                    Text("""
                        With "Always", iOS relaunches the app in the background when you move, and \
                        the whole trip is captured. Battery cost is bounded by the adaptive cadence \
                        — the SDK samples rarely while you are stationary and quickly through turns.
                        """)

                    Text("You can change this later in Settings, but only in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.screen)
            }
            .navigationTitle("Background access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") {
                        self.dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        self.onContinue()
                    }
                }
            }
        }
    }
}
