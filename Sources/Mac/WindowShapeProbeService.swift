import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct WindowShapeProbeResult: Equatable {
    var outputDirectoryURL: URL
    var reportURL: URL
    var windowID: UInt32
    var windowTitle: String
    var variants: [WindowShapeProbeVariantReport]

    var bestVariantName: String? {
        variants.first(where: \.hasUsableExteriorAlpha)?.name
    }

    var summaryText: String {
        if let bestVariantName {
            return "Probe complete. \(bestVariantName) produced exterior alpha."
        }

        return "Probe complete. None of the variants exposed exterior alpha."
    }
}

struct WindowShapeProbeVariantReport: Equatable {
    var name: String
    var imageURL: URL
    var rawAlphaURL: URL?
    var exteriorMaskURL: URL?
    var width: Int
    var height: Int
    var alphaInfo: String
    var minimumAlpha: Int
    var maximumAlpha: Int
    var transparentPixelCount: Int
    var partialAlphaPixelCount: Int
    var opaquePixelCount: Int
    var edgeTransparentPixelCount: Int
    var cornerTransparentPixelCount: Int
    var cornerPartialAlphaPixelCount: Int
    var hasUsableExteriorAlpha: Bool
}

enum WindowShapeProbeState: Equatable {
    case idle
    case running(String)
    case completed(WindowShapeProbeResult)
    case failed(String)

    var isRunning: Bool {
        if case .running = self {
            return true
        }

        return false
    }

    var isVisible: Bool {
        if case .idle = self {
            return false
        }

        return true
    }

    var title: String {
        switch self {
        case .idle:
            return "Window Shape Probe"
        case .running:
            return "Probing Window Shape"
        case .completed:
            return "Window Shape Probe Complete"
        case .failed:
            return "Window Shape Probe Failed"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "No probe has run yet."
        case .running(let title):
            return "Capturing shape variants for \(title)."
        case .completed(let result):
            return result.summaryText
        case .failed(let message):
            return message
        }
    }

    var outputDirectoryURL: URL? {
        if case .completed(let result) = self {
            return result.outputDirectoryURL
        }

        return nil
    }
}

