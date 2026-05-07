import Cocoa
import UniformTypeIdentifiers

/// Combined prompt input. Rewritten from scratch — text input first,
/// everything else gets re-added in subsequent steps.
///
/// Step 3: chips row above the text field. Folder button picks a file
/// and creates a chip with thumbnail, filename, and "start frame" /
/// "end frame" slot label. Upload runs through `uploadHandler` and the
/// chip flips to ready/failed state.
final class PromptInputView: NSView {

    // MARK: - Public API (kept stable for PreferencesWindow)

    var promptText: String {
        get { textView.string }
        set {
            textView.string = newValue
            textView.needsDisplay = true
            recomputeTextHeight()
        }
    }

    var placeholderString: String {
        get { textView.placeholderString }
        set { textView.placeholderString = newValue; textView.needsDisplay = true }
    }

    var startFrameImageId: String? {
        attachments.first { $0.imageId != nil }?.imageId
    }

    var endFrameImageId: String? {
        let ready = attachments.filter { $0.imageId != nil }
        return ready.count > 1 ? ready[1].imageId : nil
    }

    var onAttachmentsChanged: (() -> Void)?
    var uploadHandler: ((URL, @escaping (Result<String, Error>) -> Void) -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    let generateButton = NSButton(title: "Generate", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    // MARK: - State

    private struct Attachment {
        let chipView: ChipView
        var imageId: String? { chipView.imageId }
    }
    private var attachments: [Attachment] = []
    private static let maxAttachments = 2

    // MARK: - Subviews

    fileprivate let textView = PromptTextView(frame: .zero)
    private let scrollView = NSScrollView()
    private var scrollViewHeightConstraint: NSLayoutConstraint!
    private static let minTextHeight: CGFloat = 28
    private static let maxTextHeight: CGFloat = 110  // ~5 lines at 14pt
    private let folderButton = NSButton()
    private let chipsRow = NSStackView()
    private let dashedBorder = CAShapeLayer()
    private var isDraggingOver = false { didSet { applyBorderState() } }

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setUp() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        // Dashed border for drag-over state. Solid border lives on
        // self.layer.borderWidth/Color; dashed border is a separate
        // CAShapeLayer drawn on top, hidden until dragging starts.
        dashedBorder.fillColor = nil
        dashedBorder.strokeColor = NSColor.controlAccentColor.cgColor
        dashedBorder.lineWidth = 2
        dashedBorder.lineDashPattern = [6, 4]
        dashedBorder.isHidden = true
        layer?.addSublayer(dashedBorder)

        applyBorderState()

        // Chips row — added directly. NSStackView's intrinsic height
        // is 0 when empty (no arranged subviews) and matches the
        // chip's required 36pt height when populated, so the box
        // grows naturally as images are attached.
        chipsRow.orientation = .horizontal
        chipsRow.alignment = .centerY
        chipsRow.spacing = 6
        chipsRow.translatesAutoresizingMaskIntoConstraints = false

        // NSTextView wrapped in NSScrollView. Stock config — no
        // overrides of acceptsFirstResponder / acceptableDragTypes /
        // NSClipView. Placeholder is drawn inside PromptTextView's
        // draw(_:) so there's no overlay sibling that could intercept
        // clicks.
        textView.host = self
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor.labelColor
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        // Generate + Cancel — bottom-right.
        generateButton.bezelStyle = .rounded
        generateButton.controlSize = .large
        generateButton.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        generateButton.keyEquivalent = "\r"
        generateButton.target = self
        generateButton.action = #selector(generateClicked)
        generateButton.translatesAutoresizingMaskIntoConstraints = false
        generateButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.isHidden = true
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Image-attach button — bordered circular bezel, photo icon.
        let attachIconCandidates = [
            "photo.on.rectangle.angled",
            "photo.on.rectangle",
            "photo",
        ]
        var attachIcon: NSImage?
        for name in attachIconCandidates {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Attach image") {
                attachIcon = img
                break
            }
        }
        if let img = attachIcon {
            folderButton.image = img
        } else {
            folderButton.title = "+"
        }
        folderButton.bezelStyle = .circular
        folderButton.isBordered = true
        folderButton.imagePosition = .imageOnly
        folderButton.target = self
        folderButton.action = #selector(folderClicked)
        folderButton.toolTip = "Attach an image"
        folderButton.translatesAutoresizingMaskIntoConstraints = false

        // Bottom bar — folder button leading, Cancel + Generate trailing.
        let bottomBar = NSStackView()
        bottomBar.orientation = .horizontal
        bottomBar.alignment = .centerY
        bottomBar.spacing = 8
        bottomBar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.setViews([folderButton], in: .leading)
        bottomBar.setViews([cancelButton, generateButton], in: .trailing)

        addSubview(chipsRow)
        addSubview(scrollView)
        addSubview(bottomBar)

        // Height constraint mutated from textDidChange so the box
        // grows up to maxTextHeight (~5 lines), then scrolls past.
        scrollViewHeightConstraint = scrollView.heightAnchor.constraint(
            equalToConstant: Self.minTextHeight)
        scrollViewHeightConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            chipsRow.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            chipsRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            chipsRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: chipsRow.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollViewHeightConstraint,

            bottomBar.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            folderButton.widthAnchor.constraint(equalToConstant: 28),
            folderButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        registerForDraggedTypes([.fileURL])
    }

