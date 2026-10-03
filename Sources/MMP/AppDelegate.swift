import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {

    static weak var shared: AppDelegate?

    let model = ViewerModel()

    private var window: NSWindow?
    private var titleCancellable: AnyCancellable?
    private var wheelAccumulator: CGFloat = 0
    private var lastWheelTime: TimeInterval = 0

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        buildMainMenu()
        makeWindowIfNeeded()   // 冷启动时 application(_:open:) 可能已经抢先建过窗口
        installKeyMonitor()
        installScrollMonitor()
        installMagnifyMonitor()
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

    /// 放大后拖拽用于平移图片，此时禁用「拖背景移动窗口」。
    func setBackgroundMovable(_ movable: Bool) {
        window?.isMovableByWindowBackground = movable
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
            let handled = MainActor.assumeIsolated {
                self.handleKey(event)
            }
            return handled ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "o":        openDocument(nil); return true
            case "=", "+":   model.zoomIn(); return true
            case "-":        model.zoomOut(); return true
            case "0":        model.resetZoom(); return true
            default:         break
            }
        }
        switch event.keyCode {
        case 123: model.goToPrevious(); return true   // ←
        case 124: model.goToNext(); return true       // →
        case 126: model.zoomIn(); return true         // ↑
        case 125: model.zoomOut(); return true        // ↓
        case 49:                                      // 空格：GIF 播放/暂停
            guard model.isGIF else { return false }
            model.toggleGIFPlayback()
            return true
        case 53:                                      // esc：先退出缩放，再关窗口
            if model.isZoomed {
                model.resetZoom()
            } else {
                window?.performClose(nil)
            }
            return true
        default:  return false
        }
    }

    // MARK: - Scroll wheel & trackpad

    /// 光标位置换算成「以视图中心为原点、y 向下」的坐标，供缩放锚点使用。
    private func cursorPoint(_ event: NSEvent) -> CGPoint {
        guard let view = window?.contentView else { return .zero }
        let loc = event.locationInWindow
        return CGPoint(x: loc.x - view.bounds.midX, y: -(loc.y - view.bounds.midY))
    }

    private func installScrollMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // 只响应手指/滚轮的直接滚动，忽略惯性（动量）阶段
            guard event.momentumPhase == [] else { return event }
            let handled = MainActor.assumeIsolated {
                self.handleScroll(event)
            }
            return handled ? nil : event
        }
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard model.hasImage else { return false }
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16

        switch model.navigationMode {
        case .wheelZoom:
            guard dy != 0 else { return false }
            model.setZoom(model.zoomScale * exp(dy * 0.008), around: cursorPoint(event))
            return true

        case .wheelNavigate:
            // 触控板滚动是连续小量，累积过阈值才翻页；间歇太久则重新累积
            if event.timestamp - lastWheelTime > 0.6 { wheelAccumulator = 0 }
            lastWheelTime = event.timestamp
            wheelAccumulator += dy
            if abs(wheelAccumulator) >= 60 {
                let forward = wheelAccumulator < 0   // 向下滚 → 下一张
                wheelAccumulator = 0
                forward ? model.goToNext() : model.goToPrevious()
            }
            return true
        }
    }

    /// 触控板双指捏合缩放（两种模式下都可用）。
    private func installMagnifyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let handled = MainActor.assumeIsolated {
                guard self.model.hasImage else { return false }
                self.model.setZoom(self.model.zoomScale * (1 + event.magnification),
                                   around: self.cursorPoint(event))
                return true
            }
            return handled ? nil : event
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
        navMenu.addItem(.separator())
        navMenu.addItem(NSMenuItem(title: "播放 / 暂停（GIF）", action: #selector(toggleGIF(_:)), keyEquivalent: ""))
        navMenu.addItem(NSMenuItem(title: "上一帧（GIF）", action: #selector(previousFrame(_:)), keyEquivalent: ""))
        navMenu.addItem(NSMenuItem(title: "下一帧（GIF）", action: #selector(nextFrame(_:)), keyEquivalent: ""))
        navMenuItem.submenu = navMenu
        mainMenu.addItem(navMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        viewMenu.addItem(NSMenuItem(title: "放大", action: #selector(zoomIn(_:)), keyEquivalent: ""))
        viewMenu.addItem(NSMenuItem(title: "缩小", action: #selector(zoomOut(_:)), keyEquivalent: ""))
        viewMenu.addItem(NSMenuItem(title: "重置缩放", action: #selector(resetZoom(_:)), keyEquivalent: ""))
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let settingsMenuItem = NSMenuItem()
        let settingsMenu = NSMenu(title: "设置")
        let modeA = NSMenuItem(title: NavigationMode.wheelZoom.title, action: #selector(selectWheelZoom(_:)), keyEquivalent: "")
        modeA.target = self
        let modeB = NSMenuItem(title: NavigationMode.wheelNavigate.title, action: #selector(selectWheelNavigate(_:)), keyEquivalent: "")
        modeB.target = self
        settingsMenu.addItem(modeA)
        settingsMenu.addItem(modeB)
        settingsMenu.delegate = self
        settingsMenuItem.submenu = settingsMenu
        mainMenu.addItem(settingsMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func previousImage(_ sender: Any?) { model.goToPrevious() }

    @objc private func nextImage(_ sender: Any?) { model.goToNext() }

    @objc private func toggleGIF(_ sender: Any?) { model.toggleGIFPlayback() }

    @objc private func previousFrame(_ sender: Any?) { model.stepGIF(by: -1) }

    @objc private func nextFrame(_ sender: Any?) { model.stepGIF(by: 1) }

    @objc private func zoomIn(_ sender: Any?) { model.zoomIn() }

    @objc private func zoomOut(_ sender: Any?) { model.zoomOut() }

    @objc private func resetZoom(_ sender: Any?) { model.resetZoom() }

    @objc private func selectWheelZoom(_ sender: Any?) { model.navigationMode = .wheelZoom }

    @objc private func selectWheelNavigate(_ sender: Any?) { model.navigationMode = .wheelNavigate }
}

// MARK: - NSMenuDelegate（设置菜单的单选勾选）

extension AppDelegate: NSMenuDelegate {
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "设置" else { return }
        MainActor.assumeIsolated {
            for item in menu.items {
                switch item.action {
                case #selector(selectWheelZoom(_:)):
                    item.state = model.navigationMode == .wheelZoom ? .on : .off
                case #selector(selectWheelNavigate(_:)):
                    item.state = model.navigationMode == .wheelNavigate ? .on : .off
                default:
                    break
                }
            }
        }
    }
}
