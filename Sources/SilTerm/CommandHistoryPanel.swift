import AppKit
import Foundation

/// Cmd+R 命令历史搜索：只读取本地 shell 历史文件，不联网、不调用 AI。
final class CommandHistoryController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let panel: NSPanel
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private var allCommands: [String] = []
    private var filtered: [String] = []
    private var onPick: ((String) -> Void)?

    init(targetWindow: NSWindow?) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered,
                        defer: false)
        panel.title = "搜索命令历史"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        super.init()
        buildUI()
    }

    private func buildUI() {
        let container = NSView()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "输入关键字过滤历史命令（回车插入）"
        searchField.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.title = "命令"
        column.width = 520
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 20
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(pickSelected)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        container.addSubview(searchField)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        panel.contentView = container
    }

    func show(for controller: MainWindowController, onPick: @escaping (String) -> Void) {
        self.onPick = onPick
        allCommands = Self.loadHistory()
        searchField.stringValue = ""
        applyFilter("")
        if let window = controller.window {
            let origin = NSPoint(x: window.frame.midX - 280, y: window.frame.midY - 120)
            panel.setFrameOrigin(origin)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    // MARK: - 过滤

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let row = max(0, tableView.selectedRow)
            if filtered.indices.contains(row) {
                pick(filtered[row])
            } else if let first = filtered.first {
                pick(first)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveSelection(by: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            moveSelection(by: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            panel.orderOut(nil)
            return true
        }
        return false
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = tableView.selectedRow < 0 ? 0 : tableView.selectedRow
        let next = min(max(0, current + delta), filtered.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func applyFilter(_ keyword: String) {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            filtered = allCommands
        } else {
            filtered = allCommands.filter { $0.range(of: key, options: .caseInsensitive) != nil }
        }
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc private func pickSelected() {
        let row = tableView.selectedRow
        guard filtered.indices.contains(row) else { return }
        pick(filtered[row])
    }

    private func pick(_ command: String) {
        panel.orderOut(nil)
        onPick?(command)
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("HistoryCell")
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            label = reused
        } else {
            label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.lineBreakMode = .byTruncatingTail
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        label.stringValue = filtered[row]
        return label
    }

    // MARK: - 历史文件读取

    /// 读取 zsh / bash / fish 历史，最多保留最近 5000 条（内存友好）。
    private static func loadHistory() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".zsh_history"),
            home.appendingPathComponent(".bash_history"),
            home.appendingPathComponent(".local/share/fish/fish_history")
        ]

        var result: [String] = []
        var seen = Set<String>()
        for url in candidates {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let command = parseHistoryLine(String(line))
                guard !command.isEmpty, seen.insert(command).inserted else { continue }
                result.append(command)
            }
        }
        if result.count > 5_000 {
            result = Array(result.suffix(5_000))
        }
        return result.reversed()
    }

    private static func parseHistoryLine(_ line: String) -> String {
        // zsh: ": 1700000000:0;ls -la"
        if line.hasPrefix(": ") , let semicolon = line.firstIndex(of: ";") {
            return String(line[line.index(after: semicolon)...]).trimmingCharacters(in: .whitespaces)
        }
        // fish: "- cmd: ls -la"
        if line.hasPrefix("- cmd: ") {
            return String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return line.trimmingCharacters(in: .whitespaces)
    }
}
