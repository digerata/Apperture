import AppKit
import CoreGraphics
import Foundation

struct WindowDiscoveryService {
    func discoverWindows() -> [MirrorWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let currentProcessID = Int32(ProcessInfo.processInfo.processIdentifier)

        return windowInfo.compactMap { entry in
            makeWindow(from: entry, currentProcessID: currentProcessID)
        }
        .sorted { lhs, rhs in
            if lhs.isLikelySimulator != rhs.isLikelySimulator {
                return lhs.isLikelySimulator
            }

            if lhs.ownerName != rhs.ownerName {
                return lhs.ownerName.localizedCaseInsensitiveCompare(rhs.ownerName) == .orderedAscending
            }

            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    private func makeWindow(from entry: [String: Any], currentProcessID: Int32) -> MirrorWindow? {
        guard
            let rawWindowID = entry[kCGWindowNumber as String] as? UInt32,
            let ownerName = entry[kCGWindowOwnerName as String] as? String,
            let processID = entry[kCGWindowOwnerPID as String] as? Int32,
            let layer = entry[kCGWindowLayer as String] as? Int,
            let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: boundsDictionary)
        else {
            return nil
        }

        let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
        let title = entry[kCGWindowName as String] as? String ?? ""

        guard layer == 0 else { return nil }
        guard alpha > 0 else { return nil }
        guard processID != currentProcessID else { return nil }
        guard frame.width >= 120, frame.height >= 80 else { return nil }
        guard ownerName != "Window Server" else { return nil }

        return MirrorWindow(
            id: rawWindowID,
            ownerName: ownerName,
            title: title,
            processID: processID,
            frame: frame,
            layer: layer,
            isOnScreen: true
        )
    }
}
