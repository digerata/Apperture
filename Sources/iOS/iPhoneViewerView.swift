import AVFoundation
import Combine
import UIKit

final class iPhoneViewerViewController: UIViewController {
    private let streamClient = RemoteFrameStreamClient()
    private var cancellables = Set<AnyCancellable>()
    private var nextSequenceNumber: UInt64 = 0

    private let fallbackWallpaperView = FallbackWallpaperView()
    private let wallpaperImageView = UIImageView()
    private let mirrorCanvasView = MirrorCanvasView()
    private let toolbarView = ViewerToolbarView()
    private let keyboardInputView = KeyboardInputView()
    private let fpsOverlayLabel = UILabel()
    private var currentDefaultLayoutMode: MirrorLayoutMode?
    private var mirrorLeadingConstraint: NSLayoutConstraint?
    private var mirrorTrailingConstraint: NSLayoutConstraint?
    private var mirrorTopConstraint: NSLayoutConstraint?
    private var mirrorBottomConstraint: NSLayoutConstraint?
    private var frameTimestamps: [CFTimeInterval] = []
    private var displayedFPS: Double?
    private var latestStreamDiagnostics: RemoteStreamDiagnosticsMessage?

    private var isKeyboardPresented = false {
        didSet {
            toolbarView.isKeyboardPresented = isKeyboardPresented

            if isKeyboardPresented {
                keyboardInputView.becomeFirstResponder()
            } else {
                keyboardInputView.resignFirstResponder()
            }
        }
    }

