import Foundation

enum RemoteFrameStreamConfiguration {
    enum PacketType: UInt8 {
        case frame = 0
        case wallpaper = 1
        case windowList = 2
        case videoFormat = 3
        case videoFrame = 4
        case videoMask = 5
        case streamDiagnostics = 6
        case developerActivity = 7
        case streamReset = 8
    }

    static let bonjourType = "_apperture._tcp"
    static let bonjourDomain = "local."
    static let tcpPort: UInt16 = 58224
    static let maxFrameBytes = 24_000_000
    static let maxControlMessageBytes = 4_096
    static let targetFrameRate = 30.0
    static let jpegQuality = 0.48
    static let maxCapturePixelDimension = 2_560
    static let maxCapturePixels = 4_000_000
    static let videoBitRate = 8_000_000
    static let minimumAdaptiveVideoBitRate = 1_200_000
    static let maximumAdaptiveVideoBitRate = 10_000_000
    static let videoQuality = 0.72
    static let minimumAdaptiveVideoQuality = 0.42
    static let maximumAdaptiveVideoQuality = 0.76
    static let minimumAdaptiveFrameRate = 12.0
    static let maximumAdaptiveFrameRate = 30.0
    static let videoKeyFrameInterval = 60
    static let backpressureKeyFrameRequestInterval = 1.0
    static let enablesDirectCapturePixelBufferEncoding = true
}
