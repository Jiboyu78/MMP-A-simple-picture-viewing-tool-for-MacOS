import AppKit
import SwiftUI

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

    // MARK: - Private

    private var pixelBudget: CGFloat = 1600
    private var loadGeneration = 0

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

    // MARK: - Actions

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
        reload()
    }

    func goToPrevious() {
        guard hasPrevious else { return }
        index -= 1
        reload()
    }

    func goToNext() {
        guard hasNext else { return }
        index += 1
        reload()
    }

    /// Keeps decode resolution roughly in step with the window size (retina aware).
    func updateViewport(maxDimension: CGFloat) {
        let budget = min(max(maxDimension * 2, 1600), 6000)
        guard abs(budget - pixelBudget) > 150 else { return }
        pixelBudget = budget
        reload()
    }

    func revealInFinder() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Loading

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
        nsImage = result.nsImage
        pixelSize = result.pixelSize
        errorText = result.errorText
        isLoading = false
    }
}
