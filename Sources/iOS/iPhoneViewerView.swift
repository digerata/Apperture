import AVFoundation
import Combine
import UIKit

private final class PaddedLabel: UILabel {
    var contentInsets = UIEdgeInsets.zero {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: contentInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + contentInsets.left + contentInsets.right,
            height: size.height + contentInsets.top + contentInsets.bottom
        )
    }
}

private final class DeveloperActivityBannerView: UIView {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(activity: DeveloperActivityState) {
        guard let event = activity.latestEvent else {
            isHidden = true
            return
        }

        iconView.image = UIImage(systemName: symbolName(for: event))
        iconView.tintColor = symbolColor(for: event)
        titleLabel.text = activity.title
        if let issueSummary = activity.issueSummary {
            detailLabel.text = "\(activity.detail) - \(issueSummary)"
        } else {
            detailLabel.text = activity.detail
        }
        isHidden = false
    }

    private func configureSubviews() {
        isHidden = true
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.46)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.78)
        detailLabel.numberOfLines = 2

        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 2

        addSubview(iconView)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    private func symbolName(for event: DeveloperActivityEvent) -> String {
        if event.isFailure {
            return "xmark.circle.fill"
        }

        switch event.kind {
        case "buildStarted":
            return "hammer.fill"
        case "testStarted":
            return "checkmark.seal"
        case "appLaunched":
            return "play.circle.fill"
        case "simulatorBooted":
            return "iphone.gen3"
        default:
            return "terminal.fill"
        }
    }

    private func symbolColor(for event: DeveloperActivityEvent) -> UIColor {
        if event.isFailure {
            return .systemRed
        }

        return event.isActive ? .systemBlue : .systemGreen
    }
}

final class iPhoneViewerViewController: UIViewController {
    private let streamClient = RemoteFrameStreamClient()
    private var cancellables = Set<AnyCancellable>()
    private var nextSequenceNumber: UInt64 = 0

    private let fallbackWallpaperView = FallbackWallpaperView()
    private let wallpaperImageView = UIImageView()
    private let mirrorCanvasView = MirrorCanvasView()
    private let toolbarView = ViewerToolbarView()
    private let keyboardInputView = KeyboardInputView()
    private let fpsOverlayLabel = PaddedLabel()
    private let developerActivityBannerView = DeveloperActivityBannerView()
    private var currentDefaultLayoutMode: MirrorLayoutMode?
    private var mirrorLeadingConstraint: NSLayoutConstraint?
    private var mirrorTrailingConstraint: NSLayoutConstraint?
    private var mirrorTopConstraint: NSLayoutConstraint?
    private var mirrorBottomConstraint: NSLayoutConstraint?
    private var developerActivityTopConstraint: NSLayoutConstraint?
    private var developerActivityLeadingConstraint: NSLayoutConstraint?
    private var developerActivityTrailingConstraint: NSLayoutConstraint?
    private var frameTimestamps: [CFTimeInterval] = []
    private var displayedFPS: Double?
    private var latestStreamDiagnostics: RemoteStreamDiagnosticsMessage?
    private var selectedWindowIsSimulator = false
    private var hasSelectedWindowMetadata = false
    private var currentFrameHasAlphaMask = false
    private var isVideoDebugEnabled = UserDefaults.standard.bool(forKey: "VideoDebugOverlayEnabled") {
        didSet {
            UserDefaults.standard.set(isVideoDebugEnabled, forKey: "VideoDebugOverlayEnabled")
            toolbarView.isVideoDebugEnabled = isVideoDebugEnabled
            updateFrameRateOverlay()
        }
    }

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
        toolbarView.isVideoDebugEnabled = isVideoDebugEnabled

        keyboardInputView.translatesAutoresizingMaskIntoConstraints = false
        keyboardInputView.alpha = 0.01
        keyboardInputView.isAccessibilityElement = false