final class WindowShapeProbeService {
    private static let outputRootURL = URL(fileURLWithPath: "/private/tmp/apperture-window-shape-probes", isDirectory: true)
    private static let clearBackgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0)

    func run(for mirrorWindow: MirrorWindow) async throws -> WindowShapeProbeResult {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == mirrorWindow.id }) else {
            throw WindowShapeProbeError.windowUnavailable(mirrorWindow.displayTitle)
        }

        let outputDirectoryURL = try Self.makeOutputDirectory(for: mirrorWindow)
        let variants = Self.captureVariants()
        var reports = [WindowShapeProbeVariantReport]()

        for variant in variants {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = Self.makeConfiguration(for: window, filter: filter, variant: variant)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            reports.append(try Self.writeReport(
                for: image,
                variant: variant,
                outputDirectoryURL: outputDirectoryURL
            ))
        }

        let reportURL = outputDirectoryURL.appendingPathComponent("report.txt")
        let result = WindowShapeProbeResult(
            outputDirectoryURL: outputDirectoryURL,
            reportURL: reportURL,
            windowID: mirrorWindow.id,
            windowTitle: mirrorWindow.displayTitle,
            variants: reports
        )
        try Self.makeTextReport(for: result).write(to: reportURL, atomically: true, encoding: .utf8)
        return result
    }

    private static func captureVariants() -> [CaptureVariant] {
        [
            CaptureVariant(
                name: "current-opaque-unframed",
                shouldBeOpaque: true,
                ignoresShadowsSingleWindow: true,
                ignoresGlobalClipSingleWindow: true
            ),
            CaptureVariant(
                name: "alpha-unframed",
                shouldBeOpaque: false,
                ignoresShadowsSingleWindow: true,
                ignoresGlobalClipSingleWindow: true
            ),
            CaptureVariant(
                name: "alpha-unframed-global-clip",
                shouldBeOpaque: false,
                ignoresShadowsSingleWindow: true,
                ignoresGlobalClipSingleWindow: false
            ),
            CaptureVariant(
                name: "alpha-framed-global-clip",
                shouldBeOpaque: false,
                ignoresShadowsSingleWindow: false,
                ignoresGlobalClipSingleWindow: false
            )
        ]
    }

    private static func makeConfiguration(
        for window: SCWindow,
        filter: SCContentFilter,
        variant: CaptureVariant
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let nativeScale = max(CGFloat(filter.pointPixelScale), displayScale(for: window), 1)
        let captureRect = filter.contentRect.isEmpty ? window.frame : filter.contentRect
        let targetPixelSize = targetPixelSize(for: captureRect.size, nativeScale: nativeScale)

        configuration.width = max(320, Int(targetPixelSize.width))
        configuration.height = max(240, Int(targetPixelSize.height))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(RemoteFrameStreamConfiguration.targetFrameRate))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 2
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.backgroundColor = clearBackgroundColor
        configuration.ignoreShadowsSingleWindow = variant.ignoresShadowsSingleWindow
        configuration.ignoreGlobalClipSingleWindow = variant.ignoresGlobalClipSingleWindow
        configuration.shouldBeOpaque = variant.shouldBeOpaque
        return configuration
    }

    private static func targetPixelSize(for pointSize: CGSize, nativeScale: CGFloat) -> CGSize {
        let nativeSize = CGSize(
            width: max(pointSize.width * nativeScale, 1),
            height: max(pointSize.height * nativeScale, 1)
        )
        let maxDimensionScale = CGFloat(RemoteFrameStreamConfiguration.maxCapturePixelDimension) /
            max(nativeSize.width, nativeSize.height, 1)
        let maxPixelScale = sqrt(
            CGFloat(RemoteFrameStreamConfiguration.maxCapturePixels) /
                max(nativeSize.width * nativeSize.height, 1)
        )
        let outputScale = min(1, maxDimensionScale, maxPixelScale)

        return CGSize(
            width: floor(nativeSize.width * outputScale),
            height: floor(nativeSize.height * outputScale)
        )
    }

    private static func displayScale(for window: SCWindow) -> CGFloat {
        let windowCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
        return NSScreen.screens.first { screen in
            screen.frame.contains(windowCenter)
        }?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    private static func makeOutputDirectory(for window: MirrorWindow) throws -> URL {
        let timestamp = ISO8601DateFormatter.fileSafeTimestampString(from: Date())
        let directoryName = "\(timestamp)-\(window.id)-\(sanitizedComponent(window.displayTitle))"
        let outputDirectoryURL = outputRootURL.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
        return outputDirectoryURL
    }

    private static func writeReport(
        for image: CGImage,
        variant: CaptureVariant,
        outputDirectoryURL: URL
    ) throws -> WindowShapeProbeVariantReport {
        let imageURL = outputDirectoryURL.appendingPathComponent("\(variant.name)-capture.png")
        try writePNG(image, to: imageURL)

        guard let alphaArtifacts = makeAlphaArtifacts(from: image) else {
            return WindowShapeProbeVariantReport(
                name: variant.name,
                imageURL: imageURL,
                rawAlphaURL: nil,
                exteriorMaskURL: nil,
                width: image.width,
                height: image.height,
                alphaInfo: alphaDescription(for: image),
                minimumAlpha: 255,
                maximumAlpha: 255,
                transparentPixelCount: 0,
                partialAlphaPixelCount: 0,
                opaquePixelCount: image.width * image.height,
                edgeTransparentPixelCount: 0,
                cornerTransparentPixelCount: 0,
                cornerPartialAlphaPixelCount: 0,
                hasUsableExteriorAlpha: false
            )
        }

        let rawAlphaURL = outputDirectoryURL.appendingPathComponent("\(variant.name)-raw-alpha.png")
        let exteriorMaskURL = outputDirectoryURL.appendingPathComponent("\(variant.name)-exterior-mask.png")
        try writePNG(alphaArtifacts.rawAlphaImage, to: rawAlphaURL)
        try writePNG(alphaArtifacts.exteriorMaskImage, to: exteriorMaskURL)

        return WindowShapeProbeVariantReport(
            name: variant.name,
            imageURL: imageURL,
            rawAlphaURL: rawAlphaURL,
            exteriorMaskURL: exteriorMaskURL,
            width: image.width,
            height: image.height,
            alphaInfo: alphaDescription(for: image),
            minimumAlpha: Int(alphaArtifacts.stats.minimumAlpha),
            maximumAlpha: Int(alphaArtifacts.stats.maximumAlpha),
            transparentPixelCount: alphaArtifacts.stats.transparentPixelCount,
            partialAlphaPixelCount: alphaArtifacts.stats.partialAlphaPixelCount,
            opaquePixelCount: alphaArtifacts.stats.opaquePixelCount,
            edgeTransparentPixelCount: alphaArtifacts.stats.edgeTransparentPixelCount,
            cornerTransparentPixelCount: alphaArtifacts.stats.cornerTransparentPixelCount,
            cornerPartialAlphaPixelCount: alphaArtifacts.stats.cornerPartialAlphaPixelCount,
            hasUsableExteriorAlpha: alphaArtifacts.stats.hasUsableExteriorAlpha
        )
    }

    private static func makeAlphaArtifacts(from image: CGImage) -> AlphaArtifacts? {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var alpha = [UInt8](repeating: 0, count: width * height)
        var stats = AlphaStats()
        let cornerSize = max(1, min(64, min(width, height) / 6))
        let edgeBand = max(1, min(32, min(width, height) / 32))

        for y in 0..<height {
            for x in 0..<width {
                let alphaValue = pixels[y * bytesPerRow + x * bytesPerPixel + 3]
                let alphaIndex = y * width + x
                alpha[alphaIndex] = alphaValue
                stats.record(
                    alphaValue,
                    isEdgePixel: x < edgeBand || y < edgeBand || x >= width - edgeBand || y >= height - edgeBand,
                    isCornerPixel: isCornerPixel(x: x, y: y, width: width, height: height, cornerSize: cornerSize)
                )
            }
        }

        guard let rawAlphaImage = makeAlphaVisualizationImage(alpha: alpha, width: width, height: height),
              let exteriorMaskImage = makeExteriorMaskVisualizationImage(alpha: alpha, width: width, height: height) else {
            return nil
        }

        return AlphaArtifacts(
            rawAlphaImage: rawAlphaImage,
            exteriorMaskImage: exteriorMaskImage,
            stats: stats
        )
    }

    private static func makeAlphaVisualizationImage(alpha: [UInt8], width: Int, height: Int) -> CGImage? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        for index in 0..<alpha.count {
            let offset = index * bytesPerPixel
            let value = alpha[index]
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
            pixels[offset + 3] = 255
        }

        return makeImage(from: &pixels, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    private static func makeExteriorMaskVisualizationImage(alpha: [UInt8], width: Int, height: Int) -> CGImage? {
        let outside = exteriorTransparentPixels(alpha: alpha, width: width, height: height)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        for index in 0..<alpha.count {
            let offset = index * bytesPerPixel
            let value: UInt8
            if outside[index] {
                value = 0
            } else if alpha[index] < 250, isNearOutside(index, outside: outside, width: width, height: height) {
                value = alpha[index]
            } else {
                value = 255
            }

            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
            pixels[offset + 3] = 255
        }

        return makeImage(from: &pixels, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    private static func exteriorTransparentPixels(alpha: [UInt8], width: Int, height: Int) -> [Bool] {
        let transparentThreshold: UInt8 = 8
        var outside = [Bool](repeating: false, count: width * height)
        var queue = [Int]()
        queue.reserveCapacity(width * 2 + height * 2)

        func enqueue(_ x: Int, _ y: Int) {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            let index = y * width + x
            guard !outside[index], alpha[index] <= transparentThreshold else { return }
            outside[index] = true
            queue.append(index)
        }

        for x in 0..<width {
            enqueue(x, 0)
            enqueue(x, height - 1)
        }

        for y in 0..<height {
            enqueue(0, y)
            enqueue(width - 1, y)
        }

        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let x = index % width
            let y = index / width
            enqueue(x + 1, y)
            enqueue(x - 1, y)
            enqueue(x, y + 1)
            enqueue(x, y - 1)
        }

        return outside
    }

    private static func isNearOutside(_ index: Int, outside: [Bool], width: Int, height: Int) -> Bool {
        let x = index % width
        let y = index / width

        for dy in -2...2 {
            for dx in -2...2 {
                let neighborX = x + dx
                let neighborY = y + dy
                guard neighborX >= 0, neighborY >= 0, neighborX < width, neighborY < height else {
                    continue
                }

                if outside[neighborY * width + neighborX] {
                    return true
                }
            }
        }

        return false
    }

    private static func makeImage(
        from pixels: inout [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> CGImage? {
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        return context.makeImage()
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw WindowShapeProbeError.imageWriteFailed(url.path)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw WindowShapeProbeError.imageWriteFailed(url.path)
        }
    }

    private static func makeTextReport(for result: WindowShapeProbeResult) -> String {
        var lines = [
            "Window Shape Probe",
            "Window: \(result.windowTitle)",
            "Window ID: \(result.windowID)",
            "Output: \(result.outputDirectoryURL.path)",
            ""
        ]

        for variant in result.variants {
            let pixelCount = max(variant.width * variant.height, 1)
            lines.append(variant.name)
            lines.append("  image: \(variant.imageURL.path)")
            if let rawAlphaURL = variant.rawAlphaURL {
                lines.append("  raw alpha: \(rawAlphaURL.path)")
            }
            if let exteriorMaskURL = variant.exteriorMaskURL {
                lines.append("  exterior mask: \(exteriorMaskURL.path)")
            }
            lines.append("  size: \(variant.width)x\(variant.height)")
            lines.append("  alpha info: \(variant.alphaInfo)")
            lines.append("  alpha range: \(variant.minimumAlpha)...\(variant.maximumAlpha)")
            lines.append("  transparent: \(percentText(variant.transparentPixelCount, of: pixelCount))")
            lines.append("  partial alpha: \(percentText(variant.partialAlphaPixelCount, of: pixelCount))")
            lines.append("  edge transparent pixels: \(variant.edgeTransparentPixelCount)")
            lines.append("  corner transparent pixels: \(variant.cornerTransparentPixelCount)")
            lines.append("  corner partial alpha pixels: \(variant.cornerPartialAlphaPixelCount)")
            lines.append("  usable exterior alpha: \(variant.hasUsableExteriorAlpha ? "yes" : "no")")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func percentText(_ count: Int, of total: Int) -> String {
        let percent = Double(count) / Double(total) * 100
        return "\(count) (\(String(format: "%.3f", percent))%)"
    }

    private static func alphaDescription(for image: CGImage) -> String {
        switch image.alphaInfo {
        case .none:
            return "none"
        case .premultipliedLast:
            return "premultipliedLast"
        case .premultipliedFirst:
            return "premultipliedFirst"
        case .last:
            return "last"
        case .first:
            return "first"
        case .noneSkipLast:
            return "noneSkipLast"
        case .noneSkipFirst:
            return "noneSkipFirst"
        case .alphaOnly:
            return "alphaOnly"
        @unknown default:
            return "unknown"
        }
    }

    private static func isCornerPixel(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        cornerSize: Int
    ) -> Bool {
        (x < cornerSize || x >= width - cornerSize) &&
            (y < cornerSize || y >= height - cornerSize)
    }

    private static func sanitizedComponent(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = text.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
        return sanitized.isEmpty ? "window" : String(sanitized.prefix(80))
    }
}

private struct CaptureVariant {
    var name: String
    var shouldBeOpaque: Bool
    var ignoresShadowsSingleWindow: Bool
    var ignoresGlobalClipSingleWindow: Bool
}

private struct AlphaArtifacts {
    var rawAlphaImage: CGImage
    var exteriorMaskImage: CGImage
    var stats: AlphaStats
}

private struct AlphaStats {
    var minimumAlpha: UInt8 = 255
    var maximumAlpha: UInt8 = 0
    var transparentPixelCount = 0
    var partialAlphaPixelCount = 0
    var opaquePixelCount = 0
    var edgeTransparentPixelCount = 0
    var cornerTransparentPixelCount = 0
    var cornerPartialAlphaPixelCount = 0

    var hasUsableExteriorAlpha: Bool {
        minimumAlpha < 250 &&
            edgeTransparentPixelCount > 0 &&
            cornerTransparentPixelCount + cornerPartialAlphaPixelCount > 0
    }

    mutating func record(_ alpha: UInt8, isEdgePixel: Bool, isCornerPixel: Bool) {
        minimumAlpha = min(minimumAlpha, alpha)
        maximumAlpha = max(maximumAlpha, alpha)

        if alpha == 0 {
            transparentPixelCount += 1
        } else if alpha == 255 {
            opaquePixelCount += 1
        } else {
            partialAlphaPixelCount += 1
        }

        if isEdgePixel, alpha == 0 {
            edgeTransparentPixelCount += 1
        }

        if isCornerPixel, alpha == 0 {
            cornerTransparentPixelCount += 1
        } else if isCornerPixel, alpha < 255 {
            cornerPartialAlphaPixelCount += 1
        }
    }
}

private enum WindowShapeProbeError: LocalizedError {
    case windowUnavailable(String)
    case imageWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .windowUnavailable(let title):
            return "Could not find \(title) in ScreenCaptureKit's shareable window list."
        case .imageWriteFailed(let path):
            return "Could not write probe image to \(path)."
        }
    }
}

private extension ISO8601DateFormatter {
    static func fileSafeTimestampString(from date: Date) -> String {
        fileSafeTimestamp.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    static let fileSafeTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
