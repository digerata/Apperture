import Foundation

struct RemoteVideoFormatMessage: Codable, Equatable {
    var width: Int
    var height: Int
    var sps: Data
    var pps: Data
}

struct RemoteStreamDiagnosticsMessage: Codable, Equatable {
    var captureWidth: Int
    var captureHeight: Int
    var encodedWidth: Int
    var encodedHeight: Int
    var captureFPS: Double
    var encodedFPS: Double
    var sentFPS: Double
    var bitrateMbps: Double
    var configuredBitrateMbps: Double
    var targetFPS: Double
    var videoQuality: Double
    var droppedFrames: Int
    var backpressureKeyFrames: Int
    var keyFrameInterval: Int
    var codec: String
    var capturePrepMS: Double
    var cgImageMS: Double
    var cropMS: Double
    var materializeMS: Double
    var pixelBufferMS: Double
    var encodeMS: Double
    var encoderQueueMS: Double
    var directFramePercent: Double
}

struct RemoteVideoFrameMessage: Codable, Equatable {
    var isKeyFrame: Bool
    var presentationTime: Double
    var duration: Double
    var data: Data

    func binaryPayload() -> Data {
        var payload = Data()
        payload.append(isKeyFrame ? 1 : 0)
        payload.appendBigEndian(presentationTime.bitPattern)
        payload.appendBigEndian(duration.bitPattern)
        payload.appendBigEndian(UInt32(data.count))
        payload.append(data)
        return payload
    }

    static func decodePayload(_ payload: Data) -> RemoteVideoFrameMessage? {
        let minimumHeaderByteCount = 1 + MemoryLayout<UInt64>.size * 2 + MemoryLayout<UInt32>.size
        guard payload.count >= minimumHeaderByteCount else {
            return try? JSONDecoder().decode(RemoteVideoFrameMessage.self, from: payload)
        }

        let isKeyFrame = payload[payload.startIndex] == 1
        var cursor = payload.index(after: payload.startIndex)

        guard let presentationTimeBits = payload.readBigEndianUInt64(from: &cursor),
              let durationBits = payload.readBigEndianUInt64(from: &cursor),
              let frameByteCount = payload.readBigEndianUInt32(from: &cursor) else {
            return nil
        }

        let frameByteCountValue = Int(frameByteCount)
        guard frameByteCountValue >= 0,
              payload.distance(from: cursor, to: payload.endIndex) == frameByteCountValue else {
            return nil
        }

        return RemoteVideoFrameMessage(
            isKeyFrame: isKeyFrame,
            presentationTime: Double(bitPattern: presentationTimeBits),
            duration: Double(bitPattern: durationBits),
            data: payload[cursor..<payload.endIndex]
        )
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt64) {
        var bigEndianValue = value.bigEndian
        append(Data(bytes: &bigEndianValue, count: MemoryLayout<UInt64>.size))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        var bigEndianValue = value.bigEndian
        append(Data(bytes: &bigEndianValue, count: MemoryLayout<UInt32>.size))
    }

    func readBigEndianUInt64(from cursor: inout Index) -> UInt64? {
        readBigEndianInteger(from: &cursor, byteCount: MemoryLayout<UInt64>.size, as: UInt64.self)
    }

    func readBigEndianUInt32(from cursor: inout Index) -> UInt32? {
        readBigEndianInteger(from: &cursor, byteCount: MemoryLayout<UInt32>.size, as: UInt32.self)
    }

    func readBigEndianInteger<T: FixedWidthInteger>(from cursor: inout Index, byteCount: Int, as type: T.Type) -> T? {
        guard distance(from: cursor, to: endIndex) >= byteCount else { return nil }

        var value: T = 0
        for _ in 0..<byteCount {
            value <<= 8
            value |= T(self[cursor])
            cursor = index(after: cursor)
        }

        return value
    }
}
