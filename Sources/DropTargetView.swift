import Cocoa

/// A simple NSView that accepts file URL drops and forwards them to a handler.
/// Renders a faint accent-colored border while a drag is hovering.
final class DropTargetView: NSView {
    var onURLs: (([URL]) -> Void)?

    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isHovering {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
        super.draw(dirtyRect)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isAcceptable(sender) else { return [] }
        isHovering = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHovering = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isHovering = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHovering = false
        guard isAcceptable(sender) else { return false }
        let pb = sender.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return false }
        onURLs?(urls)
        return true
    }

    private func isAcceptable(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        return pb.canReadObject(forClasses: [NSURL.self], options: nil)
    }
}
