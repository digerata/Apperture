import Foundation

struct RemoteVideoFormatMessage: Codable, Equatable {
    var width: Int
    var height: Int
    var sps: Data
    var pps: Data
}

struct RemoteVideoFrameMessage: Codable, Equatable {
    var isKeyFrame: Bool
    var presentationTime: Double
    var duration: Double
    var data: Data
}
