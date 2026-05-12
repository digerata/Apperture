import Foundation

struct RemoteClipboardMessage: Codable, Equatable {
    enum ContentKind: String, Codable {
        case plainText
    }

    var kind: ContentKind
    var text: String
    var sequenceNumber: UInt64

    init(text: String, sequenceNumber: UInt64) {
        self.kind = .plainText
        self.text = text
        self.sequenceNumber = sequenceNumber
    }
}
