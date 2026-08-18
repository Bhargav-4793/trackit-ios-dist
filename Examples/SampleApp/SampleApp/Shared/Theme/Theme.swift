import SwiftUI
import TrackerGeo

/// The sample's visual vocabulary, in one place.
///
/// The colours here are **diagnostic**, not decorative. The three layer colours are quoted verbatim
/// from `docs/app/61-diagnostics.md` — grey raw, blue filter, green stored — and the whole
/// three-layer overlay is unreadable if any tab picks its own. Same for the verdict colours: a
/// reviewer looking at the decision log and the map side by side has to be able to match them by
/// eye, and that only works while one file owns them.
enum Theme {

    // MARK: - Diagnostic layers

    /// The three-layer overlay. `docs/app/61-diagnostics.md` — "which layer did the artefact first
    /// appear in" is the highest-value question in the system, and it is answered by colour.
    enum Layer {

        /// Layer 1 — raw fixes, exactly as CoreLocation delivered them.
        static let raw = Color(white: 0.42)

        /// Layer 2 — what the filter believed, recorded on every decision.
        static let filter = Color(red: 0.13, green: 0.44, blue: 0.94)

        /// Layer 3 — what was actually stored.
        static let stored = Color(red: 0.05, green: 0.64, blue: 0.36)
    }

    // MARK: - Verdicts

    /// Green / amber / red, per `docs/app/60-sample-app.md`. Amber rather than grey for `.skip`,
    /// because a skip is a fix the filter consumed and chose not to store — a fact worth seeing,
    /// not an absence.
    enum VerdictTint {

        static let accept = Color(red: 0.05, green: 0.60, blue: 0.33)
        static let skip = Color(red: 0.83, green: 0.60, blue: 0.03)
        static let reject = Color(red: 0.82, green: 0.16, blue: 0.16)

        static func color(for verdict: Verdict) -> Color {
            switch verdict {
            case .accept: Self.accept
            case .skip: Self.skip
            case .reject: Self.reject
            @unknown default: Self.reject
            }
        }

        static func label(for verdict: Verdict) -> String {
            switch verdict {
            case .accept: "ACCEPT"
            case .skip: "SKIP"
            case .reject: "REJECT"
            // Printed rather than folded into "REJECT": on a debug screen an
            // unrecognised verdict is the thing you most want to see named.
            @unknown default: "UNKNOWN"
            }
        }
    }

    // MARK: - Status

    /// Health, for a status card. Deliberately four values and not a `Bool`: "not yet known" and
    /// "known to be off" read identically in a two-state design, and on the permission ladder that
    /// difference is the whole screen.
    enum Status {

        static let good = Color(red: 0.05, green: 0.60, blue: 0.33)
        static let warn = Color(red: 0.83, green: 0.60, blue: 0.03)
        static let bad = Color(red: 0.82, green: 0.16, blue: 0.16)
        static let idle = Color.secondary
    }

    // MARK: - Metrics

    enum Spacing {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 6
        static let row: CGFloat = 10
        static let card: CGFloat = 14
        static let section: CGFloat = 18
        static let screen: CGFloat = 16
    }

    enum Radius {
        static let card: CGFloat = 12
        static let pill: CGFloat = 6
    }

    // MARK: - Type

    /// Everything that carries a number a field tester will read aloud over the phone is
    /// monospaced. Proportional digits in a capture log make two aligned columns look ragged and
    /// two ragged ones look aligned.
    enum Typography {
        static let cardTitle = Font.subheadline.weight(.semibold)
        static let factName = Font.caption
        static let factValue = Font.system(.caption, design: .monospaced).weight(.medium)
        static let log = Font.system(size: 10.5, design: .monospaced)
        static let pill = Font.system(size: 10, design: .monospaced).weight(.semibold)

        /// How far a button label may shrink before `ActionRow` stacks the row instead.
        ///
        /// Not a design flourish: SwiftUI hyphenates a label that will not fit, so without a
        /// floor to shrink toward, "Dump session" becomes "Dump ses-sion" across three lines.
        /// Held above 0.8 because a label small enough to fit anywhere is a label nobody reads.
        static let minimumButtonScale: CGFloat = 0.85
    }
}
