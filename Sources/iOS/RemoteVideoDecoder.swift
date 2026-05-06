import CoreGraphics
import CoreMedia
import Foundation

final class RemoteVideoDecoder {
    typealias OutputHandler = (CMSampleBuffer, CGSize) -> Void

    private let queue = DispatchQueue(label: "com.mikewille.Apperture.video-decoder")
    private var formatDescription: CMVideoFormatDescription?

    func configure(_ message: RemoteVideoFormatMessage) {
        queue.async {
            let sps = Array(message.sps)
            let pps = Array(message.pps)
            let parameterSetSizes = [sps.count, pps.count]

            var formatDescription: CMFormatDescription?
            let status = sps.withUnsafeBufferPointer { spsPointer in
                pps.withUnsafeBufferPointer { ppsPointer in
                    let parameterSetPointers = [spsPointer.baseAddress!, ppsPointer.baseAddress!]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: parameterSetPointers,
                        parameterSetSizes: parameterSetSizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &formatDescription
                    )
                }
            }

            guard status == noErr, let formatDescription else { return }
            self.formatDescription = formatDescription
        }
    }

    func decode(_ message: RemoteVideoFrameMessage, outputHandler: @escaping OutputHandler) {
        queue.async {
            guard let sampleBuffer = self.makeSampleBuffer(from: message) else { return }
            let size = self.videoSize

            DispatchQueue.main.async {
                outputHandler(sampleBuffer, size)
            }
        }
    }

    func reset() {
        queue.async {
            self.formatDescription = nil
        }
    }

    private var videoSize: CGSize {
        guard let formatDescription else { return .zero }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        return CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
    }

    private func makeSampleBuffer(from message: RemoteVideoFrameMessage) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: message.data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: message.data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr,
            let blockBuffer else {
            return nil
        }

        message.data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: message.data.count
            )
        }

        let durationSeconds = message.duration.isFinite && message.duration > 0
            ? message.duration
            : 1.0 / RemoteFrameStreamConfiguration.targetFrameRate
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 600),
            presentationTimeStamp: CMTime(seconds: message.presentationTime, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var sampleSize = message.data.count
        var sampleBuffer: CMSampleBuffer?

        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }

        guard let sampleBuffer else { return nil }

        Self.configureAttachments(for: sampleBuffer, isKeyFrame: message.isKeyFrame)

        return sampleBuffer
    }

    private static func configureAttachments(for sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0,
              let rawAttachment = CFArrayGetValueAtIndex(attachments, 0) else {
            return
        }

        let attachment = unsafeBitCast(rawAttachment, to: CFMutableDictionary.self)
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )

        if !isKeyFrame {
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
    }
}
