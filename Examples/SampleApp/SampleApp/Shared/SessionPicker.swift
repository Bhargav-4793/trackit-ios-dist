import SwiftUI
import TrackerCore

/// The session selector, shared by Home, Track, Debug and Decisions.
///
/// **One view, deliberately.** `docs/app/60-sample-app.md`: three copies "would drift in exactly the
/// way `Arrows.place()` exists to prevent". The drift is not cosmetic — it is a tab labelling a
/// session `a1b2c3d4` while another labels the same row by its start time, at which point two
/// screens that disagree look like a data bug rather than a formatting one.
///
/// `nil` means *the live session*, not "nothing selected". `TrackingViewModel` resolves the
/// selection as `selectedSessionID ?? currentSession()?.id`, so leaving this alone follows the run
/// that is happening now and picking a row pins every tab to the same past run.
struct SessionPicker: View {

    let sessions: [TrackSession]

    @Binding var selection: String?

    /// What the view model actually resolved the selection to, when it is known.
    ///
    /// Shown as the first eight characters underneath the picker. While `selection` is `nil` the
    /// picker reads "Live session", which is true and useless — the id is what a field tester
    /// quotes in a report and what the capture log's `sessionDump` block is keyed by.
    var resolvedSessionID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Picker("Session", selection: self.$selection) {
                Text("Live session").tag(String?.none)

                ForEach(self.sessions) { session in
                    Text(Self.label(for: session)).tag(String?.some(session.id))
                }
            }
            .pickerStyle(.menu)
            .disabled(self.sessions.isEmpty && self.selection == nil)

            HStack(spacing: Theme.Spacing.tight) {
                if let resolved = self.resolvedSessionID {
                    Text("id \(Self.shortID(resolved))")
                        .font(Theme.Typography.factValue)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("no session yet")
                        .font(Theme.Typography.factValue)
                        .foregroundStyle(.secondary)
                }

                if self.sessions.isEmpty {
                    Pill(text: "0 RECORDED", tint: Theme.Status.idle)
                } else {
                    Pill(text: "\(self.sessions.count) RECORDED", tint: Theme.Status.idle)
                }
            }
        }
    }

    // MARK: - Formatting

    /// The first eight characters of the UUID, which is what every other surface prints.
    ///
    /// `prefix` rather than a substring range: a session id is a UUID string today and a shorter
    /// identifier would crash a range-based version on the one build where it changed.
    static func shortID(_ id: String) -> String {
        String(id.prefix(8))
    }

    /// `21:34 · 10 Aug · commute · 8m` — start time first, because a field tester scans for the run
    /// they just did.
    private static func label(for session: TrackSession) -> String {
        let started = Date(timeIntervalSince1970: Double(session.startedAtMs) / 1000)

        var parts = [
            started.formatted(date: .omitted, time: .shortened),
            started.formatted(.dateTime.day().month(.abbreviated))
        ]

        if let tag = session.tag, !tag.isEmpty {
            parts.append(tag)
        }

        if session.isOpen {
            parts.append("open")
        } else if let endedAtMs = session.endedAtMs {
            parts.append(Self.duration(msFrom: session.startedAtMs, to: endedAtMs))
        }

        parts.append(Self.shortID(session.id))
        return parts.joined(separator: " · ")
    }

    private static func duration(msFrom startMs: Int64, to endMs: Int64) -> String {
        let seconds = max(0, (endMs - startMs) / 1000)
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        return "\(minutes / 60)h\(minutes % 60)m"
    }
}
