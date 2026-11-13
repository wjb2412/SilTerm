import AppKit
import SilTermCore
import UniformTypeIdentifiers

/// 主窗口控制器：Tab 管理、Pane 分片、拖拽移动、焦点切换、会话快照。
final class MainWindowController: NSWindowController, TerminalPaneActions, TabBarDelegate, NSWindowDelegate {
    weak var appDelegate: AppDelegate?

    private(set) var tabs: [TabModel] = []
    private(set) var selectedIndex = 0

    private let tabBar = TabBarView()
    private let contentContainer = NSView()
    private var controllers: [UUID: TabContentController] = [:]
    private var closedTabSnapshots: [TabSnapshot] = []

    // MARK: - 初始化

    init(appDelegate: AppDelegate?, snapshot: WindowSnapshot?) {
        self.appDelegate = appDelegate
        let window = MainWindowController.makeWindow()
        super.init(window: window)
        window.delegate = self
        setupContent()
        if let snapshot, !snapshot.tabs.isEmpty {
            restore(from: snapshot)
            window.setFrame(snapshot.frame.cgRect, display: false)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let tab = makeTab(cwd: home, title: nil, shell: nil)
            tabs = [tab]
            selectedIndex = 0
            updateTabBar()
            showActiveTab(focus: false)
            window.center()
        }
    }

    init(appDelegate: AppDelegate?, movingItem: PaneItem, at point: NSPoint?) {
        self.appDelegate = appDelegate
        let window = MainWindowController.makeWindow()
        super.init(window: window)
        window.delegate = self
        setupContent()
        let tab = TabModel(title: movingItem.session.displayTitle,
                           tree: .pane(movingItem),
                           activePaneID: movingItem.id)
        tabs = [tab]
        selectedIndex = 0
        updateTabBar()
        showActiveTab(focus: true)
        if let point {
            position(window: window, near: point)
        } else {
            window.center()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "SilTerm"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 480, height: 300)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        return window
    }

