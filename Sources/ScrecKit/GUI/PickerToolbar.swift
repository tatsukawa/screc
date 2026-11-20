import AppKit

/// One choice in the toolbar's Options menu.
enum PickerChoice: Equatable {
    case saveFolder(Preferences.SaveFolder)
    /// "Other Location…": ask for a folder.
    case otherFolder
    /// A microphone's ID, or `nil` for none.
    case microphone(String?)
    case quality(Quality)
    case hevc(Bool)
    case fps(Int)
    case showsCursor(Bool)
    case afterSaving(Preferences.AfterSaving)
}

/// The floating toolbar of the picker, laid out like the one in ⌘⇧5:
/// a glass capsule holding "close | what to record | options, record", with a one-line summary underneath.
///
/// Every setting lives in the Options menu, as in ⌘⇧5, rather than in a separate window. The toolbar knows nothing
/// about the picker's state: it reports what the user does through its `on…` closures and is told what to show
/// through `update(…)`.
@MainActor
final class PickerToolbar: NSView {
    var onCancel: () -> Void = {}
    var onStart: () -> Void = {}
    var onModeChange: (PickMode) -> Void = { _ in }
    var onChoice: (PickerChoice) -> Void = { _ in }

    private let microphones: [PickMicrophone]
    private let modeControl = NSSegmentedControl(labels: ["", "", ""], trackingMode: .selectOne, target: nil, action: nil)
    private let optionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let recordButton = makeCapsuleButton(title: "Record", symbol: "record.circle", description: "Record", width: 96)
    private let caption = NSTextField(labelWithString: "")
    private var positionX: NSLayoutConstraint?
    private var positionY: NSLayoutConstraint?
    /// The settings the Options menu was built for.
    private var menuSettings: Preferences?

    init(mode: PickMode, microphones: [PickMicrophone]) {
        self.microphones = microphones
        super.init(frame: .zero)
        build(mode: mode)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The Options menu as it is now; rebuilt when the settings change.
    var optionsMenu: NSMenu? { optionsButton.menu }

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

    /// The Options menu, in sections like the one in ⌘⇧5. Each item carries the choice it stands for.
    private func makeOptionsMenu(_ settings: Preferences) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Options", action: nil, keyEquivalent: "")  // The title the pull-down button shows.

        func section(_ title: String) {
            if menu.items.count > 1 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: title))
        }
        func add(_ title: String, _ choice: PickerChoice, checked: Bool, subtitle: String? = nil) {
            let item = NSMenuItem(title: title, action: #selector(choiceMade(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ChoiceBox(choice)
            item.state = checked ? .on : .off
            item.subtitle = subtitle
            menu.addItem(item)
        }

        section("Save to")
        let standardFolders: [(String, Preferences.SaveFolder)] = [("Movies", .movies), ("Desktop", .desktop), ("Documents", .documents)]
        for (title, folder) in standardFolders { add(title, .saveFolder(folder), checked: settings.saveFolder == folder) }
        if case .custom(let url) = settings.saveFolder {
            add(FileManager.default.displayName(atPath: url.path), .saveFolder(settings.saveFolder), checked: true,
                subtitle: (url.path as NSString).abbreviatingWithTildeInPath)
        }
        add("Other Location…", .otherFolder, checked: false)

        section("Microphone")
        add("None", .microphone(nil), checked: settings.microphoneID == nil)
        for microphone in microphones {
            add(microphone.name, .microphone(microphone.id), checked: settings.microphoneID == microphone.id,
                subtitle: microphone.bluetooth ? "What you hear drops to call quality while recording" : nil)
        }

        section("Quality")
        for quality in Quality.allCases { add(quality.title, .quality(quality), checked: settings.quality == quality) }

        section("Format")
        add("H.264", .hevc(false), checked: !settings.hevc, subtitle: "Plays everywhere")
        add("HEVC", .hevc(true), checked: settings.hevc, subtitle: "Smaller files")

        section("Frame Rate")
        add("60 fps", .fps(60), checked: settings.fps == 60)
        add("30 fps", .fps(30), checked: settings.fps == 30)

        section("Options")
        add("Show Mouse Pointer", .showsCursor(!settings.showsCursor), checked: settings.showsCursor)

        section("After Saving")
        add("Show in Finder", .afterSaving(.showInFinder), checked: settings.afterSaving == .showInFinder)
        add("Open", .afterSaving(.open), checked: settings.afterSaving == .open)
        add("Do Nothing", .afterSaving(.nothing), checked: settings.afterSaving == .nothing)
        return menu
    }

    // MARK: Updating

    /// Shows the summary line, the record button's state, and the Options menu for `settings`.
    func update(caption text: String, canRecord: Bool, settings: Preferences) {
        caption.stringValue = text
        recordButton.isEnabled = canRecord
        recordButton.alphaValue = canRecord ? 1 : 0.4
        // The picker updates on every mouse move; the menu only needs to change with the settings.
        guard settings != menuSettings else { return }
        menuSettings = settings
        optionsButton.menu = makeOptionsMenu(settings)
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

    @objc private func choiceMade(_ item: NSMenuItem) {
        guard let box = item.representedObject as? ChoiceBox else { return }
        onChoice(box.choice)
    }
}

/// Lets a `PickerChoice` ride on a menu item, which can only hold an object.
private final class ChoiceBox: NSObject {
    let choice: PickerChoice
    init(_ choice: PickerChoice) { self.choice = choice }
}
