import AppKit
import Foundation

/// 24 位 RGB 颜色，Codable/Hashable，便于主题与配置持久化。
public struct RGBColor: Codable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: Int, _ g: Int, _ b: Int) {
        self.r = UInt8(clamping: r)
        self.g = UInt8(clamping: g)
        self.b = UInt8(clamping: b)
    }

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// 解析 "#rrggbb" / "rrggbb"。
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.r = UInt8((value >> 16) & 0xFF)
        self.g = UInt8((value >> 8) & 0xFF)
        self.b = UInt8(value & 0xFF)
    }

    public var hexString: String {
        String(format: "#%02x%02x%02x", r, g, b)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1.0)
    }
}

/// 终端主题：默认前景/背景、光标、选中高亮以及 16 色 ANSI 调色板。
public struct TerminalTheme: Codable, Hashable, Sendable {
    public var name: String
    public var foreground: RGBColor
    public var background: RGBColor
    public var cursor: RGBColor
    public var selection: RGBColor
    /// 至少 16 个 ANSI 颜色。
    public var palette: [RGBColor]

    public init(name: String,
                foreground: RGBColor,
                background: RGBColor,
                cursor: RGBColor,
                selection: RGBColor,
                palette: [RGBColor]) {
        self.name = name
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
        var p = palette
        while p.count < 16 { p.append(TerminalTheme.fallback16[p.count]) }
        self.palette = Array(p.prefix(16))
    }

    // MARK: - 内置主题

    public static let dark = TerminalTheme(
        name: "Dark",
        foreground: RGBColor(0xE6, 0xE6, 0xE6),
        background: RGBColor(0x1E, 0x1F, 0x22),
        cursor: RGBColor(0xE6, 0xE6, 0xE6),
        selection: RGBColor(0x26, 0x4F, 0x78),
        palette: [
            RGBColor(0x1E, 0x1F, 0x22), RGBColor(0xE0, 0x5C, 0x5C),
            RGBColor(0x8C, 0xC2, 0x65), RGBColor(0xE5, 0xC0, 0x7B),
            RGBColor(0x61, 0xAF, 0xEF), RGBColor(0xC6, 0x78, 0xDD),
            RGBColor(0x4F, 0xC1, 0xB8), RGBColor(0xCF, 0xCF, 0xCF),
            RGBColor(0x7A, 0x7A, 0x7A), RGBColor(0xFF, 0x7B, 0x72),
            RGBColor(0xB5, 0xE8, 0x90), RGBColor(0xFF, 0xD8, 0x8F),
            RGBColor(0x82, 0xC8, 0xFF), RGBColor(0xE1, 0xA0, 0xF0),
            RGBColor(0x62, 0xD8, 0xCE), RGBColor(0xFF, 0xFF, 0xFF)
        ]
    )

    public static let light = TerminalTheme(
        name: "Light",
        foreground: RGBColor(0x1F, 0x1F, 0x1F),
        background: RGBColor(0xFA, 0xFA, 0xFA),
        cursor: RGBColor(0x1F, 0x1F, 0x1F),
        selection: RGBColor(0xB3, 0xD7, 0xFF),
        palette: [
            RGBColor(0x00, 0x00, 0x00), RGBColor(0xC1, 0x1A, 0x1A),
            RGBColor(0x1A, 0x7F, 0x37), RGBColor(0x9A, 0x6A, 0x00),
            RGBColor(0x1F, 0x4E, 0xA8), RGBColor(0x8B, 0x2A, 0x8B),
            RGBColor(0x0B, 0x6E, 0x6E), RGBColor(0x6B, 0x6B, 0x6B),
            RGBColor(0x4D, 0x4D, 0x4D), RGBColor(0xE0, 0x1B, 0x1B),
            RGBColor(0x1F, 0x8A, 0x3D), RGBColor(0xB0, 0x7A, 0x00),
            RGBColor(0x2A, 0x63, 0xC9), RGBColor(0xA8, 0x35, 0xA8),
            RGBColor(0x0E, 0x86, 0x86), RGBColor(0x2E, 0x2E, 0x2E)
        ]
    )

