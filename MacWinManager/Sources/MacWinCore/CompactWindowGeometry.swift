import Foundation

/// Normal window geometry in logical screen points. Valid user frames stay exact.
public enum CompactWindowGeometry {
    public static func fittedFrame(_ frame: CGRect, screens: [CGRect], fallback: CGRect) -> CGRect {
        let validScreens = screens.filter { !$0.isEmpty && !$0.isNull }
        if validScreens.contains(where: { $0.contains(frame) }) { return frame }
        let best = validScreens.max {
            area($0.intersection(frame)) < area($1.intersection(frame))
        }
        let target = best.flatMap { area($0.intersection(frame)) > 0 ? $0 : nil } ?? fallback
        guard !target.isEmpty, !target.isNull else { return frame }
        let margin = min(24, target.width / 8, target.height / 8)
        let safe = target.insetBy(dx: margin, dy: margin)
        let width = min(frame.width, safe.width)
        let height = min(frame.height, safe.height)
        return CGRect(x: min(max(frame.minX, safe.minX), safe.maxX - width),
                      y: min(max(frame.minY, safe.minY), safe.maxY - height),
                      width: width, height: height)
    }

    public static func minimumContentSize(nominal: CGSize, available: CGSize, current: CGSize) -> CGSize {
        CGSize(width: min(nominal.width, max(1, available.width), max(1, current.width)),
               height: min(nominal.height, max(1, available.height), max(1, current.height)))
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }
}
