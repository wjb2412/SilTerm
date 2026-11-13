import CShim
import Darwin
import Foundation

/// 基于 forkpty 的伪终端进程封装。
///
/// 负责：
/// - 启动登录 shell（zsh/bash/fish/nushell）
/// - 非阻塞读取 PTY 输出
/// - 写入用户输入、调整窗口大小
/// - 查询 shell 当前工作目录（libproc）
/// - 子进程退出监听
public final class PTYProcess {
    public private(set) var shellPID: pid_t
    public private(set) var masterFD: Int32

    /// PTY 输出回调（在内部串行队列上调用）。
    public var onData: ((Data) -> Void)?
    /// 进程退出回调（主线程）。
    public var onExit: ((Int32) -> Void)?

    private let readQueue = DispatchQueue(label: "com.silterm.pty.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "com.silterm.pty.write", qos: .userInitiated)
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var closed = false
    private let closeLock = NSLock()
    private let writeLock = NSLock()
    private var pendingWrites = Data()

    /// 创建并启动 PTY。
    /// - Parameters:
    ///   - executable: shell 绝对路径
    ///   - arguments: 参数，第一个通常是 "-zsh"（登录 shell）
    ///   - cwd: 初始工作目录
    ///   - rows/cols: 初始终端尺寸
    public init?(executable: String, arguments: [String], cwd: String, rows: Int, cols: Int) {
        var pid: pid_t = 0
        // strdup 出来的参数在 spawn 之后释放
        var argvStorage: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argvStorage.append(nil)
        defer {
            for ptr in argvStorage where ptr != nil { free(ptr) }
        }

        let fd = executable.withCString { exePtr -> Int32 in
            cwd.withCString { cwdPtr -> Int32 in
                argvStorage.withUnsafeMutableBufferPointer { buf -> Int32 in
                    silterm_spawn_pty(exePtr,
                                      UnsafePointer(buf.baseAddress),
                                      cwdPtr,
                                      Int32(rows),
                                      Int32(cols),
                                      &pid)
                }
            }
        }

        guard fd >= 0, pid > 0 else { return nil }
        self.masterFD = fd
        self.shellPID = pid
        startReading()
        startExitMonitor()
    }

    deinit {
        close()
    }

    // MARK: - 读取

    private func startReading() {
        let src = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: readQueue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            let n = read(self.masterFD, &buffer, buffer.count)
            if n > 0 {
                self.onData?(Data(buffer[0..<Int(n)]))
            } else if n == 0 {
                self.close()
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                self.close()
            }
        }
        src.resume()
        readSource = src
    }

    private func startExitMonitor() {
        let src = DispatchSource.makeProcessSource(identifier: shellPID, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            let r = waitpid(self.shellPID, &status, WNOHANG)
            self.close()
            if r >= 0 {
                if status & 0x7F == 0 {
                    self.onExit?((status >> 8) & 0xFF)
                } else {
                    self.onExit?(-(status & 0x7F))
                }
            } else {
                self.onExit?(0)
            }
        }
        src.resume()
        exitSource = src
    }

    // MARK: - 写入

    /// 线程安全的异步写入，输入顺序由串行队列保证。
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        writeLock.lock()
        pendingWrites.append(data)
        writeLock.unlock()
        writeQueue.async { [weak self] in
            self?.flushWrites()
        }
    }

    private func flushWrites() {
        writeLock.lock()
        var data = pendingWrites
        pendingWrites.removeAll(keepingCapacity: true)
        writeLock.unlock()
        guard !data.isEmpty else { return }

        var attempts = 0
        while !data.isEmpty && attempts < 2000 {
            let fd = masterFD
            guard fd >= 0 else { return }
            let written: Int = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return Darwin.write(fd, base, data.count)
            }
            if written > 0 {
                data.removeFirst(written)
                attempts = 0
            } else if written < 0 && errno == EINTR {
                continue
            } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                attempts += 1
                usleep(1000)
            } else {
                return
            }
        }
    }

    // MARK: - 尺寸

    public func resize(rows: Int, cols: Int) {
        guard masterFD >= 0 else { return }
        _ = silterm_resize_pty(masterFD, Int32(rows), Int32(cols))
    }

    // MARK: - 当前工作目录

    public func currentWorkingDirectory() -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard silterm_process_cwd(shellPID, &buffer, buffer.count) == 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    // MARK: - 生命周期

    /// 发送 SIGHUP 并关闭 PTY（幂等）。
    public func close() {
        closeLock.lock()
        if closed {
            closeLock.unlock()
            return
        }
        closed = true
        let fd = masterFD
        masterFD = -1
        closeLock.unlock()

        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    /// 主动终止 shell 及其前台进程组。
    public func terminate() {
        if shellPID > 0 {
            kill(-shellPID, SIGHUP)
            kill(shellPID, SIGHUP)
        }
        close()
    }
}
