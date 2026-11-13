import AppKit
import SilTermCore

/// 管理单个 Tab 内 Pane 树到原生 NSSplitView 的映射。
final class TabContentController: NSViewController {
    let tab: TabModel
    private unowned let actions: TerminalPaneActions

    /// 标题变化（转发给窗口控制器刷新 Tab 栏）。
    var onTitleChanged: (() -> Void)?
    /// 有 Pane 被拖入某 Pane 区域。
    var onPaneDropped: ((_ dragged: UUID, _ target: UUID, _ orientation: SplitOrientation) -> Void)?
    /// Pane 被拖出窗口。
    var onMoveToNewWindow: ((_ paneID: UUID, _ screenPoint: NSPoint) -> Void)?

    private var pendingDividers: [(split: SilTermSplitView, ratio: Double)] = []

    init(tab: TabModel, actions: TerminalPaneActions) {
        self.tab = tab
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        view = root
    }

    /// 依据 tab.tree 重建视图层级（复用已有 PaneContainerView，保留 PTY 会话）。
    func rebuild() {
        _ = view
        view.subviews.forEach { $0.removeFromSuperview() }
        pendingDividers.removeAll(keepingCapacity: true)
        let content: NSView
        if let tree = tab.tree {
            content = makeView(for: tree)
        } else {
            content = NSView()
        }
        content.frame = view.bounds
        content.autoresizingMask = [.width, .height]
        view.addSubview(content)
        view.layoutSubtreeIfNeeded()
        applyPendingDividers()
        updateActiveStates()
    }

    private func makeView(for tree: PaneTree) -> NSView {
        switch tree {
        case .pane(let item):
            return containerView(for: item)
        case .split(let node):
            let split = SilTermSplitView(frame: view.bounds)
            split.splitNode = node
            split.isVertical = (node.orientation == .vertical)
            node.splitView = split
            pendingDividers.append((split, node.ratio))
            let first = makeView(for: node.first)
            let second = makeView(for: node.second)
            split.addSubview(first)
            split.addSubview(second)
            split.adjustSubviews()
            return split
        }
    }

    private func containerView(for item: PaneItem) -> PaneContainerView {
        if let existing = item.container {
            existing.terminal.actions = actions
            return existing
        }
        let container = PaneContainerView(paneID: item.id, session: item.session)
        container.terminal.actions = actions
        container.onTitleChanged = { [weak self] in
            self?.onTitleChanged?()
        }
        container.onPaneDropped = { [weak self] dragged, orientation in
            self?.onPaneDropped?(dragged, item.id, orientation)
        }
        container.onMoveToNewWindow = { [weak self] id, point in
            self?.onMoveToNewWindow?(id, point)
        }
        item.container = container
        return container
    }

    private func applyPendingDividers() {
        for entry in pendingDividers {
            let split = entry.split
            split.adjustSubviews()
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            guard total > 1 else { continue }
            split.setPosition(total * CGFloat(entry.ratio), ofDividerAt: 0)
        }
        pendingDividers.removeAll(keepingCapacity: true)
    }

    /// 更新所有 Pane 的活动态。
    func updateActiveStates() {
        guard let tree = tab.tree else { return }
        for item in tree.panes {
            item.container?.setActive(item.id == tab.activePaneID)
        }
    }

    /// 聚焦当前活动 Pane。
    func focusActivePane() {
        guard let tree = tab.tree, let id = tab.activePaneID,
              let item = tree.pane(with: id) else { return }
        if let container = item.container {
            view.window?.makeFirstResponder(container.terminal)
        }
    }

    /// 当布局尺寸变化时，重新分配分割比例（保证首次展示正确）。
    func relayoutDividers() {
        guard let tree = tab.tree else { return }
        relayout(node: tree)
    }

    private func relayout(node: PaneTree) {
        guard case .split(let splitNode) = node else { return }
        if let split = splitNode.splitView {
            split.adjustSubviews()
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            if total > 1 {
                split.setPosition(total * CGFloat(splitNode.ratio), ofDividerAt: 0)
            }
        }
        relayout(node: splitNode.first)
        relayout(node: splitNode.second)
    }
}
