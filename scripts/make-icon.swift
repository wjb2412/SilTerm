import AppKit
import CoreGraphics
import Foundation
import ImageIO

// SilTerm 应用图标生成器（由 scripts/make-icon.sh 调用）
// 输入：SRC_IMAGE（任意方形插画） 输出：OUT_ICNS
// 可选：WATERMARK_PATCH_X / WATERMARK_PATCH_Y（0~1，水印覆盖区域起点，默认 0.752 / 0.912）
//       SKIP_WATERMARK=1 跳过去水印

let env = ProcessInfo.processInfo.environment
guard let sourcePath = env["SRC_IMAGE"], let outputPath = env["OUT_ICNS"] else {
    FileHandle.standardError.write("需要 SRC_IMAGE / OUT_ICNS 环境变量\n".data(using: .utf8)!)
    exit(1)
}

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: sourcePath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("无法读取图片：\(sourcePath)\n".data(using: .utf8)!)
    exit(1)
}

let width = image.width
let height = image.height
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - 1. 解码到可写位图

guard let ctx = CGContext(data: nil,
                          width: width,
                          height: height,
                          bitsPerComponent: 8,
                          bytesPerRow: width * 4,
                          space: colorSpace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}
ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

// MARK: - 2. 去水印：用左侧镜像纹理覆盖右下角，并在接缝处羽化

if env["SKIP_WATERMARK"] != "1" {
    let patchRatioX = Double(env["WATERMARK_PATCH_X"] ?? "") ?? 0.752
    let patchRatioY = Double(env["WATERMARK_PATCH_Y"] ?? "") ?? 0.912
    let patchX = Int(Double(width) * patchRatioX)
    let patchY = Int(Double(height) * patchRatioY)
    let feather = max(1.0, Double(width) * 0.012)
    guard let data = ctx.data else { exit(1) }
    let rowBytes = ctx.bytesPerRow
    let ptr = data.bindMemory(to: UInt8.self, capacity: rowBytes * height)
    for y in patchY..<height {
        for x in patchX..<width {
            let srcX = min(width - 1, max(0, 2 * patchX - x))
            let dstOffset = y * rowBytes + x * 4
            let srcOffset = y * rowBytes + srcX * 4
            let dx = Double(x - patchX)
            let dy = Double(y - patchY)
            let alpha = min(1.0, min(dx, dy) / feather)
            for c in 0..<3 {
                let original = Double(ptr[dstOffset + c])
                let replacement = Double(ptr[srcOffset + c])
                ptr[dstOffset + c] = UInt8(max(0, min(255, original + (replacement - original) * alpha)))
            }
        }
    }
}

guard let patched = ctx.makeImage() else { exit(1) }

// MARK: - 3. 生成 1024×1024 主图（824 内容 + 100 边距 + 圆角），符合 macOS 图标规范

let canvas: CGFloat = 1024
let content: CGFloat = 824
let cornerRadius: CGFloat = 185
func makeMaster() -> CGImage? {
    guard let master = CGContext(data: nil,
                                 width: Int(canvas),
                                 height: Int(canvas),
                                 bitsPerComponent: 8,
                                 bytesPerRow: Int(canvas) * 4,
                                 space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    master.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    master.interpolationQuality = .high
    let rect = CGRect(x: (canvas - content) / 2,
                      y: (canvas - content) / 2,
                      width: content,
                      height: content)
    master.saveGState()
    master.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
    master.clip()
    master.draw(patched, in: rect)
    master.restoreGState()
    return master.makeImage()
}

guard let master = makeMaster() else { exit(1) }

// MARK: - 4. 输出 iconset

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SilTerm.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    let size = variant.pixels
    guard let scaled = CGContext(data: nil,
                                 width: size,
                                 height: size,
                                 bitsPerComponent: 8,
                                 bytesPerRow: size * 4,
                                 space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        exit(1)
    }
    scaled.interpolationQuality = .high
    scaled.clear(CGRect(x: 0, y: 0, width: size, height: size))
    scaled.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let cg = scaled.makeImage() else { exit(1) }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

// MARK: - 5. 打包 icns

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失败\n".data(using: .utf8)!)
    exit(1)
}
print("已生成：\(outputPath)")
