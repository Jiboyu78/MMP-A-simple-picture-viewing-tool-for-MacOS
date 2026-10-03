import AppKit
import UniformTypeIdentifiers

/// CoreGraphics / ImageIO based image decoding.
/// Images are downsampled at decode time so a 100MP photo never blows up memory.
enum ImageLoading {

    /// One frame of an animated GIF, with how long it should stay on screen.
    struct GIFFrame {
        let image: NSImage
        let duration: TimeInterval
    }

    struct Result {
        let nsImage: NSImage?
        let pixelSize: CGSize?
        /// Size of the actually decoded bitmap (after downsampling).
        let decodedPixelSize: CGSize?
        /// All frames when the file is an animated GIF (nil otherwise).
        let gifFrames: [GIFFrame]?
        let errorText: String?
    }

    static func load(url: URL, maxPixelSize: Int) -> Result {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return Result(nsImage: nil, pixelSize: nil, decodedPixelSize: nil, gifFrames: nil, errorText: "无法读取该文件，可能不是支持的图片格式")
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            return Result(nsImage: nil, pixelSize: nil, decodedPixelSize: nil, gifFrames: nil, errorText: "文件中没有可显示的图片")
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        if orientation >= 5 { swap(&width, &height) }
        let pixelSize = CGSize(width: width, height: height)

        let typeID = CGImageSourceGetType(source) as? String
        if typeID == "com.compuserve.gif", count > 1 {
            return loadGIF(source: source, frameCount: count, pixelSize: pixelSize, maxPixelSize: maxPixelSize)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return Result(nsImage: nil, pixelSize: nil, decodedPixelSize: nil, gifFrames: nil, errorText: "图片解码失败")
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return Result(
            nsImage: image,
            pixelSize: pixelSize,
            decodedPixelSize: CGSize(width: cgImage.width, height: cgImage.height),
            gifFrames: nil,
            errorText: nil
        )
    }

    /// Decodes every frame of an animated GIF (downsampled) together with its delay.
    private static func loadGIF(source: CGImageSource, frameCount: Int, pixelSize: CGSize, maxPixelSize: Int) -> Result {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        var frames: [GIFFrame] = []
        frames.reserveCapacity(frameCount)
        var decodedSize: CGSize?

        for i in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, i, options as CFDictionary) else { continue }
            if decodedSize == nil {
                decodedSize = CGSize(width: cgImage.width, height: cgImage.height)
            }
            let frameProps = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gifProps = frameProps?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let unclamped = gifProps?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            let clamped = gifProps?[kCGImagePropertyGIFDelayTime] as? Double
            var delay = unclamped ?? clamped ?? 0.1
            // GIF encoders often write 0 for "as fast as possible"; browsers clamp these to 0.1s.
            if delay <= 0.02 { delay = clamped ?? 0.1 }
            if delay <= 0.02 { delay = 0.1 }

            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            frames.append(GIFFrame(image: image, duration: delay))
        }

        guard let first = frames.first, let decodedSize else {
            return Result(nsImage: nil, pixelSize: pixelSize, decodedPixelSize: nil, gifFrames: nil, errorText: "GIF 解码失败")
        }
        return Result(
            nsImage: first.image,
            pixelSize: pixelSize,
            decodedPixelSize: decodedSize,
            gifFrames: frames.count > 1 ? frames : nil,
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
