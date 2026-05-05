import Foundation

enum RemoteFrameStreamConfiguration {
    enum PacketType: UInt8 {
        case frame = 0
        case wallpaper = 1
        case windowList = 2
        case videoFormat = 3
        case videoFrame = 4
    }

    static let bonjourType = "_apperture._tcp"
    static let bonjourDomain = "local."
    static let tcpPort: UInt16 = 58224
    static let maxFrameBytes = 24_000_000
    static let maxControlMessageBytes = 4_096
    static let targetFrameRate = 10.0
    static let jpegQuality = 0.48
    static let maxCapturePixelDimension = 1_600
    static let maxCapturePixels = 1_600_000
    static let videoBitRate = 1_200_000
    static let videoKeyFrameInterval = 30
}