    override var prefersStatusBarHidden: Bool { true }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        [.portrait, .landscapeLeft, .landscapeRight]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.11, green: 0.14, blue: 0.20, alpha: 1)
        configureSubviews()
        configureCallbacks()
        bindStreamClient()
        streamClient.start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateChromeLayoutForCurrentSize()
        updateDefaultLayoutModeForCurrentSize()
    }

    private func configureSubviews() {
        fallbackWallpaperView.translatesAutoresizingMaskIntoConstraints = false

        wallpaperImageView.translatesAutoresizingMaskIntoConstraints = false
        wallpaperImageView.contentMode = .scaleAspectFill
        wallpaperImageView.clipsToBounds = true
        wallpaperImageView.isHidden = true

        mirrorCanvasView.translatesAutoresizingMaskIntoConstraints = false
        mirrorCanvasView.layoutMode = .fitHeight

        toolbarView.translatesAutoresizingMaskIntoConstraints = false

        keyboardInputView.translatesAutoresizingMaskIntoConstraints = false
        keyboardInputView.alpha = 0.01
        keyboardInputView.isAccessibilityElement = false

        fpsOverlayLabel.translatesAutoresizingMaskIntoConstraints = false
        fpsOverlayLabel.backgroundColor = UIColor.black.withAlphaComponent(0.48)
        fpsOverlayLabel.textColor = .white
        fpsOverlayLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        fpsOverlayLabel.textAlignment = .left
        fpsOverlayLabel.numberOfLines = 0
        fpsOverlayLabel.layer.cornerRadius = 7
        fpsOverlayLabel.layer.cornerCurve = .continuous
        fpsOverlayLabel.clipsToBounds = true
        fpsOverlayLabel.text = "FPS --"
        fpsOverlayLabel.isHidden = true

        view.addSubview(fallbackWallpaperView)
        view.addSubview(wallpaperImageView)
        view.addSubview(mirrorCanvasView)
        view.addSubview(toolbarView)
        view.addSubview(fpsOverlayLabel)
        view.addSubview(keyboardInputView)

        let mirrorLeadingConstraint = mirrorCanvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        let mirrorTrailingConstraint = mirrorCanvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        let mirrorTopConstraint = mirrorCanvasView.topAnchor.constraint(equalTo: view.topAnchor, constant: 76)
        let mirrorBottomConstraint = mirrorCanvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        self.mirrorLeadingConstraint = mirrorLeadingConstraint
        self.mirrorTrailingConstraint = mirrorTrailingConstraint
        self.mirrorTopConstraint = mirrorTopConstraint
        self.mirrorBottomConstraint = mirrorBottomConstraint

        NSLayoutConstraint.activate([
            fallbackWallpaperView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fallbackWallpaperView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fallbackWallpaperView.topAnchor.constraint(equalTo: view.topAnchor),
            fallbackWallpaperView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            wallpaperImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wallpaperImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            wallpaperImageView.topAnchor.constraint(equalTo: view.topAnchor),
            wallpaperImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            mirrorLeadingConstraint,
            mirrorTrailingConstraint,
            mirrorTopConstraint,
            mirrorBottomConstraint,

            toolbarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarView.topAnchor.constraint(equalTo: view.topAnchor),
            toolbarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            fpsOverlayLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            fpsOverlayLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            fpsOverlayLabel.widthAnchor.constraint(equalToConstant: 176),
            fpsOverlayLabel.heightAnchor.constraint(equalToConstant: 84),

            keyboardInputView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardInputView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            keyboardInputView.widthAnchor.constraint(equalToConstant: 1),
            keyboardInputView.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    private func configureCallbacks() {
        mirrorCanvasView.onPointerEvent = { [weak self] kind, point in
            self?.sendPointerEvent(kind: kind, point: point)
        }

        toolbarView.onLayoutModeChanged = { [weak self] layoutMode in
            self?.setLayoutMode(layoutMode)
        }

        toolbarView.onRequestWindowList = { [weak self] in
            self?.requestWindowList()
        }

        toolbarView.onWindowSelected = { [weak self] window in
            self?.selectWindow(window)
        }

        toolbarView.onKeyboardTapped = { [weak self] in
            guard let self else { return }
            isKeyboardPresented.toggle()
        }

        toolbarView.onManualConnectTapped = { [weak self] in
            self?.presentManualConnectAlert()
        }

        toolbarView.onForgetManualEndpointTapped = { [weak self] in
            self?.streamClient.forgetManualEndpoint()
        }

        toolbarView.onDiagnosticsTapped = { [weak self] in
            self?.presentConnectionDiagnostics()
        }

        toolbarView.onExitTapped = { [weak self] in
            self?.toggleStreamConnection()
        }

        keyboardInputView.onTextInput = { [weak self] text in
            self?.sendTextInput(text)
        }

        keyboardInputView.onKeyPress = { [weak self] key in
            self?.sendKeyPress(key)
        }
    }

    private func bindStreamClient() {
        streamClient.$latestFrame
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                self?.mirrorCanvasView.image = image
                self?.recordDisplayedFrame(image)
            }
            .store(in: &cancellables)

        streamClient.$videoFrameSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                self?.mirrorCanvasView.videoSourceSize = size
            }
            .store(in: &cancellables)

        streamClient.videoSampleBuffers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sampleBuffer in
                guard let self else { return }
                if mirrorCanvasView.enqueueVideoSampleBuffer(sampleBuffer) {
                    recordDisplayedFrame()
                }
            }
            .store(in: &cancellables)

        streamClient.$latestFrameMask
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mask in
                self?.mirrorCanvasView.maskImage = mask
            }
            .store(in: &cancellables)

        streamClient.$wallpaper
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                self?.wallpaperImageView.image = image
                self?.wallpaperImageView.isHidden = image == nil
            }
            .store(in: &cancellables)

        streamClient.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.mirrorCanvasView.streamState = state
                self?.toolbarView.streamState = state
                if case .connected = state {
                    self?.requestWindowList()
                }
            }
            .store(in: &cancellables)

        streamClient.$windows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] windows in
                self?.toolbarView.windows = windows
            }
            .store(in: &cancellables)

        streamClient.$manualEndpointDescription
            .receive(on: DispatchQueue.main)
            .sink { [weak self] endpoint in
                self?.toolbarView.manualEndpointDescription = endpoint
            }
            .store(in: &cancellables)

        streamClient.$streamDiagnostics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] diagnostics in
                self?.latestStreamDiagnostics = diagnostics
                self?.updateFrameRateOverlay()
            }
            .store(in: &cancellables)
    }

    private func sendPointerEvent(kind: RemoteControlMessage.Kind, point: CGPoint) {
        nextSequenceNumber += 1
        streamClient.send(
            RemoteControlMessage(
                kind: kind,
                normalizedX: Double(point.x),
                normalizedY: Double(point.y),
                sequenceNumber: nextSequenceNumber
            )
        )
    }

    private func sendTextInput(_ text: String) {
        guard !text.isEmpty else { return }
        nextSequenceNumber += 1
        streamClient.send(RemoteControlMessage(text: text, sequenceNumber: nextSequenceNumber))
    }

    private func sendKeyPress(_ key: RemoteControlMessage.Key) {
        nextSequenceNumber += 1
        streamClient.send(RemoteControlMessage(key: key, sequenceNumber: nextSequenceNumber))
    }

    private func requestWindowList() {
        nextSequenceNumber += 1
        streamClient.send(RemoteControlMessage(requestWindowListWithSequenceNumber: nextSequenceNumber))
    }

    private func selectWindow(_ window: RemoteWindowSummary) {
        resetFrameRateOverlay()
        streamClient.clearCurrentFrame()
        nextSequenceNumber += 1
        streamClient.send(RemoteControlMessage(selectWindowID: window.id, sequenceNumber: nextSequenceNumber))
    }

    private func recordDisplayedFrame(_ image: UIImage?) {
        guard image != nil else {
            resetFrameRateOverlay()
            return
        }

        recordDisplayedFrame()
    }

    private func recordDisplayedFrame() {
        let now = CACurrentMediaTime()
        frameTimestamps.append(now)
        frameTimestamps.removeAll { now - $0 > 2.0 }

        guard let firstTimestamp = frameTimestamps.first,
              let lastTimestamp = frameTimestamps.last,
              lastTimestamp > firstTimestamp,
              frameTimestamps.count > 1 else {
            fpsOverlayLabel.text = "FPS --"
            fpsOverlayLabel.isHidden = false
            return
        }

        displayedFPS = Double(frameTimestamps.count - 1) / (lastTimestamp - firstTimestamp)
        updateFrameRateOverlay()
    }

    private func resetFrameRateOverlay() {
        frameTimestamps.removeAll()
        displayedFPS = nil
        latestStreamDiagnostics = nil
        fpsOverlayLabel.text = "FPS --"
        fpsOverlayLabel.isHidden = true
    }

    private func updateFrameRateOverlay() {
        guard displayedFPS != nil || latestStreamDiagnostics != nil else {
            fpsOverlayLabel.text = "FPS --"
            fpsOverlayLabel.isHidden = false
            return
        }

        let displayFPS = displayedFPS.map { String(format: "%.1f", $0) } ?? "--"
        guard let diagnostics = latestStreamDiagnostics else {
            fpsOverlayLabel.text = "Render \(displayFPS) fps"
            fpsOverlayLabel.isHidden = false
            return
        }

        fpsOverlayLabel.text = String(
            format: "Render %@ fps\nCap %.1f Enc %.1f Send %.1f\n%d x %d  %.1f/%.1f Mbps\nDrop %d  KF %d",
            displayFPS,
            diagnostics.captureFPS,
            diagnostics.encodedFPS,
            diagnostics.sentFPS,
            diagnostics.encodedWidth,
            diagnostics.encodedHeight,
            diagnostics.bitrateMbps,
            diagnostics.configuredBitrateMbps,
            diagnostics.droppedFrames,
            diagnostics.keyFrameInterval
        )
        fpsOverlayLabel.isHidden = false
    }

    private func updateDefaultLayoutModeForCurrentSize() {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }

        let defaultLayoutMode: MirrorLayoutMode = view.bounds.width > view.bounds.height
            ? .fitWidth
            : .fitHeight

        guard currentDefaultLayoutMode != defaultLayoutMode else { return }
        currentDefaultLayoutMode = defaultLayoutMode
        setLayoutMode(defaultLayoutMode)
    }

    private func updateChromeLayoutForCurrentSize() {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }

        let isLandscape = view.bounds.width > view.bounds.height
        toolbarView.usesLandscapeLayout = isLandscape
        mirrorLeadingConstraint?.constant = isLandscape ? max(16, view.safeAreaInsets.left + 16) : 0
        mirrorTrailingConstraint?.constant = isLandscape ? -max(16, view.safeAreaInsets.right + 16) : 0
        mirrorTopConstraint?.constant = isLandscape ? 0 : 76
        mirrorBottomConstraint?.constant = isLandscape ? 0 : -8
    }

    private func setLayoutMode(_ layoutMode: MirrorLayoutMode) {
        mirrorCanvasView.layoutMode = layoutMode
        toolbarView.setLayoutMode(layoutMode)
    }

    private func toggleStreamConnection() {
        switch streamClient.state {
        case .idle, .failed:
            streamClient.restart()
        case .searching, .connecting, .connected, .live:
            streamClient.stop()
        }
    }

    private func presentManualConnectAlert() {
        let alert = UIAlertController(
            title: "Connect to Mac",
            message: "Enter the Mac's Tailscale IP, MagicDNS name, or hostname.",
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] textField in
            textField.placeholder = "100.x.y.z or mac-name"
            textField.text = self?.streamClient.manualEndpointDescription
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
            textField.clearButtonMode = .whileEditing
            textField.keyboardType = .URL
            textField.returnKeyType = .go
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let input = alert?.textFields?.first?.text ?? ""
            if let errorMessage = streamClient.connectManually(to: input) {
                presentManualConnectError(errorMessage)
            }
        })

        present(alert, animated: true)
    }

    private func presentManualConnectError(_ message: String) {
        let alert = UIAlertController(title: "Cannot Connect", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func presentConnectionDiagnostics() {
        let report = streamClient.diagnosticsReport
        let alert = UIAlertController(
            title: "Connection Diagnostics",
            message: report,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Copy", style: .default) { _ in
            UIPasteboard.general.string = report
        })
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }
}

