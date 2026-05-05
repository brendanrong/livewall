import Cocoa

enum PrefsSection: Int, CaseIterable {
    case general, display, playback, library, generate, about

    var title: String {
        switch self {
        case .general:  return "General"
        case .display:  return "Display"
        case .playback: return "Playback"
        case .library:  return "Library"
        case .generate: return "Generate"
        case .about:    return "About"
        }
    }

    var identifier: String {
        switch self {
        case .general:  return "general"
        case .display:  return "display"
        case .playback: return "playback"
        case .library:  return "library"
        case .generate: return "generate"
        case .about:    return "about"
        }
    }

    var icon: String {
        switch self {
        case .general:  return "gearshape"
        case .display:  return "display"
        case .playback: return "play.rectangle"
        case .library:  return "square.grid.2x2"
        case .generate: return "sparkles"
        case .about:    return "info.circle"
        }
    }
}

/// A single row in the settings sidebar: SF Symbol + label, with a
/// selected/unselected background. Tap-to-activate.
final class SidebarItemButton: NSView {
    let section: PrefsSection
    private let onClick: () -> Void
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private(set) var isSelected = false

    init(section: PrefsSection, onClick: @escaping () -> Void) {
        self.section = section
        self.onClick = onClick
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false

        if let img = NSImage(systemSymbolName: section.icon, accessibilityDescription: section.title) {
            iconView.image = img
            iconView.contentTintColor = .secondaryLabelColor
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        label.stringValue = section.title
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])

        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        applyAppearance()
    }

    private func applyAppearance() {
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            iconView.contentTintColor = .controlAccentColor
            label.textColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            iconView.contentTintColor = .secondaryLabelColor
            label.textColor = .labelColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    override func updateLayer() {
        super.updateLayer()
        applyAppearance()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
