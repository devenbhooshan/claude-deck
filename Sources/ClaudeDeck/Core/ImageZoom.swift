import Foundation

/// The image viewer's zoom: fitted to the window, or a scale you chose (1 = actual size).
enum ImageZoom {
    static let range: ClosedRange<CGFloat> = 0.1...8
    /// Each step in or out is a quarter more or less.
    static let factor: CGFloat = 1.25

    /// The scale that shows the whole image inside `area` (less `margin` on each side); small
    /// images aren't blown up past their actual size.
    static func fit(_ image: CGSize, in area: CGSize, margin: CGFloat = 16) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        let w = max(1, area.width - margin * 2), h = max(1, area.height - margin * 2)
        return min(1, w / image.width, h / image.height)
    }

    /// One step in or out from `scale`, kept within `range`.
    static func step(_ scale: CGFloat, in zoomIn: Bool) -> CGFloat {
        scaled(scale, by: zoomIn ? factor : 1 / factor)
    }

    /// `scale` times `by` (a pinch, or a wheel turn), kept within `range`.
    static func scaled(_ scale: CGFloat, by: CGFloat) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, scale * by))
    }

    /// How much one wheel event zooms: scrolling up (positive delta) zooms in.
    static func wheelFactor(_ deltaY: CGFloat) -> CGFloat { pow(1.01, deltaY) }

    static func percent(_ scale: CGFloat) -> String { "\(Int((scale * 100).rounded()))%" }
}