private final class ViewerToolbarView: UIView {
    var streamState: RemoteFrameStreamState = .idle {
        didSet {
            updateStatusColor()
            updateConnectionButton()
        }
    }

    var isKeyboardPresented = false {
        didSet { updateKeyboardButton() }
    }

    var onExitTapped: () -> Void = {}
    var onKeyboardTapped: () -> Void = {}
    var onManualConnectTapped: () -> Void = {}
    var onForgetManualEndpointTapped: () -> Void = {}
    var onDiagnosticsTapped: () -> Void = {}
    var onRequestWindowList: () -> Void = {}
    var onWindowSelected: (RemoteWindowSummary) -> Void = { _ in }
    var onLayoutModeChanged: (MirrorLayoutMode) -> Void = { _ in }
    var windows: [RemoteWindowSummary] = [] {
        didSet {
            updateConnectionMenu()
        }
    }
    var manualEndpointDescription: String? {
        didSet {
            updateConnectionMenu()
            updateSettingsMenu()
        }
    }

    private var layoutMode: MirrorLayoutMode = .fitHeight
    private let exitButton = ViewerToolbarView.makeButton(systemName: "rectangle.portrait.and.arrow.right")
    private let keyboardButton = ViewerToolbarView.makeButton(systemName: "keyboard")
    private let settingsButton = ViewerToolbarView.makeButton(systemName: "gearshape")
    private let statusDotView = UIView()
    private let rightStackView = UIStackView()
    var usesLandscapeLayout = false {
        didSet {
            guard usesLandscapeLayout != oldValue else { return }
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSubviews()
        configureActions()
        updateStatusColor()
        updateConnectionButton()
        updateKeyboardButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureSubviews() {
        isUserInteractionEnabled = true

        exitButton.translatesAutoresizingMaskIntoConstraints = false
        exitButton.showsMenuAsPrimaryAction = true
        rightStackView.translatesAutoresizingMaskIntoConstraints = false
        rightStackView.alignment = .center
        rightStackView.distribution = .fill
        rightStackView.spacing = 8

        rightStackView.addArrangedSubview(keyboardButton)
        rightStackView.addArrangedSubview(settingsButton)

        addSubview(exitButton)
        addSubview(rightStackView)

        statusDotView.translatesAutoresizingMaskIntoConstraints = false
        statusDotView.layer.cornerRadius = 4
        statusDotView.layer.borderWidth = 1
        statusDotView.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        settingsButton.addSubview(statusDotView)

        NSLayoutConstraint.activate([
            statusDotView.leadingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: 8),
            statusDotView.topAnchor.constraint(equalTo: settingsButton.topAnchor, constant: 8),
            statusDotView.widthAnchor.constraint(equalToConstant: 8),
            statusDotView.heightAnchor.constraint(equalToConstant: 8)
        ])
    }

    private func configureActions() {
        keyboardButton.addAction(UIAction { [weak self] _ in
            self?.onKeyboardTapped()
        }, for: .touchUpInside)

        settingsButton.showsMenuAsPrimaryAction = true
        updateConnectionMenu()
        updateSettingsMenu()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        if usesLandscapeLayout {
            let leftInset = max(20, safeAreaInsets.left + 20)
            let railCenterY = bounds.height / 2

            exitButton.transform = CGAffineTransform(rotationAngle: .pi / 2)
            keyboardButton.transform = CGAffineTransform(rotationAngle: .pi / 2)
            settingsButton.transform = CGAffineTransform(rotationAngle: .pi / 2)

            exitButton.frame = CGRect(x: leftInset, y: railCenterY - 22, width: 44, height: 44)
            rightStackView.axis = .vertical
            rightStackView.frame = CGRect(x: leftInset, y: railCenterY + 52, width: 44, height: 96)
        } else {
            exitButton.transform = .identity
            keyboardButton.transform = .identity
            settingsButton.transform = .identity

            exitButton.frame = CGRect(x: 20, y: 20, width: 44, height: 44)
            rightStackView.axis = .horizontal
            rightStackView.frame = CGRect(x: bounds.width - 116, y: 20, width: 96, height: 44)
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        [exitButton, keyboardButton, settingsButton].contains { button in
            button.point(inside: convert(point, to: button), with: event)
        }
    }

    private func updateSettingsMenu() {
        settingsButton.menu = UIMenu(
            children: [
                UIMenu(
                    title: "View",
                    options: .displayInline,
                    children: layoutMenuActions()
                ),
                UIMenu(
                    title: "Connection",
                    options: .displayInline,
                    children: settingsConnectionActions()
                )
            ]
        )
    }

    private func layoutMenuActions() -> [UIMenuElement] {
        MirrorLayoutMode.allCases.map { mode in
            UIAction(
                title: mode.title,
                image: UIImage(systemName: mode.symbolName),
                state: mode == layoutMode ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                setLayoutMode(mode)
                onLayoutModeChanged(mode)
            }
        }
    }

    private func settingsConnectionActions() -> [UIMenuElement] {
        var actions: [UIMenuElement] = [
            UIAction(
                title: "Connect to Mac",
                subtitle: manualEndpointDescription,
                image: UIImage(systemName: "network")
            ) { [weak self] _ in
                self?.onManualConnectTapped()
            }
        ]

        if manualEndpointDescription != nil {
            actions.append(
                UIAction(
                    title: "Forget Direct Mac",
                    image: UIImage(systemName: "xmark.circle"),
                    attributes: .destructive
                ) { [weak self] _ in
                    self?.onForgetManualEndpointTapped()
                }
            )
        }

        actions.append(
            UIAction(
                title: "Diagnostics",
                image: UIImage(systemName: "stethoscope")
            ) { [weak self] _ in
                self?.onDiagnosticsTapped()
            }
        )

        return actions
    }

    private func updateConnectionMenu() {
        exitButton.menu = UIMenu(
            title: "Connection",
            children: connectionMenuActions() + windowMenuActions()
        )
    }

    private func connectionMenuActions() -> [UIMenuElement] {
        let title: String
        let imageName: String

        switch streamState {
        case .idle, .failed:
            title = "Reconnect"
            imageName = "arrow.clockwise"
        case .searching, .connecting, .connected, .live:
            title = "Disconnect"
            imageName = "rectangle.portrait.and.arrow.right"
        }

        return [
            UIAction(title: title, image: UIImage(systemName: imageName)) { [weak self] _ in
                self?.onExitTapped()
            }
        ]
    }

    private func windowMenuActions() -> [UIMenuElement] {
        let selectableWindows = windows.filter { window in
            #if targetEnvironment(simulator)
            !window.isSimulator
            #else
            true
            #endif
        }

        let refreshAction = UIAction(
            title: "Refresh Apps",
            image: UIImage(systemName: "arrow.clockwise")
        ) { [weak self] _ in
            self?.onRequestWindowList()
        }

        guard !selectableWindows.isEmpty else {
            return [refreshAction]
        }

        return [refreshAction] + selectableWindows.map { window in
            UIAction(
                title: window.title,
                subtitle: window.subtitle,
                image: UIImage(systemName: window.isSimulator ? "iphone.gen3" : "macwindow"),
                state: window.isSelected ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                onWindowSelected(window)
            }
        }
    }

    func setLayoutMode(_ mode: MirrorLayoutMode) {
        guard layoutMode != mode else { return }
        layoutMode = mode
        updateSettingsMenu()
    }

    private func updateStatusColor() {
        statusDotView.backgroundColor = streamState.indicatorColor
    }

    private func updateConnectionButton() {
        let systemName: String

        switch streamState {
        case .idle, .failed:
            systemName = "arrow.clockwise"
        case .searching, .connecting, .connected, .live:
            systemName = "rectangle.portrait.and.arrow.right"
        }

        exitButton.setImage(UIImage(systemName: systemName), for: .normal)
        updateConnectionMenu()
    }

    private func updateKeyboardButton() {
        keyboardButton.backgroundColor = isKeyboardPresented
            ? UIColor.systemBlue.withAlphaComponent(0.48)
            : UIColor.black.withAlphaComponent(0.18)
    }

    private static func makeButton(systemName: String) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        button.layer.cornerRadius = 22
        button.layer.cornerCurve = .continuous
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.contentVerticalAlignment = .center
        button.contentHorizontalAlignment = .center
        button.imageView?.contentMode = .scaleAspectFit
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 22, weight: .medium),
            forImageIn: .normal
        )

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])

        return button
    }
}

