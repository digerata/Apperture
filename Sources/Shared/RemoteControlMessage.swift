import CoreGraphics
import Foundation

struct RemoteControlMessage: Codable, Equatable {
    enum Kind: String, Codable {
        case pointerDown
        case pointerMove
        case pointerUp
        case scroll
        case textInput
        case keyPress
        case requestWindowList
        case selectWindow
        case startStream
        case requestKeyFrame
    }

    enum Key: String, Codable {
        case deleteBackward
        case returnKey
        case tab
        case escape
    }

    enum ScrollPhase: String, Codable {
        case began
        case changed
        case ended
        case cancelled
        case momentumBegan
        case momentumChanged
        case momentumEnded
    }

    var kind: Kind
    var normalizedX: Double
    var normalizedY: Double
    var sequenceNumber: UInt64
    var text: String?
    var key: Key?
    var windowID: UInt32?
    var scrollDeltaX: Double
    var scrollDeltaY: Double
    var scrollPhase: ScrollPhase?

    init(kind: Kind, normalizedX: Double, normalizedY: Double, sequenceNumber: UInt64) {
        self.kind = kind
        self.normalizedX = min(max(normalizedX, 0), 1)
        self.normalizedY = min(max(normalizedY, 0), 1)
        self.sequenceNumber = sequenceNumber
        self.text = nil
        self.key = nil
        self.windowID = nil
        self.scrollDeltaX = 0
        self.scrollDeltaY = 0
        self.scrollPhase = nil
    }

    init(scrollAt point: CGPoint, delta: CGPoint, phase: ScrollPhase, sequenceNumber: UInt64) {
        self.kind = .scroll
        self.normalizedX = min(max(Double(point.x), 0), 1)
        self.normalizedY = min(max(Double(point.y), 0), 1)
        self.sequenceNumber = sequenceNumber
        self.text = nil
        self.key = nil
        self.windowID = nil
        self.scrollDeltaX = Double(delta.x)
        self.scrollDeltaY = Double(delta.y)
        self.scrollPhase = phase
    }

    init(text: String, sequenceNumber: UInt64) {
        self.kind = .textInput
        self.normalizedX = 0
        self.normalizedY = 0
        self.sequenceNumber = sequenceNumber
        self.text = text
        self.key = nil
        self.windowID = nil
        self.scrollDeltaX = 0
        self.scrollDeltaY = 0
        self.scrollPhase = nil
    }

    init(key: Key, sequenceNumber: UInt64) {
        self.kind = .keyPress
        self.normalizedX = 0
        self.normalizedY = 0
        self.sequenceNumber = sequenceNumber
        self.text = nil
        self.key = key
        self.windowID = nil
        self.scrollDeltaX = 0
        self.scrollDeltaY = 0
        self.scrollPhase = nil
    }

    init(requestWindowListWithSequenceNumber sequenceNumber: UInt64) {
        self.kind = .requestWindowList
        self.normalizedX = 0
        self.normalizedY = 0
        self.sequenceNumber = sequenceNumber
        self.text = nil
        self.key = nil
        self.windowID = nil
        self.scrollDeltaX = 0
        self.scrollDeltaY = 0
        self.scrollPhase = nil
    }

    init(selectWindowID windowID: UInt32, sequenceNumber: UInt64) {
        self.kind = .selectWindow
        self.normalizedX = 0
        self.normalizedY = 0
        self.sequenceNumber = sequenceNumber
        self.text = nil
        self.key = nil
        self.windowID = windowID
        self.scrollDeltaX = 0
        self.scrollDeltaY = 0
        self.scrollPhase = nil
    }

    init(startStreamWithSequenceNumber sequenceNumber: UInt64) {
        self.kind = .startStream
        self.normalizedX = 0
        self.normalizedY = 0
        self.sequenceNumber = sequenceNumber
        self.text = nil
        self.key = nil
        self.windowID = nil
        self.scrollDeltaX = 0
        self.scrollDeltaY = 0
        self.scrollPhase = nil
    }

    init(requestKeyFrameWithSequenceNumber sequenceNumber: UInt64) {
        self.kind = .requestKeyFrame
        self.normalizedX = 0
        self.normalizedY = 0
        self.sequenceNumber = sequenceNumber
        self.text = nil
        self.key = nil
        self.windowID = nil
        self.scrollDeltaX = 0
        self.scrollDeltaY = 0
        self.scrollPhase = nil
    }
}
