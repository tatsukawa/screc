import AppKit

// Building blocks shared by the picker toolbar and the recording panel, so both look alike.

/// An SF Symbol, at the size used for toolbar icons.
func symbolImage(_ name: String, _ description: String, pointSize: CGFloat = 15) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: description)?
        .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
}

/// A thin vertical line between groups of controls.
@MainActor
func makeSeparator() -> NSView {
    let line = NSBox()
    line.boxType = .separator
    line.widthAnchor.constraint(equalToConstant: 1).isActive = true
    line.heightAnchor.constraint(equalToConstant: 22).isActive = true
    return line
}

/// A red, capsule-shaped button with a white symbol and title.
///
/// It is drawn by hand because a standard button turns gray while its window is not frontmost, and the overlay windows
/// are never the active ones in practice. A gray button looks disabled.
@MainActor
func makeCapsuleButton(title: String, symbol: String, description: String, width: CGFloat) -> NSButton {
    let button = NSButton(title: "", target: nil, action: nil)
    button.isBordered = false
    button.wantsLayer = true
    button.layer?.backgroundColor = NSColor.systemRed.cgColor
    button.layer?.cornerRadius = 15
    button.image = symbolImage(symbol, description, pointSize: 13)
    button.imagePosition = .imageLeading
    button.imageHugsTitle = true
    button.contentTintColor = .white
    button.attributedTitle = NSAttributedString(string: title, attributes: [
        .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
    ])
    button.widthAnchor.constraint(equalToConstant: width).isActive = true
    button.heightAnchor.constraint(equalToConstant: 30).isActive = true
    return button
}

/// A rounded bar of Liquid Glass (a blurred material before macOS 26) that fills itself with `content`.
///
/// The bar always uses the dark appearance, because it floats above a dimmed screen and needs white text and icons.
@MainActor
func makeGlassBar(around content: NSView, cornerRadius: CGFloat) -> NSView {
    let bar: NSView
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView()
        glass.contentView = content
        glass.cornerRadius = cornerRadius
        bar = glass
    } else {
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.masksToBounds = true
        blur.addSubview(content)
        bar = blur
    }
    bar.appearance = NSAppearance(named: .darkAqua)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        content.topAnchor.constraint(equalTo: bar.topAnchor),
        content.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
    ])
    return bar
}
