import AppKit
import CoreGraphics

final class RemoteInputInjectionService {
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private let focusSettleDelay: TimeInterval = 0.08
    private var isPointerDown = false

    func perform(_ message: RemoteControlMessage, in window: MirrorWindow, targetFrame: CGRect?) {
        let currentWindow = refreshedWindow(window)
        let point = screenPoint(for: message, in: targetFrame ?? currentWindow.frame)

        switch message.kind {
        case .pointerDown:
            prepareTargetForPointerDown(currentWindow, at: point)
            isPointerDown = true
            postMouseEvent(type: .leftMouseDown, at: point, clickState: 1)
        case .pointerMove:
            postMouseEvent(type: isPointerDown ? .leftMouseDragged : .mouseMoved, at: point, clickState: 0)
        case .pointerUp:
            postMouseEvent(type: .leftMouseUp, at: point, clickState: 1)
            isPointerDown = false
        case .scroll:
            prepareTargetForScroll(currentWindow, at: point)
            postMouseEvent(type: .mouseMoved, at: point, clickState: 0)
            postScroll(
                deltaX: message.scrollDeltaX,
                deltaY: message.scrollDeltaY,
                phase: message.scrollPhase ?? .changed
            )
        case .textInput:
            guard let text = message.text, !text.isEmpty else { return }
            prepareTargetForKeyboardInput(currentWindow)
            postText(text)
        case .keyPress:
            guard let key = message.key else { return }
            prepareTargetForKeyboardInput(currentWindow)
            postKey(key)
        case .requestWindowList, .selectWindow, .requestKeyFrame:
            return
        }
    }

    private func screenPoint(for message: RemoteControlMessage, in frame: CGRect) -> CGPoint {
        CGPoint(
            x: frame.minX + CGFloat(message.normalizedX) * frame.width,
            y: frame.minY + CGFloat(message.normalizedY) * frame.height
        )
    }

    private func prepareTargetForPointerDown(_ window: MirrorWindow, at point: CGPoint) {
        guard needsFocusRepair(window, at: point) else { return }

        bringTargetForward(window)
        Thread.sleep(forTimeInterval: focusSettleDelay)
    }

    private func prepareTargetForKeyboardInput(_ window: MirrorWindow) {
        let centerPoint = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard needsFocusRepair(window, at: centerPoint) else { return }

        bringTargetForward(window)
        Thread.sleep(forTimeInterval: focusSettleDelay)
    }

    private func needsFocusRepair(_ window: MirrorWindow, at point: CGPoint) -> Bool {
        let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontmostProcessID != window.processID {
            return true
        }

        guard let topWindow = topWindow(at: point) else { return false }
        return topWindow.id != window.id
    }

