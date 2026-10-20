import AppKit
@preconcurrency import AVFoundation

/// A round, draggable camera preview. It is part of the recording: ScreenCaptureKit films the window itself.
@MainActor
final class WebcamBubble {
    let panel: FloatingPanel
    private let session = AVCaptureSession()
    private let bubble: BubbleView
    private(set) var size: WebcamSize

    /// Returns nil when no camera can be opened.
    init?(near area: CGRect, size: WebcamSize, deviceID: String) {
        let device = (deviceID.isEmpty ? nil : AVCaptureDevice(uniqueID: deviceID)) ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return nil
        }
        session.addInput(input)
        session.commitConfiguration()

        self.size = size
        let screen = Placement.screen(containing: area)
        let visible = screen.visibleFrame
        let diameter = size.diameter
        let margin: CGFloat = 24
        var origin = CGPoint(x: area.minX + margin, y: area.minY + margin)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - diameter)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - diameter)
        let frame = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))

        panel = FloatingPanel(frame: frame, level: .statusBar)
        panel.isMovableByWindowBackground = true
        bubble = BubbleView(frame: CGRect(origin: .zero, size: frame.size), session: session)
        panel.contentView = bubble
        bubble.onResize = { [weak self] size in self?.setSize(size) }
        bubble.currentSize = { [weak self] in self?.size ?? .medium }

        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    func show() { panel.present() }

    func setSize(_ size: WebcamSize) {
        self.size = size
        Prefs[Pref.recordingWebcamSize] = size
        let diameter = size.diameter
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let frame = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        panel.setFrame(frame, display: true, animate: true)
    }

    func close() {
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        panel.dismiss()
    }
}

private final class BubbleView: NSView {
    var onResize: ((WebcamSize) -> Void)?
    var currentSize: (() -> WebcamSize)?
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let ring = CALayer()

    init(frame: NSRect, session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.masksToBounds = true
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        layer?.addSublayer(previewLayer)

        ring.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        ring.borderWidth = 3
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        previewLayer.cornerRadius = bounds.width / 2
        ring.frame = bounds
        ring.cornerRadius = bounds.width / 2
        CATransaction.commit()
        window?.invalidateShadow()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for size in WebcamSize.allCases {
            let item = NSMenuItem(title: size.title, action: #selector(pick(_:)), keyEquivalent: "")
            item.representedObject = size.rawValue
            item.target = self
            item.state = currentSize?() == size ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = WebcamSize(rawValue: raw) else { return }
        onResize?(size)
    }
}