    // MARK: - Auto-grow

    fileprivate func recomputeTextHeight() {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let inset = textView.textContainerInset.height * 2
        let measured = ceil(used.height + inset)
        let clamped = max(Self.minTextHeight, min(Self.maxTextHeight, measured))
        if abs(scrollViewHeightConstraint.constant - clamped) > 0.5 {
            scrollViewHeightConstraint.constant = clamped
        }
    }

    // MARK: - Border state

    override func layout() {
        super.layout()
        dashedBorder.frame = bounds
        let r = bounds.insetBy(dx: 1, dy: 1)
        dashedBorder.path = CGPath(
            roundedRect: r,
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        )
    }

    private func applyBorderState() {
        dashedBorder.isHidden = !isDraggingOver
        layer?.borderWidth = isDraggingOver ? 0 : 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = isDraggingOver
            ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            : NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
    }

    // MARK: - Drag and drop

    fileprivate func acceptableImageURL(in pasteboard: NSPasteboard) -> URL? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ["public.image"],
        ]) as? [URL], let url = urls.first else { return nil }
        let ext = url.pathExtension.lowercased()
        guard ["jpg", "jpeg", "png", "webp"].contains(ext) else { return nil }
        return url
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard attachments.count < Self.maxAttachments,
              acceptableImageURL(in: sender.draggingPasteboard) != nil else { return [] }
        isDraggingOver = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDraggingOver = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDraggingOver = false
        guard let url = acceptableImageURL(in: sender.draggingPasteboard) else { return false }
        attachFile(at: url)
        return true
    }

    // MARK: - Folder button

    @objc private func folderClicked() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.jpeg, .png, .webP]
        } else {
            panel.allowedFileTypes = ["jpg", "jpeg", "png", "webp"]
        }
        panel.message = "Pick an image to attach"
        if panel.runModal() == .OK, let url = panel.url {
            attachFile(at: url)
        }
    }

    // MARK: - Attachments

    fileprivate func attachFile(at url: URL) {
        guard attachments.count < Self.maxAttachments else { return }
        guard let image = NSImage(contentsOf: url) else { return }

        let chip = ChipView(filename: url.lastPathComponent,
                            preview: image,
                            slot: slotLabel(for: attachments.count))
        chip.onRemove = { [weak self, weak chip] in
            guard let self = self, let chip = chip else { return }
            self.chipsRow.removeArrangedSubview(chip)
            chip.removeFromSuperview()
            self.attachments.removeAll { $0.chipView === chip }
            for (i, att) in self.attachments.enumerated() {
                att.chipView.slot = self.slotLabel(for: i)
            }
            self.onAttachmentsChanged?()
        }
        chipsRow.addArrangedSubview(chip)
        attachments.append(Attachment(chipView: chip))

        chip.state = .uploading
        onAttachmentsChanged?()

        uploadHandler?(url) { [weak self, weak chip] result in
            guard let self = self, let chip = chip else { return }
            switch result {
            case .success(let id): chip.state = .ready(id)
            case .failure(let e):  chip.state = .failed(e.localizedDescription)
            }
            self.onAttachmentsChanged?()
        }
    }

    private func slotLabel(for index: Int) -> String {
        index == 0 ? "start frame" : "end frame"
    }

    // MARK: - Button actions

    @objc private func generateClicked() { onSubmit?() }
    @objc private func cancelClicked() { onCancel?() }
}