    private func bringTargetForward(_ window: MirrorWindow) {
        NSRunningApplication(processIdentifier: window.processID)?
            .activate(options: [.activateAllWindows])

        guard AXIsProcessTrusted() else { return }

        let appElement = AXUIElementCreateApplication(window.processID)
        guard let axWindow = matchingAXWindow(for: window, in: appElement) else { return }

        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, axWindow)
        AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
    }

    private func prepareTargetForScroll(_ window: MirrorWindow, at point: CGPoint) {
        guard needsFocusRepair(window, at: point) else { return }
        bringTargetForward(window)
    }

    private func refreshedWindow(_ window: MirrorWindow) -> MirrorWindow {
        guard let frame = currentFrame(for: window.id) else { return window }

        var updatedWindow = window
        updatedWindow.frame = frame
        return updatedWindow
    }

    private func currentFrame(for windowID: CGWindowID) -> CGRect? {
        guard let windowInfo = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let entry = windowInfo.first,
              let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }

        return CGRect(dictionaryRepresentation: boundsDictionary)
    }

    private func topWindow(at point: CGPoint) -> WindowStackEntry? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let currentProcessID = Int32(ProcessInfo.processInfo.processIdentifier)

        for entry in windowInfo {
            guard
                let rawWindowID = entry[kCGWindowNumber as String] as? UInt32,
                let processID = entry[kCGWindowOwnerPID as String] as? Int32,
                let layer = entry[kCGWindowLayer as String] as? Int,
                let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                continue
            }

            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            guard layer == 0 else { continue }
            guard alpha > 0 else { continue }
            guard processID != currentProcessID else { continue }
            guard frame.contains(point) else { continue }

            return WindowStackEntry(id: rawWindowID, processID: processID, frame: frame)
        }

        return nil
    }

    private func matchingAXWindow(for window: MirrorWindow, in appElement: AXUIElement) -> AXUIElement? {
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows) == .success,
              let axWindows = rawWindows as? [AXUIElement] else {
            return nil
        }

        return axWindows.compactMap { axWindow -> (element: AXUIElement, distance: CGFloat)? in
            guard let frame = frame(for: axWindow) else { return nil }
            return (axWindow, frameDistance(frame, window.frame))
        }
        .min { lhs, rhs in
            lhs.distance < rhs.distance
        }?
        .element
    }

    private func frame(for axWindow: AXUIElement) -> CGRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?

        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition,
              let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else {
            return nil
        }

        let positionValue = rawPosition as! AXValue
        let sizeValue = rawSize as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        return abs(lhs.minX - rhs.minX)
            + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }

    private func postMouseEvent(type: CGEventType, at point: CGPoint, clickState: Int64) {
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            return
        }

        event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.post(tap: .cghidEventTap)
    }

    private func postScroll(
        deltaX: Double,
        deltaY: Double,
        phase: RemoteControlMessage.ScrollPhase
    ) {
        let verticalDelta = Int32(max(min(deltaY, 320), -320))
        let horizontalDelta = Int32(max(min(deltaX, 320), -320))
        guard verticalDelta != 0 || horizontalDelta != 0,
              let event = CGEvent(
                scrollWheelEvent2Source: eventSource,
                units: .pixel,
                wheelCount: 2,
                wheel1: verticalDelta,
                wheel2: horizontalDelta,
                wheel3: 0
              ) else {
            return
        }

        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(verticalDelta))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(horizontalDelta))
        event.post(tap: .cghidEventTap)
    }

    private func postText(_ text: String) {
        for character in text {
            switch character {
            case "\n":
                postKey(.returnKey)
            case "\t":
                postKey(.tab)
            default:
                guard let keyStroke = KeyStroke(character: character) else { continue }
                postKeyStroke(keyStroke)
            }
        }
    }

    private func postKey(_ key: RemoteControlMessage.Key) {
        guard let keyCode = key.macVirtualKeyCode else { return }

        postKeyboardEvent(keyCode: keyCode, isKeyDown: true)
        postKeyboardEvent(keyCode: keyCode, isKeyDown: false)
    }

    private func postKeyStroke(_ keyStroke: KeyStroke) {
        let modifiers = ModifierKey.modifiers(for: keyStroke.flags)

        for modifier in modifiers {
            postModifierKey(modifier, isKeyDown: true)
        }

        postKeyboardEvent(keyCode: keyStroke.keyCode, flags: keyStroke.flags, isKeyDown: true)
        postKeyboardEvent(keyCode: keyStroke.keyCode, flags: keyStroke.flags, isKeyDown: false)

        for modifier in modifiers.reversed() {
            postModifierKey(modifier, isKeyDown: false)
        }
    }

    private func postKeyboardEvent(keyCode: CGKeyCode, flags: CGEventFlags = [], isKeyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: isKeyDown) else {
            return
        }

        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func postModifierKey(_ modifier: ModifierKey, isKeyDown: Bool) {
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: modifier.keyCode,
            keyDown: isKeyDown
        ) else {
            return
        }

        event.type = .flagsChanged
        event.flags = isKeyDown ? modifier.flag : []
        event.post(tap: .cghidEventTap)
    }
}

