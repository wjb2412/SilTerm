import AppKit
import QuickLookThumbnailing

/// Hover 文件路径时的轻量缩略预览浮窗。
/// 使用系统 QuickLook 生成缩略图，隐藏时立即释放图片资源。
final class PathPreviewController {
    private let panel: NSPanel
    private let imageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    private var currentURL: URL?
    private var currentRequest: QLThumbnailGenerator.Request?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 224, height: 196),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 224, height: 196))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        container.autoresizingMask = [.width, .height]

        imageView.frame = NSRect(x: 12, y: 46, width: 200, height: 138)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true

        nameLabel.frame = NSRect(x: 12, y: 24, width: 200, height: 18)
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.textColor = .labelColor

        pathLabel.frame = NSRect(x: 12, y: 6, width: 200, height: 15)
        pathLabel.font = NSFont.systemFont(ofSize: 10)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.textColor = .secondaryLabelColor

        container.addSubview(imageView)
        container.addSubview(nameLabel)
        container.addSubview(pathLabel)
        panel.contentView = container
    }

    deinit {
        hide()
    }

    /// 显示指定文件的预览。
    func show(url: URL, near screenPoint: NSPoint) {
        if currentURL != url {
            currentURL = url
            nameLabel.stringValue = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            pathLabel.stringValue = url.deletingLastPathComponent().path
            if isDirectory(url) {
                imageView.image = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                imageView.image = nil
            }
            generateThumbnail(for: url)
        }
        position(near: screenPoint)
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    /// 隐藏并释放缩略图资源。
    func hide() {
        if let request = currentRequest {
            QLThumbnailGenerator.shared.cancel(request)
            currentRequest = nil
        }
        currentURL = nil
        imageView.image = nil
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    // MARK: - 私有

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func generateThumbnail(for url: URL) {
        if let request = currentRequest {
            QLThumbnailGenerator.shared.cancel(request)
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: 400, height: 276),
                                                   scale: scale,
                                                   representationTypes: .thumbnail)
        currentRequest = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let self, let representation else { return }
            DispatchQueue.main.async {
                guard self.currentURL == url else { return }
                self.imageView.image = representation.nsImage
            }
        }
    }

    private func position(near point: NSPoint) {
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = point.x + 16
        var y = point.y - size.height - 16
        if x + size.width > visible.maxX { x = point.x - size.width - 16 }
        if y < visible.minY { y = point.y + 20 }
        if x < visible.minX { x = visible.minX + 8 }
        if y + size.height > visible.maxY { y = visible.maxY - size.height - 8 }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
