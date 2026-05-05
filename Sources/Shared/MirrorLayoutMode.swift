import Foundation
import CoreGraphics

enum MirrorLayoutMode: String, CaseIterable, Identifiable {
    case fitWidth
    case fitHeight
    case readableZoom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fitWidth:
            return "Fit Width"
        case .fitHeight:
            return "Fit Height"
        case .readableZoom:
            return "Readable"
        }
    }

    var symbolName: String {
        switch self {
        case .fitWidth:
            return "arrow.left.and.right"
        case .fitHeight:
            return "arrow.up.and.down"
        case .readableZoom:
            return "text.magnifyingglass"
        }
    }
}

enum MirrorTargetKind: String, CaseIterable, Identifiable {
    case macWindow
    case simulator

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macWindow:
            return "Mac"
        case .simulator:
            return "Simulator"
        }
    }

    var symbolName: String {
        switch self {
        case .macWindow:
            return "macwindow"
        case .simulator:
            return "iphone"
        }
    }
}

struct ViewportMapping: Equatable {
    var sourceSize: CGSize
    var viewportSize: CGSize
    var layoutMode: MirrorLayoutMode
    var readableScale: CGFloat

    var scale: CGFloat {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return 1 }

        switch layoutMode {
        case .fitWidth:
            return viewportSize.width / sourceSize.width
        case .fitHeight:
            return viewportSize.height / sourceSize.height
        case .readableZoom:
            return readableScale
        }
    }

    var renderedSize: CGSize {
        CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    }

    var origin: CGPoint {
        CGPoint(
            x: (viewportSize.width - renderedSize.width) / 2,
            y: (viewportSize.height - renderedSize.height) / 2
        )
    }

    func sourcePoint(for viewportPoint: CGPoint) -> CGPoint? {
        let x = (viewportPoint.x - origin.x) / scale
        let y = (viewportPoint.y - origin.y) / scale

        guard x >= 0, y >= 0, x <= sourceSize.width, y <= sourceSize.height else {
            return nil
        }

        return CGPoint(x: x, y: y)
    }
}