        fpsOverlayLabel.translatesAutoresizingMaskIntoConstraints = false
        fpsOverlayLabel.backgroundColor = UIColor.black.withAlphaComponent(0.48)
        fpsOverlayLabel.textColor = .white
        fpsOverlayLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        fpsOverlayLabel.textAlignment = .left
        fpsOverlayLabel.numberOfLines = 0
        fpsOverlayLabel.contentInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        fpsOverlayLabel.layer.cornerRadius = 7
        fpsOverlayLabel.layer.cornerCurve = .continuous
        fpsOverlayLabel.clipsToBounds = true
        fpsOverlayLabel.text = "FPS --"
        fpsOverlayLabel.isHidden = true

        developerActivityBannerView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(fallbackWallpaperView)
        view.addSubview(wallpaperImageView)
        view.addSubview(mirrorCanvasView)
        view.addSubview(toolbarView)
        view.addSubview(developerActivityBannerView)
        view.addSubview(fpsOverlayLabel)
        view.addSubview(keyboardInputView)

        let mirrorLeadingConstraint = mirrorCanvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        let mirrorTrailingConstraint = mirrorCanvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        let mirrorTopConstraint = mirrorCanvasView.topAnchor.constraint(equalTo: view.topAnchor, constant: 76)
        let mirrorBottomConstraint = mirrorCanvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        let developerActivityTopConstraint = developerActivityBannerView.topAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.topAnchor,
            constant: 72
        )
        let developerActivityLeadingConstraint = developerActivityBannerView.leadingAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.leadingAnchor,
            constant: 16
        )
        let developerActivityTrailingConstraint = developerActivityBannerView.trailingAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.trailingAnchor,
            constant: -16
        )
        self.mirrorLeadingConstraint = mirrorLeadingConstraint
        self.mirrorTrailingConstraint = mirrorTrailingConstraint
        self.mirrorTopConstraint = mirrorTopConstraint
        self.mirrorBottomConstraint = mirrorBottomConstraint
        self.developerActivityTopConstraint = developerActivityTopConstraint
        self.developerActivityLeadingConstraint = developerActivityLeadingConstraint
        self.developerActivityTrailingConstraint = developerActivityTrailingConstraint

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

            developerActivityTopConstraint,
            developerActivityLeadingConstraint,
            developerActivityTrailingConstraint,
            developerActivityBannerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),

            fpsOverlayLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            fpsOverlayLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            fpsOverlayLabel.widthAnchor.constraint(equalToConstant: 176),
            fpsOverlayLabel.heightAnchor.constraint(equalToConstant: 120),

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
        mirrorCanvasView.onScrollEvent = { [weak self] point, delta, phase in
            self?.sendScrollEvent(point: point, delta: delta, phase: phase)
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

        toolbarView.onVideoDebugToggled = { [weak self] in
            guard let self else { return }
            isVideoDebugEnabled.toggle()
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
                } else {
                    streamClient.requestKeyFrameIfNeeded()
                }
            }
            .store(in: &cancellables)

        streamClient.$latestFrameMask
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mask in
                guard let self else { return }
                mirrorCanvasView.maskImage = mask
                currentFrameHasAlphaMask = mask != nil
                updateInputMode()
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
                self?.toolbarView.streamState = state
                if case .connected = state {
                    self?.requestWindowList()
                }
            }
            .store(in: &cancellables)

        streamClient.$windows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] windows in
                guard let self else { return }
                toolbarView.windows = windows
                if let selectedWindow = windows.first(where: \.isSelected) {
                    selectedWindowIsSimulator = selectedWindow.isSimulator
                    hasSelectedWindowMetadata = true
                } else {
                    selectedWindowIsSimulator = false
                    hasSelectedWindowMetadata = false
                }
                updateInputMode()
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

        streamClient.$developerActivity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activity in
                self?.developerActivityBannerView.configure(activity: activity)
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

    private func sendScrollEvent(point: CGPoint, delta: CGPoint, phase: RemoteControlMessage.ScrollPhase) {
        nextSequenceNumber += 1
        streamClient.send(
            RemoteControlMessage(
                scrollAt: point,
                delta: delta,
                phase: phase,
                sequenceNumber: nextSequenceNumber
            )
        )
    }

    private func updateInputMode() {
        mirrorCanvasView.usesTouchDragForSingleFingerPan = hasSelectedWindowMetadata
            ? selectedWindowIsSimulator
            : currentFrameHasAlphaMask
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
        currentFrameHasAlphaMask = false
        selectedWindowIsSimulator = window.isSimulator
        hasSelectedWindowMetadata = true
        updateInputMode()
        mirrorCanvasView.prepareForAppSwitch()
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
            updateFrameRateOverlay()
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
        guard isVideoDebugEnabled else {
            fpsOverlayLabel.isHidden = true
            return
        }

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
            format: "Render %@ fps\nCap %.1f Enc %.1f Send %.1f Target %.0f\n%d x %d  %.1f/%.1f Mbps Q %.2f\nDrop %d  RKF %d  KF %d\nPrep %.1f CG %.1f Crop %.1f Mat %.1f\nPB %.1f Enc %.1f Q %.1f Dir %.0f%%",
            displayFPS,
            diagnostics.captureFPS,
            diagnostics.encodedFPS,
            diagnostics.sentFPS,
            diagnostics.targetFPS,
            diagnostics.encodedWidth,
            diagnostics.encodedHeight,
            diagnostics.bitrateMbps,
            diagnostics.configuredBitrateMbps,
            diagnostics.videoQuality,
            diagnostics.droppedFrames,
            diagnostics.backpressureKeyFrames,
            diagnostics.keyFrameInterval,
            diagnostics.capturePrepMS,
            diagnostics.cgImageMS,
            diagnostics.cropMS,
            diagnostics.materializeMS,
            diagnostics.pixelBufferMS,
            diagnostics.encodeMS,
            diagnostics.encoderQueueMS,
            diagnostics.directFramePercent
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
        developerActivityTopConstraint?.constant = isLandscape ? 12 : 72
        developerActivityLeadingConstraint?.constant = isLandscape ? max(84, view.safeAreaInsets.left + 84) : 16
        developerActivityTrailingConstraint?.constant = isLandscape ? -max(20, view.safeAreaInsets.right + 20) : -16
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
    var onVideoDebugToggled: () -> Void = {}
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
    var isVideoDebugEnabled = false {
        didSet {
            guard isVideoDebugEnabled != oldValue else { return }
            updateSettingsMenu()
        }
    }
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
                    title: "Debug",
                    options: .displayInline,
                    children: debugMenuActions()
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

    private func debugMenuActions() -> [UIMenuElement] {
        [
            UIAction(
                title: "Video Debug",
                image: UIImage(systemName: "chart.line.uptrend.xyaxis"),
                state: isVideoDebugEnabled ? .on : .off
            ) { [weak self] _ in
                self?.onVideoDebugToggled()
            }
        ]
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

        return [refreshAction] + RemoteApplicationWindowGroup.make(from: selectableWindows).map { group -> UIMenuElement in
            if group.windows.count == 1, let window = group.windows.first {
                return UIAction(
                    title: group.name,
                    subtitle: window.subtitle,
                    image: group.iconImage ?? group.fallbackImage,
                    state: window.isSelected ? .on : .off
                ) { [weak self] _ in
                    guard let self else { return }
                    onWindowSelected(window)
                }
            }

            return UIMenu(
                title: group.name,
                image: group.iconImage ?? group.fallbackImage,
                children: group.windows.map { window in
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
            )
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

private struct RemoteApplicationWindowGroup {
    var id: String
    var name: String
    var iconPNGData: Data?
    var windows: [RemoteWindowSummary]

    var containsSimulator: Bool {
        windows.contains(where: \.isSimulator)
    }

    var iconImage: UIImage? {
        guard let iconPNGData else { return nil }
        return UIImage(data: iconPNGData)
    }

    var fallbackImage: UIImage? {
        UIImage(systemName: containsSimulator ? "iphone.gen3" : "app.fill")
    }

    static func make(from windows: [RemoteWindowSummary]) -> [RemoteApplicationWindowGroup] {
        Dictionary(grouping: windows) { $0.appGroupID }
            .values
            .map { windows in
                let sortedWindows = windows.sorted { lhs, rhs in
                    lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                let firstWindow = sortedWindows[0]
                return RemoteApplicationWindowGroup(
                    id: firstWindow.appGroupID,
                    name: firstWindow.displayAppName,
                    iconPNGData: sortedWindows.first(where: { $0.appIconPNGData != nil })?.appIconPNGData,
                    windows: sortedWindows
                )
            }
            .sorted { lhs, rhs in
                if lhs.containsSimulator != rhs.containsSimulator {
                    return lhs.containsSimulator
                }

                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

private enum MirrorContentTransitionStyle: Equatable {
    case normal
    case switching(direction: CGFloat)
}

private final class MirrorCanvasView: UIView {
    var image: UIImage? {
        didSet {
            let hadContent = oldValue != nil || videoSourceSize != nil
            let isDeparting = hadContent && image == nil && videoSourceSize == nil

            if image != nil {
                isSynchronizingRenderMode = true
                videoSourceSize = nil
                isSynchronizingRenderMode = false
                videoRenderView.flush()
            }

            if !isDeparting {
                imageView.image = image
            }

            finishContentUpdate(hadContent: hadContent, isDeparting: isDeparting)
        }
    }

    var videoSourceSize: CGSize? {
        didSet {
            let hadContent = image != nil || oldValue != nil
            let isDeparting = hadContent && image == nil && videoSourceSize == nil

            if videoSourceSize != nil {
                if oldValue != videoSourceSize {
                    videoRenderView.flush()
                }
                imageView.image = nil
            } else if !isDeparting {
                videoRenderView.flush()
            }

            if isSynchronizingRenderMode {
                updateContentVisibility()
                updateScrollableContent(resetOffsetIfNeeded: false)
            } else {
                finishContentUpdate(hadContent: hadContent, isDeparting: isDeparting)
            }
        }
    }

    var maskImage: UIImage? {
        didSet {
            updateImageMask()
        }
    }

    var layoutMode: MirrorLayoutMode = .fitHeight {
        didSet {
            updateScrollableContent(resetOffsetIfNeeded: true)
        }
    }
    var usesTouchDragForSingleFingerPan = false {
        didSet {
            pointerSurfaceView.usesTouchDragForSingleFingerPan = usesTouchDragForSingleFingerPan
        }
    }

    func prepareForAppSwitch() {
        nextSwitchDirection *= -1
        pendingTransitionStyle = .switching(direction: nextSwitchDirection)
    }

    var onPointerEvent: (RemoteControlMessage.Kind, CGPoint) -> Void = { _, _ in }
    var onScrollEvent: (CGPoint, CGPoint, RemoteControlMessage.ScrollPhase) -> Void = { _, _, _ in }

    private let scrollView = TwoFingerScrollView()
    private let contentView = UIView()
    private let renderPivotView = UIView()
    private let renderSurfaceView = UIView()
    private let shadowView = UIView()
    private let videoRenderView = VideoRenderView()
    private let imageView = UIImageView()
    private let imageMaskLayer = CALayer()
    private let pointerSurfaceView = PointerSurfaceView()
    private var lastShadowBounds = CGRect.zero
    private var lastContentSize = CGSize.zero
    private var isSynchronizingRenderMode = false
    private var isAnimatingDeparture = false
    private var pendingTransitionStyle: MirrorContentTransitionStyle = .normal
    private var nextSwitchDirection: CGFloat = 1
    private var transitionGeneration = 0
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

        renderPivotView.backgroundColor = .clear
        renderPivotView.isUserInteractionEnabled = false
        renderPivotView.layer.anchorPoint = CGPoint(x: 0.5, y: 1)
        renderPivotView.layer.allowsGroupOpacity = true
        renderPivotView.layer.isDoubleSided = false
        renderPivotView.layer.rasterizationScale = UIScreen.main.scale

        renderSurfaceView.backgroundColor = .clear
        renderSurfaceView.isUserInteractionEnabled = false
        renderSurfaceView.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        renderSurfaceView.layer.allowsGroupOpacity = true
        renderSurfaceView.layer.isDoubleSided = false

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
        pointerSurfaceView.onScrollEvent = { [weak self] point, delta, phase in
            self?.onScrollEvent(point, delta, phase)
        }

        addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(renderPivotView)
        renderPivotView.addSubview(renderSurfaceView)
        renderSurfaceView.addSubview(shadowView)
        renderSurfaceView.addSubview(videoRenderView)
        renderSurfaceView.addSubview(imageView)
        contentView.addSubview(pointerSurfaceView)
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

    private func finishContentUpdate(hadContent: Bool, isDeparting: Bool) {
        let hasUpdatedContent = hasContent

        if isDeparting {
            animateContentDeparture()
            return
        }

        updateContentVisibility()
        updateScrollableContent(resetOffsetIfNeeded: false)

        if !hadContent && hasUpdatedContent {
            animateContentArrival()
        }
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
        renderPivotView.bounds = CGRect(origin: .zero, size: frame.size)
        renderPivotView.layer.anchorPoint = CGPoint(x: 0.5, y: 1)
        renderPivotView.layer.position = CGPoint(x: frame.midX, y: frame.maxY)
        renderSurfaceView.bounds = renderPivotView.bounds
        renderSurfaceView.layer.position = CGPoint(
            x: renderPivotView.bounds.midX,
            y: renderPivotView.bounds.midY
        )
        shadowView.frame = renderSurfaceView.bounds
        videoRenderView.frame = renderSurfaceView.bounds
        imageView.frame = renderSurfaceView.bounds
        updateImageMask()
        pointerSurfaceView.frame = contentView.bounds
        pointerSurfaceView.imageFrame = hasContent ? frame : nil

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
        guard !isAnimatingDeparture else { return }

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
        renderPivotView.isHidden = !hasContent
        renderSurfaceView.isHidden = !hasContent
        videoRenderView.isHidden = !isDisplayingVideo
        imageView.isHidden = isDisplayingVideo || imageView.image == nil
    }

    private func animateContentArrival() {
        transitionGeneration += 1
        let generation = transitionGeneration
        let style = pendingTransitionStyle
        let reducedMotion = UIAccessibility.isReduceMotionEnabled

        renderPivotView.isHidden = false
        renderSurfaceView.isHidden = false
        applyLayerState(
            to: renderPivotView,
            alpha: 0,
            transform: reducedMotion ? CATransform3DIdentity : bottomHingeTransform(for: style)
        )
        applyAffineState(
            to: renderSurfaceView,
            alpha: 1,
            transform: reducedMotion ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
        )
        pointerSurfaceView.isUserInteractionEnabled = false

        UIView.animate(
            withDuration: reducedMotion ? 0.18 : arrivalDuration(for: style),
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction],
            animations: {
                self.renderPivotView.alpha = 1
                self.renderPivotView.layer.transform = CATransform3DIdentity
                self.renderSurfaceView.transform = .identity
            },
            completion: { _ in
                guard generation == self.transitionGeneration else { return }
                self.renderPivotView.alpha = 1
                self.renderPivotView.layer.transform = CATransform3DIdentity
                self.renderSurfaceView.alpha = 1
                self.renderSurfaceView.transform = .identity
                self.pointerSurfaceView.isUserInteractionEnabled = true
                self.pendingTransitionStyle = .normal
                self.updateContentVisibility()
            }
        )
    }

    private func animateContentDeparture() {
        transitionGeneration += 1
        let generation = transitionGeneration
        let style = pendingTransitionStyle
        let reducedMotion = UIAccessibility.isReduceMotionEnabled

        isAnimatingDeparture = true
        applyLayerState(
            to: renderPivotView,
            alpha: renderPivotView.alpha,
            transform: CATransform3DIdentity
        )
        applyAffineState(to: renderSurfaceView, alpha: 1, transform: .identity)
        setRenderRasterizationEnabled(true)
        pointerSurfaceView.isUserInteractionEnabled = false

        guard !renderPivotView.isHidden else {
            guard generation == transitionGeneration else { return }
            isAnimatingDeparture = false
            clearDepartedContent()
            setRenderRasterizationEnabled(false)
            pointerSurfaceView.isUserInteractionEnabled = true
            updateContentVisibility()
            updateScrollableContent(resetOffsetIfNeeded: false)
            return
        }

        UIView.animate(
            withDuration: reducedMotion ? 0.16 : departureDuration(for: style),
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction],
            animations: {
                self.renderPivotView.alpha = 0
                self.renderPivotView.layer.transform = reducedMotion ? CATransform3DIdentity : self.bottomHingeTransform(for: style)
                self.renderSurfaceView.transform = reducedMotion ? .identity : CGAffineTransform(scaleX: 0.8, y: 0.8)
            },
            completion: { _ in
                guard generation == self.transitionGeneration else {
                    self.isAnimatingDeparture = false
                    self.setRenderRasterizationEnabled(false)
                    self.updateImageMask()
                    return
                }
                self.isAnimatingDeparture = false
                self.clearDepartedContent()
                self.renderPivotView.alpha = 1
                self.renderPivotView.layer.transform = CATransform3DIdentity
                self.renderSurfaceView.alpha = 1
                self.renderSurfaceView.transform = .identity
                self.setRenderRasterizationEnabled(false)
                self.pointerSurfaceView.isUserInteractionEnabled = true
                self.updateContentVisibility()
                self.updateScrollableContent(resetOffsetIfNeeded: false)
            }
        )
    }

    private func clearDepartedContent() {
        imageView.image = nil
        videoRenderView.flush()
        updateImageMask()
    }

    private func setRenderRasterizationEnabled(_ isEnabled: Bool) {
        renderPivotView.layer.shouldRasterize = isEnabled
    }

    private func applyLayerState(to view: UIView, alpha: CGFloat, transform: CATransform3D) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.alpha = alpha
        view.transform = .identity
        view.layer.transform = transform
        CATransaction.commit()
    }

    private func applyAffineState(to view: UIView, alpha: CGFloat, transform: CGAffineTransform) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.alpha = alpha
        view.layer.transform = CATransform3DIdentity
        view.transform = transform
        CATransaction.commit()
    }

    private func bottomHingeTransform(for style: MirrorContentTransitionStyle) -> CATransform3D {
        let angle: CGFloat

        switch style {
        case .normal, .switching:
            angle = 25 * .pi / 180
        }

        var transform = CATransform3DIdentity
        transform.m34 = -1 / 700
        return CATransform3DRotate(transform, angle, 1, 0, 0)
    }

    private func arrivalDuration(for style: MirrorContentTransitionStyle) -> TimeInterval {
        switch style {
        case .normal, .switching:
            return 0.25
        }
    }

    private func departureDuration(for style: MirrorContentTransitionStyle) -> TimeInterval {
        switch style {
        case .normal, .switching:
            return 0.25
        }
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
    var usesTouchDragForSingleFingerPan = false
    var onPointerEvent: (RemoteControlMessage.Kind, CGPoint) -> Void = { _, _ in }
    var onScrollEvent: (CGPoint, CGPoint, RemoteControlMessage.ScrollPhase) -> Void = { _, _, _ in }

    private enum PointerIntent {
        case idle
        case pendingTap
        case scrolling
        case dragging
    }

    private let dragStartThreshold: CGFloat = 7
    private let holdDownDelay: TimeInterval = 0.32
    private var pointerIntent: PointerIntent = .idle
    private var initialTouchLocation: CGPoint?
    private var initialPointerPoint: CGPoint?
    private var lastTouchLocation: CGPoint?
    private var lastTouchTimestamp: TimeInterval?
    private var lastScrollVelocity = CGPoint.zero
    private var lastScrollPoint: CGPoint?
    private var scrollSamples: [ScrollSample] = []
    private var hasSentScrollBegin = false
    private var lastPointerPoint: CGPoint?
    private var holdDownWorkItem: DispatchWorkItem?
    private var momentumGeneration = 0

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
        stopScrollMomentum()
        let activeTouches = activeTouches(from: event, fallback: touches)
        guard activeTouches.count == 1,
              let touch = touches.first,
              let point = normalizedPoint(for: touch.location(in: self), allowsClamping: false) else {
            cancelPointerIfNeeded()
            return
        }

        let location = touch.location(in: self)
        initialTouchLocation = location
        lastTouchLocation = location
        lastTouchTimestamp = touch.timestamp
        initialPointerPoint = point
        lastPointerPoint = point
        lastScrollPoint = point
        lastScrollVelocity = .zero
        scrollSamples = [ScrollSample(time: touch.timestamp, location: location)]
        hasSentScrollBegin = false

        if usesTouchDragForSingleFingerPan {
            pointerIntent = .dragging
            onPointerEvent(.pointerDown, point)
            return
        }

        pointerIntent = .pendingTap
        scheduleHoldDown(at: point)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouches(from: event, fallback: touches).count == 1 else {
            cancelPointerIfNeeded()
            return
        }

        guard let touch = touches.first,
              let point = normalizedPoint(for: touch.location(in: self), allowsClamping: true) else {
            return
        }

        switch pointerIntent {
        case .idle:
            return
        case .pendingTap:
            guard hasExceededDragThreshold(touch.location(in: self)) else { return }
            holdDownWorkItem?.cancel()
            holdDownWorkItem = nil
            if usesTouchDragForSingleFingerPan {
                let startPoint = initialPointerPoint ?? point
                onPointerEvent(.pointerDown, startPoint)
                pointerIntent = .dragging
                fallthrough
            } else {
                pointerIntent = .scrolling
                sendScroll(from: touch.location(in: self), timestamp: touch.timestamp, at: point)
            }
        case .scrolling:
            sendScroll(from: touch.location(in: self), timestamp: touch.timestamp, at: point)
        case .dragging:
            guard shouldSendMove(to: point) else { return }
            lastPointerPoint = point
            onPointerEvent(.pointerMove, point)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        holdDownWorkItem?.cancel()
        holdDownWorkItem = nil

        let point: CGPoint?
        if let touch = touches.first {
            point = normalizedPoint(for: touch.location(in: self), allowsClamping: true)
        } else {
            point = lastPointerPoint
        }

        switch pointerIntent {
        case .idle:
            break
        case .pendingTap:
            if let point {
                onPointerEvent(.pointerDown, point)
                onPointerEvent(.pointerUp, point)
            }
        case .scrolling:
            if let point {
                startScrollMomentum(at: point)
                return
            }
        case .dragging:
            if let point {
                onPointerEvent(.pointerUp, point)
            }
        }

        resetPointerState()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelPointerIfNeeded()
    }

    func cancelPointerIfNeeded() {
        holdDownWorkItem?.cancel()
        holdDownWorkItem = nil
        stopScrollMomentum()

        if case .dragging = pointerIntent, let lastPointerPoint {
            onPointerEvent(.pointerUp, lastPointerPoint)
        }

        if case .scrolling = pointerIntent, hasSentScrollBegin, let lastScrollPoint {
            onScrollEvent(lastScrollPoint, .zero, .cancelled)
        }

        resetPointerState()
    }

    private func activeTouches(from event: UIEvent?, fallback: Set<UITouch>) -> [UITouch] {
        Array(event?.allTouches ?? fallback)
    }

    private func scheduleHoldDown(at point: CGPoint) {
        holdDownWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, case .pendingTap = self.pointerIntent else { return }
            self.onPointerEvent(.pointerDown, point)
            self.pointerIntent = .dragging
        }
        holdDownWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDownDelay, execute: workItem)
    }

    private func hasExceededDragThreshold(_ location: CGPoint) -> Bool {
        guard let initialTouchLocation else { return false }
        let dx = location.x - initialTouchLocation.x
        let dy = location.y - initialTouchLocation.y
        return hypot(dx, dy) >= dragStartThreshold
    }

    private func resetPointerState() {
        pointerIntent = .idle
        initialTouchLocation = nil
        initialPointerPoint = nil
        lastTouchLocation = nil
        lastTouchTimestamp = nil
        lastScrollVelocity = .zero
        lastScrollPoint = nil
        scrollSamples.removeAll()
        hasSentScrollBegin = false
        lastPointerPoint = nil
    }

    private func sendScroll(from location: CGPoint, timestamp: TimeInterval, at point: CGPoint) {
        guard let lastTouchLocation, let lastTouchTimestamp else {
            self.lastTouchLocation = location
            self.lastTouchTimestamp = timestamp
            return
        }

        let movement = CGPoint(
            x: location.x - lastTouchLocation.x,
            y: location.y - lastTouchLocation.y
        )
        self.lastTouchLocation = location
        self.lastTouchTimestamp = timestamp
        lastScrollPoint = point
        recordScrollSample(time: timestamp, location: location)

        guard abs(movement.x) > 0.2 || abs(movement.y) > 0.2 else { return }
        let interval = max(timestamp - lastTouchTimestamp, 1.0 / 120.0)
        let instantVelocity = CGPoint(x: movement.x / interval, y: movement.y / interval)
        lastScrollVelocity = CGPoint(
            x: lastScrollVelocity.x * 0.35 + instantVelocity.x * 0.65,
            y: lastScrollVelocity.y * 0.35 + instantVelocity.y * 0.65
        )
        let phase: RemoteControlMessage.ScrollPhase = hasSentScrollBegin ? .changed : .began
        hasSentScrollBegin = true
        sendScrollDelta(movement, at: point, phase: phase)
    }

    private func sendScrollDelta(
        _ movement: CGPoint,
        at point: CGPoint,
        phase: RemoteControlMessage.ScrollPhase
    ) {
        let scrollSensitivity: CGFloat = 7.0
        onScrollEvent(
            point,
            CGPoint(
                x: movement.x * scrollSensitivity,
                y: movement.y * scrollSensitivity
            ),
            phase
        )
    }

    private func startScrollMomentum(at point: CGPoint) {
        var velocity = releaseScrollVelocity()
        let minimumVelocity: CGFloat = 35
        if hasSentScrollBegin {
            onScrollEvent(point, .zero, .ended)
        }

        guard hypot(velocity.x, velocity.y) >= minimumVelocity else {
            resetPointerState()
            return
        }

        momentumGeneration &+= 1
        let generation = momentumGeneration
        let frameInterval: TimeInterval = 1.0 / 60.0
        let decay: CGFloat = 0.965
        let momentumBoost: CGFloat = 1.55
        velocity.x *= momentumBoost
        velocity.y *= momentumBoost
        var hasSentMomentumBegin = false

        func step(_ remainingSteps: Int) {
            guard generation == momentumGeneration else { return }
            guard remainingSteps > 0, hypot(velocity.x, velocity.y) >= 4 else {
                onScrollEvent(point, .zero, .momentumEnded)
                resetPointerState()
                return
            }

            let movement = CGPoint(
                x: velocity.x * frameInterval,
                y: velocity.y * frameInterval
            )
            sendScrollDelta(
                movement,
                at: point,
                phase: hasSentMomentumBegin ? .momentumChanged : .momentumBegan
            )
            hasSentMomentumBegin = true
            velocity.x *= decay
            velocity.y *= decay

            DispatchQueue.main.asyncAfter(deadline: .now() + frameInterval) {
                step(remainingSteps - 1)
            }
        }

        step(150)
    }

    private func stopScrollMomentum() {
        momentumGeneration &+= 1
    }

    private func recordScrollSample(time: TimeInterval, location: CGPoint) {
        scrollSamples.append(ScrollSample(time: time, location: location))
        let cutoff = time - 0.16
        scrollSamples.removeAll { $0.time < cutoff }
    }

    private func releaseScrollVelocity() -> CGPoint {
        guard let newest = scrollSamples.last else { return lastScrollVelocity }

        let minimumWindow: TimeInterval = 0.045
        let oldest = scrollSamples.first { newest.time - $0.time <= 0.14 && newest.time - $0.time >= minimumWindow }
            ?? scrollSamples.first

        guard let oldest, newest.time > oldest.time else { return lastScrollVelocity }

        let interval = CGFloat(newest.time - oldest.time)
        let velocity = CGPoint(
            x: (newest.location.x - oldest.location.x) / interval,
            y: (newest.location.y - oldest.location.y) / interval
        )

        if hypot(velocity.x, velocity.y) > hypot(lastScrollVelocity.x, lastScrollVelocity.y) * 0.65 {
            return velocity
        }

        return lastScrollVelocity
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

private struct ScrollSample {
    var time: TimeInterval
    var location: CGPoint
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
