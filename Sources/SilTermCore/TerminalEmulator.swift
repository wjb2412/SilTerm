import CVTerm
import Foundation

/// 渲染用的终端单元格。
public struct RenderCell {
    /// Unicode 标量；0 表示空白。
    public var scalar: UInt32 = 0
    /// 0 = 宽字符的延续单元格，1 = 普通，2 = 宽字符首格。
    public var width: Int = 1
    public var fg: RGBColor
    public var bg: RGBColor
    public var bold: Bool = false
    public var italic: Bool = false
    public var underline: Bool = false
    public var strike: Bool = false
    public var reverse: Bool = false
    /// 背景是否为主题默认背景（绘制时可跳过填充）。
    public var isDefaultBg: Bool = true
}

public struct CursorState {
    public var row: Int
    public var col: Int
    public var visible: Bool
    public var shape: Int
}

// MARK: - C 回调

private func emulatorOf(_ user: UnsafeMutableRawPointer?) -> TerminalEmulator? {
    guard let user else { return nil }
    return Unmanaged<TerminalEmulator>.fromOpaque(user).takeUnretainedValue()
}

private func cDamage(_ rect: VTermRect, _ user: UnsafeMutableRawPointer?) -> Int32 {
    emulatorOf(user)?.markDamaged()
    return 1
}

private func cMoveCursor(_ pos: VTermPos, _ oldPos: VTermPos, _ visible: Int32, _ user: UnsafeMutableRawPointer?) -> Int32 {
    emulatorOf(user)?.markDamaged()
    return 1
}

private func cSetTermProp(_ prop: VTermProp, _ val: UnsafeMutablePointer<VTermValue>?, _ user: UnsafeMutableRawPointer?) -> Int32 {
    emulatorOf(user)?.handleTermProp(prop, val)
    return 1
}

private func cBell(_ user: UnsafeMutableRawPointer?) -> Int32 {
    emulatorOf(user)?.handleBell()
    return 1
}

private func cResize(_ rows: Int32, _ cols: Int32, _ user: UnsafeMutableRawPointer?) -> Int32 {
    emulatorOf(user)?.handleResize(rows: Int(rows), cols: Int(cols))
    return 1
}

private func cPushLine(_ cols: Int32, _ cells: UnsafePointer<VTermScreenCell>?, _ user: UnsafeMutableRawPointer?) -> Int32 {
    emulatorOf(user)?.handlePushLine(cols: Int(cols), cells: cells)
    return 1
}

private func cPopLine(_ cols: Int32, _ cells: UnsafeMutablePointer<VTermScreenCell>?, _ user: UnsafeMutableRawPointer?) -> Int32 {
    // 本项目使用自定义回滚缓冲，不支持回填
    return 0
}

private func cScrollClear(_ user: UnsafeMutableRawPointer?) -> Int32 {
    emulatorOf(user)?.clearScrollback()
    return 1
}

// MARK: - 终端模拟器

/// libvterm 的 Swift 封装：解析 PTY 输出、维护回滚缓冲、生成渲染帧、生成键盘输入。
public final class TerminalEmulator {
    private var vt: OpaquePointer?
    private var screen: OpaquePointer?
    private var state: OpaquePointer?

    /// libvterm 只保存回调结构体指针（不拷贝），必须由我们保证生命周期稳定。
    private let callbacksStorage: UnsafeMutablePointer<VTermScreenCallbacks>

    private let lock = NSRecursiveLock()

    public private(set) var rows: Int
    public private(set) var cols: Int

    public private(set) var title: String = ""
    public private(set) var altScreen: Bool = false
    public private(set) var cursorVisible: Bool = true
    public private(set) var cursorShape: Int = 1
    public private(set) var mouseMode: Int = 0

    public var onTitleChange: ((String) -> Void)?
    public var onBell: (() -> Void)?

    public var theme: TerminalTheme {
        didSet {
            lock.lock()
            resetScrollbackLocked()
            lock.unlock()
            markDamaged()
        }
    }

    /// 回滚行数上限。
    public var scrollbackLimit: Int {
        didSet { trimScrollbackLocked() }
    }

    // 回滚缓冲
    private struct StoredStyle: Hashable {
        var fg: RGBColor
        var bg: RGBColor
        var flags: UInt8 // bit0 bold, 1 italic, 2 underline, 3 strike
        var defaultBg: Bool
    }

    private struct StoredCell {
        var scalar: UInt32
        var style: UInt32
        var width: UInt8
    }

    private struct StoredLine {
        var cells: [StoredCell]
    }

    private var scrollback: [StoredLine] = []
    private var styleTable: [StoredStyle] = []
    private var styleIndex: [StoredStyle: UInt32] = [:]

