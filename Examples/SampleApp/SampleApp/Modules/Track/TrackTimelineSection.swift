import SwiftUI
import TrackerCore
import TrackerGeo

// MARK: - TrackTimelineSection

/// §24 — cluster-based expandable timeline derived from Track.segments.
/// Each cluster = startStop (arrival) + optional travel middleNode + endStop (departure/next arrival).
struct TrackTimelineSection: View {

    let plot: TrackPlot

    /// Which travel-segment indices are expanded (by their position in segments array).
    @State private var expanded: Set<Int> = []

    var body: some View {
        let clusters = Self.buildClusters(track: self.plot.track)
        if clusters.isEmpty { return AnyView(EmptyView()) }
        return AnyView(
            DiagnosticCard(
                title: "Timeline",
                systemImage: "timeline.selection.left.and.line.vertical.and.line.horizontal.right"
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(clusters.enumerated()), id: \.offset) { idx, cluster in
                        ClusterView(
                            cluster: cluster,
                            timezone: self.plot.track.timezone,
                            isExpanded: cluster.travel.map { self.expanded.contains($0.segIndex) } ?? false
                        ) {
                            if let t = cluster.travel {
                                if self.expanded.contains(t.segIndex) {
                                    self.expanded.remove(t.segIndex)
                                } else {
                                    self.expanded.insert(t.segIndex)
                                }
                            }
                        }
                        if idx < clusters.count - 1 {
                            TimelineConnector()
                        }
                    }
                }
            }
        )
    }

    // MARK: Cluster model

    struct TravelInfo {
        let segIndex: Int        // index in track.segments array
        let segment: TrackSegment
    }

    struct Cluster {
        let startStop: StopNode?
        let travel: TravelInfo?
        let endStop: StopNode?
        /// §19 phantom-leg: travelStartMs > 0 means a signal blackout during drive.
        var hasPhantomLeg: Bool { (travel?.segment.travelStartMs ?? 0) > 0 }
    }

    /// Build clusters from the segments array.
    /// Segments alternate: travel?, [stop, travel]*, stop?
    /// Each cluster covers one "leg": the travel between two stops.
    static func buildClusters(track: Track) -> [Cluster] {
        var clusters: [Cluster] = []
        var pendingStop: StopNode? = nil
        var seenFirstStop = false

        for (idx, seg) in track.segments.enumerated() {
            switch seg.type {
            case .stop:
                guard let stopIdx = seg.stopIndex, stopIdx < track.stops.count else { continue }
                let stop = track.stops[stopIdx]
                if !seenFirstStop {
                    seenFirstStop = true
                    pendingStop = stop
                } else {
                    // close previous pending
                    pendingStop = stop
                }
            case .travel:
                let travel = TravelInfo(segIndex: idx, segment: seg)
                let cluster = Cluster(startStop: pendingStop, travel: travel, endStop: nil)
                clusters.append(cluster)
                pendingStop = nil
            @unknown default: break
                
            }
        }

        // If there's a trailing stop with no following travel
        if let stop = pendingStop {
            clusters.append(Cluster(startStop: stop, travel: nil, endStop: nil))
        }

        // Fill endStop: the endStop of cluster N is the startStop of cluster N+1
        var result: [Cluster] = []
        for i in 0 ..< clusters.count {
            var c = clusters[i]
            if i + 1 < clusters.count {
                let nextStart = clusters[i + 1].startStop
                c = Cluster(startStop: c.startStop, travel: c.travel, endStop: nextStart)
            }
            result.append(c)
        }
        return result
    }
}

// MARK: - ClusterView

private struct ClusterView: View {

    let cluster: TrackTimelineSection.Cluster
    let timezone: String
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Start node (arrival at stop)
            if let stop = self.cluster.startStop {
                StopTimelineRow(stop: stop, timezone: self.timezone, role: .arrival)
            }

