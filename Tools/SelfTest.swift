import Foundation
import AppKit
import UniformTypeIdentifiers

// Headless check of the two pieces that carry most of the risk:
//   1. FolderScanner - which files in a folder count as images, and in what order
//   2. ImageLoading  - do the common formats actually decode, at the right size
// Usage: SelfTest <folder>

@main
enum SelfTest {
    static func main() {
        let folder = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "/tmp/mmptest"
        let budget = 2000

        print("=== 扫描目录: \(folder) ===")
        let found = FolderScanner.imageFiles(in: URL(fileURLWithPath: folder))
        found.forEach { print("  [图]   \($0.lastPathComponent)") }

        let all = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: folder),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        all.filter { !found.contains($0) }
            .forEach { print("  [跳过] \($0.lastPathComponent)（非图片或无法识别类型）") }

        print("\n=== 解码测试 (maxPixelSize = \(budget)) ===")
        var failures = 0
        for url in found {
            let result = ImageLoading.load(url: url, maxPixelSize: budget)
            let name = url.lastPathComponent.padding(toLength: 18, withPad: " ", startingAt: 0)
            guard let decoded = result.decodedPixelSize else {
                print("  ❌ \(name) \(result.errorText ?? "未知错误")")
                failures += 1
                continue
            }
            let original = result.pixelSize ?? .zero
            let maxSide = max(original.width, original.height)
            // 矢量图（SVG）按解码预算栅格化，允许超过其固有尺寸，只要不超过预算即可
            let isVector = url.pathExtension.lowercased() == "svg"
            let expected = isVector ? CGFloat(budget) : min(maxSide, CGFloat(budget))
            let actual = max(decoded.width, decoded.height)
            let ok = actual <= expected + 1
            print("  \(ok ? "✅" : "❌") \(name) 原始 \(Int(original.width))×\(Int(original.height))  →  解码 \(Int(decoded.width))×\(Int(decoded.height))\(isVector ? "（矢量栅格化）" : "")")
            if !ok {
                print("     期望最长边 ≤ \(Int(expected))，实际 \(Int(actual))")
                failures += 1
            }
        }

        print("\n=== 排序（访达风格自然序）===")
        print("  " + found.map { $0.lastPathComponent }.joined(separator: "  →  "))

        print(failures == 0 ? "\n全部通过" : "\n失败 \(failures) 项")
        exit(failures == 0 ? 0 : 1)
    }
}