    private var titleBuffer: String = ""
    private var pendingDamage = false

    // MARK: 初始化

    public init(rows: Int, cols: Int, theme: TerminalTheme, scrollbackLimit: Int) {
        self.rows = max(1, rows)
        self.cols = max(1, cols)
        self.theme = theme
        self.scrollbackLimit = max(0, scrollbackLimit)
        self.callbacksStorage = UnsafeMutablePointer<VTermScreenCallbacks>.allocate(capacity: 1)
        self.callbacksStorage.initialize(to: VTermScreenCallbacks())

        vt = vterm_new(Int32(self.rows), Int32(self.cols))
        guard let vt else { return }
        vterm_set_utf8(vt, 1)
        vterm_screen_enable_altscreen(vterm_obtain_screen(vt), 1)
        state = vterm_obtain_state(vt)
        screen = vterm_obtain_screen(vt)

        let callbacks = callbacksStorage
        callbacks.pointee.damage = cDamage
        callbacks.pointee.movecursor = cMoveCursor
        callbacks.pointee.settermprop = cSetTermProp
        callbacks.pointee.bell = cBell
        callbacks.pointee.resize = cResize
        callbacks.pointee.sb_pushline = cPushLine
        callbacks.pointee.sb_popline = cPopLine
        callbacks.pointee.sb_clear = cScrollClear
        if let screen {
            vterm_screen_set_callbacks(screen, callbacks, Unmanaged.passUnretained(self).toOpaque())
            vterm_screen_set_damage_merge(screen, VTERM_DAMAGE_ROW)
            vterm_screen_reset(screen, 1)
        }
        if let state {
            vterm_state_set_bold_highbright(state, 1)
        }
    }

    deinit {
        callbacksStorage.pointee = VTermScreenCallbacks()
        if let screen {
            vterm_screen_set_callbacks(screen, callbacksStorage, nil)
        }
        if let vt {
            vterm_free(vt)
        }
        callbacksStorage.deinitialize(count: 1)
        callbacksStorage.deallocate()
    }

    // MARK: - 数据输入

