# MMP

A simple picture viewing tool for macOS. 对标「WPS 看图」的基础功能。

**当前版本：1.5**

## 功能

- **打开常见图片格式**：PNG / JPEG / HEIC / HEIF / GIF / TIFF / BMP / WebP / SVG / JPEG2000，以及部分 RAW。底层走 macOS 系统的 ImageIO，无需第三方依赖。
- **设为系统默认看图软件**：菜单栏 `MMP → 设为默认看图软件…`，或点窗口右上角的 ⭐ 按钮，一键接管全部常见图片格式。
- **一次打开，一个窗口，看完整个文件夹**：双击任意一张图片，MMP 会自动载入同文件夹下的所有图片（按访达的自然排序），用 `←` `→` 方向键或窗口两侧的圆形箭头按钮轮播。
- **缩放浏览**（1.5 新增）：
  - 滚轮 / 触控板双指捏合缩放，以光标为锚点；`⌘+` `⌘-` `⌘0` 或 `↑` `↓` 也可以缩放 / 重置。
  - 放大后直接拖拽平移图片。
  - **右下角缩略图**：放大时自动出现，白色方框实时标出当前可视区域在原图中的位置。
  - 放大到一定程度会按缩放级别重新高清解码（防抖处理），细节不会糊。
  - 底部控制条显示当前缩放比例，点百分比可一键复位；`Esc` 先退出缩放、再按一次才关窗口。
- **GIF 逐帧播放**（1.5 新增）：动图自动播放，底部控制条可播放 / 暂停（空格键）、逐帧前进 / 后退，并显示当前帧号。
- **设置菜单**（1.5 新增）：菜单栏「设置」或窗口右上角 ⚙️，可在两种浏览方式间切换（自动记忆）：
  - 滚轮缩放 · 方向键切换图片（默认）
  - 滚轮切换图片 · 上下键缩放
- **大图不卡**：解码时按窗口大小降采样（Retina 感知），100MP 的照片也不会撑爆内存。
- 支持拖拽图片到窗口、`⌘O` 打开、`Esc` 关闭窗口。

## 构建

无需 Xcode 工程，一条脚本即可（需要安装 Xcode 命令行工具）：

```bash
./build.sh           # 产出 build/MMP.app
./build.sh install   # 顺便拷贝到 /Applications
```

## 使用建议

1. 运行 `./build.sh install` 把 MMP 装进 `/Applications`。
2. 启动 MMP，点窗口右上角 ⭐（或菜单栏 `MMP → 设为默认看图软件…`）。
3. 之后在访达里双击任意图片，默认就是 MMP。

> 未安装到 `/Applications` 时系统可能在重启后忘记默认打开方式，脚本会提示。

## 技术栈

- **语言**：Swift 6.3
- **UI**：AppKit（窗口 / 菜单 / 键盘与滚轮事件监听）+ SwiftUI（界面布局与控件）
- **图片解码**：ImageIO / CoreGraphics（`CGImageSource` 降采样解码；GIF 逐帧提取 + 帧延迟）
- **系统集成**：LaunchServices（`CFBundleDocumentTypes` 声明 + `LSSetDefaultRoleHandlerForContentType` 设置默认打开方式）
- **构建**：`swiftc` 直接编译 + 手工组装 `.app` bundle + ad-hoc 签名，不依赖 `.xcodeproj`

## 目录结构

```
Sources/MMP/
  MMPMain.swift      入口（NSApplication 启动）
  AppDelegate.swift  窗口 / 菜单 / 键盘与滚轮监听 / 文档打开
  ViewerModel.swift  浏览状态 / 缩放平移 / GIF 播放 / 设置
  ContentView.swift  SwiftUI 界面（缩放画布 / 缩略图 / 控制条）
  Support.swift      文件夹扫描 / 解码（含 GIF 逐帧）/ 设为默认
Tools/
  GenIcon.swift      生成 AppIcon.icns
  SelfTest.swift     无界面自测（扫描 / 解码 / 排序）
Resources/
  Info.plist         UTI 与文档类型声明
build.sh             一键构建脚本
```

## 已知限制（1.5）

- 少数使用「局部帧」优化（每帧只存变化区域）的 GIF 可能出现残影——目前按整帧解码。
- GIF 放大浏览时不会重新高清解码（帧通常很小，影响有限）。
- 不支持旋转、裁剪、多窗口。
