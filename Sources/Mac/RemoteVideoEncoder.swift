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

    func encode(_ image: CGImage, outputHandler: @escaping OutputHandler) {
        queue.async {
            guard !self.isEncoding else { return }
            self.isEncoding = true

            defer {
                self.isEncoding = false
            }

            do {
                try self.prepareSessionIfNeeded(width: image.width, height: image.height, outputHandler: outputHandler)
                guard let pixelBuffer = Self.makePixelBuffer(from: image) else { return }

                let frameRate = Int32(RemoteFrameStreamConfiguration.targetFrameRate.rounded())
                let frameDuration = CMTime(value: 1, timescale: frameRate)
                let presentationTime = CMTime(value: self.frameIndex, timescale: frameRate)
                self.frameIndex += 1

                guard let compressionSession = self.compressionSession else { return }
                let frameProperties: CFDictionary?
                if self.shouldForceNextKeyFrame {
                    self.shouldForceNextKeyFrame = false
                    frameProperties = [
                        kVTEncodeFrameOptionKey_ForceKeyFrame: true
                    ] as CFDictionary
                } else {
                    frameProperties = nil
                }

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
                    throw RemoteVideoEncoderError.cannotEncodeFrame(status)
                }

                VTCompressionSessionCompleteFrames(
                    compressionSession,
                    untilPresentationTimeStamp: presentationTime
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

    func invalidate() {
        queue.async {
            self.compressionSession.map(VTCompressionSessionInvalidate)
            self.compressionSession = nil
            self.formatDescription = nil
            self.currentSize = .zero
            self.frameIndex = 0
            self.isEncoding = false
            self.shouldForceNextKeyFrame = true
        }
    }

    private func prepareSessionIfNeeded(width: Int, height: Int, outputHandler: @escaping OutputHandler) throws {
        self.outputHandler = outputHandler
        let size = CGSize(width: width, height: height)
        guard compressionSession == nil || currentSize != size else { return }

        compressionSession.map(VTCompressionSessionInvalidate)
        compressionSession = nil
        formatDescription = nil
        lastFormat = nil
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
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: RemoteFrameStreamConfiguration.targetFrameRate as NSNumber
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: RemoteFrameStreamConfiguration.videoBitRate as NSNumber
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
        VTCompressionSessionPrepareToEncodeFrames(session)
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
    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let frameData = Self.sampleData(from: sampleBuffer) else {
            return
        }

        if let format = Self.formatMessage(from: formatDescription), format != lastFormat {
            lastFormat = format
            outputHandler?(.format(format))
        }

        outputHandler?(
            .frame(
                RemoteVideoFrameMessage(
                    isKeyFrame: Self.isKeyFrame(sampleBuffer),
                    presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds,
                    duration: CMSampleBufferGetDuration(sampleBuffer).seconds,
                    data: frameData
                )
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
    case frame(RemoteVideoFrameMessage)
}

private enum RemoteVideoEncoderError: Error {
    case cannotCreateSession(OSStatus)
    case cannotEncodeFrame(OSStatus)
}