// MARK: - NSTextViewDelegate

extension PromptInputView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        recomputeTextHeight()
    }
}

// MARK: - PromptTextView

/// NSTextView subclass that:
///   1. Draws a placeholder when string is empty (NSTextView has none).
///   2. Submits on plain Enter; Shift+Enter inserts a newline.
///   3. Forwards image-URL drops to the host so a drop over the
///      textView attaches as a chip rather than inserting the path.
///
/// Critically does NOT override `acceptsFirstResponder` or
/// `acceptableDragTypes` — those broke text input in earlier attempts.
fileprivate final class PromptTextView: NSTextView {

    weak var host: PromptInputView?

    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isReturn && mods.isEmpty {
            host?.onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: style,
        ]
        let inset = textContainerInset
        let pad = textContainer?.lineFragmentPadding ?? 0
        let drawRect = NSRect(
            x: inset.width + pad,
            y: inset.height,
            width: bounds.width - 2 * (inset.width + pad),
            height: bounds.height - 2 * inset.height
        )
        (placeholderString as NSString).draw(in: drawRect, withAttributes: attrs)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let host = host,
           host.acceptableImageURL(in: sender.draggingPasteboard) != nil {
            return host.draggingEntered(sender)
        }
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let host = host {
            host.draggingExited(sender)
        }
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let host = host,
           host.acceptableImageURL(in: sender.draggingPasteboard) != nil {
            return host.performDragOperation(sender)
        }
        return super.performDragOperation(sender)
    }
}

// MARK: - ChipView

private final class ChipView: NSView {

    enum State {
        case uploading
        case ready(String)
        case failed(String)
    }

    var state: State = .uploading {
        didSet { applyState() }
    }

    var imageId: String? {
        if case .ready(let id) = state { return id }
        return nil
    }

    var slot: String = "" {
        didSet { applyState() }
    }

    var onRemove: (() -> Void)?

    private let thumbView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let slotLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "×", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    init(filename: String, preview: NSImage, slot: String) {
        super.init(frame: .zero)
        self.slot = slot
        setUp(filename: filename, preview: preview)
        applyState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setUp(filename: String, preview: NSImage) {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor

        thumbView.image = preview
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 4
        thumbView.layer?.masksToBounds = true

        nameLabel.stringValue = filename
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        slotLabel.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        slotLabel.textColor = .controlAccentColor
        slotLabel.translatesAutoresizingMaskIntoConstraints = false

        removeButton.bezelStyle = .circular
        removeButton.controlSize = .small
        removeButton.font = NSFont.boldSystemFont(ofSize: 10)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.target = self
        removeButton.action = #selector(removeClicked)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [nameLabel, slotLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(thumbView)
        addSubview(textStack)
        addSubview(spinner)
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),

            thumbView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            thumbView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: 28),
            thumbView.heightAnchor.constraint(equalToConstant: 28),

            textStack.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -6),

            spinner.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -4),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),

            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 18),
            removeButton.heightAnchor.constraint(equalToConstant: 18),

            widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])
    }

    private func applyState() {
        switch state {
        case .uploading:
            spinner.startAnimation(nil)
            slotLabel.textColor = .secondaryLabelColor
            slotLabel.stringValue = "uploading…"
        case .ready:
            spinner.stopAnimation(nil)
            slotLabel.textColor = .controlAccentColor
            slotLabel.stringValue = slot
        case .failed(let msg):
            spinner.stopAnimation(nil)
            slotLabel.textColor = .systemRed
            slotLabel.stringValue = "failed"
            nameLabel.toolTip = msg
        }
    }

    @objc private func removeClicked() {
        onRemove?()
    }
}