private final class MirrorCanvasView: UIView {
    var image: UIImage? {
        didSet {
            if image != nil {
                videoSourceSize = nil
                videoRenderView.flush()
            }
            imageView.image = image
            updateContentVisibility()
            updateScrollableContent(resetOffsetIfNeeded: false)
        }
    }

    var videoSourceSize: CGSize? {
        didSet {
            if videoSourceSize != nil {
                if oldValue != videoSourceSize {
                    videoRenderView.flush()
                }
                imageView.image = nil
            } else {
                videoRenderView.flush()
            }
            updateContentVisibility()
            updateScrollableContent(resetOffsetIfNeeded: false)
        }
    }

    var maskImage: UIImage? {
        didSet {
            updateImageMask()
        }
    }

    var streamState: RemoteFrameStreamState = .idle {
        didSet {
            placeholderView.configure(state: streamState)
        }
    }

    var layoutMode: MirrorLayoutMode = .fitHeight {
        didSet {
            updateScrollableContent(resetOffsetIfNeeded: true)
        }
    }

    var onPointerEvent: (RemoteControlMessage.Kind, CGPoint) -> Void = { _, _ in }

    private let scrollView = TwoFingerScrollView()
    private let contentView = UIView()
    private let shadowView = UIView()
    private let videoRenderView = VideoRenderView()
    private let imageView = UIImageView()
    private let imageMaskLayer = CALayer()
    private let pointerSurfaceView = PointerSurfaceView()
    private let placeholderView = StreamPlaceholderView()
    private var lastShadowBounds = CGRect.zero
    private var lastContentSize = CGSize.zero
    private let viewportPadding: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        scrollView.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 1
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bounces = true
        scrollView.decelerationRate = .normal
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 2
        scrollView.clipsToBounds = true