            if let travel = self.cluster.travel {
                if self.isExpanded {
                    // Expanded: full travel details
                    ExpandedTravelRow(
                        travel: travel,
                        timezone: self.timezone,
                        onCollapse: self.onToggle
                    )
                } else {
                    // Collapsed: summary pill
                    CollapsedTravelRow(travel: travel, onExpand: self.onToggle)
                }

                // §24 phantom-leg: if travelStartMs > 0, show drive/dwell split
                if self.cluster.hasPhantomLeg, let t = self.cluster.travel {
                    PhantomLegNote(segment: t.segment, timezone: self.timezone)
                }
            }

            // End node (arrival at next stop = departure from current)
            if let stop = self.cluster.endStop {
                StopTimelineRow(stop: stop, timezone: self.timezone, role: .departure)
            }
        }
    }
}

// MARK: - CollapsedTravelRow

private struct CollapsedTravelRow: View {
    let travel: TrackTimelineSection.TravelInfo
    let onExpand: () -> Void

    var body: some View {
        Button(action: self.onExpand) {
            HStack(spacing: 10) {
                // Left connector dot
                Circle()
                    .fill(self.bandColor.opacity(0.25))
                    .frame(width: 24, height: 24)
                    .overlay(Text(self.icon).font(.system(size: 12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(self.travel.segment.activity ?? "Travel")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    HStack(spacing: 12) {
                        if self.travel.segment.distanceMeters > 0 {
                            Text(self.distanceText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if self.travel.segment.durationSec > 0 {
                            Text(formatDuration(self.travel.segment.durationSec))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private var icon: String { activityIcon(self.travel.segment) }
    private var bandColor: Color { speedBandColor(self.travel.segment.speedBand) }
    private var distanceText: String { formatDistance(self.travel.segment.distanceMeters) }
}

// MARK: - ExpandedTravelRow

private struct ExpandedTravelRow: View {
    let travel: TrackTimelineSection.TravelInfo
    let timezone: String
    let onCollapse: () -> Void

    var body: some View {
        let seg = self.travel.segment
        VStack(alignment: .leading, spacing: 6) {
            Button(action: self.onCollapse) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(speedBandColor(seg.speedBand).opacity(0.25))
                        .frame(width: 24, height: 24)
                        .overlay(Text(activityIcon(seg)).font(.system(size: 12)))

                    Text(seg.activity ?? "Travel")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: "chevron.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            // Detail grid
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                alignment: .leading,
                spacing: 8
            ) {
                if seg.distanceMeters > 0 {
                    TravelStat(label: "Distance", value: formatDistance(seg.distanceMeters))
                }
                if seg.durationSec > 0 {
                    TravelStat(label: "Duration", value: formatDuration(seg.durationSec))
                }
                if seg.avgSpeedMps > 0 {
                    TravelStat(label: "Avg speed", value: formatSpeed(seg.avgSpeedMps))
                }
                if seg.maxSpeedMps > 0 {
                    TravelStat(label: "Max speed", value: formatSpeed(seg.maxSpeedMps))
                }
                if seg.p75SpeedMps > 0 {
                    TravelStat(label: "p75 speed", value: formatSpeed(seg.p75SpeedMps))
                }
                if seg.startMs > 0, seg.endMs > 0 {
                    TravelStat(label: "Time", value: timeRange(seg, timezone: self.timezone))
                }
            }
            .padding(.leading, 34)
            .padding(.bottom, 4)
        }
        .padding(.vertical, 6)
    }
}

private struct TravelStat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(self.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(self.value)
                .font(.caption.weight(.semibold))
        }
    }
}

// MARK: - PhantomLegNote (§24 dual window)

private struct PhantomLegNote: View {
    let segment: TrackSegment
    let timezone: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text("Signal gap during drive · drive window \(self.driveWindow)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 34)
        .padding(.bottom, 4)
    }

    private var driveWindow: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm"
        fmt.timeZone = TimeZone(identifier: self.timezone) ?? .current
        let tStart = Date(timeIntervalSince1970: Double(self.segment.travelStartMs) / 1000)
        let tEnd   = Date(timeIntervalSince1970: Double(self.segment.startMs) / 1000)
        return "\(fmt.string(from: tStart))–\(fmt.string(from: tEnd))"
    }
}

// MARK: - StopTimelineRow

private enum StopRole { case arrival, departure }

private struct StopTimelineRow: View {

    let stop: StopNode
    let timezone: String
    let role: StopRole

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(self.stop.isOngoing ? Color.blue.opacity(0.15) : Color(.systemGray5))
                    .frame(width: 28, height: 28)
                Image(systemName: self.stop.isOngoing ? "location.fill" : "mappin.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(self.stop.isOngoing ? .blue : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(self.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(self.timeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let address = self.stop.address, !address.isEmpty {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !self.dwellText.isEmpty {
                    Text(self.dwellText)
                        .font(.caption)
                        .foregroundStyle(self.stop.isOngoing ? .blue : .secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var title: String {
        if self.stop.isOngoing { return "Currently here" }
        return "Stop \(self.stop.index + 1)"
    }

    private var timeText: String {
        let ms = self.role == .arrival ? self.stop.arrivalMs : (self.stop.departureMs ?? self.stop.arrivalMs)
        guard ms > 0 else { return "" }
        let fmt = DateFormatter()
        fmt.timeZone = TimeZone(identifier: self.timezone) ?? .current
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private var dwellText: String {
        guard self.role == .arrival else { return "" }
        if self.stop.isOngoing {
            let elapsed = Int64(Date().timeIntervalSince1970) - self.stop.arrivalMs / 1000
            return elapsed > 0 ? "Stopped \(formatDuration(elapsed))" : "Ongoing"
        }
        guard self.stop.dwellSec > 0 else { return "" }
        return "Stopped \(formatDuration(self.stop.dwellSec))"
    }

}

// MARK: - TimelineConnector

private struct TimelineConnector: View {
    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color(.systemGray4))
                .frame(width: 2, height: 12)
                .padding(.leading, 13)
            Spacer()
        }
    }
}

// MARK: - Shared helpers (file-scope so all private structs can reach them)

private func activityIcon(_ seg: TrackSegment) -> String {
    if let raw = seg.activityIcon, !raw.isEmpty { return raw }
    switch seg.activity {
    case ActivityName.flight:    return "✈️"
    case ActivityName.train:     return "🚄"
    case ActivityName.driving:   return "🚗"
    case ActivityName.riding:    return "🛵"
    case ActivityName.cycling:   return "🚲"
    case ActivityName.running:   return "🏃"
    case ActivityName.walking:   return "🚶"
    default:                     return "🗺️"
    }
}

private func speedBandColor(_ band: String?) -> Color {
    switch band {
    case SpeedBandName.green:  return .green
    case SpeedBandName.yellow: return .yellow
    default:                   return .red
    }
}

private func formatDistance(_ m: Double) -> String {
    m >= 1000 ? String(format: "%.2f km", m / 1000) : String(format: "%.0f m", m)
}

private func formatSpeed(_ mps: Float) -> String {
    String(format: "%.0f km/h", mps * 3.6)
}

private func timeRange(_ seg: TrackSegment, timezone: String) -> String {
    guard seg.startMs > 0, seg.endMs > 0 else { return "" }
    let fmt = DateFormatter()
    fmt.timeZone = TimeZone(identifier: timezone) ?? .current
    fmt.dateFormat = "h:mm"
    let s = fmt.string(from: Date(timeIntervalSince1970: Double(seg.startMs) / 1000))
    let e = fmt.string(from: Date(timeIntervalSince1970: Double(seg.endMs)   / 1000))
    return "\(s)–\(e)"
}

// Public-ish so StopTimelineRow can call it
func TrackTimelineSection_formatDuration(_ sec: Int64) -> String {
    if sec < 60 { return "\(sec)s" }
    let m = sec / 60; let s = sec % 60
    if m < 60 { return s == 0 ? "\(m)min" : "\(m)min \(s)s" }
    let h = m / 60; let rm = m % 60
    return rm == 0 ? "\(h)hr" : "\(h)hr \(rm)min"
}

private func formatDuration(_ sec: Int64) -> String { TrackTimelineSection_formatDuration(sec) }
