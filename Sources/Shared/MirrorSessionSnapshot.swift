import Foundation
import CoreGraphics

struct MirrorSessionSnapshot: Equatable {
    var targetName: String
    var targetKind: MirrorTargetKind
    var layoutMode: MirrorLayoutMode
    var sourceSize: CGSize
    var isConnected: Bool

    static let preview = MirrorSessionSnapshot(
        targetName: "Scheduling",
        targetKind: .macWindow,
        layoutMode: .fitWidth,
        sourceSize: CGSize(width: 960, height: 720),
        isConnected: true
    )
}
