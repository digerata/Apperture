import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VideoToolbox

struct LiveCaptureFrame {
    var image: CGImage?
    var pixelBuffer: CVPixelBuffer?
    var screenFrame: CGRect
    var timing: LiveCaptureFrameTiming

    var previewImage: CGImage? {
        if let image {
            return image
        }

        guard let pixelBuffer else {
            return nil
        }

        var image: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        guard status == noErr else {
            return nil
        }
        return image
    }

    var pixelSize: CGSize {
        if let image {
            return CGSize(width: image.width, height: image.height)
        }

        if let pixelBuffer {
            return CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        }

        return .zero
    }
}

struct LiveCaptureFrameTiming {
    var cgImageMilliseconds: Double = 0
    var cropMilliseconds: Double = 0
    var materializeMilliseconds: Double = 0
    var totalMilliseconds: Double = 0
    var usesDirectPixelBuffer = false
}

enum LiveCaptureMode {
    case window
    case simulator
}

final class LiveWindowCaptureService: NSObject {
    private let outputQueue = DispatchQueue(label: "com.mikewille.Apperture.live-capture")
    private var stream: SCStream?
    private var frameHandler: ((LiveCaptureFrame) -> Void)?
    private var stopHandler: ((Error) -> Void)?
    private var fallbackScreenFrame: CGRect?
    private var captureMode: LiveCaptureMode = .window

    static func canAccessShareableContent() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    static func bootstrapFrame(for window: MirrorWindow, mode: LiveCaptureMode) async -> LiveCaptureFrame? {
        guard mode == .window else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let capturedWindow = content.windows.first(where: { $0.windowID == window.id }) else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: capturedWindow)
            let configuration = makeConfiguration(for: capturedWindow, filter: filter)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            return LiveCaptureFrame(
                image: image,
                pixelBuffer: nil,
                screenFrame: window.frame,
                timing: LiveCaptureFrameTiming()
            )
        } catch {
            return nil
        }
    }

    func start(
        windowID: CGWindowID,
        mode: LiveCaptureMode = .window,
        onFrame: @escaping (LiveCaptureFrame) -> Void,
        onStop: @escaping (Error) -> Void
    ) async throws {
        await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)

        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw LiveCaptureError.windowUnavailable
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = Self.makeConfiguration(for: window, filter: filter)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)

        self.stream = stream
        frameHandler = onFrame
        stopHandler = onStop
        fallbackScreenFrame = window.frame
        captureMode = mode

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func stop() async {
        guard let stream else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stream.stopCapture { _ in
                continuation.resume()
            }
        }

        try? stream.removeStreamOutput(self, type: .screen)
        self.stream = nil
        frameHandler = nil
        stopHandler = nil
        fallbackScreenFrame = nil
        captureMode = .window
    }

    private static func makeConfiguration(for window: SCWindow, filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let nativeScale = max(CGFloat(filter.pointPixelScale), Self.displayScale(for: window), 1)
        let captureRect = filter.contentRect.isEmpty ? window.frame : filter.contentRect
        let targetPixelSize = Self.targetPixelSize(for: captureRect.size, nativeScale: nativeScale)
        configuration.width = max(320, Int(targetPixelSize.width))
        configuration.height = max(240, Int(targetPixelSize.height))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(RemoteFrameStreamConfiguration.targetFrameRate))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 2
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.shouldBeOpaque = true
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
}

