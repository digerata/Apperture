import Foundation
import CoreGraphics

struct MirrorWindow: Identifiable, Equatable {
    let id: UInt32
    var ownerName: String
    var title: String
    var processID: Int32
    var frame: CGRect
    var layer: Int
    var isOnScreen: Bool

    var displayTitle: String {
        title.isEmpty ? ownerName : title
    }

    var subtitle: String {
        let size = "\(Int(frame.width)) x \(Int(frame.height))"
        if title.isEmpty {
            return size
        }
        return "\(ownerName) - \(size)"
    }

    var isLikelySimulator: Bool {
        ownerName.localizedCaseInsensitiveContains("Simulator") ||
            title.localizedCaseInsensitiveContains("Simulator")
    }

    var targetKind: MirrorTargetKind {
        isLikelySimulator ? .simulator : .macWindow
    }
}
