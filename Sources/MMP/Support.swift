import AppKit
import UniformTypeIdentifiers

/// CoreGraphics / ImageIO based image decoding.
/// Images are downsampled at decode time so a 100MP photo never blows up memory.
enum ImageLoading {

    struct Result {
        let nsImage: NSImage?
        let pixelSize: CGSize?
        /// Size of the actually decoded bitmap (after downsampling).
        let decodedPixelSize: CGSize?
        let errorText: String?
    }

    static func load(url: URL, maxPixelSize: Int) -> Result {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return Result(nsImage: nil, pixelSize: nil, decodedPixelSize: nil, errorText: "无法读取该文件，可能不是支持的图片格式")
        }
        guard CGImageSourceGetCount(source) > 0 else {
            return Result(nsImage: nil, pixelSize: nil, decodedPixelSize: nil, errorText: "文件中没有可显示的图片")
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        if orientation >= 5 { swap(&width, &height) }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return Result(nsImage: nil, pixelSize: nil, decodedPixelSize: nil, errorText: "图片解码失败")
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return Result(
            nsImage: image,
            pixelSize: CGSize(width: width, height: height),
            decodedPixelSize: CGSize(width: cgImage.width, height: cgImage.height),
            errorText: nil
        )
    }
}

/// Lists the sibling images of a given file, sorted the way Finder sorts.
enum FolderScanner {

    static func isImage(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return type.conforms(to: .image)
    }

    static func imageFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { isImage($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// Registers MMP as the default handler for the common image UTIs.
enum DefaultAppSetter {

    static let imageUTIs: [String] = [
        "public.jpeg",
        "public.png",
        "public.tiff",
        "public.heic",
        "public.heif",
        "com.compuserve.gif",
        "com.microsoft.bmp",
        "org.webmproject.webp",
        "public.webp",
        "public.svg-image",
        "public.camera-raw-image",
        "com.adobe.raw-image"
    ]

    struct Outcome {
        let succeeded: Int
        let total: Int
        let bundleIdentifier: String?
        let isInstalledInApplications: Bool
    }

    @discardableResult
    static func setAsDefaultViewer() -> Outcome {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return Outcome(succeeded: 0, total: imageUTIs.count, bundleIdentifier: nil, isInstalledInApplications: false)
        }
        var succeeded = 0
        for uti in imageUTIs where LSSetDefaultRoleHandlerForContentType(uti as CFString, .viewer, bundleID as CFString) == noErr {
            succeeded += 1
        }
        return Outcome(
            succeeded: succeeded,
            total: imageUTIs.count,
            bundleIdentifier: bundleID,
            isInstalledInApplications: Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications"
        )
    }
}