        contentView.backgroundColor = .clear
        contentView.isUserInteractionEnabled = true

        shadowView.isUserInteractionEnabled = false
        shadowView.backgroundColor = .clear
        shadowView.layer.shadowColor = UIColor.black.cgColor
        shadowView.layer.shadowOpacity = 0.28
        shadowView.layer.shadowRadius = 18
        shadowView.layer.shadowOffset = CGSize(width: 0, height: 10)
        shadowView.layer.shouldRasterize = true
        shadowView.layer.rasterizationScale = UIScreen.main.scale

        videoRenderView.clipsToBounds = true
        videoRenderView.layer.cornerRadius = 8
        videoRenderView.layer.cornerCurve = .continuous
        videoRenderView.isUserInteractionEnabled = false
        videoRenderView.isHidden = true

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 8
        imageView.layer.cornerCurve = .continuous
        imageView.isUserInteractionEnabled = false

        pointerSurfaceView.onPointerEvent = { [weak self] kind, point in
            self?.onPointerEvent(kind, point)
        }

        placeholderView.isUserInteractionEnabled = false

        addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(shadowView)
        contentView.addSubview(videoRenderView)
        contentView.addSubview(imageView)
        contentView.addSubview(pointerSurfaceView)
        addSubview(placeholderView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateScrollableContent(resetOffsetIfNeeded: false)
    }