    private func setupContent() {
        guard let window else { return }
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        window.contentView = effect

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true

        effect.addSubview(tabBar)
        effect.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: effect.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 38),
            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
    }

    private func position(window: NSWindow, near point: NSPoint) {
        let size = window.frame.size
        var x = point.x - size.width / 2
        var y = point.y - size.height / 2
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            x = min(max(visible.minX + 20, x), visible.maxX - size.width - 20)
            y = min(max(visible.minY + 20, y), visible.maxY - size.height - 20)
        }
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Tab 显示

    @discardableResult
    func newTab(cwd: String?, shell: String?) -> TabModel {
        let directory = cwd ?? currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let tab = makeTab(cwd: directory, title: nil, shell: shell)
        tabs.append(tab)
        selectedIndex = tabs.count - 1
        updateTabBar()
        showActiveTab(focus: true)
        appDelegate?.scheduleSessionSave()
        return tab
    }

    private func makeTab(cwd: String, title: String?, shell: String?) -> TabModel {
        let settings = SettingsStore.shared.settings
        let session = TerminalSession(shell: shell ?? settings.defaultShell,
                                      cwd: cwd,
                                      rows: 24,
                                      cols: 80,
                                      theme: settings.resolvedTheme,
                                      scrollbackLimit: settings.scrollbackLines)
        let item = PaneItem(session: session)
        return TabModel(title: title ?? session.displayTitle,
                        tree: .pane(item),
                        activePaneID: item.id)
    }

    private var currentDirectory: String? {
        guard tabs.indices.contains(selectedIndex) else { return nil }
        return tabs[selectedIndex].activePane?.session.refreshWorkingDirectory()
    }

    private func updateTabBar() {
        let display = tabs.map { TabDisplay(id: $0.id, title: $0.displayTitle) }
        let changed = display.count != tabBar.tabs.count
            || zip(display, tabBar.tabs).contains { $0.id != $1.id || $0.title != $1.title }
        if changed {
            tabBar.tabs = display
        }
        tabBar.selectedIndex = selectedIndex
        if tabs.indices.contains(selectedIndex) {
            window?.title = tabs[selectedIndex].displayTitle
        }
    }

    private func showActiveTab(focus: Bool) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        guard tabs.indices.contains(selectedIndex) else { return }
        let tab = tabs[selectedIndex]
        let controller = contentController(for: tab)
        controller.rebuild()
        controller.view.frame = contentContainer.bounds
        controller.view.autoresizingMask = [.width, .height]
        contentContainer.addSubview(controller.view)
        controller.updateActiveStates()
        if focus {
            controller.focusActivePane()
        }
    }

    private func contentController(for tab: TabModel) -> TabContentController {
        if let existing = controllers[tab.id] { return existing }
        let controller = TabContentController(tab: tab, actions: self)
        controller.onTitleChanged = { [weak self] in
            self?.updateTabBar()
            self?.appDelegate?.scheduleSessionSave()
        }
        controller.onPaneDropped = { [weak self] dragged, target, orientation in
            self?.movePane(dragged, beside: target, orientation: orientation)
        }
        controller.onMoveToNewWindow = { [weak self] paneID, point in
            self?.paneMoveToNewWindow(paneID, at: point)
        }
        controllers[tab.id] = controller
        return controller
    }

    private func rebuild(tab: TabModel, focus: Bool) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if index == selectedIndex {
            showActiveTab(focus: focus)
        }
        updateTabBar()
    }

    private func selectTab(index: Int, focus: Bool = true) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
        tabBar.selectedIndex = index
        showActiveTab(focus: focus)
        updateTabBar()
    }

    // MARK: - Pane 操作

    func paneDidBecomeActive(_ paneID: UUID) {
        guard let tab = tabContaining(paneID: paneID) else { return }
        if tab.activePaneID != paneID {
            tab.activePaneID = paneID
        }
        if let index = tabs.firstIndex(where: { $0 === tab }), index != selectedIndex {
            selectedIndex = index
            tabBar.selectedIndex = index
            showActiveTab(focus: false)
        }
        controllers[tab.id]?.updateActiveStates()
        updateTabBar()
    }

    func paneSplit(_ paneID: UUID, orientation: SplitOrientation) {
        guard let tab = tabContaining(paneID: paneID),
              let tree = tab.tree,
              let target = tree.pane(with: paneID) else { return }
        let settings = SettingsStore.shared.settings
        let cwd = target.session.refreshWorkingDirectory()
        let session = TerminalSession(shell: settings.defaultShell,
                                      cwd: cwd,
                                      rows: 24,
                                      cols: 80,
                                      theme: settings.resolvedTheme,
                                      scrollbackLimit: settings.scrollbackLines)
        let item = PaneItem(session: session)
        guard let newTree = tree.inserting(paneID: paneID, item: item, orientation: orientation) else { return }
        tab.tree = newTree
        tab.activePaneID = item.id
        rebuild(tab: tab, focus: true)
        appDelegate?.scheduleSessionSave()
    }

    func paneClose(_ paneID: UUID) {
        guard let tab = tabContaining(paneID: paneID), let tree = tab.tree else { return }
        let snapshot = tab.snapshot
        tree.pane(with: paneID)?.session.close()
        let remaining = tree.removing(paneID: paneID)
        if let remaining, !remaining.panes.isEmpty {
            tab.tree = remaining
            if tab.activePaneID == paneID {
                tab.activePaneID = remaining.panes.first?.id
            }
            rebuild(tab: tab, focus: true)
        } else {
            recordClosedTab(snapshot)
            removeTabObject(tab)
        }
        appDelegate?.scheduleSessionSave()
    }

    func paneFocusNext(_ paneID: UUID, backwards: Bool) {
        guard let tab = tabContaining(paneID: paneID),
              let tree = tab.tree else { return }
        let panes = tree.panes
        guard panes.count > 1, let index = panes.firstIndex(where: { $0.id == paneID }) else { return }
        let next = (index + (backwards ? -1 : 1) + panes.count) % panes.count
        tab.activePaneID = panes[next].id
        controllers[tab.id]?.updateActiveStates()
        if let container = panes[next].container {
            window?.makeFirstResponder(container.terminal)
        }
        updateTabBar()
    }

    func paneMoveToNewWindow(_ paneID: UUID, at screenPoint: NSPoint?) {
        guard let tab = tabContaining(paneID: paneID),
              let tree = tab.tree,
              let item = tree.pane(with: paneID) else { return }
        let remaining = tree.removing(paneID: paneID)
        tab.tree = remaining
        if let remaining, !remaining.panes.isEmpty {
            if tab.activePaneID == paneID {
                tab.activePaneID = remaining.panes.first?.id
            }
            rebuild(tab: tab, focus: true)
        } else {
            removeTabObject(tab)
        }
        let controller = MainWindowController(appDelegate: appDelegate, movingItem: item, at: screenPoint)
        appDelegate?.registerWindow(controller)
        appDelegate?.scheduleSessionSave()
    }

    /// 将 Pane 插入到另一个 Pane 旁边（同一或不同 Tab）。
    func movePane(_ draggedID: UUID, beside targetID: UUID, orientation: SplitOrientation) {
        guard draggedID != targetID,
              let sourceTab = tabContaining(paneID: draggedID),
              let sourceTree = sourceTab.tree,
              let item = sourceTree.pane(with: draggedID),
              let targetTab = tabContaining(paneID: targetID),
              let targetTree = targetTab.tree else { return }

        if sourceTab === targetTab {
            guard let remaining = sourceTree.removing(paneID: draggedID) else { return }
            sourceTab.tree = remaining
            if let newTree = remaining.inserting(paneID: targetID, item: item, orientation: orientation) {
                sourceTab.tree = newTree
            } else {
                sourceTab.tree = .split(SplitNode(orientation: orientation,
                                                   ratio: 0.5,
                                                   first: remaining,
                                                   second: .pane(item)))
            }
            sourceTab.activePaneID = item.id
            rebuild(tab: sourceTab, focus: true)
            appDelegate?.scheduleSessionSave()
            return
        }

        let remaining = sourceTree.removing(paneID: draggedID)
        sourceTab.tree = remaining
        if let remaining, !remaining.panes.isEmpty {
            if sourceTab.activePaneID == draggedID {
                sourceTab.activePaneID = remaining.panes.first?.id
            }
        } else {
            removeTabObject(sourceTab)
        }

        if let newTree = targetTree.inserting(paneID: targetID, item: item, orientation: orientation) {
            targetTab.tree = newTree
        } else {
            targetTab.tree = .split(SplitNode(orientation: orientation,
                                               ratio: 0.5,
                                               first: targetTree,
                                               second: .pane(item)))
        }
        targetTab.activePaneID = item.id
        if let index = tabs.firstIndex(where: { $0 === targetTab }) {
            selectedIndex = index
        }
        rebuild(tab: targetTab, focus: true)
        appDelegate?.scheduleSessionSave()
    }

    /// 将 Pane 移动到指定 Tab（拖到 Tab 栏）。
    func movePane(_ paneID: UUID, toTabIndex index: Int) {
        guard tabs.indices.contains(index) else { return }
        let targetTab = tabs[index]
        guard let sourceTab = tabContaining(paneID: paneID),
              let sourceTree = sourceTab.tree,
              let item = sourceTree.pane(with: paneID) else { return }
        if sourceTab === targetTab { return }

        let remaining = sourceTree.removing(paneID: paneID)
        sourceTab.tree = remaining
        if let remaining, !remaining.panes.isEmpty {
            if sourceTab.activePaneID == paneID {
                sourceTab.activePaneID = remaining.panes.first?.id
            }
        } else {
            removeTabObject(sourceTab)
        }

        if let targetTree = targetTab.tree, let targetPane = targetTab.activePaneID ?? targetTree.panes.first?.id,
           let newTree = targetTree.inserting(paneID: targetPane, item: item, orientation: .vertical) {
            targetTab.tree = newTree
        } else if let targetTree = targetTab.tree {
            targetTab.tree = .split(SplitNode(orientation: .vertical,
                                               ratio: 0.5,
                                               first: targetTree,
                                               second: .pane(item)))
        } else {
            targetTab.tree = .pane(item)
        }
        targetTab.activePaneID = item.id
        if let newIndex = tabs.firstIndex(where: { $0 === targetTab }) {
            selectedIndex = newIndex
        }
        rebuild(tab: targetTab, focus: true)
        appDelegate?.scheduleSessionSave()
    }

    // MARK: - Tab 操作

    func closeTab(index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        recordClosedTab(tab.snapshot)
        tab.closeAllSessions()
        removeTabObject(tab)
        appDelegate?.scheduleSessionSave()
    }

    private func recordClosedTab(_ snapshot: TabSnapshot?) {
        guard let snapshot else { return }
        closedTabSnapshots.append(snapshot)
        if closedTabSnapshots.count > 12 {
            closedTabSnapshots.removeFirst(closedTabSnapshots.count - 12)
        }
    }

    /// 从 tabs 数组移除 Tab 对象（不负责关闭会话）。
    private func removeTabObject(_ tab: TabModel) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: index)
        if let controller = controllers.removeValue(forKey: tab.id) {
            controller.view.removeFromSuperview()
        }
        guard !tabs.isEmpty else {
            window?.performClose(nil)
            return
        }
        selectedIndex = min(index, tabs.count - 1)
        updateTabBar()
        showActiveTab(focus: true)
    }

    func reopenClosedTab() {
        guard let snapshot = closedTabSnapshots.popLast() else {
            NSSound.beep()
            return
        }
        let settings = SettingsStore.shared.settings
        let tree = PaneTree.make(from: snapshot.layout,
                                 theme: settings.resolvedTheme,
                                 scrollbackLimit: settings.scrollbackLines)
        let activeID = snapshot.activePaneID.flatMap { id in
            tree.pane(with: id) != nil ? id : nil
        } ?? tree.panes.first?.id
        let tab = TabModel(id: snapshot.id,
                           title: snapshot.title,
                           tree: tree,
                           activePaneID: activeID)
        tabs.append(tab)
        selectedIndex = tabs.count - 1
        updateTabBar()
        showActiveTab(focus: true)
        appDelegate?.scheduleSessionSave()
    }

    func renameTab(index: Int) {
        guard tabs.indices.contains(index), let window else { return }
        let tab = tabs[index]
        let alert = NSAlert()
        alert.messageText = "重命名 Tab"
        alert.informativeText = "输入新的 Tab 名称"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = tab.displayTitle
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            tab.title = title
            tab.isCustomTitle = true
            self?.updateTabBar()
            self?.appDelegate?.scheduleSessionSave()
        }
    }

    func reorderTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        let moved = tabs.remove(at: from)
        tabs.insert(moved, at: to)
        selectedIndex = to
        updateTabBar()
        showActiveTab(focus: true)
        appDelegate?.scheduleSessionSave()
    }

    private func tabContaining(paneID: UUID) -> TabModel? {
        for tab in tabs {
            if tab.tree?.pane(with: paneID) != nil {
                return tab
            }
        }
        return nil
    }

    // MARK: - TabBarDelegate

    func tabBar(_ bar: TabBarView, didSelect index: Int) {
        selectTab(index: index, focus: true)
    }

    func tabBar(_ bar: TabBarView, didClose index: Int) {
        closeTab(index: index)
    }

    func tabBarDidRequestNewTab(_ bar: TabBarView) {
        newTab(cwd: nil, shell: nil)
    }

    func tabBar(_ bar: TabBarView, didMovePane paneID: UUID, toTab index: Int) {
        movePane(paneID, toTabIndex: index)
    }

    func tabBar(_ bar: TabBarView, didReorderTab from: Int, to: Int) {
        reorderTab(from: from, to: to)
    }

    func tabBar(_ bar: TabBarView, didRequestRename index: Int) {
        renameTab(index: index)
    }

    func tabBar(_ bar: TabBarView, menuFor index: Int) -> NSMenu? {
        guard tabs.indices.contains(index) else { return nil }
        let menu = NSMenu()
        let rename = NSMenuItem(title: "重命名 Tab…", action: #selector(renameTabMenuAction(_:)), keyEquivalent: "")
        rename.tag = index
        rename.target = self
        menu.addItem(rename)

        let close = NSMenuItem(title: "关闭 Tab", action: #selector(closeTabMenuAction(_:)), keyEquivalent: "")
        close.tag = index
        close.target = self
        menu.addItem(close)

        let closeOthers = NSMenuItem(title: "关闭其他 Tab", action: #selector(closeOtherTabsMenuAction(_:)), keyEquivalent: "")
        closeOthers.tag = index
        closeOthers.target = self
        menu.addItem(closeOthers)

        menu.addItem(.separator())

        let saveLayout = NSMenuItem(title: "保存布局快照…", action: #selector(saveLayoutMenuAction(_:)), keyEquivalent: "")
        saveLayout.tag = index
        saveLayout.target = self
        menu.addItem(saveLayout)

        let newTab = NSMenuItem(title: "新建 Tab", action: #selector(newTabMenuAction(_:)), keyEquivalent: "")
        newTab.target = self
        menu.addItem(newTab)

        return menu
    }

    @objc private func renameTabMenuAction(_ sender: NSMenuItem) {
        renameTab(index: sender.tag)
    }

    @objc private func closeTabMenuAction(_ sender: NSMenuItem) {
        closeTab(index: sender.tag)
    }

    @objc private func closeOtherTabsMenuAction(_ sender: NSMenuItem) {
        let keep = sender.tag
        guard tabs.indices.contains(keep) else { return }
        let remaining = tabs[keep]
        for (index, tab) in tabs.enumerated() where tab !== remaining {
            tab.closeAllSessions()
            _ = index
        }
        tabs = [remaining]
        selectedIndex = 0
        updateTabBar()
        showActiveTab(focus: true)
        appDelegate?.scheduleSessionSave()
    }

    @objc private func saveLayoutMenuAction(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag), let window else { return }
        let tab = tabs[sender.tag]
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(tab.displayTitle)-layout.json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let tree = tab.tree else { return }
            SessionStore.shared.saveLayout(tree.snapshot, title: tab.displayTitle, to: url)
            _ = self
        }
    }

    @objc private func newTabMenuAction(_ sender: Any?) {
        newTab(cwd: nil, shell: nil)
    }

    // MARK: - 会话快照

    func windowSnapshot() -> WindowSnapshot? {
        guard let window else { return nil }
        let tabSnapshots = tabs.compactMap { $0.snapshot }
        guard !tabSnapshots.isEmpty else { return nil }
        return WindowSnapshot(frame: WindowFrameSnapshot(frame: window.frame),
                              tabs: tabSnapshots,
                              selectedTabIndex: selectedIndex)
    }

    private func restore(from snapshot: WindowSnapshot) {
        let settings = SettingsStore.shared.settings
        var restored: [TabModel] = []
        for tabSnapshot in snapshot.tabs {
            let tree = PaneTree.make(from: tabSnapshot.layout,
                                     theme: settings.resolvedTheme,
                                     scrollbackLimit: settings.scrollbackLines)
            guard !tree.panes.isEmpty else { continue }
            let activeID = tabSnapshot.activePaneID.flatMap { id in
                tree.pane(with: id) != nil ? id : nil
            } ?? tree.panes.first?.id
            restored.append(TabModel(id: tabSnapshot.id,
                                     title: tabSnapshot.title,
                                     tree: tree,
                                     activePaneID: activeID))
        }
        if restored.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            restored = [makeTab(cwd: home, title: nil, shell: nil)]
        }
        tabs = restored
        selectedIndex = min(max(0, snapshot.selectedTabIndex), tabs.count - 1)
        updateTabBar()
        showActiveTab(focus: false)
    }

    // MARK: - 窗口关闭

    func windowWillClose(_ notification: Notification) {
        for tab in tabs {
            tab.closeAllSessions()
        }
        controllers.removeAll()
        appDelegate?.windowControllerDidClose(self)
    }

    // MARK: - 便捷入口

    func splitActivePane(orientation: SplitOrientation) {
        guard tabs.indices.contains(selectedIndex),
              let paneID = tabs[selectedIndex].activePaneID else { return }
        paneSplit(paneID, orientation: orientation)
    }

    func closeActivePane() {
        guard tabs.indices.contains(selectedIndex),
              let paneID = tabs[selectedIndex].activePaneID else { return }
        paneClose(paneID)
    }

    func focusNextPane(backwards: Bool) {
        guard tabs.indices.contains(selectedIndex),
              let paneID = tabs[selectedIndex].activePaneID else { return }
        paneFocusNext(paneID, backwards: backwards)
    }

    func focusTerminal() {
        guard tabs.indices.contains(selectedIndex) else { return }
        contentController(for: tabs[selectedIndex]).focusActivePane()
    }

    func tabCount() -> Int { tabs.count }

    /// 在活动 Pane 旁新建 Pane，并进入指定目录（Finder 服务 / Dock 拖入）。
    func openPane(cwd: String, shell: String? = nil) {
        guard tabs.indices.contains(selectedIndex),
              let paneID = tabs[selectedIndex].activePaneID,
              let tab = tabContaining(paneID: paneID),
              let tree = tab.tree else {
            newTab(cwd: cwd, shell: shell)
            return
        }
        let settings = SettingsStore.shared.settings
        let session = TerminalSession(shell: shell ?? settings.defaultShell,
                                      cwd: cwd,
                                      rows: 24,
                                      cols: 80,
                                      theme: settings.resolvedTheme,
                                      scrollbackLimit: settings.scrollbackLines)
        let item = PaneItem(session: session)
        guard let newTree = tree.inserting(paneID: paneID, item: item, orientation: .vertical) else {
            newTab(cwd: cwd, shell: shell)
            return
        }
        tab.tree = newTree
        tab.activePaneID = item.id
        rebuild(tab: tab, focus: true)
        appDelegate?.scheduleSessionSave()
    }

    /// 供菜单快捷键切换 Tab。
    func selectTabAtIndex(_ index: Int) {
        selectTab(index: index, focus: true)
    }

    /// 将命令历史插入当前活动 Pane（不自动执行）。
    func insertCommand(_ command: String) {
        guard tabs.indices.contains(selectedIndex),
              let pane = tabs[selectedIndex].activePane else { return }
        pane.session.write(Data(command.utf8))
        focusTerminal()
    }
}
