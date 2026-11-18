import AppKit

/// The floating toolbar of the picker, laid out like the one in ⌘⇧5:
/// a glass capsule holding "close | what to record | options, record", with a one-line summary underneath.
///
/// It knows nothing about the picker's state. It reports what the user does through its `on…` closures and is told
/// what to show through `update(…)`.
@MainActor
final class PickerToolbar: NSView {
    var onCancel: () -> Void = {}
    var onStart: () -> Void = {}
    var onModeChange: (PickMode) -> Void = { _ in }
    /// `nil` means "no microphone".
    var onMicrophoneChange: (PickMicrophone?) -> Void = { _ in }
    var onQualityChange: (Quality) -> Void = { _ in }

    private let microphones: [PickMicrophone]
    private let modeControl = NSSegmentedControl(labels: ["", "", ""], trackingMode: .selectOne, target: nil, action: nil)
    private let optionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let recordButton = makeCapsuleButton(title: "Record", symbol: "record.circle", description: "Record", width: 96)
    private let caption = NSTextField(labelWithString: "")
    private var positionX: NSLayoutConstraint?
    private var positionY: NSLayoutConstraint?

    init(mode: PickMode, microphones: [PickMicrophone]) {
        self.microphones = microphones
        super.init(frame: .zero)
        build(mode: mode)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Building

    private func build(mode: PickMode) {
        let cancelButton = NSButton(title: "", target: self, action: #selector(cancelClicked))
        cancelButton.image = symbolImage("xmark", "Cancel")
        cancelButton.imagePosition = .imageOnly
        cancelButton.isBordered = false
        cancelButton.toolTip = "Cancel (Esc)"
        cancelButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let modes = [("display", "Record the whole display"), ("macwindow", "Record a window"), ("rectangle.dashed", "Record a selected area")]
        for (segment, (symbol, tip)) in modes.enumerated() {
            modeControl.setImage(symbolImage(symbol, tip), forSegment: segment)
            modeControl.setToolTip(tip, forSegment: segment)
            modeControl.setWidth(46, forSegment: segment)
        }
        modeControl.selectedSegment = mode.rawValue
        modeControl.target = self
        modeControl.action = #selector(modeClicked)

        optionsButton.menu = makeOptionsMenu()
        optionsButton.isBordered = false
        (optionsButton.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false  // The check marks are set by hand.

        recordButton.toolTip = "Start recording (Enter)"
        recordButton.target = self
        recordButton.action = #selector(startClicked)

        for control in [modeControl, optionsButton] as [NSControl] { control.controlSize = .large }

        let controls = NSStackView(views: [cancelButton, makeSeparator(), modeControl, makeSeparator(), optionsButton, recordButton])
        controls.spacing = 10
        let padded = NSView()
        padded.addSubview(controls)
        controls.translatesAutoresizingMaskIntoConstraints = false

        let bar = makeGlassBar(around: padded, cornerRadius: 27)
        if #available(macOS 26.0, *) { modeControl.borderShape = .capsule }

        // The summary sits on the dimmed screen rather than on glass, so it gets a shadow to stay readable.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 4
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = NSColor.white.withAlphaComponent(0.92)
        caption.shadow = shadow
        caption.wantsLayer = true
        caption.alignment = .center

        addSubview(bar)
        addSubview(caption)
        for view in [bar, caption] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: 14),
            controls.trailingAnchor.constraint(equalTo: padded.trailingAnchor, constant: -10),
            controls.topAnchor.constraint(equalTo: padded.topAnchor, constant: 9),
            controls.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -9),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            caption.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            caption.centerXAnchor.constraint(equalTo: centerXAnchor),
            caption.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// The "Options" pull-down: microphone and quality. A selected entry is told apart by its tag.
    private func makeOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Options", action: nil, keyEquivalent: "")  // The title the pull-down button shows.
        func add(_ title: String, _ action: Selector, tag: Int, subtitle: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.subtitle = subtitle
            menu.addItem(item)
        }
        menu.addItem(.sectionHeader(title: "Microphone"))
        add("None", #selector(microphoneChosen), tag: -1)
        for (index, microphone) in microphones.enumerated() {
            add(microphone.name, #selector(microphoneChosen), tag: index, subtitle: microphone.bluetooth ? "What you hear drops to call quality while recording" : nil)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Quality"))
        for (index, quality) in Quality.allCases.enumerated() { add(quality.title, #selector(qualityChosen), tag: index) }
        return menu
    }

    // MARK: Updating

    /// Shows the summary line, the record button's state and the checkmarks of the options menu.
    func update(caption text: String, canRecord: Bool, microphone: PickMicrophone?, quality: Quality) {
        caption.stringValue = text
        recordButton.isEnabled = canRecord
        recordButton.alphaValue = canRecord ? 1 : 0.4

        let microphoneTag = microphones.firstIndex { $0.id == microphone?.id } ?? -1
        for item in optionsButton.menu?.items ?? [] {
            if item.action == #selector(microphoneChosen) { item.state = item.tag == microphoneTag ? .on : .off }
            if item.action == #selector(qualityChosen) { item.state = Quality.allCases[item.tag] == quality ? .on : .off }
        }
    }

    // MARK: Placement

    /// Puts the toolbar near the bottom centre of `host`.
    func install(in host: NSView) {
        host.addSubview(self)
        translatesAutoresizingMaskIntoConstraints = false
        let x = centerXAnchor.constraint(equalTo: host.centerXAnchor)
        let y = bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -120)
        positionX = x
        positionY = y
        NSLayoutConstraint.activate([x, y])
    }

    /// Moves the toolbar by a drag, never out of the view it is installed in.
    func move(dx: CGFloat, dy: CGFloat) {
        guard let host = superview, let positionX, let positionY else { return }
        let reach = max(0, (host.bounds.width - frame.width) / 2)
        positionX.constant = min(max(positionX.constant + dx, -reach), reach)
        positionY.constant = min(max(positionY.constant + dy, frame.height - host.bounds.height), 0)
    }

    // MARK: Actions

    @objc private func cancelClicked() { onCancel() }
    @objc private func startClicked() { onStart() }
    @objc private func modeClicked() { onModeChange(PickMode(rawValue: modeControl.selectedSegment) ?? .display) }

    @objc private func microphoneChosen(_ item: NSMenuItem) {
        onMicrophoneChange(microphones.indices.contains(item.tag) ? microphones[item.tag] : nil)
    }

    @objc private func qualityChosen(_ item: NSMenuItem) { onQualityChange(Quality.allCases[item.tag]) }
}
