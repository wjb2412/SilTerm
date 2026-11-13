import AppKit
import SilTermCore

extension NSPasteboard.PasteboardType {
    /// Pane 跨 Tab / 跨窗口拖拽类型。
    static let siltermPane = NSPasteboard.PasteboardType("com.silterm.pane")
}

// MARK: - 分割视图

/// 原生 NSSplitView 子类：记录用户拖动后的分割比例，并限制最小尺寸。
final class SilTermSplitView: NSSplitView, NSSplitViewDelegate {
    weak var splitNode: SplitNode?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        dividerStyle = .thin
        autoresizingMask = [.width, .height]
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard let node = splitNode, subviews.count == 2 else { return }
        let total = isVertical ? bounds.width : bounds.height
        guard total > 1 else { return }
        let firstLength = isVertical ? subviews[0].frame.width : subviews[0].frame.height
        node.ratio = min(max(0.1, Double(firstLength / total)), 0.9)
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 80
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return max(80, total - 80)
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        return false
    }
}

// MARK: - Pane 标题栏（拖拽源）

final class PaneHeaderView: NSView, NSDraggingSource {
    let paneID: UUID
    private let titleLabel = NSTextField(labelWithString: "")
    private let gripLabel = NSTextField(labelWithString: "⋮⋮")

    var onMoveToNewWindow: ((NSPoint) -> Void)?
    var onFocusRequest: (() -> Void)?

    private var dragStart: NSPoint?
    private var isActive = false

    init(paneID: UUID) {
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true

        gripLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        gripLabel.textColor = .tertiaryLabelColor
        gripLabel.alignment = .center
        gripLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(gripLabel)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            gripLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            gripLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            gripLabel.widthAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: gripLabel.trailingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    func setActive(_ active: Bool) {
        isActive = active
        titleLabel.textColor = active ? .labelColor : .secondaryLabelColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(isActive ? 0.40 : 0.18).setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
    }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
        dragStart = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let distance = hypot(point.x - start.x, point.y - start.y)
        guard distance > 4 else { return }
        dragStart = nil
        beginPaneDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    private func beginPaneDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(paneID.uuidString, forType: .siltermPane)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)

        let captureBounds = NSRect(x: 0, y: 0, width: max(160, bounds.width), height: max(24, bounds.height))
        var image = NSImage(size: captureBounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image = NSImage(size: bounds.size)
            image.addRepresentation(rep)
        }
        image = image.isValid ? image : NSImage(size: NSSize(width: 160, height: 24))
        draggingItem.setDraggingFrame(captureBounds, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // 拖到窗口外（未被任何目标接收）→ 按设置决定是否生成独立窗口
        if operation.isEmpty && SettingsStore.shared.settings.paneDragToNewWindow {
            onMoveToNewWindow?(screenPoint)
        }
    }
}

// MARK: - Pane 容器

/// 包含标题栏与终端视图的 Pane 容器，同时作为 Pane 拖拽落点。
final class PaneContainerView: NSView {
    let paneID: UUID
    let terminal: TerminalView
    private let header: PaneHeaderView

    /// 标题变化（用于刷新 Tab 栏）。
    var onTitleChanged: (() -> Void)?
    /// 其他 Pane 被拖入本 Pane 区域。
    var onPaneDropped: ((_ draggedPaneID: UUID, _ orientation: SplitOrientation) -> Void)?
    /// 本 Pane 被拖到窗口外。
    var onMoveToNewWindow: ((_ paneID: UUID, _ screenPoint: NSPoint) -> Void)?

    private var dropHighlight = false
    private var isActive = false

    init(paneID: UUID, session: TerminalSession) {
        self.paneID = paneID
        self.terminal = TerminalView(session: session, paneID: paneID)
        self.header = PaneHeaderView(paneID: paneID)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.clear.cgColor

        header.translatesAutoresizingMaskIntoConstraints = false
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(terminal)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 24),
            terminal.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        header.onFocusRequest = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.terminal)
        }
        header.onMoveToNewWindow = { [weak self] point in
            guard let self else { return }
            self.onMoveToNewWindow?(self.paneID, point)
        }
        terminal.onTitleChanged = { [weak self] in
            self?.refreshTitle()
            self?.onTitleChanged?()
        }
        refreshTitle()
        registerForDraggedTypes([.siltermPane])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setActive(_ active: Bool) {
        isActive = active
        header.setActive(active)
        terminal.setActive(active)
        updateBorder()
    }

    private func updateBorder() {
        if dropHighlight {
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        } else if isActive {
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        } else {
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        }
    }

    private func refreshTitle() {
        var title = terminal.session.displayTitle
        if title.isEmpty {
            title = (terminal.session.refreshWorkingDirectory() as NSString).lastPathComponent
        }
        header.setTitle(title)
    }

    // MARK: 拖放目标

    private func draggedPaneID(_ sender: NSDraggingInfo) -> UUID? {
        guard let raw = sender.draggingPasteboard.string(forType: .siltermPane) else { return nil }
        return UUID(uuidString: raw)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let id = draggedPaneID(sender), id != paneID else { return [] }
        dropHighlight = true
        updateBorder()
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHighlight = false
        updateBorder()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropHighlight = false
        updateBorder()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        updateBorder()
        guard let id = draggedPaneID(sender), id != paneID else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let dx = abs(point.x - bounds.midX)
        let dy = abs(point.y - bounds.midY)
        let orientation: SplitOrientation = dx >= dy ? .vertical : .horizontal
        onPaneDropped?(id, orientation)
        return true
    }
}
