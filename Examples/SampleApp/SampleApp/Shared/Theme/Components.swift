import SwiftUI
import UIKit

// MARK: - DiagnosticCard

/// The one card every tab uses.
///
/// Shared for the same reason `SessionPicker` is: four tabs each drawing their own grouped box is
/// four sets of padding that drift apart, and a diagnostic screen where the Debug tab's counts sit
/// a few points off the Decisions tab's counts is a screen people stop trusting.
struct DiagnosticCard<Content: View>: View {

    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            Label(self.title, systemImage: self.systemImage)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(.secondary)

            self.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.card)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }
}

// MARK: - FactRow

/// One name/value pair from a status card.
///
/// The value is monospaced and trailing-aligned so a column of them can be read down rather than
/// across, and `tint` carries health — a tier of `none` and a tier of `always` must not be the same
/// colour on a screen whose job is to answer "why is nothing being recorded".
struct FactRow: View {

    let name: String
    let value: String
    var tint: Color = .primary

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Name above value at accessibility sizes, beside it otherwise.
        //
        // Two columns of large text in a phone's width is not a layout, it is two columns of
        // hyphens: "Authoriza-tion" against "RECORD-ING", with a session id broken across lines
        // mid-token. Stacking gives each the full width, which is what the value needs — an id or
        // a coordinate read in halves is worse than one that wraps cleanly.
        if self.typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
                self.nameText
                self.valueText
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.row) {
                self.nameText

                Spacer(minLength: Theme.Spacing.tight)

                self.valueText
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var nameText: some View {
        Text(self.name)
            .font(Theme.Typography.factName)
            .foregroundStyle(.secondary)
    }

    /// Shrinks a little before it wraps, and never hyphenates: these values are ids, statuses and
    /// coordinates, and a hyphen inside one reads as part of the value.
    private var valueText: some View {
        Text(self.value)
            .font(Theme.Typography.factValue)
            .foregroundStyle(self.tint)
            .minimumScaleFactor(Theme.Typography.minimumButtonScale)
            .textSelection(.enabled)
    }
}

// MARK: - Pill

/// A small tinted label — a count, a verdict, a state.
struct Pill: View {

    let text: String
    let tint: Color

    var body: some View {
        Text(self.text)
            .font(Theme.Typography.pill)
            .foregroundStyle(self.tint)
            .padding(.horizontal, Theme.Spacing.tight)
            .padding(.vertical, Theme.Spacing.hair + 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                    .fill(self.tint.opacity(0.14))
            )
            .accessibilityLabel(self.text)
    }
}

// MARK: - ExplanationBox

/// A block of prose attached to a control that cannot do anything useful yet.
///
/// `docs/app/60-sample-app.md`: handle `.needsSettings` "with an explanation rather than a bare
/// link". A link on its own tells a user where to go and nothing about what to do when they arrive,
/// and the Always rung is exactly the case where the user has one chance to get it right.
struct ExplanationBox: View {

    let text: String
    var tint: Color = Theme.Status.warn

    var body: some View {
        Text(self.text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.row)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                    .fill(self.tint.opacity(0.10))
            )
    }
}

// MARK: - ShareSheet

/// `UIActivityViewController`, for the cases `ShareLink` cannot cover — sharing a string that has
/// no file behind it, such as an exported fixture.
///
/// The capture log itself is file-backed and goes out through `ShareLink`; this exists so that the
/// diagnostic tabs have a way to get a payload off the device that does not involve a debugger,
/// which is the whole point of the instrument.
struct ShareSheet: UIViewControllerRepresentable {

    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: self.items, applicationActivities: nil)
    }

    func updateUIViewController(
        _ controller: UIActivityViewController,
        context: Context
    ) {
        // Nothing to update: the item set is fixed for the lifetime of the presentation.
    }
}

// MARK: - ActionRow

/// A row of buttons that becomes a column when the labels no longer fit beside each other.
///
/// Three bordered buttons across a phone is comfortable for "Share" and impossible for "Dump
/// session": SwiftUI hyphenates before it truncates, so the row degraded into "Dump ses-sion"
/// stacked three lines high beside "Fix-ture" — legible, technically, and unreadable in practice.
///
/// Switched on `dynamicTypeSize` rather than measured with `ViewThatFits`, which cannot help
/// here: every button in these rows is `maxWidth: .infinity`, so its ideal width is tiny and the
/// horizontal candidate always claims to fit. The type size is the thing that actually decides.
struct ActionRow<Content: View>: View {

    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder let content: Content

    var body: some View {
        if self.typeSize.isAccessibilitySize {
            VStack(spacing: Theme.Spacing.row) {
                self.content
            }
        } else {
            HStack(spacing: Theme.Spacing.row) {
                self.content
            }
        }
    }
}

// MARK: - Action labels

extension View {

    /// The label rule for a button that shares its row.
    ///
    /// One line, shrinking a little rather than wrapping — a hyphen inside a two-word button is
    /// never the right answer, and truncation would hide which button this is. Below the scale
    /// floor `ActionRow` has already gone vertical and there is room again.
    func actionLabel() -> some View {
        self.lineLimit(1)
            .minimumScaleFactor(Theme.Typography.minimumButtonScale)
            .frame(maxWidth: .infinity)
    }
}
