import SwiftUI
import TrackerMaps

// MARK: - TravellingArrow

/// One direction chevron, drawn at an anchor the engine placed.
///
/// **The positions are `Track.arrows`, not this view's idea of where an arrow belongs.**
/// `TrackBuilder` spaces the anchors and computes each bearing, and `TrackMapView` renders
/// the same array the same way — so the sample and the SDK cannot end up pointing
/// different directions on the same leg, and neither can drift from the exported JSON.
///
/// This file once also held an `ArrowPath` that walked a chevron along the route on a
/// timer. It was removed rather than slowed down: the walk read `progress` from inside the
/// `Map` content builder, so every tick rebuilt every polyline, every pin and the raw
/// thread for a track that had not changed. That continuous invalidation is what starved
/// MapKit's own pinch and pan recognisers and made the map feel stuck. Direction is
/// already legible from the static anchors, which cost nothing to draw.
struct TravellingArrow: View {

    /// Degrees clockwise from true north — the same convention `TrackMapView` applies to
    /// `ArrowAnchor.bearing`.
    let headingDeg: Double

    let size: CGFloat

    var body: some View {
        // `TrackIcons.chevron` draws pointing UP and caches by (size, colour), so this is a
        // dictionary lookup and a rotation. It is the same image `TrackMapView` uses, from
        // the same cache.
        Image(uiImage: TrackIcons.chevron(size: self.size))
            .rotationEffect(.degrees(self.headingDeg))
            .allowsHitTesting(false)
    }
}
