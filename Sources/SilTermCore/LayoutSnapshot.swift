import CoreGraphics
import Foundation

/// 分割方向。
/// - vertical: 左右排列（分割线竖直），对应 Cmd+D
/// - horizontal: 上下排列（分割线水平），对应 Cmd+Shift+D
public enum SplitOrientation: String, Codable, Sendable {
    case vertical
    case horizontal
}

/// 单个 Pane 的持久化信息。
public struct PaneSnapshot: Codable, Sendable {
    public var id: UUID
    public var cwd: String
    public var shell: String

    public init(id: UUID = UUID(), cwd: String, shell: String) {
        self.id = id
        self.cwd = cwd
        self.shell = shell
    }
}

public struct SplitSnapshot: Codable, Sendable {
    public var orientation: SplitOrientation
    /// 第一个子节点占比（0.1 ~ 0.9）。
    public var ratio: Double
    public var first: LayoutSnapshot
    public var second: LayoutSnapshot

    public init(orientation: SplitOrientation,
                ratio: Double,
                first: LayoutSnapshot,
                second: LayoutSnapshot) {
        self.orientation = orientation
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}

/// 布局树快照。
public indirect enum LayoutSnapshot: Codable, Sendable {
    case pane(PaneSnapshot)
    case split(SplitSnapshot)

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    private enum Kind: String, Codable {
        case pane
        case split
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .pane:
            self = .pane(try c.decode(PaneSnapshot.self, forKey: .pane))
        case .split:
            self = .split(try c.decode(SplitSnapshot.self, forKey: .split))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try c.encode(Kind.pane, forKey: .type)
            try c.encode(pane, forKey: .pane)
        case .split(let split):
            try c.encode(Kind.split, forKey: .type)
            try c.encode(split, forKey: .split)
        }
    }

    /// 深度优先收集所有 Pane。
    public var panes: [PaneSnapshot] {
        switch self {
        case .pane(let p):
            return [p]
        case .split(let s):
            return s.first.panes + s.second.panes
        }
    }
}

/// Tab 持久化信息。
public struct TabSnapshot: Codable, Sendable {
    public var id: UUID
    public var title: String
    public var layout: LayoutSnapshot
    public var activePaneID: UUID?

    public init(id: UUID = UUID(), title: String, layout: LayoutSnapshot, activePaneID: UUID? = nil) {
        self.id = id
        self.title = title
        self.layout = layout
        self.activePaneID = activePaneID
    }
}

/// 窗口尺寸（避免直接依赖 CGRect 的 Codable 表现）。
public struct WindowFrameSnapshot: Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(frame: CGRect) {
        self.x = Double(frame.origin.x)
        self.y = Double(frame.origin.y)
        self.width = Double(frame.size.width)
        self.height = Double(frame.size.height)
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// 单个窗口的持久化信息。
public struct WindowSnapshot: Codable, Sendable {
    public var id: UUID
    public var frame: WindowFrameSnapshot
    public var tabs: [TabSnapshot]
    public var selectedTabIndex: Int

    public init(id: UUID = UUID(),
                frame: WindowFrameSnapshot,
                tabs: [TabSnapshot],
                selectedTabIndex: Int = 0) {
        self.id = id
        self.frame = frame
        self.tabs = tabs
        self.selectedTabIndex = selectedTabIndex
    }
}

/// 整体工作区快照（会话恢复）。
public struct WorkspaceSnapshot: Codable, Sendable {
    public var version: Int
    public var windows: [WindowSnapshot]

    public init(version: Int = 1, windows: [WindowSnapshot]) {
        self.version = version
        self.windows = windows
    }
}
