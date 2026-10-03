import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {

    @EnvironmentObject var model: ViewerModel
    @State private var alert: AlertPayload?
    @State private var showSettings = false
    @State private var lastDragTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(white: 0.07).ignoresSafeArea()

                imageLayer
                    .overlay(alignment: .top) { topChrome }
                    .overlay(alignment: .bottom) { bottomChrome }
                    .overlay(alignment: .leading) { navButton(.backward) }
                    .overlay(alignment: .trailing) { navButton(.forward) }
                    .overlay(alignment: .bottomTrailing) { minimap(viewSize: geo.size) }
            }
            .onAppear { model.updateViewport(size: geo.size) }
            .onChange(of: geo.size) { size in
                model.updateViewport(size: size)
            }
        }
        .onChange(of: model.isZoomed) { zoomed in
            // 放大后让拖拽用于平移图片，而不是移动窗口
            AppDelegate.shared?.setBackgroundMovable(!zoomed)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .alert(item: $alert) { payload in
            Alert(title: Text(payload.title), message: Text(payload.message), dismissButton: .default(Text("好")))
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    // MARK: - Layers

    @ViewBuilder
    private var imageLayer: some View {
        if let image = model.nsImage {
            let fitted = model.fittedSize
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: fitted.width * model.zoomScale, height: fitted.height * model.zoomScale)
                .offset(model.panOffset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(panGesture)
                .transition(.opacity)
        } else if model.isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorText {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyState
        }
    }

    /// 拖拽平移：把 DragGesture 的累计位移换算成增量交给 model。
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let delta = CGSize(
                    width: value.translation.width - lastDragTranslation.width,
                    height: value.translation.height - lastDragTranslation.height
                )
                lastDragTranslation = value.translation
                model.pan(by: delta)
            }
            .onEnded { _ in
                lastDragTranslation = .zero
            }
    }

    /// 右下角缩略图：放大时显示，白色方框标出当前可视区域在原图中的位置。
    @ViewBuilder
    private func minimap(viewSize: CGSize) -> some View {
        if model.isZoomed, let image = model.nsImage, model.fittedSize.width > 0 {
            let displayedW = model.fittedSize.width * model.zoomScale
            let displayedH = model.fittedSize.height * model.zoomScale
            let fracW = min(1, viewSize.width / displayedW)
            let fracH = min(1, viewSize.height / displayedH)
            let centerX = 0.5 - model.panOffset.width / displayedW
            let centerY = 0.5 - model.panOffset.height / displayedH
            let rectX = min(max(centerX - fracW / 2, 0), 1 - fracW)
            let rectY = min(max(centerY - fracH / 2, 0), 1 - fracH)
            let mapW: CGFloat = 150
            let mapH = mapW * (image.size.height / max(image.size.width, 1))

            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: mapW, height: mapH)
                Rectangle()
                    .fill(.white.opacity(0.15))
                    .overlay { Rectangle().strokeBorder(.white.opacity(0.9), lineWidth: 1) }
                    .frame(width: max(fracW * mapW, 8), height: max(fracH * mapH, 8))
                    .offset(x: rectX * mapW, y: rectY * mapH)
            }
            .frame(width: mapW, height: mapH)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
            .padding(.trailing, 14)
            .padding(.bottom, 64)   // 避开底部控制条
            .transition(.opacity)
            .animation(.easeOut(duration: 0.15), value: model.isZoomed)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52))
                .foregroundStyle(.white.opacity(0.25))
            Text("把图片拖到这里，或者直接双击任意图片")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.55))
            Button("选择图片…") { AppDelegate.shared?.openDocument(nil) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var topChrome: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 78)          // leave room for the traffic lights

            if !model.fileName.isEmpty {
                chromePill {
                    Text(model.fileName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(model.counterText)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                chromeIcon("folder", help: "在访达中显示") { model.revealInFinder() }
                chromeIcon("gearshape", help: "设置") { showSettings.toggle() }
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                        settingsPopover
                    }
                chromeIcon("star", help: "设为默认看图软件") { setAsDefault() }
            }
        }
        .padding(.top, 26)
        .padding(.horizontal, 14)
        .opacity(model.isEmpty ? 0 : 1)
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("浏览方式")
                .font(.system(size: 13, weight: .semibold))
            ForEach(NavigationMode.allCases) { mode in
                Button {
                    model.navigationMode = mode
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.navigationMode == mode ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.navigationMode == mode ? Color.accentColor : Color.secondary)
                        Text(mode.title)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(model.navigationMode.hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 250)
    }

    private var bottomChrome: some View {
        HStack {
            Spacer(minLength: 0)
            if model.hasImage {
                chromePill {
                    if model.isGIF {
                        pillIcon(model.gifPlaying ? "pause.fill" : "play.fill",
                                 help: model.gifPlaying ? "暂停（空格）" : "播放（空格）") {
                            model.toggleGIFPlayback()
                        }
                        pillIcon("backward.frame.fill", help: "上一帧") { model.stepGIF(by: -1) }
                        pillIcon("forward.frame.fill", help: "下一帧") { model.stepGIF(by: 1) }
                        Text(model.gifFrameText)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.65))
                            .frame(minWidth: 44)
                        pillDivider
                    }

                    pillIcon("minus.magnifyingglass", help: "缩小（⌘-）") { model.zoomOut() }
                    Button(model.zoomPercentText) { model.resetZoom() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.white.opacity(model.isZoomed ? 0.95 : 0.65))
                        .frame(minWidth: 42)
                        .help("重置缩放（⌘0）")
                    pillIcon("plus.magnifyingglass", help: "放大（⌘+）") { model.zoomIn() }

                    if !model.dimensionText.isEmpty {
                        pillDivider
                        Text(model.dimensionText)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 16)
    }

    private var pillDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.15))
            .frame(width: 1, height: 14)
    }

    private func pillIcon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func navButton(_ direction: Direction) -> some View {
        let enabled = direction == .backward ? model.hasPrevious : model.hasNext
        return Button {
            direction == .backward ? model.goToPrevious() : model.goToNext()
        } label: {
            Image(systemName: direction == .backward ? "chevron.left" : "chevron.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.25))
                .frame(width: 44, height: 44)
                .background {
                    Circle().fill(.black.opacity(enabled ? 0.32 : 0.18))
                }
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(direction == .backward ? .leading : .trailing, 18)
        .opacity(model.files.count > 1 ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: model.files.count)
    }

    private func chromePill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule().fill(.black.opacity(0.35))
            }
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            }
            .foregroundStyle(.white)
    }

    private func chromeIcon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background { Circle().fill(.black.opacity(0.35)) }
                .overlay { Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Behaviour

    private func setAsDefault() {
        let outcome = DefaultAppSetter.setAsDefaultViewer()
        if outcome.succeeded > 0 {
            var message = "已把 \(outcome.succeeded)/\(outcome.total) 种图片格式的默认打开方式设置为 MMP。"
            if !outcome.isInstalledInApplications {
                message += "\n\n建议把 MMP.app 拷贝到「应用程序」文件夹，否则系统可能在重启后丢失该设置。"
            }
            alert = AlertPayload(title: "设置完成", message: message)
        } else {
            alert = AlertPayload(
                title: "设置未生效",
                message: "可以手动设置：在访达中右键一张图片 →「打开方式」→ 选择 MMP → 按住 Option 会变为「始终以此方式打开」。"
            )
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let direct = item as? URL {
                url = direct
            }
            guard let url, FolderScanner.isImage(url) else { return }
            Task { @MainActor in AppDelegate.shared?.open(url: url) }
        }
        return true
    }

    private enum Direction { case backward, forward }
}

private struct AlertPayload: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
