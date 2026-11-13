import Foundation

/// 会话快照 JSON 读写。
public final class SessionStore {
    public static let shared = SessionStore()

    public let configDirectory: URL

    public init(configDirectory: URL = SettingsStore.shared.configDirectory) {
        self.configDirectory = configDirectory
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    }

    public var sessionFileURL: URL {
        configDirectory.appendingPathComponent("session.json")
    }

    // MARK: - 默认会话

    public func saveSession(_ snapshot: WorkspaceSnapshot) {
        save(snapshot, to: sessionFileURL)
    }

    public func loadSession() -> WorkspaceSnapshot? {
        load(from: sessionFileURL)
    }

    public func clearSession() {
        try? FileManager.default.removeItem(at: sessionFileURL)
    }

    // MARK: - 手动快照

    public func save(_ snapshot: WorkspaceSnapshot, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func load(from url: URL) -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }

    // MARK: - Tab 布局快照

    public func saveLayout(_ layout: LayoutSnapshot, title: String, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(layout) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func loadLayout(from url: URL) -> LayoutSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LayoutSnapshot.self, from: data)
    }
}