private struct WindowStackEntry {
    var id: UInt32
    var processID: Int32
    var frame: CGRect
}

private extension RemoteControlMessage.ScrollPhase {
    var scrollWheelPhase: NSEvent.Phase? {
        switch self {
        case .began:
            return .began
        case .changed:
            return .changed
        case .ended:
            return .ended
        case .cancelled:
            return .cancelled
        case .momentumBegan, .momentumChanged, .momentumEnded:
            return nil
        }
    }

    var scrollWheelMomentumPhase: NSEvent.Phase? {
        switch self {
        case .began, .changed, .ended, .cancelled:
            return nil
        case .momentumBegan:
            return .began
        case .momentumChanged:
            return .changed
        case .momentumEnded:
            return .ended
        }
    }

    var isTerminal: Bool {
        switch self {
        case .ended, .cancelled, .momentumEnded:
            return true
        case .began, .changed, .momentumBegan, .momentumChanged:
            return false
        }
    }
}

private extension RemoteControlMessage.Key {
    var macVirtualKeyCode: CGKeyCode? {
        switch self {
        case .deleteBackward:
            return 51
        case .returnKey:
            return 36
        case .tab:
            return 48
        case .escape:
            return 53
        }
    }
}

private struct KeyStroke {
    var keyCode: CGKeyCode
    var flags: CGEventFlags

    init?(character: Character) {
        let value = String(character)

        if let keyCode = Self.lowercaseKeyCodes[value.lowercased()], value.count == 1 {
            self.keyCode = keyCode
            self.flags = value == value.lowercased() ? [] : .maskShift
            return
        }

        if let keyCode = Self.unshiftedSymbolKeyCodes[value] {
            self.keyCode = keyCode
            self.flags = []
            return
        }

        if let keyCode = Self.shiftedSymbolKeyCodes[value] {
            self.keyCode = keyCode
            self.flags = .maskShift
            return
        }

        return nil
    }

    private static let lowercaseKeyCodes: [String: CGKeyCode] = [
        "a": 0,
        "s": 1,
        "d": 2,
        "f": 3,
        "h": 4,
        "g": 5,
        "z": 6,
        "x": 7,
        "c": 8,
        "v": 9,
        "b": 11,
        "q": 12,
        "w": 13,
        "e": 14,
        "r": 15,
        "y": 16,
        "t": 17,
        "o": 31,
        "u": 32,
        "i": 34,
        "p": 35,
        "l": 37,
        "j": 38,
        "k": 40,
        "n": 45,
        "m": 46
    ]

    private static let unshiftedSymbolKeyCodes: [String: CGKeyCode] = [
        "1": 18,
        "2": 19,
        "3": 20,
        "4": 21,
        "6": 22,
        "5": 23,
        "=": 24,
        "9": 25,
        "7": 26,
        "-": 27,
        "8": 28,
        "0": 29,
        "]": 30,
        "[": 33,
        "'": 39,
        ";": 41,
        "\\": 42,
        ",": 43,
        "/": 44,
        ".": 47,
        "`": 50,
        " ": 49
    ]

    private static let shiftedSymbolKeyCodes: [String: CGKeyCode] = [
        "!": 18,
        "@": 19,
        "#": 20,
        "$": 21,
        "^": 22,
        "%": 23,
        "+": 24,
        "(": 25,
        "&": 26,
        "_": 27,
        "*": 28,
        ")": 29,
        "}": 30,
        "{": 33,
        "\"": 39,
        ":": 41,
        "|": 42,
        "<": 43,
        "?": 44,
        ">": 47,
        "~": 50
    ]
}

private enum ModifierKey: CaseIterable {
    case shift

    var keyCode: CGKeyCode {
        switch self {
        case .shift:
            return 56
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .shift:
            return .maskShift
        }
    }

    static func modifiers(for flags: CGEventFlags) -> [ModifierKey] {
        allCases.filter { flags.contains($0.flag) }
    }
}
