import AppKit
import SwiftUI

/// 滚轮与方向键的行为模式（设置菜单里切换）。
enum NavigationMode: String, CaseIterable, Identifiable {
    /// 鼠标滚轮缩放，左右方向键切换图片
    case wheelZoom
    /// 鼠标滚轮切换图片，上下方向键缩放
    case wheelNavigate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wheelZoom:     return "滚轮缩放 · 方向键切换图片"
        case .wheelNavigate: return "滚轮切换图片 · 上下键缩放"
        }
    }

    var hint: String {
        switch self {
        case .wheelZoom:     return "滚动滚轮以光标为中心缩放；← → 切换图片。"
        case .wheelNavigate: return "滚动滚轮切换图片；↑ ↓ 缩放。"
        }
    }
}

/// Holds all viewer state. Everything is main-actor isolated.
@MainActor
final class ViewerModel: ObservableObject, @unchecked Sendable {

    // MARK: - Published state

    @Published private(set) var nsImage: NSImage?
    @Published private(set) var files: [URL] = []
    @Published private(set) var index: Int = -1
    @Published private(set) var pixelSize: CGSize?
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?

    // Zoom & pan
    @Published private(set) var zoomScale: CGFloat = 1
    @Published private(set) var panOffset: CGSize = .zero

    // GIF playback
    @Published private(set) var gifFrameCount = 0
    @Published private(set) var gifFrameIndex = 0
    @Published private(set) var gifPlaying = false

    // Settings
    @Published var navigationMode: NavigationMode {
        didSet { UserDefaults.standard.set(navigationMode.rawValue, forKey: Self.navigationModeKey) }
    }

    // MARK: - Private

    private var baseBudget: CGFloat = 1600
    private var pixelBudget: CGFloat = 1600
    private var loadGeneration = 0
    private var viewportSize: CGSize = CGSize(width: 1120, height: 780)
    private var gifFrames: [ImageLoading.GIFFrame] = []
    private var gifTask: Task<Void, Never>?
    private var hiResTask: Task<Void, Never>?

