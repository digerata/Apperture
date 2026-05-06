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
        var applicationInfoByProcessID: [Int32: DiscoveredApplicationInfo] = [:]

        return windowInfo.compactMap { entry in
            makeWindow(
                from: entry,
                currentProcessID: currentProcessID,
                applicationInfoByProcessID: &applicationInfoByProcessID
            )
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

    private func makeWindow(
        from entry: [String: Any],
        currentProcessID: Int32,
        applicationInfoByProcessID: inout [Int32: DiscoveredApplicationInfo]
    ) -> MirrorWindow? {
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

        let applicationInfo = applicationInfo(
            for: processID,
            fallbackName: ownerName,
            cache: &applicationInfoByProcessID
        )

        return MirrorWindow(
            id: rawWindowID,
            applicationName: applicationInfo.name,
            applicationBundleIdentifier: applicationInfo.bundleIdentifier,
            applicationIconPNGData: applicationInfo.iconPNGData,
            ownerName: ownerName,
            title: title,
            processID: processID,
            frame: frame,
            layer: layer,
            isOnScreen: true
        )
    }

    private func applicationInfo(
        for processID: Int32,
        fallbackName: String,
        cache: inout [Int32: DiscoveredApplicationInfo]
    ) -> DiscoveredApplicationInfo {
        if let cachedInfo = cache[processID] {
            return cachedInfo
        }

        let runningApplication = NSRunningApplication(processIdentifier: processID)
        let icon = runningApplication?.icon ?? runningApplication?.bundleURL.map { bundleURL in
            NSWorkspace.shared.icon(forFile: bundleURL.path)
        }

        let info = DiscoveredApplicationInfo(
            name: runningApplication?.localizedName ?? fallbackName,
            bundleIdentifier: runningApplication?.bundleIdentifier,
            iconPNGData: icon.flatMap { Self.iconPNGData(from: $0) }
        )
        cache[processID] = info
        return info
    }

    private static func iconPNGData(from icon: NSImage) -> Data? {
        let iconSize = NSSize(width: 64, height: 64)
        let outputImage = NSImage(size: iconSize)

        outputImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(
            in: NSRect(origin: .zero, size: iconSize),
            from: NSRect(origin: .zero, size: icon.size),
            operation: .copy,
            fraction: 1
        )
        outputImage.unlockFocus()

        guard let tiffData = outputImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}

private struct DiscoveredApplicationInfo {
    var name: String
    var bundleIdentifier: String?
    var iconPNGData: Data?
}