    @discardableResult
    func enqueueVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        imageView.image = nil
        let didEnqueue = videoRenderView.enqueue(sampleBuffer)
        updateContentVisibility()
        return didEnqueue
    }

    private func updateScrollableContent(resetOffsetIfNeeded: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let previousContentSize = scrollView.contentSize
        let previousOffset = scrollView.contentOffset
        let size = renderedSize
        let contentSize = CGSize(
            width: scrollsHorizontally ? max(bounds.width, size.width + viewportPadding * 2) : bounds.width,
            height: scrollsVertically ? max(bounds.height, size.height + viewportPadding * 2) : bounds.height
        )
        let frame = CGRect(
            x: scrollsHorizontally ? viewportPadding : (contentSize.width - size.width) / 2,
            y: scrollsVertically ? viewportPadding : (contentSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        scrollView.frame = bounds
        scrollView.contentSize = contentSize
        scrollView.alwaysBounceHorizontal = scrollsHorizontally
        scrollView.alwaysBounceVertical = scrollsVertically
        scrollView.isDirectionalLockEnabled = true
        contentView.frame = CGRect(origin: .zero, size: contentSize)
        shadowView.frame = frame
        videoRenderView.frame = frame
        imageView.frame = frame
        updateImageMask()
        pointerSurfaceView.frame = contentView.bounds
        pointerSurfaceView.imageFrame = hasContent ? frame : nil
        placeholderView.frame = placeholderRect

        if shadowView.bounds != lastShadowBounds {
            lastShadowBounds = shadowView.bounds
            shadowView.layer.shadowPath = UIBezierPath(
                roundedRect: shadowView.bounds,
                cornerRadius: renderCornerRadius
            ).cgPath
        }

        CATransaction.commit()

        let shouldResetOffset = resetOffsetIfNeeded || previousContentSize == .zero
        if shouldResetOffset {
            scrollView.setContentOffset(.zero, animated: false)
        } else if previousContentSize != contentSize {
            scrollView.setContentOffset(
                clampedContentOffset(previousOffset, contentSize: contentSize),
                animated: false
            )
        }
    }

    private func updateImageMask() {
        imageView.layer.mask = nil
        videoRenderView.layer.mask = nil

        guard let maskImage, let targetLayer = activeRenderLayer else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageMaskLayer.frame = targetLayer.bounds
        imageMaskLayer.contents = maskImage.cgImage
        imageMaskLayer.contentsGravity = .resize
        targetLayer.mask = imageMaskLayer
        CATransaction.commit()
    }

    private func updateContentVisibility() {
        let isDisplayingVideo = videoSourceSize != nil
        videoRenderView.isHidden = !isDisplayingVideo
        imageView.isHidden = isDisplayingVideo || imageView.image == nil
        placeholderView.isHidden = hasContent
    }

    private func clampedContentOffset(_ offset: CGPoint, contentSize: CGSize) -> CGPoint {
        CGPoint(
            x: scrollsHorizontally ? min(max(offset.x, 0), max(contentSize.width - bounds.width, 0)) : 0,
            y: scrollsVertically ? min(max(offset.y, 0), max(contentSize.height - bounds.height, 0)) : 0
        )
    }

    private var sourceSize: CGSize {
        if let videoSourceSize, videoSourceSize.width > 0, videoSourceSize.height > 0 {
            return videoSourceSize
        }

        guard let image, image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: 960, height: 640)
        }

        return image.size
    }

    private var renderedSize: CGSize {
        ViewerGeometry.renderedSize(
            sourceSize: sourceSize,
            availableSize: bounds.size,
            layoutMode: layoutMode
        )
    }

    private var placeholderRect: CGRect {
        ViewerGeometry.frameRect(
            sourceSize: CGSize(width: 960, height: 640),
            availableSize: bounds.size,
            layoutMode: layoutMode,
            panOffset: .zero,
            startsAtLeadingEdge: true
        )
    }

    private var imageFrame: CGRect {
        let size = renderedSize
        let contentSize = CGSize(
            width: scrollsHorizontally ? max(bounds.width, size.width + viewportPadding * 2) : bounds.width,
            height: scrollsVertically ? max(bounds.height, size.height + viewportPadding * 2) : bounds.height
        )
        return CGRect(
            x: scrollsHorizontally ? viewportPadding : (contentSize.width - size.width) / 2,
            y: scrollsVertically ? viewportPadding : (contentSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private var hasContent: Bool {
        image != nil || videoSourceSize != nil
    }

    private var activeRenderLayer: CALayer? {
        if videoSourceSize != nil {
            return videoRenderView.layer
        }

        if image != nil {
            return imageView.layer
        }

        return nil
    }

    private var renderCornerRadius: CGFloat {
        videoRenderView.layer.cornerRadius
    }

    private var scrollsHorizontally: Bool {
        switch layoutMode {
        case .fitHeight:
            return renderedSize.width > bounds.width
        case .fitWidth:
            return false
        case .readableZoom:
            return renderedSize.width > bounds.width
        }
    }

    private var scrollsVertically: Bool {
        switch layoutMode {
        case .fitHeight:
            return false
        case .fitWidth:
            return renderedSize.height > bounds.height
        case .readableZoom:
            return renderedSize.height > bounds.height
        }
    }
}

extension MirrorCanvasView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let currentOffset = scrollView.contentOffset
        let axisLockedOffset = CGPoint(
            x: scrollsHorizontally ? currentOffset.x : 0,
            y: scrollsVertically ? currentOffset.y : 0
        )

        if axisLockedOffset != currentOffset {
            scrollView.contentOffset = axisLockedOffset
        }

        pointerSurfaceView.cancelPointerIfNeeded()
    }
}

