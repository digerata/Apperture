import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class RemoteVideoEncoder {
    typealias OutputHandler = (RemoteVideoEncoderOutput) -> Void

    private let queue = DispatchQueue(label: "com.mikewille.Apperture.video-encoder")
    private var compressionSession: VTCompressionSession?
    private var formatDescription: CMFormatDescription?
    private var frameIndex: Int64 = 0
    private var isEncoding = false
    private var currentSize = CGSize.zero
    private var outputHandler: OutputHandler?
    private var lastFormat: RemoteVideoFormatMessage?
    private var shouldForceNextKeyFrame = true
    private var pendingTimings: [Double: RemoteVideoEncodeTiming] = [:]
    private var targetBitRate = RemoteFrameStreamConfiguration.videoBitRate
    private var targetQuality = RemoteFrameStreamConfiguration.videoQuality
    private var targetFrameRate = RemoteFrameStreamConfiguration.targetFrameRate

    func encode(_ image: CGImage, outputHandler: @escaping OutputHandler) {
        let requestStart = DispatchTime.now().uptimeNanoseconds
        queue.async {
            guard !self.isEncoding else { return }
            self.isEncoding = true

            defer {
                self.isEncoding = false
            }

            do {
                try self.prepareSessionIfNeeded(width: image.width, height: image.height, outputHandler: outputHandler)
                let pixelBufferStart = DispatchTime.now().uptimeNanoseconds
                guard let pixelBuffer = Self.makePixelBuffer(from: image) else { return }
                let pixelBufferMilliseconds = Self.milliseconds(from: pixelBufferStart)

                try self.encodePreparedPixelBuffer(
                    pixelBuffer,
                    queueWaitMilliseconds: Self.milliseconds(from: requestStart),
                    pixelBufferMilliseconds: pixelBufferMilliseconds,
                    usedDirectPixelBuffer: false
                )
            } catch {
                self.invalidate()
            }
        }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, outputHandler: @escaping OutputHandler) {
        let requestStart = DispatchTime.now().uptimeNanoseconds
        queue.async {
            guard !self.isEncoding else { return }
            self.isEncoding = true

            defer {
                self.isEncoding = false
            }

            do {
                try self.prepareSessionIfNeeded(
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer),
                    outputHandler: outputHandler
                )

                try self.encodePreparedPixelBuffer(
                    pixelBuffer,
                    queueWaitMilliseconds: Self.milliseconds(from: requestStart),
                    pixelBufferMilliseconds: 0,
                    usedDirectPixelBuffer: true
                )
            } catch {
                self.invalidate()
            }
        }
    }

    func requestKeyFrame() {
        queue.async {
            self.shouldForceNextKeyFrame = true
        }
    }

    func updateAdaptiveSettings(bitRate: Int, quality: Double, frameRate: Double) {
        queue.async {
            self.targetBitRate = bitRate
            self.targetQuality = quality
            self.targetFrameRate = frameRate
            guard let compressionSession = self.compressionSession else { return }
            self.applyAdaptiveSettings(to: compressionSession)
        }
    }

    func invalidate() {
        queue.async {
            self.compressionSession.map(VTCompressionSessionInvalidate)
            self.compressionSession = nil
            self.formatDescription = nil
            self.currentSize = .zero
            self.frameIndex = 0
            self.isEncoding = false
            self.shouldForceNextKeyFrame = true
            self.pendingTimings.removeAll()
        }
    }

    private func encodePreparedPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        queueWaitMilliseconds: Double,
        pixelBufferMilliseconds: Double,
        usedDirectPixelBuffer: Bool
    ) throws {
        let frameRate = Int32(max(1, targetFrameRate.rounded()))
        let frameDuration = CMTime(value: 1, timescale: frameRate)
        let presentationTime = CMTime(value: frameIndex, timescale: frameRate)
        frameIndex += 1

        guard let compressionSession else { return }
        let frameProperties: CFDictionary?
        if shouldForceNextKeyFrame {
            shouldForceNextKeyFrame = false
            frameProperties = [
                kVTEncodeFrameOptionKey_ForceKeyFrame: true
            ] as CFDictionary
        } else {
            frameProperties = nil
        }

        let encodeStart = DispatchTime.now().uptimeNanoseconds
        pendingTimings[presentationTime.seconds] = RemoteVideoEncodeTiming(
            queueWaitMilliseconds: queueWaitMilliseconds,
            pixelBufferMilliseconds: pixelBufferMilliseconds,
            encodeMilliseconds: 0,
            usedDirectPixelBuffer: usedDirectPixelBuffer,
            encodeStartNanoseconds: encodeStart
        )

        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: frameDuration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        guard status == noErr else {
            pendingTimings.removeValue(forKey: presentationTime.seconds)
            throw RemoteVideoEncoderError.cannotEncodeFrame(status)
        }

        VTCompressionSessionCompleteFrames(
            compressionSession,
            untilPresentationTimeStamp: presentationTime
        )
    }

    private func prepareSessionIfNeeded(width: Int, height: Int, outputHandler: @escaping OutputHandler) throws {
        self.outputHandler = outputHandler
        let size = CGSize(width: width, height: height)
        guard compressionSession == nil || currentSize != size else { return }

        compressionSession.map(VTCompressionSessionInvalidate)
        compressionSession = nil
        formatDescription = nil
        lastFormat = nil
        pendingTimings.removeAll()
        currentSize = size
        frameIndex = 0
        shouldForceNextKeyFrame = true

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw RemoteVideoEncoderError.cannotCreateSession(status)
        }

        compressionSession = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxFrameDelayCount,
            value: 1 as NSNumber
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_Quality,
            value: targetQuality as NSNumber
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: targetFrameRate as NSNumber
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: targetBitRate as NSNumber
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: RemoteFrameStreamConfiguration.videoKeyFrameInterval as NSNumber
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: (Double(RemoteFrameStreamConfiguration.videoKeyFrameInterval) / RemoteFrameStreamConfiguration.targetFrameRate) as NSNumber
        )
        applyAdaptiveSettings(to: session)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func applyAdaptiveSettings(to session: VTCompressionSession) {
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_Quality,
            value: targetQuality as NSNumber
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: targetFrameRate as NSNumber
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: targetBitRate as NSNumber
        )
    }

    private static let outputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard status == noErr,
              let refcon,
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        let encoder = Unmanaged<RemoteVideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
        encoder.handle(sampleBuffer)
    }

    private static func makePixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ] as CFDictionary

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            image.width,
            image.height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixelBuffer
    }

    private static func milliseconds(from start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let frameData = Self.sampleData(from: sampleBuffer) else {
            return
        }

        if let format = Self.formatMessage(from: formatDescription), format != lastFormat {
            lastFormat = format
            outputHandler?(.format(format))
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        var timing = pendingTimings.removeValue(forKey: presentationTime) ?? RemoteVideoEncodeTiming()
        if timing.encodeStartNanoseconds > 0 {
            timing.encodeMilliseconds = Self.milliseconds(from: timing.encodeStartNanoseconds)
            timing.encodeStartNanoseconds = 0
        }

        outputHandler?(
            .frame(
                RemoteVideoFrameMessage(
                    isKeyFrame: Self.isKeyFrame(sampleBuffer),
                    presentationTime: presentationTime,
                    duration: CMSampleBufferGetDuration(sampleBuffer).seconds,
                    data: frameData
                ),
                timing
            )
        )
    }

    private static func formatMessage(from formatDescription: CMFormatDescription) -> RemoteVideoFormatMessage? {
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var spsCount = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        var ppsCount = 0
        var nalHeaderLength: Int32 = 0

        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: &nalHeaderLength
        ) == noErr,
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPointer,
                parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: &ppsCount,
                nalUnitHeaderLengthOut: &nalHeaderLength
            ) == noErr,
            let spsPointer,
            let ppsPointer else {
            return nil
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        return RemoteVideoFormatMessage(
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            sps: Data(bytes: spsPointer, count: spsSize),
            pps: Data(bytes: ppsPointer, count: ppsSize)
        )
    }

    private static func sampleData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var length = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == noErr,
            let dataPointer else {
            return nil
        }

        return Data(bytes: dataPointer, count: totalLength)
    }

    private static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let firstAttachment = attachments.first else {
            return true
        }

        return firstAttachment[kCMSampleAttachmentKey_NotSync] == nil
    }
}

enum RemoteVideoEncoderOutput {
    case format(RemoteVideoFormatMessage)
    case frame(RemoteVideoFrameMessage, RemoteVideoEncodeTiming)
}

struct RemoteVideoEncodeTiming {
    var queueWaitMilliseconds: Double = 0
    var pixelBufferMilliseconds: Double = 0
    var encodeMilliseconds: Double = 0
    var usedDirectPixelBuffer = false
    fileprivate var encodeStartNanoseconds: UInt64 = 0
}

private enum RemoteVideoEncoderError: Error {
    case cannotCreateSession(OSStatus)
    case cannotEncodeFrame(OSStatus)
}