    public static let highContrast = TerminalTheme(
        name: "High Contrast",
        foreground: RGBColor(0xFF, 0xFF, 0xFF),
        background: RGBColor(0x00, 0x00, 0x00),
        cursor: RGBColor(0xFF, 0xFF, 0xFF),
        selection: RGBColor(0x00, 0x5F, 0xD7),
        palette: [
            RGBColor(0x00, 0x00, 0x00), RGBColor(0xFF, 0x5F, 0x5F),
            RGBColor(0x5F, 0xFF, 0x5F), RGBColor(0xFF, 0xFF, 0x5F),
            RGBColor(0x5F, 0xAF, 0xFF), RGBColor(0xFF, 0x5F, 0xFF),
            RGBColor(0x5F, 0xFF, 0xFF), RGBColor(0xFF, 0xFF, 0xFF),
            RGBColor(0x80, 0x80, 0x80), RGBColor(0xFF, 0x9F, 0x9F),
            RGBColor(0x9F, 0xFF, 0x9F), RGBColor(0xFF, 0xFF, 0x9F),
            RGBColor(0x9F, 0xCF, 0xFF), RGBColor(0xFF, 0x9F, 0xFF),
            RGBColor(0x9F, 0xFF, 0xFF), RGBColor(0xFF, 0xFF, 0xFF)
        ]
    )

    public static let builtins: [TerminalTheme] = [.dark, .light, .highContrast]

    static let fallback16: [RGBColor] = [
        RGBColor(0x00, 0x00, 0x00), RGBColor(0xCD, 0x31, 0x31),
        RGBColor(0x0D, 0xBC, 0x79), RGBColor(0xE5, 0xE5, 0x10),
        RGBColor(0x24, 0x72, 0xC8), RGBColor(0xBC, 0x3F, 0xBC),
        RGBColor(0x11, 0xA8, 0xCD), RGBColor(0xE5, 0xE5, 0xE5),
        RGBColor(0x66, 0x66, 0x66), RGBColor(0xF1, 0x4C, 0x4C),
        RGBColor(0x23, 0xD1, 0x8B), RGBColor(0xF5, 0xF5, 0x43),
        RGBColor(0x3B, 0x8E, 0xEA), RGBColor(0xD6, 0x70, 0xD6),
        RGBColor(0x29, 0xB8, 0xDB), RGBColor(0xFF, 0xFF, 0xFF)
    ]

    /// 解析 ANSI 256 色（0-15 使用主题调色板，16-255 使用标准 xterm 公式）。
    public func color(at index: Int) -> RGBColor {
        if index < 0 { return foreground }
        if index < 16 { return palette[index] }
        if index >= 232 {
            let level = 8 + (index - 232) * 10
            return RGBColor(level, level, level)
        }
        let i = index - 16
        let steps = [0, 95, 135, 175, 215, 255]
        let r = steps[(i / 36) % 6]
        let g = steps[(i / 6) % 6]
        let b = steps[i % 6]
        return RGBColor(r, g, b)
    }

    // MARK: - TOML

    /// 生成可读的 .toml 主题文本。
    public func tomlString() -> String {
        var lines: [String] = []
        lines.append("# SilTerm theme")
        lines.append("name = \"\(name.replacingOccurrences(of: "\"", with: "\\\""))\"")
        lines.append("")
        lines.append("[colors]")
        lines.append("foreground = \"\(foreground.hexString)\"")
        lines.append("background = \"\(background.hexString)\"")
        lines.append("cursor = \"\(cursor.hexString)\"")
        lines.append("selection = \"\(selection.hexString)\"")
        lines.append("")
        lines.append("[palette]")
        for (i, c) in palette.enumerated() {
            lines.append("color\(i) = \"\(c.hexString)\"")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// 从 .toml 文本解析主题（容错：缺失项使用 Dark 主题补全）。
    public static func parse(toml: String) -> TerminalTheme {
        var theme = TerminalTheme.dark
        var section = ""
        for rawLine in toml.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).lowercased()
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            let color = RGBColor(hex: value)
            switch (section, key) {
            case ("", "name"):
                theme.name = value
            case ("colors", "foreground"), ("", "foreground"):
                if let c = color { theme.foreground = c }
            case ("colors", "background"), ("", "background"):
                if let c = color { theme.background = c }
            case ("colors", "cursor"), ("", "cursor"):
                if let c = color { theme.cursor = c }
            case ("colors", "selection"), ("", "selection"):
                if let c = color { theme.selection = c }
            default:
                if section == "palette", key.hasPrefix("color"),
                   let idx = Int(key.dropFirst(5)), (0..<16).contains(idx),
                   let c = color {
                    theme.palette[idx] = c
                }
            }
        }
        return theme
    }
}
