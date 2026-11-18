import AppKit

/// What the user sees while a recording runs: a panel at the top of the screen reading "● Recording 0:12 | ■ Stop",
/// plus the same stop button in the menu bar.
///
/// A menu bar icon alone is easy to miss, and clicking it makes everything vanish without saying what happened. So the
/// panel is large and labelled, and after stopping it shows "Saved" before the program ends. The panel is excluded from
/// the recording (see `Control.excludedWindowIDs`), so it never appears in the video.
@MainActor
final class RecordingIndicator {
    enum Phase { case starting, recording, saving, saved }

    let panel: NSPanel
    let stopButton = makeCapsuleButton(title: "Stop", symbol: "stop.fill", description: "Stop", width: 84)
    private(set) var phase = Phase.starting

    private let stop: () -> Void
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var began = Date()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let clock = NSTextField(labelWithString: "0:00")
    private let divider = makeSeparator()

    /// - Parameter stop: Called once, when the user asks to stop.
    init(stop: @escaping () -> Void) {
        self.stop = stop
        // A non-activating panel: clicking it does not take the focus away from the app being recorded.
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 268, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        build()
        apply(.starting)
    }

    /// The panel's window ID, needed to exclude it from the recording. Valid once the panel has been shown.
    var windowID: CGWindowID { CGWindowID(max(panel.windowNumber, 0)) }

    // MARK: Building

    private func build() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true  // It can be dragged out of the way.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        clock.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        clock.textColor = .white
        stopButton.toolTip = "Stop recording and save"
        stopButton.target = self
        stopButton.action = #selector(stopRequested)

        let row = NSStackView(views: [dot, label, clock, divider, stopButton])
        row.spacing = 10
        row.alignment = .centerY
        let padded = NSView()
        padded.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: padded.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: padded.centerYAnchor),
        ])
        panel.contentView = makeGlassBar(around: padded, cornerRadius: 26)
    }

    /// Shows what belongs to `phase` and hides the rest.
    private func apply(_ phase: Phase) {
        self.phase = phase
        let recording = phase == .recording
        dot.isHidden = !recording
        clock.isHidden = phase == .starting || phase == .saved
        divider.isHidden = !recording
        stopButton.isHidden = !recording
        switch phase {
        case .starting: label.stringValue = "Starting…"
        case .recording: label.stringValue = "Recording"
        case .saving: label.stringValue = "Saving…"
        case .saved: label.stringValue = "✓ Saved"
        }
    }

    // MARK: Phases

    /// Shows the panel before the recording starts. The panel has to be on screen, with a window ID, to be excluded.
    func prepare() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame  // Below the menu bar.
        panel.setFrameOrigin(CGPoint(x: visible.midX - panel.frame.width / 2, y: visible.maxY - panel.frame.height - 12))
        panel.orderFrontRegardless()
    }

    /// The recording has started: count the time and offer the stop button.
    func started() {
        began = Date()
        apply(.recording)

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")?
            .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.button?.target = self
        item.button?.action = #selector(stopRequested)
        item.button?.toolTip = "Click to stop recording and save"
        statusItem = item

        tick()
        // The .common modes keep the clock running while a menu is open or the panel is being dragged.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let elapsed = formatClock(Date().timeIntervalSince(began))
        clock.stringValue = elapsed
        statusItem?.button?.title = " Stop " + elapsed
    }

    @objc private func stopRequested() {
        guard phase == .recording else { return }
        stopping()
        stop()
    }

    /// The recording is ending, however it was stopped (this button, Ctrl+C, `--duration` or a failure).
    func stopping() {
        guard phase == .recording else { return }
        timer?.invalidate()
        dot.layer?.removeAllAnimations()
        apply(.saving)
        statusItem?.button?.image = nil
        statusItem?.button?.title = "Saving…"
    }

    /// The file is saved. Say so, so that the panel does not just vanish.
    func saved() {
        apply(.saved)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
}
