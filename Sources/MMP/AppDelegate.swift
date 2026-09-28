import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {

    static weak var shared: AppDelegate?

    let model = ViewerModel()

    private var window: NSWindow?
    private var titleCancellable: AnyCancellable?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        buildMainMenu()
        makeWindowIfNeeded()   // 冷启动时 application(_:open:) 可能已经抢先建过窗口
        installKeyMonitor()
        observeTitle()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { makeWindow() }
        return true
    }

    /// Finder「打开方式」、Dock 拖放、命令行 `open` 都会走到这里。
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { FolderScanner.isImage($0) }) else { return }
        open(url: url)
    }

    // MARK: - Public

    func open(url: URL) {
        makeWindowIfNeeded()
        model.open(url)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "选择一张图片，MMP 会自动载入同文件夹下的所有图片"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    @objc func setAsDefaultViewer(_ sender: Any?) {
        let outcome = DefaultAppSetter.setAsDefaultViewer()
        let alert = NSAlert()
        alert.alertStyle = .informational
        if outcome.succeeded > 0 {
            var text = "已把 \(outcome.succeeded)/\(outcome.total) 种图片格式的默认打开方式设置为 MMP。"
            if !outcome.isInstalledInApplications {
                text += "\n\n建议把 MMP.app 拷贝到「应用程序」文件夹，否则系统可能在重启后丢失该设置。"
            }
            alert.messageText = "设置完成"
            alert.informativeText = text
        } else {
            alert.messageText = "设置未生效"
            alert.informativeText = "可以手动设置：在访达中右键一张图片 →「打开方式」→ 选择 MMP → 按住 Option 会变为「始终以此方式打开」。"
        }
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - Window

    private func makeWindowIfNeeded() {
        if window == nil { makeWindow() }
    }

    private func makeWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "MMP"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1)
        window.minSize = NSSize(width: 480, height: 320)
        window.center()
        window.contentView = NSHostingView(rootView: ContentView().environmentObject(model))
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func observeTitle() {
        titleCancellable = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let name = self.model.fileName
                self.window?.title = name.isEmpty ? "MMP" : name
            }
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let keyCode = event.keyCode
            let isCommand = event.modifierFlags.contains(.command)
            let characters = event.charactersIgnoringModifiers
            let handled = MainActor.assumeIsolated {
                self.handle(keyCode: keyCode, isCommand: isCommand, characters: characters)
            }
            return handled ? nil : event
        }
    }

    private func handle(keyCode: UInt16, isCommand: Bool, characters: String?) -> Bool {
        if isCommand, characters?.lowercased() == "o" {
            openDocument(nil)
            return true
        }
        switch keyCode {
        case 123: model.goToPrevious(); return true   // ←
        case 124: model.goToNext(); return true       // →
        case 53:  window?.performClose(nil); return true  // esc
        default:  return false
        }
    }

    // MARK: - Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 MMP", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设为默认看图软件…", action: #selector(setAsDefaultViewer(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 MMP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(NSMenuItem(title: "打开…", action: #selector(openDocument(_:)), keyEquivalent: "o"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let navMenuItem = NSMenuItem()
        let navMenu = NSMenu(title: "浏览")
        navMenu.addItem(NSMenuItem(title: "上一张", action: #selector(previousImage(_:)), keyEquivalent: ""))
        navMenu.addItem(NSMenuItem(title: "下一张", action: #selector(nextImage(_:)), keyEquivalent: ""))
        navMenuItem.submenu = navMenu
        mainMenu.addItem(navMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func previousImage(_ sender: Any?) { model.goToPrevious() }

    @objc private func nextImage(_ sender: Any?) { model.goToNext() }
}