private final class TwoFingerScrollView: UIScrollView, UIGestureRecognizerDelegate {
    override init(frame: CGRect) {
        super.init(frame: frame)
        panGestureRecognizer.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}

private final class VideoRenderView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    private var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        displayLayer.backgroundColor = UIColor.clear.cgColor
        displayLayer.videoGravity = .resize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        if displayLayer.status == .failed {
            displayLayer.flushAndRemoveImage()
        }

        if !displayLayer.isReadyForMoreMediaData {
            displayLayer.flush()
        }

        guard displayLayer.isReadyForMoreMediaData else { return false }
        displayLayer.enqueue(sampleBuffer)
        return true
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
    }
}

private final class PointerSurfaceView: UIView {
    var imageFrame: CGRect?
    var onPointerEvent: (RemoteControlMessage.Kind, CGPoint) -> Void = { _, _ in }

    private var lastPointerPoint: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouches(from: event, fallback: touches).count == 1,
              let touch = touches.first,
              let point = normalizedPoint(for: touch.location(in: self), allowsClamping: false) else {
            return
        }

        lastPointerPoint = point
        onPointerEvent(.pointerDown, point)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouches(from: event, fallback: touches).count == 1,
              let touch = touches.first,
              let point = normalizedPoint(for: touch.location(in: self), allowsClamping: true),
              shouldSendMove(to: point) else {
            return
        }

        lastPointerPoint = point
        onPointerEvent(.pointerMove, point)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let point: CGPoint?

        if let touch = touches.first {
            point = normalizedPoint(for: touch.location(in: self), allowsClamping: true)
        } else {
            point = lastPointerPoint
        }

        if let point {
            onPointerEvent(.pointerUp, point)
        }

        lastPointerPoint = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelPointerIfNeeded()
    }

    func cancelPointerIfNeeded() {
        guard let lastPointerPoint else { return }
        onPointerEvent(.pointerUp, lastPointerPoint)
        self.lastPointerPoint = nil
    }

    private func activeTouches(from event: UIEvent?, fallback: Set<UITouch>) -> [UITouch] {
        Array(event?.allTouches ?? fallback)
    }

    private func normalizedPoint(for location: CGPoint, allowsClamping: Bool) -> CGPoint? {
        guard let imageFrame, imageFrame.width > 0, imageFrame.height > 0 else { return nil }

        let x = (location.x - imageFrame.minX) / imageFrame.width
        let y = (location.y - imageFrame.minY) / imageFrame.height

        if allowsClamping {
            return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        }

        guard x >= 0, y >= 0, x <= 1, y <= 1 else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func shouldSendMove(to point: CGPoint) -> Bool {
        guard let lastPointerPoint else { return true }
        return abs(lastPointerPoint.x - point.x) > 0.001 || abs(lastPointerPoint.y - point.y) > 0.001
    }
}

private final class StreamPlaceholderView: UIView {
    private let iconView = UIImageView(image: UIImage(systemName: "display.trianglebadge.exclamationmark"))
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let contentStackView = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSubviews()
        configure(state: .idle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(state: RemoteFrameStreamState) {
        titleLabel.text = state.title
        detailLabel.text = state.detail
    }

    private func configureSubviews() {
        backgroundColor = UIColor.black.withAlphaComponent(0.34)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .regular)

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center

        detailLabel.font = .systemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.68)
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 2

        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        contentStackView.axis = .vertical
        contentStackView.alignment = .center
        contentStackView.spacing = 8
        contentStackView.addArrangedSubview(iconView)
        contentStackView.addArrangedSubview(titleLabel)
        contentStackView.addArrangedSubview(detailLabel)

        addSubview(contentStackView)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 42),
            iconView.heightAnchor.constraint(equalToConstant: 42),
            contentStackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            contentStackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            contentStackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStackView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

private final class KeyboardInputView: UIView, UIKeyInput {
    var onTextInput: (String) -> Void = { _ in }
    var onKeyPress: (RemoteControlMessage.Key) -> Void = { _ in }

    var hasText: Bool { true }
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    override var canBecomeFirstResponder: Bool { true }

    func insertText(_ text: String) {
        switch text {
        case "\n":
            onKeyPress(.returnKey)
        case "\t":
            onKeyPress(.tab)
        default:
            onTextInput(text)
        }
    }

    func deleteBackward() {
        onKeyPress(.deleteBackward)
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscapeKey))
        ]
    }

    @objc private func handleEscapeKey() {
        onKeyPress(.escape)
    }
}

