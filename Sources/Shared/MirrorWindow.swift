import Foundation
import CoreGraphics

struct MirrorWindow: Identifiable, Equatable {
    let id: UInt32
    var applicationName: String
    var applicationBundleIdentifier: String?
    var applicationIconPNGData: Data?
    var ownerName: String
    var title: String
    var processID: Int32
    var frame: CGRect
    var layer: Int
    var isOnScreen: Bool

    var displayTitle: String {
        title.isEmpty ? applicationName : title
    }

    var windowListTitle: String {
        title.isEmpty ? "Main Window" : title
    }

    var sizeDescription: String {
        "\(Int(frame.width)) x \(Int(frame.height))"
    }

    var windowListSubtitle: String {
        sizeDescription
    }

    var subtitle: String {
        if title.isEmpty {
            return sizeDescription
        }
        return "\(applicationName) - \(sizeDescription)"
    }

    var applicationGroupID: String {
        applicationBundleIdentifier ?? applicationName.lowercased()
    }

    var isLikelySimulator: Bool {
        ownerName.localizedCaseInsensitiveContains("Simulator") ||
            title.localizedCaseInsensitiveContains("Simulator")
    }

    var targetKind: MirrorTargetKind {
        isLikelySimulator ? .simulator : .macWindow
    }
}