    static let minZoom: CGFloat = 0.2
    static let maxZoom: CGFloat = 20
    private static let navigationModeKey = "MMP.navigationMode"

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.navigationModeKey)
        navigationMode = NavigationMode(rawValue: saved ?? "") ?? .wheelZoom
    }

    // MARK: - Derived

    var currentURL: URL? { files.indices.contains(index) ? files[index] : nil }

    var fileName: String { currentURL?.lastPathComponent ?? "" }

    var counterText: String {
        guard !files.isEmpty, files.indices.contains(index) else { return "" }
        return "\(index + 1) / \(files.count)"
    }

    var dimensionText: String {
        guard let size = pixelSize, size.width > 0, size.height > 0 else { return "" }
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    var hasPrevious: Bool { index > 0 }

    var hasNext: Bool { !files.isEmpty && index < files.count - 1 }

    var hasImage: Bool { nsImage != nil }

    var isEmpty: Bool { files.isEmpty }

    var isZoomed: Bool { abs(zoomScale - 1) > 0.001 }

    var zoomPercentText: String { "\(Int((zoomScale * 100).rounded()))%" }

    var isGIF: Bool { gifFrameCount > 1 }

    var gifFrameText: String {
        isGIF ? "\(gifFrameIndex + 1) / \(gifFrameCount)" : ""
    }

    /// Size of the image when fitted into the viewport (before user zoom).
    var fittedSize: CGSize {
        guard let image = nsImage else { return .zero }
        let iw = image.size.width, ih = image.size.height
        guard iw > 0, ih > 0 else { return .zero }
        let availW = max(viewportSize.width - 48, 50)
        let availH = max(viewportSize.height - 48, 50)
        let s = min(availW / iw, availH / ih)
        return CGSize(width: iw * s, height: ih * s)
    }

    // MARK: - Navigation

    /// Opens one file and immediately makes the whole folder browsable.
    func open(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        var siblings = FolderScanner.imageFiles(in: folder)

        let targetPath = url.standardizedFileURL.path
        if let found = siblings.firstIndex(where: { $0.standardizedFileURL.path == targetPath }) {
            index = found
        } else {
            siblings.insert(url, at: 0)
            index = 0
        }
        files = siblings
        resetViewState()
        reload()
    }

    func goToPrevious() {
        guard hasPrevious else { return }
        index -= 1
        resetViewState()
        reload()
    }

    func goToNext() {
        guard hasNext else { return }
        index += 1
        resetViewState()
        reload()
    }

    // MARK: - Zoom & pan

    /// Sets the zoom scale, optionally keeping the image point under `point` fixed.
    /// `point` is in view coordinates: origin at the view center, y-axis pointing down.
    func setZoom(_ scale: CGFloat, around point: CGPoint? = nil) {
        let clamped = min(max(scale, Self.minZoom), Self.maxZoom)
        guard abs(clamped - zoomScale) > 0.0001 else { return }
        if let point {
            let k = clamped / zoomScale
            panOffset = CGSize(
                width: point.x - (point.x - panOffset.width) * k,
                height: point.y - (point.y - panOffset.height) * k
            )
        }
        zoomScale = clamped
        clampPan()
        scheduleHiResReload()
    }

    func zoomIn()  { setZoom(zoomScale * 1.25) }

    func zoomOut() { setZoom(zoomScale / 1.25) }

    func resetZoom() {
        guard isZoomed || panOffset != .zero else { return }
        zoomScale = 1
        panOffset = .zero
        scheduleHiResReload()
    }

    /// Pans by a delta in view coordinates (y down).
    func pan(by delta: CGSize) {
        panOffset.width += delta.width
        panOffset.height += delta.height
        clampPan()
    }

    /// Keeps decode resolution roughly in step with the window size (retina aware).
    func updateViewport(size: CGSize) {
        viewportSize = size
        clampPan()
        let budget = min(max(max(size.width, size.height) * 2, 1600), 6000)
        guard abs(budget - baseBudget) > 150 else { return }
        baseBudget = budget
        reloadIfNeeded()
    }

    private func clampPan() {
        let fitted = fittedSize
        guard fitted.width > 0, fitted.height > 0 else {
            panOffset = .zero
            return
        }
        let displayedW = fitted.width * zoomScale
        let displayedH = fitted.height * zoomScale
        let maxX = max(0, (displayedW - viewportSize.width) / 2)
        let maxY = max(0, (displayedH - viewportSize.height) / 2)
        panOffset.width = min(max(panOffset.width, -maxX), maxX)
        panOffset.height = min(max(panOffset.height, -maxY), maxY)
    }

    // MARK: - GIF playback

    func toggleGIFPlayback() {
        guard isGIF else { return }
        gifPlaying.toggle()
    }

    /// Steps one frame forward/backward; pauses playback first.
    func stepGIF(by delta: Int) {
        guard isGIF else { return }
        gifPlaying = false
        let n = gifFrames.count
        showGIFFrame((gifFrameIndex + delta + n) % n)
    }

    private func showGIFFrame(_ i: Int) {
        guard gifFrames.indices.contains(i) else { return }
        gifFrameIndex = i
        nsImage = gifFrames[i].image
    }

    private func startGIFPlayback() {
        gifTask?.cancel()
        gifPlaying = true
        gifTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                guard self.gifFrames.count > 1 else { break }
                let i = min(self.gifFrameIndex, self.gifFrames.count - 1)
                let duration = self.gifFrames[i].duration
                try? await Task.sleep(nanoseconds: UInt64(max(duration, 0.02) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                guard self.gifPlaying else { continue }
                self.showGIFFrame((self.gifFrameIndex + 1) % self.gifFrames.count)
            }
        }
    }

    private func stopGIF() {
        gifTask?.cancel()
        gifTask = nil
        gifFrames = []
        gifFrameCount = 0
        gifFrameIndex = 0
        gifPlaying = false
    }

    // MARK: - Misc

    func revealInFinder() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Loading

    /// Decode budget grows with zoom so magnified views stay sharp;
    /// capped by the source resolution (no point decoding beyond it).
    private var effectiveBudget: Int {
        var budget = baseBudget * max(1, zoomScale)
        if let pixel = pixelSize {
            let sourceMax = max(pixel.width, pixel.height)
            if sourceMax > 0 { budget = min(budget, sourceMax * 1.05) }
        }
        return Int(min(max(budget, 1600), 8000).rounded())
    }

    /// Re-decoding at a higher budget is debounced so fast wheel scrolling
    /// doesn't start a decode storm.
    private func scheduleHiResReload() {
        hiResTask?.cancel()
        hiResTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            self.reloadIfNeeded()
        }
    }

    private func reloadIfNeeded() {
        guard currentURL != nil, !isGIF else { return }
        let budget = CGFloat(effectiveBudget)
        guard abs(budget - pixelBudget) / pixelBudget > 0.15 else { return }
        pixelBudget = budget
        reload()
    }

    /// Resets zoom/pan/GIF state before loading another image.
    private func resetViewState() {
        hiResTask?.cancel()
        stopGIF()
        zoomScale = 1
        panOffset = .zero
        pixelBudget = baseBudget
    }

    private func reload() {
        guard let url = currentURL else {
            nsImage = nil
            pixelSize = nil
            isLoading = false
            errorText = nil
            return
        }

        isLoading = true
        errorText = nil
        let generation = loadGeneration + 1
        loadGeneration = generation
        let budget = Int(pixelBudget.rounded())

        // Capturing `self` strongly is safe here: the model lives for the whole
        // app lifetime, and the decode finishes in milliseconds.
        Task.detached(priority: .userInitiated) {
            let result = ImageLoading.load(url: url, maxPixelSize: budget)
            await MainActor.run { self.apply(result, generation: generation) }
        }
    }

    private func apply(_ result: ImageLoading.Result, generation: Int) {
        guard loadGeneration == generation else { return }
        stopGIF()
        nsImage = result.nsImage
        pixelSize = result.pixelSize
        errorText = result.errorText
        isLoading = false
        if let frames = result.gifFrames, frames.count > 1 {
            gifFrames = frames
            gifFrameCount = frames.count
            gifFrameIndex = 0
            nsImage = frames[0].image
            startGIFPlayback()
        }
    }
}