extension LiveWindowCaptureService: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let frameStart = DispatchTime.now().uptimeNanoseconds
        guard type == .screen else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        guard Self.isCompleteFrame(sampleBuffer) else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if RemoteFrameStreamConfiguration.enablesDirectCapturePixelBufferEncoding,
           let directFrame = Self.makeDirectFrame(
            from: pixelBuffer,
            sampleBuffer: sampleBuffer,
            fallbackScreenFrame: fallbackScreenFrame,
            mode: captureMode,
            frameStart: frameStart
        ) {
            frameHandler?(directFrame)
            return
        }

        let cgImageStart = DispatchTime.now().uptimeNanoseconds
        var image: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        let cgImageMilliseconds = Self.milliseconds(from: cgImageStart)

        guard status == noErr, let image else { return }
        frameHandler?(
            Self.makeFrame(
                from: image,
                sampleBuffer: sampleBuffer,
                fallbackScreenFrame: fallbackScreenFrame,
                mode: captureMode,
                frameStart: frameStart,
                cgImageMilliseconds: cgImageMilliseconds
            )
        )
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = frameAttachments(from: sampleBuffer),
              let rawStatus = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return true
        }

        return status == .complete || status == .started
    }

    private static func makeDirectFrame(
        from pixelBuffer: CVPixelBuffer,
        sampleBuffer: CMSampleBuffer,
        fallbackScreenFrame: CGRect?,
        mode: LiveCaptureMode,
        frameStart: UInt64
    ) -> LiveCaptureFrame? {
        guard mode == .window else { return nil }

        let attachments = frameAttachments(from: sampleBuffer)
        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        let screenFrame = screenFrame(
            from: attachments,
            fallbackScreenFrame: fallbackScreenFrame,
            imageSize: imageSize
        )

        guard preferredCropRect(from: attachments, imageSize: imageSize, mode: mode) == nil else {
            return nil
        }

        let copyStart = DispatchTime.now().uptimeNanoseconds
        guard let stablePixelBuffer = copyPixelBuffer(pixelBuffer) else {
            return nil
        }
        let copyMilliseconds = milliseconds(from: copyStart)

        return LiveCaptureFrame(
            image: nil,
            pixelBuffer: stablePixelBuffer,
            screenFrame: screenFrame,
            timing: LiveCaptureFrameTiming(
                materializeMilliseconds: copyMilliseconds,
                totalMilliseconds: milliseconds(from: frameStart),
                usesDirectPixelBuffer: true
            )
        )
    }

    private static func copyPixelBuffer(_ sourcePixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(sourcePixelBuffer)
        let height = CVPixelBufferGetHeight(sourcePixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(sourcePixelBuffer)
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: pixelFormat
        ] as CFDictionary

        var copiedPixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes,
            &copiedPixelBuffer
        ) == kCVReturnSuccess, let copiedPixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(sourcePixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(copiedPixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copiedPixelBuffer, [])
            CVPixelBufferUnlockBaseAddress(sourcePixelBuffer, .readOnly)
        }

        guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(sourcePixelBuffer),
              let destinationBaseAddress = CVPixelBufferGetBaseAddress(copiedPixelBuffer) else {
            return nil
        }

        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(sourcePixelBuffer)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(copiedPixelBuffer)
        let copiedBytesPerRow = min(sourceBytesPerRow, destinationBytesPerRow)

        for row in 0..<height {
            memcpy(
                destinationBaseAddress.advanced(by: row * destinationBytesPerRow),
                sourceBaseAddress.advanced(by: row * sourceBytesPerRow),
                copiedBytesPerRow
            )
        }

        return copiedPixelBuffer
    }

    private static func makeFrame(
        from image: CGImage,
        sampleBuffer: CMSampleBuffer,
        fallbackScreenFrame: CGRect?,
        mode: LiveCaptureMode,
        frameStart: UInt64,
        cgImageMilliseconds: Double
    ) -> LiveCaptureFrame {
        let attachments = frameAttachments(from: sampleBuffer)
        let imageSize = CGSize(width: image.width, height: image.height)
        let screenFrame = screenFrame(
            from: attachments,
            fallbackScreenFrame: fallbackScreenFrame,
            imageSize: imageSize
        )

        guard let cropRect = preferredCropRect(from: attachments, imageSize: imageSize, image: image, mode: mode) else {
            let materializeStart = DispatchTime.now().uptimeNanoseconds
            let outputImage = materializedCopy(of: image) ?? image
            return LiveCaptureFrame(
                image: outputImage,
                pixelBuffer: nil,
                screenFrame: screenFrame,
                timing: LiveCaptureFrameTiming(
                    cgImageMilliseconds: cgImageMilliseconds,
                    materializeMilliseconds: milliseconds(from: materializeStart),
                    totalMilliseconds: milliseconds(from: frameStart)
                )
            )
        }

        let cropStart = DispatchTime.now().uptimeNanoseconds
        guard let croppedImage = image.cropping(to: cropRect.integral) else {
            let materializeStart = DispatchTime.now().uptimeNanoseconds
            let outputImage = materializedCopy(of: image) ?? image
            return LiveCaptureFrame(
                image: outputImage,
                pixelBuffer: nil,
                screenFrame: screenFrame,
                timing: LiveCaptureFrameTiming(
                    cgImageMilliseconds: cgImageMilliseconds,
                    cropMilliseconds: milliseconds(from: cropStart),
                    materializeMilliseconds: milliseconds(from: materializeStart),
                    totalMilliseconds: milliseconds(from: frameStart)
                )
            )
        }
        let cropMilliseconds = milliseconds(from: cropStart)

        let materializeStart = DispatchTime.now().uptimeNanoseconds
        let outputImage = mode == .simulator
            ? transparentEdgeBackground(in: croppedImage) ?? croppedImage
            : materializedCopy(of: croppedImage) ?? croppedImage
        let materializeMilliseconds = milliseconds(from: materializeStart)

        let xScale = screenFrame.width > 0 ? CGFloat(image.width) / screenFrame.width : 1
        let yScale = screenFrame.height > 0 ? CGFloat(image.height) / screenFrame.height : 1
        let croppedScreenFrame = CGRect(
            x: screenFrame.minX + cropRect.minX / max(xScale, 1),
            y: screenFrame.minY + cropRect.minY / max(yScale, 1),
            width: cropRect.width / max(xScale, 1),
            height: cropRect.height / max(yScale, 1)
        )

        return LiveCaptureFrame(
            image: outputImage,
            pixelBuffer: nil,
            screenFrame: croppedScreenFrame,
            timing: LiveCaptureFrameTiming(
                cgImageMilliseconds: cgImageMilliseconds,
                cropMilliseconds: cropMilliseconds,
                materializeMilliseconds: materializeMilliseconds,
                totalMilliseconds: milliseconds(from: frameStart)
            )
        )
    }

    private static func materializedCopy(of image: CGImage) -> CGImage? {
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
        return context.makeImage()
    }

    private static func preferredCropRect(
        from attachments: [SCStreamFrameInfo: Any]?,
        imageSize: CGSize,
        mode: LiveCaptureMode
    ) -> CGRect? {
        guard let attachments else { return nil }
        let imageRect = CGRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)

        if mode == .simulator {
            return nil
        }

        return preferredWindowCropRect(from: attachments, imageRect: imageRect)
    }

    private static func preferredCropRect(
        from attachments: [SCStreamFrameInfo: Any]?,
        imageSize: CGSize,
        image: CGImage,
        mode: LiveCaptureMode
    ) -> CGRect? {
        if mode == .simulator, let simulatorCropRect = simulatorDeviceCropRect(in: image) {
            let imageRect = CGRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)
            return simulatorCropRect.intersection(imageRect)
        }

        guard let attachments else { return nil }
        return preferredWindowCropRect(
            from: attachments,
            imageRect: CGRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)
        )
    }

    private static func preferredWindowCropRect(
        from attachments: [SCStreamFrameInfo: Any],
        imageRect: CGRect
    ) -> CGRect? {
        let contentScale = numberValue(attachments[SCStreamFrameInfo.contentScale]) ?? 1
        let scaleFactor = numberValue(attachments[SCStreamFrameInfo.scaleFactor]) ?? 1

        let candidates = [
            rectValue(attachments[SCStreamFrameInfo.contentRect]),
            rectValue(attachments[SCStreamFrameInfo.boundingRect])
        ]

        for candidate in candidates {
            guard let candidate else { continue }

            for scale in scaleCandidates(for: candidate, imageRect: imageRect, contentScale: contentScale, scaleFactor: scaleFactor) {
                let pixelRect = CGRect(
                    x: candidate.minX * scale,
                    y: candidate.minY * scale,
                    width: candidate.width * scale,
                    height: candidate.height * scale
                )
                .integral
                .intersection(imageRect)

                guard pixelRect.width > 0, pixelRect.height > 0 else { continue }
                guard !approximatelyEqual(pixelRect, imageRect) else { return nil }
                return pixelRect
            }
        }

        return nil
    }

    private static func screenFrame(
        from attachments: [SCStreamFrameInfo: Any]?,
        fallbackScreenFrame: CGRect?,
        imageSize: CGSize
    ) -> CGRect {
        rectValue(attachments?[SCStreamFrameInfo.screenRect]) ?? fallbackScreenFrame ?? CGRect(
            x: 0,
            y: 0,
            width: imageSize.width,
            height: imageSize.height
        )
    }

    private static func milliseconds(from start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func scaleCandidates(
        for rect: CGRect,
        imageRect: CGRect,
        contentScale: CGFloat,
        scaleFactor: CGFloat
    ) -> [CGFloat] {
        var candidates = [contentScale, scaleFactor]

        if rect.width > 0 {
            candidates.append(imageRect.width / rect.width)
        }

        if rect.height > 0 {
            candidates.append(imageRect.height / rect.height)
        }

        candidates.append(1)

        return candidates
            .sorted(by: >)
            .reduce(into: []) { result, scale in
            guard scale.isFinite, scale > 0 else { return }
            guard !result.contains(where: { abs($0 - scale) < 0.001 }) else { return }
            result.append(scale)
        }
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1
            && abs(lhs.minY - rhs.minY) < 1
            && abs(lhs.width - rhs.width) < 1
            && abs(lhs.height - rhs.height) < 1
    }

    private static func simulatorDeviceCropRect(in image: CGImage) -> CGRect? {
        guard let providerData = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(providerData) else {
            return nil
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = max(image.bitsPerPixel / 8, 4)
        let sampleStep = max(1, min(width, height) / 360)
        let minimumDevicePixelsPerRow = max(8, width / (18 * sampleStep))
        let maximumToolbarPixelsPerRow = max(minimumDevicePixelsPerRow, Int(Double(width / sampleStep) * 0.72))
        let topSearchLimit = max(height / 3, 1)

        var cropTop = 0

        for y in stride(from: 0, to: topSearchLimit, by: sampleStep) {
            var nonBackgroundPixels = 0

            for x in stride(from: 0, to: width, by: sampleStep) {
                if isSimulatorDevicePixel(bytes: bytes, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel, x: x, y: y) {
                    nonBackgroundPixels += 1
                }
            }

            if nonBackgroundPixels >= minimumDevicePixelsPerRow,
               nonBackgroundPixels <= maximumToolbarPixelsPerRow {
                cropTop = y
                break
            }
        }

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0

        for y in stride(from: cropTop, to: height, by: sampleStep) {
            for x in stride(from: 0, to: width, by: sampleStep) {
                guard isSimulatorDevicePixel(bytes: bytes, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel, x: x, y: y) else {
                    continue
                }

                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard minX < maxX, minY < maxY else { return nil }

        let refinedRect = simulatorBezelCropRect(
            bytes: bytes,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytesPerPixel: bytesPerPixel,
            cropTop: cropTop,
            sampleStep: sampleStep
        )

        if let refinedRect {
            return refinedRect
        }

        let padding = sampleStep
        let rect = CGRect(
            x: max(minX - padding, 0),
            y: max(minY - padding, 0),
            width: min(maxX - minX + padding * 2, width - max(minX - padding, 0)),
            height: min(maxY - minY + padding * 2, height - max(minY - padding, 0))
        ).integral

        guard rect.width > CGFloat(width) * 0.15,
              rect.height > CGFloat(height) * 0.25,
              !approximatelyEqual(rect, CGRect(x: 0, y: 0, width: width, height: height)) else {
            return nil
        }

        return rect
    }

    private static func simulatorBezelCropRect(
        bytes: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int,
        cropTop: Int,
        sampleStep: Int
    ) -> CGRect? {
        let columnThreshold = max(12, (height - cropTop) / (sampleStep * 5))
        let rowThreshold = max(12, width / (sampleStep * 5))
        var minX: Int?
        var maxX: Int?
        var minY: Int?
        var maxY: Int?

        for x in stride(from: 0, to: width, by: sampleStep) {
            var darkPixels = 0

            for y in stride(from: cropTop, to: height, by: sampleStep) {
                if isDarkPixel(bytes: bytes, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel, x: x, y: y) {
                    darkPixels += 1
                }
            }

            guard darkPixels >= columnThreshold else { continue }
            minX = minX.map { min($0, x) } ?? x
            maxX = maxX.map { max($0, x) } ?? x
        }

        for y in stride(from: cropTop, to: height, by: sampleStep) {
            var darkPixels = 0

            for x in stride(from: 0, to: width, by: sampleStep) {
                if isDarkPixel(bytes: bytes, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel, x: x, y: y) {
                    darkPixels += 1
                }
            }

            guard darkPixels >= rowThreshold else { continue }
            minY = minY.map { min($0, y) } ?? y
            maxY = maxY.map { max($0, y) } ?? y
        }

        guard let minX, let maxX, let minY, let maxY,
              minX < maxX, minY < maxY else {
            return nil
        }

        let padding = sampleStep
        let originX = max(minX - padding, 0)
        let originY = max(minY - padding, 0)
        let rect = CGRect(
            x: originX,
            y: originY,
            width: min(maxX - minX + padding * 2, width - originX),
            height: min(maxY - minY + padding * 2, height - originY)
        ).integral

        guard rect.width > CGFloat(width) * 0.15,
              rect.height > CGFloat(height) * 0.25 else {
            return nil
        }

        return rect
    }

    private static func transparentEdgeBackground(in image: CGImage) -> CGImage? {
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

        var visited = [Bool](repeating: false, count: width * height)
        var queue = [(Int, Int)]()

        func enqueue(_ x: Int, _ y: Int) {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            let index = y * width + x
            guard !visited[index] else { return }
            visited[index] = true

            let offset = y * bytesPerRow + x * bytesPerPixel
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            let isStagePixel = red > 224 && green > 224 && blue > 224 && abs(red - green) < 18 && abs(green - blue) < 18
            guard isStagePixel else { return }

            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = 0
            queue.append((x, y))
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
            let (x, y) = queue[cursor]
            cursor += 1
            enqueue(x + 1, y)
            enqueue(x - 1, y)
            enqueue(x, y + 1)
            enqueue(x, y - 1)
        }

        return context.makeImage()
    }

    private static func isSimulatorDevicePixel(
        bytes: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        bytesPerPixel: Int,
        x: Int,
        y: Int
    ) -> Bool {
        let offset = y * bytesPerRow + x * bytesPerPixel
        let blue = Int(bytes[offset])
        let green = Int(bytes[offset + 1])
        let red = Int(bytes[offset + 2])

        let isWhiteStage = red > 232 && green > 232 && blue > 232
        let isLightGrayStage = abs(red - green) < 8 && abs(green - blue) < 8 && red > 210

        return !isWhiteStage && !isLightGrayStage
    }

    private static func isDarkPixel(
        bytes: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        bytesPerPixel: Int,
        x: Int,
        y: Int
    ) -> Bool {
        let offset = y * bytesPerRow + x * bytesPerPixel
        let blue = Int(bytes[offset])
        let green = Int(bytes[offset + 1])
        let red = Int(bytes[offset + 2])

        return red < 90 && green < 90 && blue < 90
    }

    private static func frameAttachments(from sampleBuffer: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]] else {
            return nil
        }

        return attachmentsArray.first
    }

    private static func rectValue(_ value: Any?) -> CGRect? {
        if let value = value as? CGRect {
            return value
        }

        if let value = value as? NSValue {
            return value.rectValue
        }

        if let value = value as? NSDictionary {
            return CGRect(dictionaryRepresentation: value)
        }

        if let value = value as? [String: Any] {
            return CGRect(dictionaryRepresentation: value as CFDictionary)
        }

        return nil
    }

    private static func numberValue(_ value: Any?) -> CGFloat? {
        if let value = value as? CGFloat {
            return value
        }

        if let value = value as? NSNumber {
            return CGFloat(truncating: value)
        }

        return nil
    }
}

extension LiveWindowCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stopHandler?(error)
    }
}

enum LiveCaptureError: LocalizedError {
    case windowUnavailable

    var errorDescription: String? {
        switch self {
        case .windowUnavailable:
            return "The selected window is no longer available to ScreenCaptureKit."
        }
    }
}
