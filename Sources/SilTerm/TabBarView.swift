import AppKit

struct TabDisplay {
    let id: UUID
    let title: String
}

protocol TabBarDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didSelect index: Int)
    func tabBar(_ bar: TabBarView, didClose index: Int)
    func tabBarDidRequestNewTab(_ bar: TabBarView)
    func tabBar(_ bar: TabBarView, didMovePane paneID: UUID, toTab index: Int)
    func tabBar(_ bar: TabBarView, didReorderTab from: Int, to: Int)
    func tabBar(_ bar: TabBarView, didRequestRename index: Int)
    func tabBar(_ bar: TabBarView, menuFor index: Int) -> NSMenu?
}

/// 自绘 Tab 栏：原生外观、拖拽排序、Pane 拖入、右键菜单。
final class TabBarView: NSView {
    weak var delegate: TabBarDelegate?

    var tabs: [TabDisplay] = [] {
        didSet { needsDisplay = true }
    }
    var selectedIndex = 0 {
        didSet { needsDisplay = true }
    }

    private struct TabRect {
        var index: Int
        var rect: NSRect
        var closeRect: NSRect
    }

    private var tabRects: [TabRect] = []
    private var plusRect: NSRect = .zero
    private var mouseDownPoint: NSPoint?
    private var pressedIndex: Int?
    private var isReordering = false
    private var dropTargetIndex: Int?

    private let barHeight: CGFloat = 38
    private let tabHeight: CGFloat = 28
    /// 左侧留出红绿灯按钮的位置（窗口使用 fullSizeContentView）。
    private let leftPadding: CGFloat = 78
    private let tabSpacing: CGFloat = 4

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.siltermPane])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 布局计算

    private func rebuildRects() {
        tabRects.removeAll(keepingCapacity: true)
        var x = leftPadding
        let y = (barHeight - tabHeight) / 2
        for (index, tab) in tabs.enumerated() {
            let textWidth = (tab.title as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium)
            ]).width
            let width = min(220, max(108, ceil(textWidth) + 42))
            let rect = NSRect(x: x, y: y, width: width, height: tabHeight)
            let closeRect = NSRect(x: rect.maxX - 24, y: rect.minY + 5, width: 18, height: 18)
            tabRects.append(TabRect(index: index, rect: rect, closeRect: closeRect))
            x += width + tabSpacing
        }
        plusRect = NSRect(x: x + 2, y: y + 3, width: 24, height: 22)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        rebuildRects()
        // 背景
        NSColor.controlBackgroundColor.withAlphaComponent(0.18).setFill()
        bounds.fill()

        // 底部细分隔线
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()

        for tab in tabRects {
            let isSelected = tab.index == selectedIndex
            let isDropTarget = dropTargetIndex == tab.index
            let path = NSBezierPath(roundedRect: tab.rect, xRadius: 6, yRadius: 6)
            if isSelected {
                NSColor.controlBackgroundColor.withAlphaComponent(0.75).setFill()
                path.fill()
            } else if isDropTarget {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                path.fill()
            } else {
                NSColor.clear.setFill()
            }
            if isSelected {
                NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }

            let title = tabs[tab.index].title
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular),
                .foregroundColor: isSelected ? NSColor.labelColor : NSColor.secondaryLabelColor
            ]
            let titleRect = NSRect(x: tab.rect.minX + 12,
                                   y: tab.rect.minY + (tabHeight - 17) / 2,
                                   width: tab.rect.width - 40,
                                   height: 17)
            (title as NSString).draw(in: titleRect, withAttributes: attributes)

            // 关闭按钮
            let closeAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: isSelected ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
            ]
            ("✕" as NSString).draw(in: NSRect(x: tab.closeRect.minX + 4,
                                               y: tab.closeRect.minY + 3,
                                               width: 12,
                                               height: 12),
                                    withAttributes: closeAttributes)
        }

        // 新建 Tab 按钮
        let plusAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        ("+" as NSString).draw(in: NSRect(x: plusRect.minX + 6,
                                          y: plusRect.minY + 1,
                                          width: 16,
                                          height: 18),
                               withAttributes: plusAttributes)
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        rebuildRects()
        mouseDownPoint = point
        pressedIndex = nil
        isReordering = false

        if plusRect.insetBy(dx: -4, dy: -4).contains(point) {
            delegate?.tabBarDidRequestNewTab(self)
            return
        }

        for tab in tabRects where tab.rect.contains(point) {
            if tab.closeRect.insetBy(dx: -4, dy: -4).contains(point) {
                delegate?.tabBar(self, didClose: tab.index)
                return
            }
            pressedIndex = tab.index
            delegate?.tabBar(self, didSelect: tab.index)
            if event.clickCount >= 2 {
                delegate?.tabBar(self, didRequestRename: tab.index)
            }
            return
        }

        // 空白区域：拖动窗口
        if let window {
            window.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let pressed = pressedIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !isReordering && hypot(point.x - start.x, point.y - start.y) > 6 {
            isReordering = true
        }
        guard isReordering else { return }
        dropTargetIndex = tabIndex(at: point)
        _ = pressed
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            isReordering = false
            dropTargetIndex = nil
            needsDisplay = true
        }
        guard isReordering, let from = pressedIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let to = tabIndex(at: point), to != from else { return }
        delegate?.tabBar(self, didReorderTab: from, to: to)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        rebuildRects()
        for tab in tabRects where tab.rect.contains(point) {
            if let menu = delegate?.tabBar(self, menuFor: tab.index) {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            }
            return
        }
    }

    private func tabIndex(at point: NSPoint) -> Int? {
        guard !tabRects.isEmpty else { return nil }
        for tab in tabRects where tab.rect.contains(point) {
            return tab.index
        }
        // 拖到最右侧：放到最后一个 Tab 之后
        if point.x > (tabRects.last?.rect.maxX ?? 0) {
            return tabs.count - 1
        }
        if point.x < (tabRects.first?.rect.minX ?? 0) {
            return 0
        }
        // 落在间隙中：取最近的 Tab
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for tab in tabRects {
            let d = abs(tab.rect.midX - point.x)
            if d < bestDistance {
                bestDistance = d
                best = tab.index
            }
        }
        return best
    }

    // MARK: - Pane 拖入

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: .siltermPane) != nil else { return [] }
        dropTargetIndex = tabIndex(at: convert(sender.draggingLocation, from: nil))
        needsDisplay = true
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTargetIndex = nil
        needsDisplay = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropTargetIndex = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            dropTargetIndex = nil
            needsDisplay = true
        }
        guard let raw = sender.draggingPasteboard.string(forType: .siltermPane),
              let paneID = UUID(uuidString: raw),
              let index = tabIndex(at: convert(sender.draggingLocation, from: nil)) else { return false }
        delegate?.tabBar(self, didMovePane: paneID, toTab: index)
        return true
    }
}
