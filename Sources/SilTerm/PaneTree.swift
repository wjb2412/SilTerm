import Foundation
import SilTermCore

/// 一个 Pane 的运行时对象：持有 TerminalSession，并缓存其视图。
final class PaneItem {
    let id: UUID
    let session: TerminalSession
    var container: PaneContainerView?

    init(id: UUID = UUID(), session: TerminalSession) {
        self.id = id
        self.session = session
    }
}

/// 分割节点（类，便于在拖动分割线时回写比例）。
final class SplitNode {
    let id = UUID()
    let orientation: SplitOrientation
    var ratio: Double
    var first: PaneTree
    var second: PaneTree
    weak var splitView: SilTermSplitView?

    init(orientation: SplitOrientation, ratio: Double, first: PaneTree, second: PaneTree) {
        self.orientation = orientation
        self.ratio = min(max(0.1, ratio), 0.9)
        self.first = first
        self.second = second
    }
}

/// Tab 内的 Pane 布局树。
indirect enum PaneTree {
    case pane(PaneItem)
    case split(SplitNode)

    var panes: [PaneItem] {
        switch self {
        case .pane(let item):
            return [item]
        case .split(let node):
            return node.first.panes + node.second.panes
        }
    }

    func pane(with id: UUID) -> PaneItem? {
        switch self {
        case .pane(let item):
            return item.id == id ? item : nil
        case .split(let node):
            return node.first.pane(with: id) ?? node.second.pane(with: id)
        }
    }

    /// 移除指定 Pane；返回 nil 表示整棵树被清空。
    func removing(paneID: UUID) -> PaneTree? {
        switch self {
        case .pane(let item):
            return item.id == paneID ? nil : self
        case .split(let node):
            let newFirst = node.first.removing(paneID: paneID)
            let newSecond = node.second.removing(paneID: paneID)
            if newFirst == nil && newSecond == nil { return nil }
            if let f = newFirst, let s = newSecond {
                node.first = f
                node.second = s
                return .split(node)
            }
            return newFirst ?? newSecond
        }
    }

    /// 在目标 Pane 旁插入新的 Pane；找不到目标时返回 nil。
    func inserting(paneID targetID: UUID, item: PaneItem, orientation: SplitOrientation) -> PaneTree? {
        switch self {
        case .pane(let existing):
            guard existing.id == targetID else { return nil }
            let node = SplitNode(orientation: orientation,
                                 ratio: 0.5,
                                 first: .pane(existing),
                                 second: .pane(item))
            return .split(node)
        case .split(let node):
            if let newFirst = node.first.inserting(paneID: targetID, item: item, orientation: orientation) {
                node.first = newFirst
                return .split(node)
            }
            if let newSecond = node.second.inserting(paneID: targetID, item: item, orientation: orientation) {
                node.second = newSecond
                return .split(node)
            }
            return nil
        }
    }

    /// 生成持久化快照。
    var snapshot: LayoutSnapshot {
        switch self {
        case .pane(let item):
            return .pane(PaneSnapshot(id: item.id,
                                      cwd: item.session.refreshWorkingDirectory(),
                                      shell: item.session.shellPath))
        case .split(let node):
            return .split(SplitSnapshot(orientation: node.orientation,
                                        ratio: node.ratio,
                                        first: node.first.snapshot,
                                        second: node.second.snapshot))
        }
    }

    /// 从快照恢复（重建 PTY 会话）。
    static func make(from snapshot: LayoutSnapshot,
                     theme: TerminalTheme,
                     scrollbackLimit: Int) -> PaneTree {
        switch snapshot {
        case .pane(let paneSnapshot):
            let settings = SettingsStore.shared.settings
            let shell = FileManager.default.isExecutableFile(atPath: paneSnapshot.shell)
                ? paneSnapshot.shell
                : settings.defaultShell
            var cwd = paneSnapshot.cwd
            if cwd.isEmpty || !FileManager.default.fileExists(atPath: cwd) {
                cwd = FileManager.default.homeDirectoryForCurrentUser.path
            }
            let session = TerminalSession(shell: shell,
                                          cwd: cwd,
                                          rows: 24,
                                          cols: 80,
                                          theme: theme,
                                          scrollbackLimit: scrollbackLimit)
            return .pane(PaneItem(id: paneSnapshot.id, session: session))
        case .split(let splitSnapshot):
            let first = make(from: splitSnapshot.first, theme: theme, scrollbackLimit: scrollbackLimit)
            let second = make(from: splitSnapshot.second, theme: theme, scrollbackLimit: scrollbackLimit)
            return .split(SplitNode(orientation: splitSnapshot.orientation,
                                    ratio: splitSnapshot.ratio,
                                    first: first,
                                    second: second))
        }
    }
}

/// 一个 Tab：命名 + Pane 布局树。
final class TabModel {
    let id: UUID
    var title: String
    var tree: PaneTree?
    var activePaneID: UUID?
    var isCustomTitle = false

    init(id: UUID = UUID(), title: String, tree: PaneTree?, activePaneID: UUID? = nil) {
        self.id = id
        self.title = title
        self.tree = tree
        self.activePaneID = activePaneID ?? tree?.panes.first?.id
    }

    var displayTitle: String {
        if isCustomTitle && !title.isEmpty { return title }
        if let activeID = activePaneID,
           let item = tree?.pane(with: activeID) {
            let title = item.session.displayTitle
            if !title.isEmpty { return title }
        }
        if let first = tree?.panes.first {
            let title = first.session.displayTitle
            if !title.isEmpty { return title }
        }
        return title
    }

    var activePane: PaneItem? {
        guard let id = activePaneID else { return tree?.panes.first }
        return tree?.pane(with: id)
    }

    var sessions: [TerminalSession] {
        tree?.panes.map { $0.session } ?? []
    }

    var snapshot: TabSnapshot? {
        guard let tree else { return nil }
        return TabSnapshot(id: id, title: title, layout: tree.snapshot, activePaneID: activePaneID)
    }

    func closeAllSessions() {
        for session in sessions {
            session.close()
        }
    }
}