private final class FallbackWallpaperView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = UIColor(red: 0.11, green: 0.14, blue: 0.20, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let context = UIGraphicsGetCurrentContext() else { return }

        UIColor(red: 0.11, green: 0.14, blue: 0.20, alpha: 1).setFill()
        context.fill(rect)

        UIColor.systemYellow.withAlphaComponent(0.16).setFill()

        let bands = [
            CGRect(x: bounds.width * 0.02, y: bounds.height * 0.70, width: bounds.width * 0.56, height: 10),
            CGRect(x: bounds.width * 0.18, y: bounds.height * 0.76, width: bounds.width * 0.62, height: 8),
            CGRect(x: bounds.width * 0.56, y: bounds.height * 0.18, width: bounds.width * 0.34, height: 7)
        ]

        for band in bands {
            UIBezierPath(roundedRect: band, cornerRadius: 4).fill()
        }
    }
}

private enum ViewerGeometry {
    static func renderedSize(sourceSize: CGSize, availableSize: CGSize, layoutMode: MirrorLayoutMode) -> CGSize {
        let maxWidth = max(availableSize.width - 32, 1)
        let maxHeight = max(availableSize.height - 32, 1)
        let fitWidthScale = maxWidth / sourceSize.width
        let fitHeightScale = maxHeight / sourceSize.height

        switch layoutMode {
        case .fitWidth:
            let scale = fitWidthScale
            return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        case .fitHeight:
            let scale = fitHeightScale
            return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        case .readableZoom:
            let scale = max(fitHeightScale, maxWidth / 720, 0.6)
            return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        }
    }

    static func frameRect(
        sourceSize: CGSize,
        availableSize: CGSize,
        layoutMode: MirrorLayoutMode,
        panOffset: CGPoint,
        startsAtLeadingEdge: Bool
    ) -> CGRect {
        let size = renderedSize(sourceSize: sourceSize, availableSize: availableSize, layoutMode: layoutMode)
        let horizontalInset: CGFloat = 16
        let verticalInset: CGFloat = 16
        let constrainedOffset = constrainedPanOffset(
            panOffset,
            sourceSize: sourceSize,
            availableSize: availableSize,
            layoutMode: layoutMode,
            startsAtLeadingEdge: startsAtLeadingEdge
        )
        let x: CGFloat
        let y: CGFloat

        if size.width > availableSize.width {
            x = startsAtLeadingEdge
                ? horizontalInset + constrainedOffset.x
                : (availableSize.width - size.width) / 2 + constrainedOffset.x
        } else {
            x = (availableSize.width - size.width) / 2
        }

        if size.height > availableSize.height {
            y = startsAtLeadingEdge
                ? verticalInset + constrainedOffset.y
                : (availableSize.height - size.height) / 2 + constrainedOffset.y
        } else {
            y = (availableSize.height - size.height) / 2
        }

        return CGRect(
            x: x,
            y: y,
            width: size.width,
            height: size.height
        )
    }

    static func constrainedPanOffset(
        _ offset: CGPoint,
        sourceSize: CGSize,
        availableSize: CGSize,
        layoutMode: MirrorLayoutMode,
        startsAtLeadingEdge: Bool
    ) -> CGPoint {
        let renderedSize = renderedSize(sourceSize: sourceSize, availableSize: availableSize, layoutMode: layoutMode)
        let horizontalInset: CGFloat = 16
        let verticalInset: CGFloat = 16
        let xOffset: CGFloat
        let yOffset: CGFloat

        if renderedSize.width > availableSize.width {
            let minOffset = startsAtLeadingEdge
                ? availableSize.width - renderedSize.width - (horizontalInset * 2)
                : (availableSize.width - renderedSize.width) / 2
            let maxOffset = startsAtLeadingEdge
                ? 0
                : (renderedSize.width - availableSize.width) / 2
            xOffset = min(max(offset.x, minOffset), maxOffset)
        } else {
            xOffset = 0
        }

        if renderedSize.height > availableSize.height {
            let minOffset = startsAtLeadingEdge
                ? availableSize.height - renderedSize.height - (verticalInset * 2)
                : (availableSize.height - renderedSize.height) / 2
            let maxOffset = startsAtLeadingEdge
                ? 0
                : (renderedSize.height - availableSize.height) / 2
            yOffset = min(max(offset.y, minOffset), maxOffset)
        } else {
            yOffset = 0
        }

        return CGPoint(x: xOffset, y: yOffset)
    }

    static func normalizedPoint(
        for location: CGPoint,
        sourceSize: CGSize,
        availableSize: CGSize,
        layoutMode: MirrorLayoutMode,
        panOffset: CGPoint,
        startsAtLeadingEdge: Bool,
        allowsClamping: Bool
    ) -> CGPoint? {
        let rect = frameRect(
            sourceSize: sourceSize,
            availableSize: availableSize,
            layoutMode: layoutMode,
            panOffset: panOffset,
            startsAtLeadingEdge: startsAtLeadingEdge
        )
        guard rect.width > 0, rect.height > 0 else { return nil }

        let x = (location.x - rect.minX) / rect.width
        let y = (location.y - rect.minY) / rect.height

        if allowsClamping {
            return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        }

        guard x >= 0, y >= 0, x <= 1, y <= 1 else { return nil }
        return CGPoint(x: x, y: y)
    }
}
