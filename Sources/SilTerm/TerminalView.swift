import AppKit
import CVTerm
import SilTermCore

/// Pane 级别的操作回调（由窗口控制器实现）。
protocol TerminalPaneActions: AnyObject {
    func paneSplit(_ paneID: UUID, orientation: SplitOrientation)
    func paneClose(_ paneID: UUID)
    func paneMoveToNewWindow(_ paneID: UUID, at screenPoint: NSPoint?)
    func paneDidBecomeActive(_ paneID: UUID)
    func paneFocusNext(_ paneID: UUID, backwards: Bool)
}

/// 原生 AppKit 终端视图：libvterm 单元格渲染 + 键盘/鼠标输入 + 选择复制 + hover 预览。
final class TerminalView: NSView, NSTextInputClient {
    let session: TerminalSession
    var paneID: UUID

    weak var actions: TerminalPaneActions?
    var onTitleChanged: (() -> Void)?

    private(set) var isActivePane = false

    // 字体与网格
    private var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .bold)
    private var italicFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldItalicFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .bold)
    private var cellWidth: CGFloat = 8
    private var cellHeight: CGFloat = 16
    private var textAscent: CGFloat = 12
    private var textDescent: CGFloat = 3

    private let insetLeft: CGFloat = 8
    private let insetRight: CGFloat = 8
    private let insetTop: CGFloat = 6
    private let insetBottom: CGFloat = 6

    // 设置 / 主题
    private var settings = SettingsStore.shared.settings
    private var theme = SettingsStore.shared.theme
    private var attributeCache: [TextStyleKey: [NSAttributedString.Key: Any]] = [:]
    private var colorCache: [SilTermCore.RGBColor: NSColor] = [:]
    private var observerTokens: [NSObjectProtocol] = []

    // 渲染
    private var cachedFrame: [[RenderCell]] = []
    private var scrollOffset = 0
    private var scrollAccumulator: CGFloat = 0

    // 选择
    private var selectionAnchor: (row: Int, col: Int)?
    private var selectionHead: (row: Int, col: Int)?
    private var isSelecting = false

    // Hover 预览
    private let preview = PathPreviewController()
    private var trackingAreaRef: NSTrackingArea?
    private var hoverWork: DispatchWorkItem?
    private var hoverToken: String?

    // 光标闪烁
    private var blinkTimer: Timer?
    private var cursorOn = true

    // 输入法（IME）组字状态
    private var markedTextString = ""
    private var markedSelection = NSRange(location: 0, length: 0)
    private var markedRangeValue = NSRange(location: NSNotFound, length: 0)

    /// 自定义视图需要自建输入上下文，否则 interpretKeyEvents 无法唤起输入法。
    private lazy var textInputContext = NSTextInputContext(client: self)

    override var inputContext: NSTextInputContext? {
        textInputContext
    }

    private struct TextStyleKey: Hashable {
        var fg: SilTermCore.RGBColor
        var bold: Bool
        var italic: Bool
        var underline: Bool
        var strike: Bool
    }

    // MARK: - 初始化

    init(session: TerminalSession, paneID: UUID) {
        self.session = session
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setupSessionCallbacks()
        setupObservers()
        applySettings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        blinkTimer?.invalidate()
        hoverWork?.cancel()
        preview.hide()
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        actions?.paneDidBecomeActive(paneID)
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        clearMarkedText()
        needsDisplay = true
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 接收 mouseMoved 才能触发 hover 预览
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
        needsDisplay = true
    }

    private func setupSessionCallbacks() {
        session.onUpdate = { [weak self] in
            self?.sessionDidUpdate()
        }
        session.onTitleChange = { [weak self] in
            self?.onTitleChanged?()
        }
        session.onExit = { [weak self] _ in
            self?.needsDisplay = true
            self?.onTitleChanged?()
        }
    }

    private func setupObservers() {
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(forName: SettingsStore.didChangeNotification,
                                                 object: nil,
                                                 queue: .main) { [weak self] _ in
            self?.applySettings()
        })
        observerTokens.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                 object: nil,
                                                 queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        })
        observerTokens.append(center.addObserver(forName: NSWindow.didResignKeyNotification,
                                                 object: nil,
                                                 queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        })
    }

    // MARK: - 设置

    private func applySettings() {
        let newSettings = SettingsStore.shared.settings
        let newTheme = SettingsStore.shared.theme
        let themeChanged = newTheme != theme
        settings = newSettings
        theme = newTheme
        attributeCache.removeAll(keepingCapacity: true)
        colorCache.removeAll(keepingCapacity: true)
        rebuildFonts()
        session.setScrollbackLimit(newSettings.scrollbackLines)
        if themeChanged {
            session.setTheme(newTheme)
        }
        if !newSettings.hoverPreviewEnabled {
            preview.hide()
        }
        setupBlinkTimer()
        updateGridSize()
        needsDisplay = true
    }

    private func rebuildFonts() {
        let size = CGFloat(max(8, min(32, settings.fontSize)))
        font = NSFont(name: settings.fontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        boldItalicFont = NSFontManager.shared.convert(boldFont, toHaveTrait: .italicFontMask)
        let traits = NSFontManager.shared.traits(of: boldFont)
        if boldFont.pointSize == font.pointSize && !traits.contains(.boldFontMask) {
            boldFont = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        // 使用字体的精确前进宽度，避免累积误差导致光标与文字错位
        cellWidth = ("M" as NSString).size(withAttributes: attributes).width
        if cellWidth < 1 { cellWidth = size * 0.6 }
        textAscent = font.ascender
        textDescent = -font.descender
        let naturalHeight = font.ascender - font.descender + font.leading
        cellHeight = ceil(naturalHeight * CGFloat(settings.lineHeightMultiplier))
        if cellHeight < size { cellHeight = ceil(size * 1.2) }
    }

    private func setupBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        cursorOn = true
        guard settings.cursorBlink else { return }
        let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.window?.isKeyWindow == true, self.isActivePane else { return }
            self.cursorOn.toggle()
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    /// 被外部设置为当前活动 Pane。
    func setActive(_ active: Bool) {
        isActivePane = active
        if active { cursorOn = true }
        needsDisplay = true
    }

    // MARK: - 网格尺寸

    private var columns: Int {
        max(1, Int((bounds.width - insetLeft - insetRight) / max(1, cellWidth)))
    }

    private var rows: Int {
        max(1, Int((bounds.height - insetTop - insetBottom) / max(1, cellHeight)))
    }

    override func layout() {
        super.layout()
        updateGridSize()
    }

    private func updateGridSize() {
        let r = rows
        let c = columns
        let cursor = session.emulator.cursorState()
        _ = cursor
        // 仅在变化时触发 PTY resize，避免布局循环
        let key = "\(r)x\(c)"
        if lastGridKey != key {
            lastGridKey = key
            session.resize(rows: r, cols: c)
            needsDisplay = true
        }
    }

    private var lastGridKey = ""

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let background = theme.background.nsColor.withAlphaComponent(CGFloat(settings.backgroundOpacity))
        ctx.setFillColor(background.cgColor)
        ctx.fill(bounds)

        let maxOffset = session.emulator.scrollbackCount
        if scrollOffset > maxOffset { scrollOffset = maxOffset }
        let frame = session.emulator.renderFrame(scrollOffset: scrollOffset)
        cachedFrame = frame

        drawBackgrounds(frame, in: ctx)
        drawSelection(frame, in: ctx)
        drawText(frame)
        if !markedTextString.isEmpty {
            drawMarkedText()
        }
        drawCursor(in: ctx)
    }

    private func drawBackgrounds(_ frame: [[RenderCell]], in ctx: CGContext) {
        for (row, line) in frame.enumerated() where row < rows {
            let y = insetTop + CGFloat(row) * cellHeight
            let count = min(columns, line.count)
            for col in 0..<count {
                let cell = line[col]
                if cell.isDefaultBg { continue }
                let rect = CGRect(x: insetLeft + CGFloat(col) * cellWidth,
                                  y: y,
                                  width: cellWidth,
                                  height: cellHeight)
                ctx.setFillColor(nsColor(cell.bg).cgColor)
                ctx.fill(rect)
            }
        }
    }

    private func drawSelection(_ frame: [[RenderCell]], in ctx: CGContext) {
        guard let (start, end) = normalizedSelection(), hasSelection else { return }
        let selectionColor = theme.selection.nsColor.withAlphaComponent(0.45)
        ctx.setFillColor(selectionColor.cgColor)
        for row in start.row...end.row where row >= 0 && row < frame.count && row < rows {
            let line = frame[row]
            let c0 = row == start.row ? start.col : 0
            let c1 = row == end.row ? end.col : columns - 1
            let clamped0 = max(0, min(c0, line.count - 1))
            let clamped1 = max(0, min(c1, line.count - 1))
            guard clamped1 >= clamped0 else { continue }
            let rect = CGRect(x: insetLeft + CGFloat(clamped0) * cellWidth,
                              y: insetTop + CGFloat(row) * cellHeight,
                              width: CGFloat(clamped1 - clamped0 + 1) * cellWidth,
                              height: cellHeight)
            ctx.fill(rect)
        }
    }

    private func drawText(_ frame: [[RenderCell]]) {
        let textHeight = textAscent + textDescent
        for (row, line) in frame.enumerated() where row < rows {
            var last = min(columns, line.count) - 1
            while last >= 0 {
                let cell = line[last]
                if cell.width != 0 && cell.scalar != 32 { break }
                last -= 1
            }
            guard last >= 0 else { continue }

            let y = insetTop + CGFloat(row) * cellHeight + floor((cellHeight - textHeight) / 2)

            var runStart = 0
            var runText = ""
            var runKey: TextStyleKey?

            // 以单元格网格为锚点分段绘制：避免整行一次性绘制导致字距累积偏差、光标与文字错位
            func flushRun() {
                guard let key = runKey, !runText.isEmpty else { return }
                NSAttributedString(string: runText, attributes: attributes(for: key))
                    .draw(at: NSPoint(x: insetLeft + CGFloat(runStart) * cellWidth, y: y))
                runText = ""
                runKey = nil
            }

            var col = 0
            while col <= last && col < line.count {
                let cell = line[col]
                if cell.width == 0 {
                    col += 1
                    continue
                }
                guard let scalar = Unicode.Scalar(cell.scalar) else {
                    col += 1
                    continue
                }
                let key = TextStyleKey(fg: cell.fg,
                                       bold: cell.bold,
                                       italic: cell.italic,
                                       underline: cell.underline,
                                       strike: cell.strike)
                if cell.width >= 2 {
                    // 宽字符单独定位，避免不同字体的前进宽度不一致
                    flushRun()
                    NSAttributedString(string: String(Character(scalar)), attributes: attributes(for: key))
                        .draw(at: NSPoint(x: insetLeft + CGFloat(col) * cellWidth, y: y))
                } else {
                    if runKey != key {
                        flushRun()
                        runStart = col
                        runKey = key
                    }
                    runText.append(Character(scalar))
                }
                col += max(1, cell.width)
            }
            flushRun()
        }
    }

    /// 绘制输入法组字（候选）文本。
    private func drawMarkedText() {
        guard !markedTextString.isEmpty, isActivePane, window?.isKeyWindow == true else { return }
        let cursor = session.emulator.cursorState()
        guard cursor.row >= 0, cursor.row < rows else { return }
        let textHeight = textAscent + textDescent
        let y = insetTop + CGFloat(cursor.row) * cellHeight + floor((cellHeight - textHeight) / 2)
        let x = insetLeft + CGFloat(cursor.col) * cellWidth
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: nsColor(theme.foreground),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        let attributed = NSAttributedString(string: markedTextString, attributes: attrs)
        attributed.draw(at: NSPoint(x: x, y: y))
        // 组字光标（竖线）
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setFillColor(theme.cursor.nsColor.cgColor)
            ctx.fill(CGRect(x: x + attributed.size().width,
                            y: y,
                            width: max(1.5, cellWidth * 0.1),
                            height: cellHeight))
        }
    }

    private func drawCursor(in ctx: CGContext) {
        guard isActivePane,
              window?.isKeyWindow == true,
              markedTextString.isEmpty,
              scrollOffset == 0,
              cursorOn,
              session.emulator.cursorVisible else { return }
        let cursor = session.emulator.cursorState()
        guard cursor.row >= 0, cursor.row < rows, cursor.col >= 0, cursor.col < columns else { return }
        let x = insetLeft + CGFloat(cursor.col) * cellWidth
        let y = insetTop + CGFloat(cursor.row) * cellHeight
        ctx.setFillColor(theme.cursor.nsColor.withAlphaComponent(0.75).cgColor)
        switch settings.cursorStyle {
        case .block:
            ctx.fill(CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
            drawCellUnderBlockCursor(row: cursor.row, col: cursor.col)
        case .bar:
            ctx.fill(CGRect(x: x, y: y, width: max(2, cellWidth * 0.12), height: cellHeight))
        case .underline:
            ctx.fill(CGRect(x: x, y: y + cellHeight - max(2, cellHeight * 0.1), width: cellWidth, height: max(2, cellHeight * 0.1)))
        }
    }

    /// 方块光标下用背景色重绘字符，避免遮住用户刚输入的字符。
    private func drawCellUnderBlockCursor(row: Int, col: Int) {
        guard row < cachedFrame.count, col < cachedFrame[row].count else { return }
        let cell = cachedFrame[row][col]
        guard cell.width != 0, cell.scalar != 32, let scalar = Unicode.Scalar(cell.scalar) else { return }
        let textHeight = textAscent + textDescent
        let y = insetTop + CGFloat(row) * cellHeight + floor((cellHeight - textHeight) / 2)
        let key = TextStyleKey(fg: cell.fg,
                               bold: cell.bold,
                               italic: cell.italic,
                               underline: cell.underline,
                               strike: cell.strike)
        var attrs = attributes(for: key)
        attrs[.foregroundColor] = theme.background.nsColor
        NSAttributedString(string: String(Character(scalar)), attributes: attrs)
            .draw(at: NSPoint(x: insetLeft + CGFloat(col) * cellWidth, y: y))
    }

    private func attributes(for key: TextStyleKey) -> [NSAttributedString.Key: Any] {
        if let cached = attributeCache[key] { return cached }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: fontVariant(bold: key.bold, italic: key.italic),
            .foregroundColor: nsColor(key.fg)
        ]
        if key.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if key.strike {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        attributeCache[key] = attrs
        return attrs
    }

    private func fontVariant(bold: Bool, italic: Bool) -> NSFont {
        if bold && italic { return boldItalicFont }
        if bold { return boldFont }
        if italic { return italicFont }
        return font
    }

    private func nsColor(_ color: SilTermCore.RGBColor) -> NSColor {
        if let cached = colorCache[color] { return cached }
        let c = color.nsColor
        colorCache[color] = c
        return c
    }

    // MARK: - 输入

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        scrollOffset = 0
        scrollAccumulator = 0

        // 输入法组字期间，所有按键（含方向键、回车）优先交给输入法选词/确认
        if !markedTextString.isEmpty {
            interpretKeyEvents([event])
            return
        }

        let flags = event.modifierFlags.intersection([.shift, .option, .control])
        var raw: UInt32 = 0
        if flags.contains(.shift) { raw |= VTERM_MOD_SHIFT.rawValue }
        if flags.contains(.option) { raw |= VTERM_MOD_ALT.rawValue }
        if flags.contains(.control) { raw |= VTERM_MOD_CTRL.rawValue }
        let modifiers = VTermModifier(rawValue: raw)

        // 特殊键（方向/回车/退格/功能键）直接发送，不经过输入法
        if let key = specialKey(for: event.keyCode) {
            session.write(session.emulator.keyBytes(key: key, modifiers: modifiers))
            return
        }

        // Option / Ctrl 组合保持终端语义（ESC 前缀 / 控制码），不触发输入法
        if flags.contains(.option) || flags.contains(.control) {
            var text = event.characters ?? ""
            if flags.contains(.option) {
                text = event.charactersIgnoringModifiers ?? text
            }
            guard !text.isEmpty else { return }
            if flags.contains(.control), text.unicodeScalars.count == 1,
               let scalar = text.unicodeScalars.first,
               scalar.value >= 0x20, scalar.value < 0x7F {
                let controlScalar = scalar.value & 0x1F
                session.write(session.emulator.unicodeBytes(controlScalar, modifiers: VTERM_MOD_NONE))
                return
            }
            for scalar in text.unicodeScalars {
                let mods: VTermModifier = flags.contains(.option) ? VTERM_MOD_ALT : VTERM_MOD_NONE
                session.write(session.emulator.unicodeBytes(scalar.value, modifiers: mods))
            }
            return
        }

        // 普通可打印字符（含 Shift）交给输入法：无组字时回落到 insertText，有组字时进入候选状态
        interpretKeyEvents([event])
    }

    // MARK: - NSTextInputClient（中文 / 日文 / 韩文输入法）

    func insertText(_ string: Any, replacementRange: NSRange) {
        if !markedTextString.isEmpty {
            clearMarkedText()
        }
        let text: String
        if let value = string as? String {
            text = value
        } else if let value = string as? NSAttributedString {
            text = value.string
        } else {
            return
        }
        guard !text.isEmpty else { return }
        scrollOffset = 0
        for scalar in text.unicodeScalars {
            session.write(session.emulator.unicodeBytes(scalar.value, modifiers: VTERM_MOD_NONE))
        }
        needsDisplay = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let value = string as? String {
            text = value
        } else if let value = string as? NSAttributedString {
            text = value.string
        } else {
            return
        }
        markedTextString = text
        markedSelection = selectedRange
        markedRangeValue = text.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: (text as NSString).length)
        needsDisplay = true
    }

    func unmarkText() {
        clearMarkedText()
    }

    func hasMarkedText() -> Bool {
        !markedTextString.isEmpty
    }

    func markedRange() -> NSRange {
        markedRangeValue
    }

    func selectedRange() -> NSRange {
        markedTextString.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : markedSelection
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard !markedTextString.isEmpty else { return nil }
        let ns = markedTextString as NSString
        guard range.location != NSNotFound, range.location <= ns.length else { return nil }
        let length = min(range.length, ns.length - range.location)
        actualRange?.pointee = NSRange(location: range.location, length: length)
        return NSAttributedString(string: ns.substring(with: NSRange(location: range.location, length: length)),
                                  attributes: [.font: font, .foregroundColor: nsColor(theme.foreground)])
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .foregroundColor, .font]
    }

    /// 输入法候选窗口的锚点（光标所在单元格，屏幕坐标）。
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let cursor = session.emulator.cursorState()
        let rect = CGRect(x: insetLeft + CGFloat(cursor.col) * cellWidth,
                          y: insetTop + CGFloat(cursor.row) * cellHeight,
                          width: cellWidth,
                          height: cellHeight)
        actualRange?.pointee = range
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        let cell = self.cell(at: convert(point, from: nil))
        return cell.row * max(1, columns) + cell.col
    }

    override func doCommand(by selector: Selector) {
        // 组字中不把命令透传给终端（避免退格/回车误发给 shell）
        guard markedTextString.isEmpty else { return }
        switch NSStringFromSelector(selector) {
        case "insertNewline:", "insertLineBreak:", "insertParagraphSeparator:":
            sendSpecialKey(VTERM_KEY_ENTER)
        case "deleteBackward:":
            sendSpecialKey(VTERM_KEY_BACKSPACE)
        case "deleteForward:":
            sendSpecialKey(VTERM_KEY_DEL)
        case "cancelOperation:":
            sendSpecialKey(VTERM_KEY_ESCAPE)
        case "insertTab:":
            sendSpecialKey(VTERM_KEY_TAB)
        case "insertBacktab:":
            sendSpecialKey(VTERM_KEY_TAB, shift: true)
        case "moveLeft:":
            sendSpecialKey(VTERM_KEY_LEFT)
        case "moveRight:":
            sendSpecialKey(VTERM_KEY_RIGHT)
        case "moveUp:":
            sendSpecialKey(VTERM_KEY_UP)
        case "moveDown:":
            sendSpecialKey(VTERM_KEY_DOWN)
        case "scrollPageUp:", "pageUp:":
            sendSpecialKey(VTERM_KEY_PAGEUP)
        case "scrollPageDown:", "pageDown:":
            sendSpecialKey(VTERM_KEY_PAGEDOWN)
        default:
            break
        }
    }

    private func sendSpecialKey(_ key: VTermKey, shift: Bool = false) {
        let modifiers: VTermModifier = shift ? VTERM_MOD_SHIFT : VTERM_MOD_NONE
        session.write(session.emulator.keyBytes(key: key, modifiers: modifiers))
    }

    private func clearMarkedText() {
        guard !markedTextString.isEmpty || markedRangeValue.location != NSNotFound else { return }
        markedTextString = ""
        markedSelection = NSRange(location: 0, length: 0)
        markedRangeValue = NSRange(location: NSNotFound, length: 0)
        needsDisplay = true
    }

    private func specialKey(for keyCode: UInt16) -> VTermKey? {
        switch Int(keyCode) {
        case 36, 76: return VTERM_KEY_ENTER
        case 48: return VTERM_KEY_TAB
        case 51: return VTERM_KEY_BACKSPACE
        case 53: return VTERM_KEY_ESCAPE
        case 123: return VTERM_KEY_LEFT
        case 124: return VTERM_KEY_RIGHT
        case 125: return VTERM_KEY_DOWN
        case 126: return VTERM_KEY_UP
        case 115: return VTERM_KEY_HOME
        case 119: return VTERM_KEY_END
        case 116: return VTERM_KEY_PAGEUP
        case 121: return VTERM_KEY_PAGEDOWN
        case 117: return VTERM_KEY_DEL
        case 114: return VTERM_KEY_INS
        case 122: return VTermKey(rawValue: 256 + 1)
        case 120: return VTermKey(rawValue: 256 + 2)
        case 99: return VTermKey(rawValue: 256 + 3)
        case 118: return VTermKey(rawValue: 256 + 4)
        case 96: return VTermKey(rawValue: 256 + 5)
        case 97: return VTermKey(rawValue: 256 + 6)
        case 98: return VTermKey(rawValue: 256 + 7)
        case 100: return VTermKey(rawValue: 256 + 8)
        case 101: return VTermKey(rawValue: 256 + 9)
        case 109: return VTermKey(rawValue: 256 + 10)
        case 103: return VTermKey(rawValue: 256 + 11)
        case 111: return VTermKey(rawValue: 256 + 12)
        default: return nil
        }
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        clearMarkedText()
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command),
           let url = linkURL(at: point) {
            NSWorkspace.shared.open(url)
            return
        }
        let cell = cell(at: point)
        if event.clickCount >= 2 {
            selectWord(at: cell)
            if settings.autoCopySelection { copySelection() }
            return
        }
        selectionAnchor = cell
        selectionHead = cell
        isSelecting = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelecting else { return }
        let point = convert(event.locationInWindow, from: nil)
        selectionHead = cell(at: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isSelecting else { return }
        isSelecting = false
        if settings.autoCopySelection && hasSelection {
            copySelection()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let menu = buildContextMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        preview.hide()
        if session.emulator.isAltScreen { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * cellHeight
        scrollAccumulator += delta
        let maxOffset = session.emulator.scrollbackCount
        var newOffset = scrollOffset
        while scrollAccumulator >= cellHeight {
            newOffset += 1
            scrollAccumulator -= cellHeight
        }
        while scrollAccumulator <= -cellHeight {
            newOffset -= 1
            scrollAccumulator += cellHeight
        }
        newOffset = min(max(0, newOffset), maxOffset)
        if newOffset != scrollOffset {
            scrollOffset = newOffset
            needsDisplay = true
        }
    }

    private func cell(at point: NSPoint) -> (row: Int, col: Int) {
        let col = max(0, min(columns - 1, Int((point.x - insetLeft) / max(1, cellWidth))))
        let row = max(0, min(rows - 1, Int((point.y - insetTop) / max(1, cellHeight))))
        return (row, col)
    }

    private func selectWord(at cell: (row: Int, col: Int)) {
        guard cell.row < cachedFrame.count else { return }
        let line = cachedFrame[cell.row]
        guard cell.col < line.count else { return }
        func isSpace(_ c: RenderCell) -> Bool {
            guard let scalar = Unicode.Scalar(c.scalar) else { return true }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        if isSpace(line[cell.col]) {
            selectionAnchor = cell
            selectionHead = cell
            needsDisplay = true
            return
        }
        var start = cell.col
        while start > 0 && !isSpace(line[start - 1]) { start -= 1 }
        var end = cell.col
        while end + 1 < line.count && !isSpace(line[end + 1]) { end += 1 }
        selectionAnchor = (cell.row, start)
        selectionHead = (cell.row, end)
        needsDisplay = true
    }

    // MARK: - 选择 / 剪贴板

    private var hasSelection: Bool {
        guard let a = selectionAnchor, let h = selectionHead else { return false }
        return !(a.row == h.row && a.col == h.col)
    }

    private func normalizedSelection() -> ((row: Int, col: Int), (row: Int, col: Int))? {
        guard let a = selectionAnchor, let h = selectionHead else { return nil }
        if a.row < h.row || (a.row == h.row && a.col <= h.col) {
            return (a, h)
        }
        return (h, a)
    }

    private func selectedText() -> String {
        guard let (start, end) = normalizedSelection(), !cachedFrame.isEmpty else { return "" }
        var lines: [String] = []
        let firstRow = max(0, min(start.row, end.row))
        let lastRow = min(cachedFrame.count - 1, max(start.row, end.row))
        guard firstRow <= lastRow else { return "" }
        for row in firstRow...lastRow {
            let line = cachedFrame[row]
            guard !line.isEmpty else { continue }
            let c0 = row == start.row ? start.col : 0
            let c1 = row == end.row ? end.col : line.count - 1
            var s = ""
            var col = max(0, min(c0, line.count - 1))
            let last = max(0, min(c1, line.count - 1))
            while col <= last {
                let cell = line[col]
                if cell.width != 0, let scalar = Unicode.Scalar(cell.scalar) {
                    s.unicodeScalars.append(scalar)
                }
                col += max(1, cell.width)
            }
            lines.append(s.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        return lines.joined(separator: "\n")
    }

    func copySelection() {
        let text = selectedText()
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc func copy(_ sender: Any?) {
        copySelection()
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        session.write(session.emulator.pasteBytes(text))
        scrollOffset = 0
        needsDisplay = true
    }

    override func selectAll(_ sender: Any?) {
        guard !cachedFrame.isEmpty else { return }
        selectionAnchor = (0, 0)
        selectionHead = (max(0, cachedFrame.count - 1), max(0, columns - 1))
        needsDisplay = true
    }

    @objc func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return hasSelection
        }
        if item.action == #selector(paste(_:)) {
            return NSPasteboard.general.string(forType: .string) != nil
        }
        if item.action == #selector(selectAll(_:)) {
            return true
        }
        return true
    }

    // MARK: - 路径 / 链接

    private func linkURL(at point: NSPoint) -> URL? {
        let cell = cell(at: point)
        guard let token = token(at: cell) else { return nil }
        if PathResolver.isWebLink(token) {
            if token.lowercased().hasPrefix("www.") {
                return URL(string: "https://" + token)
            }
            return URL(string: token)
        }
        return PathResolver.resolve(token, relativeTo: session.refreshWorkingDirectory())
    }

    private func token(at cell: (row: Int, col: Int)) -> String? {
        guard cell.row < cachedFrame.count else { return nil }
        let line = cachedFrame[cell.row]
        guard cell.col < line.count else { return nil }
        let terminators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\"'`“”‘’()[]{}<>|,;"))
        func isTerminator(_ s: UInt32) -> Bool {
            guard let scalar = Unicode.Scalar(s) else { return true }
            return terminators.contains(scalar)
        }
        if isTerminator(line[cell.col].scalar) { return nil }
        var start = cell.col
        while start > 0 && !isTerminator(line[start - 1].scalar) { start -= 1 }
        var end = cell.col
        while end + 1 < line.count && !isTerminator(line[end + 1].scalar) { end += 1 }
        var result = ""
        for i in start...end where line[i].width != 0 {
            if let scalar = Unicode.Scalar(line[i].scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Hover 预览

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingAreaRef {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        handleHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hidePreview()
    }

    private func handleHover(at point: NSPoint) {
        guard settings.hoverPreviewEnabled else {
            hidePreview()
            return
        }
        let cell = cell(at: point)
        guard let token = token(at: cell), token.count > 1 else {
            hidePreview()
            return
        }
        if token == hoverToken { return }
        hoverToken = token
        hoverWork?.cancel()
        let cwd = session.refreshWorkingDirectory()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoverToken == token else { return }
            if let url = PathResolver.resolve(token, relativeTo: cwd) {
                self.preview.show(url: url, near: NSEvent.mouseLocation)
            } else {
                self.preview.hide()
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func hidePreview() {
        hoverWork?.cancel()
        hoverWork = nil
        hoverToken = nil
        preview.hide()
    }

    // MARK: - 会话刷新

    private func sessionDidUpdate() {
        let maxOffset = session.emulator.scrollbackCount
        if scrollOffset > maxOffset { scrollOffset = maxOffset }
        needsDisplay = true
    }

    // MARK: - 右键菜单

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let cwd = session.refreshWorkingDirectory()

        let splitVertical = NSMenuItem(title: "垂直分割 Pane",
                                       action: #selector(splitVerticalAction(_:)),
                                       keyEquivalent: "")
        applyCombo(splitVertical, .splitVertical)
        splitVertical.target = self
        menu.addItem(splitVertical)

        let splitHorizontal = NSMenuItem(title: "水平分割 Pane",
                                         action: #selector(splitHorizontalAction(_:)),
                                         keyEquivalent: "")
        applyCombo(splitHorizontal, .splitHorizontal)
        splitHorizontal.target = self
        menu.addItem(splitHorizontal)

        menu.addItem(.separator())

        let close = NSMenuItem(title: "关闭 Pane", action: #selector(closePaneAction(_:)), keyEquivalent: "")
        applyCombo(close, .closePane)
        close.target = self
        menu.addItem(close)

        let copySel = NSMenuItem(title: "复制选中文本", action: #selector(copySelectionAction(_:)), keyEquivalent: "")
        copySel.target = self
        copySel.isEnabled = hasSelection
        menu.addItem(copySel)

        menu.addItem(.separator())

        let copyPath = NSMenuItem(title: "复制当前路径", action: #selector(copyPathAction(_:)), keyEquivalent: "")
        copyPath.target = self
        copyPath.toolTip = cwd
        menu.addItem(copyPath)

        let openFinder = NSMenuItem(title: "在访达中打开当前目录",
                                    action: #selector(openInFinderAction(_:)),
                                    keyEquivalent: "")
        openFinder.target = self
        openFinder.toolTip = cwd
        menu.addItem(openFinder)

        menu.addItem(.separator())

        let newWindow = NSMenuItem(title: "在新窗口打开此 Pane",
                                   action: #selector(moveToNewWindowAction(_:)),
                                   keyEquivalent: "")
        newWindow.target = self
        menu.addItem(newWindow)

        let clear = NSMenuItem(title: "清空回滚缓冲", action: #selector(clearScrollbackAction(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        return menu
    }

    private func applyCombo(_ item: NSMenuItem, _ action: ShortcutAction) {
        guard let combo = settings.combo(for: action) else { return }
        item.keyEquivalent = combo.key
        var mask: NSEvent.ModifierFlags = []
        if combo.command { mask.insert(.command) }
        if combo.shift { mask.insert(.shift) }
        if combo.option { mask.insert(.option) }
        if combo.control { mask.insert(.control) }
        item.keyEquivalentModifierMask = mask
    }

    @objc private func splitVerticalAction(_ sender: Any?) {
        actions?.paneSplit(paneID, orientation: .vertical)
    }

    @objc private func splitHorizontalAction(_ sender: Any?) {
        actions?.paneSplit(paneID, orientation: .horizontal)
    }

    @objc private func closePaneAction(_ sender: Any?) {
        actions?.paneClose(paneID)
    }

    @objc private func copySelectionAction(_ sender: Any?) {
        copySelection()
    }

    @objc private func copyPathAction(_ sender: Any?) {
        FinderBridge.copyToPasteboard(session.refreshWorkingDirectory())
    }

    @objc private func openInFinderAction(_ sender: Any?) {
        FinderBridge.openDirectory(session.refreshWorkingDirectory())
    }

    @objc private func moveToNewWindowAction(_ sender: Any?) {
        actions?.paneMoveToNewWindow(paneID, at: NSEvent.mouseLocation)
    }

    @objc private func clearScrollbackAction(_ sender: Any?) {
        session.emulator.clearScrollback()
        scrollOffset = 0
        needsDisplay = true
    }

    // MARK: - 菜单动作（响应链）

    @objc func splitVertical(_ sender: Any?) {
        actions?.paneSplit(paneID, orientation: .vertical)
    }

    @objc func splitHorizontal(_ sender: Any?) {
        actions?.paneSplit(paneID, orientation: .horizontal)
    }

    @objc func closePaneFromMenu(_ sender: Any?) {
        actions?.paneClose(paneID)
    }

    @objc func increaseFontSize(_ sender: Any?) {
        adjustFontSize(+1)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        adjustFontSize(-1)
    }

    @objc func focusNextPane(_ sender: Any?) {
        actions?.paneFocusNext(paneID, backwards: false)
    }

    @objc func focusPreviousPane(_ sender: Any?) {
        actions?.paneFocusNext(paneID, backwards: true)
    }

    /// 右键菜单：在访达中打开当前目录（复用 FinderBridge，便于统一处理）。
    @objc func revealCurrentDirectoryInFinder(_ sender: Any?) {
        FinderBridge.openDirectory(session.refreshWorkingDirectory())
    }

    private func adjustFontSize(_ delta: Double) {
        var s = SettingsStore.shared.settings
        s.fontSize = max(8, min(32, s.fontSize + delta))
        SettingsStore.shared.settings = s
    }
}
