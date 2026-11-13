import Foundation

/// 终端输出中的路径 / 链接识别与解析。
public enum PathResolver {
    /// 判断是否为 http(s) 链接。
    public static func isWebLink(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.")
    }

    /// 将终端中的一段文本解析为本地存在的文件 URL。
    /// 支持：绝对路径、`~/` 路径、相对当前目录的路径、`file://` URL、`path:line:col`。
    public static func resolve(_ raw: String, relativeTo cwd: String) -> URL? {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’"))
        guard !token.isEmpty else { return nil }
        if isWebLink(token) || token.contains("://") { return nil }

        // 去掉 :line 或 :line:col 后缀
        if let range = token.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) {
            token.removeSubrange(range)
        }
        // 去掉包裹 / 尾随标点
        while let first = token.first, "([{<".contains(first) {
            token.removeFirst()
        }
        while let last = token.last, ",.;:)]}>".contains(last) {
            token.removeLast()
        }
        guard !token.isEmpty else { return nil }

        var path = token
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        if path == "~" {
            path = NSHomeDirectory()
        } else if path.hasPrefix("~/") {
            path = (NSHomeDirectory() as NSString).appendingPathComponent(String(path.dropFirst(2)))
        } else if !path.hasPrefix("/") {
            path = (cwd as NSString).appendingPathComponent(path)
        }
        path = (path as NSString).standardizingPath

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue)
    }

    /// 从一行文本中截取包含指定字符位置的 token（按 Unicode 标量近似处理）。
    public static func token(in line: String, around column: Int) -> String? {
        let scalars = Array(line.unicodeScalars)
        guard !scalars.isEmpty else { return nil }
        let index = min(max(0, column), scalars.count - 1)
        let terminators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`“”‘’()[]{}<>|,;"))
        func isTerminator(_ scalar: Unicode.Scalar) -> Bool {
            terminators.contains(scalar)
        }
        if isTerminator(scalars[index]) { return nil }
        var start = index
        while start > 0 && !isTerminator(scalars[start - 1]) {
            start -= 1
        }
        var end = index
        while end + 1 < scalars.count && !isTerminator(scalars[end + 1]) {
            end += 1
        }
        var view = String.UnicodeScalarView()
        for i in start...end {
            view.append(scalars[i])
        }
        return String(view)
    }
}