    /// 写入 PTY 字节流（内部解析）。
    public func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        if let vt {
            data.withUnsafeBytes { raw in
                if let base = raw.bindMemory(to: CChar.self).baseAddress {
                    _ = vterm_input_write(vt, base, data.count)
                }
            }
            if let screen {
                vterm_screen_flush_damage(screen)
            }
        }
        lock.unlock()
    }

    /// 调整尺寸。
    public func resize(rows: Int, cols: Int) {
        guard rows > 0, cols > 0 else { return }
        lock.lock()
        self.rows = rows
        self.cols = cols
        if let vt {
            vterm_set_size(vt, Int32(rows), Int32(cols))
            if let screen { vterm_screen_flush_damage(screen) }
        }
        lock.unlock()
    }

    // MARK: - 键盘输入（返回需要写入 PTY 的字节）

    public func keyBytes(key: VTermKey, modifiers: VTermModifier) -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let vt else { return Data() }
        vterm_keyboard_key(vt, key, modifiers)
        return drainOutputLocked()
    }

    public func unicodeBytes(_ scalar: UInt32, modifiers: VTermModifier) -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let vt else { return Data() }
        vterm_keyboard_unichar(vt, scalar, modifiers)
        return drainOutputLocked()
    }

    /// 处理粘贴：自动包裹 bracketed paste 序列。
    public func pasteBytes(_ text: String) -> Data {
        guard !text.isEmpty else { return Data() }
        lock.lock()
        defer { lock.unlock() }
        guard let vt else { return Data() }
        var out = Data()
        vterm_keyboard_start_paste(vt)
        out.append(drainOutputLocked())
        if let data = text.data(using: .utf8) {
            out.append(data)
        }
        vterm_keyboard_end_paste(vt)
        out.append(drainOutputLocked())
        return out
    }

    private func drainOutputLocked() -> Data {
        guard let vt else { return Data() }
        let count = vterm_output_get_buffer_current(vt)
        guard count > 0 else { return Data() }
        var buffer = [CChar](repeating: 0, count: count)
        let readCount = vterm_output_read(vt, &buffer, count)
        guard readCount > 0 else { return Data() }
        return Data(bytes: buffer, count: readCount)
    }

    // MARK: - 光标 / 状态

    public func cursorState() -> CursorState {
        lock.lock()
        defer { lock.unlock() }
        var row: Int32 = 0
        var col: Int32 = 0
        if let state {
            var pos = VTermPos(row: 0, col: 0)
            vterm_state_get_cursorpos(state, &pos)
            row = pos.row
            col = pos.col
        }
        return CursorState(row: Int(row), col: Int(col), visible: cursorVisible, shape: cursorShape)
    }

    public var scrollbackCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scrollback.count
    }

    /// 是否处于备用屏幕（vim/less 等），此状态下禁用回滚。
    public var isAltScreen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return altScreen
    }

    public func clearScrollback() {
        lock.lock()
        resetScrollbackLocked()
        lock.unlock()
        markDamaged()
    }

    private func resetScrollbackLocked() {
        scrollback.removeAll(keepingCapacity: true)
        styleTable.removeAll(keepingCapacity: true)
        styleIndex.removeAll(keepingCapacity: true)
    }

    private func trimScrollbackLocked() {
        guard scrollbackLimit >= 0 else { return }
        if scrollback.count > scrollbackLimit {
            let removeCount = scrollback.count - scrollbackLimit
            scrollback.removeFirst(removeCount)
        }
        // 样式表过大时做一次压缩，避免长期运行无限增长
        if styleTable.count > 512 {
            var newTable: [StoredStyle] = []
            var newIndex: [StoredStyle: UInt32] = [:]
            var remap = [UInt32](repeating: 0, count: styleTable.count)
            for (i, style) in styleTable.enumerated() {
                if let existing = newIndex[style] {
                    remap[i] = existing
                } else {
                    let id = UInt32(newTable.count)
                    newTable.append(style)
                    newIndex[style] = id
                    remap[i] = id
                }
            }
            for li in scrollback.indices {
                for ci in scrollback[li].cells.indices {
                    let old = Int(scrollback[li].cells[ci].style)
                    if old >= 0 && old < remap.count {
                        scrollback[li].cells[ci].style = remap[old]
                    }
                }
            }
            styleTable = newTable
            styleIndex = newIndex
        }
    }

    // MARK: - 回调处理

    func markDamaged() {
        lock.lock()
        pendingDamage = true
        lock.unlock()
    }

    func handleTermProp(_ prop: VTermProp, _ val: UnsafeMutablePointer<VTermValue>?) {
        guard let val else { return }
        switch prop {
        case VTERM_PROP_CURSORVISIBLE:
            cursorVisible = silterm_value_bool(val) != 0
        case VTERM_PROP_CURSORSHAPE:
            cursorShape = Int(silterm_value_number(val))
        case VTERM_PROP_ALTSCREEN:
            altScreen = silterm_value_bool(val) != 0
        case VTERM_PROP_MOUSE:
            mouseMode = Int(silterm_value_number(val))
        case VTERM_PROP_TITLE:
            let len = silterm_value_string_len(val)
            if let ptr = silterm_value_string(val), len > 0 {
                let data = Data(bytes: ptr, count: len)
                if silterm_value_string_final(val) != 0 {
                    titleBuffer = ""
                }
                if let s = String(data: data, encoding: .utf8) {
                    titleBuffer += s
                }
                if silterm_value_string_final(val) != 0 {
                    title = titleBuffer
                    let t = titleBuffer
                    titleBuffer = ""
                    DispatchQueue.main.async { [weak self] in
                        self?.onTitleChange?(t)
                    }
                }
            }
        default:
            break
        }
    }

    func handleBell() {
        DispatchQueue.main.async { [weak self] in
            self?.onBell?()
        }
    }

    func handleResize(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
    }

    func handlePushLine(cols: Int, cells: UnsafePointer<VTermScreenCell>?) {
        guard let cells, cols > 0 else { return }
        var line = StoredLine(cells: [])
        line.cells.reserveCapacity(cols)
        for i in 0..<cols {
            var info = SilTermCellInfo()
            silterm_decode_cell(cells.advanced(by: i), &info)
            let decoded = decode(info: info)
            let style = StoredStyle(
                fg: decoded.fg,
                bg: decoded.bg,
                flags: styleFlags(decoded),
                defaultBg: decoded.isDefaultBg
            )
            let id = styleIDLocked(style)
            line.cells.append(StoredCell(scalar: decoded.scalar, style: id, width: UInt8(decoded.width)))
        }
        scrollback.append(line)
        trimScrollbackLocked()
    }

    private func styleFlags(_ c: RenderCell) -> UInt8 {
        var f: UInt8 = 0
        if c.bold { f |= 1 }
        if c.italic { f |= 2 }
        if c.underline { f |= 4 }
        if c.strike { f |= 8 }
        return f
    }

    private func styleIDLocked(_ style: StoredStyle) -> UInt32 {
        if let existing = styleIndex[style] { return existing }
        let id = UInt32(styleTable.count)
        styleTable.append(style)
        styleIndex[style] = id
        return id
    }

    // MARK: - 颜色解析

    private func resolveColor(info: SilTermCellInfo, foreground: Bool) -> (RGBColor, Bool) {
        if foreground {
            if info.fg_default != 0 { return (theme.foreground, true) }
            if info.fg_indexed != 0 { return (theme.color(at: Int(info.fg_index)), false) }
            return (RGBColor(Int(info.fg_r), Int(info.fg_g), Int(info.fg_b)), false)
        } else {
            if info.bg_default != 0 { return (theme.background, true) }
            if info.bg_indexed != 0 { return (theme.color(at: Int(info.bg_index)), false) }
            return (RGBColor(Int(info.bg_r), Int(info.bg_g), Int(info.bg_b)), false)
        }
    }

    private func decode(info: SilTermCellInfo) -> RenderCell {
        var (fg, _) = resolveColor(info: info, foreground: true)
        var (bg, defaultBg) = resolveColor(info: info, foreground: false)
        var reverse = info.reverse != 0
        if reverse {
            swap(&fg, &bg)
            defaultBg = false
        }
        if info.conceal != 0 {
            fg = bg
        }
        var scalar = info.chars.0
        if scalar == 0 { scalar = 32 }
        return RenderCell(
            scalar: scalar,
            width: Int(info.width),
            fg: fg,
            bg: bg,
            bold: info.bold != 0,
            italic: info.italic != 0,
            underline: info.underline != 0,
            strike: info.strike != 0,
            reverse: reverse,
            isDefaultBg: defaultBg
        )
    }

    // MARK: - 渲染帧

    /// 生成可视区域渲染帧。
    /// - Parameter scrollOffset: 向上回滚的行数（0 表示底部）。
    public func renderFrame(scrollOffset: Int) -> [[RenderCell]] {
        lock.lock()
        defer { lock.unlock() }
        let offset = altScreen ? 0 : min(max(0, scrollOffset), scrollback.count)
        let startVirtual = scrollback.count - offset
        var lines: [[RenderCell]] = []
        lines.reserveCapacity(rows)
        for viewRow in 0..<rows {
            let virtualIndex = startVirtual + viewRow
            if virtualIndex >= 0 && virtualIndex < scrollback.count {
                lines.append(renderStoredLine(scrollback[virtualIndex]))
            } else {
                let screenRow = virtualIndex - scrollback.count
                if screenRow >= 0 && screenRow < rows {
                    lines.append(renderScreenRow(screenRow))
                } else {
                    lines.append(emptyLine())
                }
            }
        }
        pendingDamage = false
        return lines
    }

    private func renderScreenRow(_ row: Int) -> [RenderCell] {
        var cells: [RenderCell] = []
        cells.reserveCapacity(cols)
        guard let screen else { return emptyLine() }
        for col in 0..<cols {
            var cell = VTermScreenCell()
            let ok = vterm_screen_get_cell(screen, VTermPos(row: Int32(row), col: Int32(col)), &cell)
            if ok == 0 {
                cells.append(emptyCell())
            } else {
                var info = SilTermCellInfo()
                silterm_decode_cell(&cell, &info)
                cells.append(decode(info: info))
            }
        }
        return cells
    }

    private func renderStoredLine(_ line: StoredLine) -> [RenderCell] {
        var cells: [RenderCell] = []
        cells.reserveCapacity(cols)
        for stored in line.cells.prefix(cols) {
            let idx = Int(stored.style)
            let style = idx < styleTable.count ? styleTable[idx] : StoredStyle(fg: theme.foreground,
                                                                              bg: theme.background,
                                                                              flags: 0,
                                                                              defaultBg: true)
            let flags = style.flags
            cells.append(RenderCell(
                scalar: stored.scalar,
                width: Int(stored.width),
                fg: style.fg,
                bg: style.bg,
                bold: flags & 1 != 0,
                italic: flags & 2 != 0,
                underline: flags & 4 != 0,
                strike: flags & 8 != 0,
                reverse: false,
                isDefaultBg: style.defaultBg
            ))
        }
        while cells.count < cols {
            cells.append(emptyCell())
        }
        return cells
    }

    private func emptyCell() -> RenderCell {
        RenderCell(scalar: 32, width: 1, fg: theme.foreground, bg: theme.background, isDefaultBg: true)
    }

    private func emptyLine() -> [RenderCell] {
        Array(repeating: emptyCell(), count: cols)
    }

    // MARK: - 文本提取

    /// 提取指定行（相对可视区域）纯文本。
    public func lineText(_ line: [RenderCell]) -> String {
        var result = ""
        for cell in line where cell.width != 0 {
            if let scalar = Unicode.Scalar(cell.scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result.trimmingTrailingSpaces()
    }
}

extension String {
    /// 去掉行尾空白（终端右侧常有大片空白）。
    func trimmingTrailingSpaces() -> String {
        var s = self
        while let last = s.last, last == " " {
            s.removeLast()
        }
        return s
    }
}
