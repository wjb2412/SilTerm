import AppKit
import Foundation

/// 一个 Pane 对应的会话：PTY 进程 + 终端模拟器。
public final class TerminalSession {
    public let id = UUID()
    public let emulator: TerminalEmulator

    public private(set) var shellPath: String
    public private(set) var cwd: String
    public private(set) var isRunning = false
    public private(set) var lastExitCode: Int32?

    /// 渲染刷新（主线程）。
    public var onUpdate: (() -> Void)?
    /// 标题变化（主线程）。
    public var onTitleChange: (() -> Void)?
    /// 进程退出（主线程）。
    public var onExit: ((Int32) -> Void)?

    private var pty: PTYProcess?
    private var updatePending = false
    private let updateLock = NSLock()

    public init(shell: String,
                cwd: String,
                rows: Int,
                cols: Int,
                theme: TerminalTheme,
                scrollbackLimit: Int) {
        self.shellPath = shell
        self.cwd = cwd
        self.emulator = TerminalEmulator(rows: rows, cols: cols, theme: theme, scrollbackLimit: scrollbackLimit)
        emulator.onTitleChange = { [weak self] _ in
            self?.onTitleChange?()
        }
        emulator.onBell = {
            NSSound.beep()
        }
        start(rows: rows, cols: cols)
    }

    deinit {
        pty?.terminate()
    }

    // MARK: - 生命周期

    public func start(rows: Int, cols: Int) {
        guard pty == nil else { return }
        let shellName = (shellPath as NSString).lastPathComponent
        let arguments = ["-\(shellName)"]
        guard let proc = PTYProcess(executable: shellPath,
                                    arguments: arguments,
                                    cwd: cwd,
                                    rows: rows,
                                    cols: cols) else {
            let message = "\r\n[SilTerm] 无法启动 shell：\(shellPath)\r\n"
            emulator.feed(Data(message.utf8))
            scheduleUpdate()
            return
        }
        pty = proc
        isRunning = true
        proc.onData = { [weak self] data in
            guard let self else { return }
            self.emulator.feed(data)
            self.scheduleUpdate()
        }
        proc.onExit = { [weak self] code in
            guard let self else { return }
            self.isRunning = false
            self.lastExitCode = code
            self.pty = nil
            let message = "\r\n[进程已退出，退出码 \(code)]\r\n"
            self.emulator.feed(Data(message.utf8))
            self.onExit?(code)
            self.scheduleUpdate()
        }
    }

    public func close() {
        pty?.terminate()
        pty = nil
        isRunning = false
    }

    // MARK: - 输入输出

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        pty?.write(data)
    }

    public func resize(rows: Int, cols: Int) {
        emulator.resize(rows: rows, cols: cols)
        pty?.resize(rows: rows, cols: cols)
    }

    /// 实时查询 shell 当前目录（失败时回退到缓存值）。
    @discardableResult
    public func refreshWorkingDirectory() -> String {
        if let path = pty?.currentWorkingDirectory(), !path.isEmpty {
            cwd = path
        }
        return cwd
    }

    public var currentWorkingDirectory: String {
        refreshWorkingDirectory()
    }

    public var displayTitle: String {
        let t = emulator.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return (shellPath as NSString).lastPathComponent
    }

    public func setTheme(_ theme: TerminalTheme) {
        emulator.theme = theme
        scheduleUpdate()
    }

    public func setScrollbackLimit(_ limit: Int) {
        emulator.scrollbackLimit = limit
    }

    // MARK: - 刷新节流

    private func scheduleUpdate() {
        updateLock.lock()
        if updatePending {
            updateLock.unlock()
            return
        }
        updatePending = true
        updateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateLock.lock()
            self.updatePending = false
            self.updateLock.unlock()
            self.onUpdate?()
        }
    }
}
