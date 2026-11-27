import AppKit
import SwiftUI
import MonitorKit

/// 离屏预览渲染：把菜单栏视图按不同状态/外观画成 PNG。
///
/// 用途：在没有屏幕录制权限、也不想靠肉眼比对的情况下，
/// 验证"浅色/深色 × 显示/隐藏百分比 × 三种压力状态"的实际像素效果。
@MainActor
enum PreviewRenderer {

    private struct Variant {
        var title: String
        var dark: Bool
        var showPercent: Bool
        var labelStyle: MetricLabelStyle
        var showsBar: Bool
        var barWidth: CGFloat
        var cpu: Double?
        var gpu: Double?
        var pressure: MemoryPressureLevel?
    }

    static func render(to url: URL) {
        let variants: [Variant] = [
            Variant(title: "浅色 · 标准条 30 · Normal", dark: false, showPercent: true,
                    labelStyle: .full, showsBar: true, barWidth: 30, cpu: 42, gpu: 31, pressure: .normal),
            Variant(title: "深色 · 短条 20 · Warning", dark: true, showPercent: true,
                    labelStyle: .full, showsBar: true, barWidth: 20, cpu: 78, gpu: 64, pressure: .warning),
            Variant(title: "浅色 · 长条 40 · Critical", dark: false, showPercent: true,
                    labelStyle: .short, showsBar: true, barWidth: 40, cpu: 93, gpu: 88, pressure: .critical),
            Variant(title: "浅色 · 仅百分比（无条）· Normal", dark: false, showPercent: true,
                    labelStyle: .full, showsBar: false, barWidth: 30, cpu: 42, gpu: 31, pressure: .normal),
            Variant(title: "深色 · 无标签无百分比 · 占位", dark: true, showPercent: false,
                    labelStyle: .hidden, showsBar: true, barWidth: 30, cpu: nil, gpu: nil, pressure: nil),
        ]

        var rendered: [(Variant, NSImage, NSSize)] = []
        for variant in variants {
            let view = StatusItemView(frame: .zero)
            view.showsCPUPercent = variant.showPercent
            view.showsGPUPercent = variant.showPercent
            view.labelStyle = variant.labelStyle
            view.showsBar = variant.showsBar
            view.barWidth = variant.barWidth
            view.snapshot = MonitorSnapshot(
                cpu: variant.cpu,
                gpu: variant.gpu,
                memoryPressure: variant.pressure
            )
            view.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
            view.frame = NSRect(origin: .zero, size: view.preferredSize)

            let pdf = view.dataWithPDF(inside: view.bounds)
            let image = NSImage(data: pdf) ?? NSImage(size: view.preferredSize)
            image.size = view.preferredSize
            rendered.append((variant, image, view.preferredSize))
        }

        let scale: CGFloat = 2
        let padding: CGFloat = 14
        let titleHeight: CGFloat = 18
        let swatchPadding: CGFloat = 6
        let rowGap: CGFloat = 8
        let titleFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let titleWidth = rendered
            .map { ($0.0.title as NSString).size(withAttributes: [.font: titleFont]).width }
            .max() ?? 120
        let viewWidth = rendered.map { $0.2.width }.max() ?? 120
        let maxWidth = max(viewWidth, titleWidth)
        let swatchWidth = maxWidth + swatchPadding * 2
        let totalWidth = swatchWidth + padding * 2
        let totalHeight = padding * 2 + CGFloat(rendered.count) * (titleHeight + 24 + rowGap)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(totalWidth * scale),
            pixelsHigh: Int(totalHeight * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = NSSize(width: totalWidth, height: totalHeight)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        NSColor(calibratedWhite: 0.5, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight).fill()

        var cursorY = totalHeight - padding
        for (variant, image, size) in rendered {
            // 标题（画在该行上方）
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: NSColor(calibratedWhite: 0.95, alpha: 1),
            ]
            let titlePoint = NSPoint(x: padding, y: cursorY - 13)
            (variant.title as NSString).draw(at: titlePoint, withAttributes: titleAttributes)

            // 菜单栏底色块
            let swatchRect = NSRect(
                x: padding,
                y: cursorY - titleHeight - 24,
                width: swatchWidth,
                height: 24
            )
            let background = variant.dark
                ? NSColor(calibratedWhite: 0.16, alpha: 1)
                : NSColor(calibratedWhite: 0.94, alpha: 1)
            background.setFill()
            NSBezierPath(roundedRect: swatchRect, xRadius: 5, yRadius: 5).fill()

            image.draw(
                in: NSRect(
                    x: swatchRect.minX + swatchPadding,
                    y: swatchRect.minY,
                    width: size.width,
                    height: size.height
                )
            )

            cursorY -= (titleHeight + 24 + rowGap)
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
            print("预览已写入: \(url.path)  (\(Int(totalWidth))×\(Int(totalHeight)) @2x)")
        } catch {
            FileHandle.standardError.write("写入预览失败: \(error)\n".data(using: .utf8)!)
        }

        renderPopover(to: url.deletingLastPathComponent().appendingPathComponent("popover.png"))
        renderSettings(to: url.deletingLastPathComponent().appendingPathComponent("settings.png"))
    }

    // MARK: - 设置窗口预览

    private static func renderSettings(to url: URL) {
        let suite = UserDefaults(suiteName: "com.captainslow667.MacStatusMonitor.preview") ?? .standard
        let settings = AppSettings(defaults: suite)
        let colors = PressureColorSettings(defaults: suite)
        let login = LoginItemManager()

        var images: [(NSImage, NSSize)] = []
        for dark in [false, true] {
            let view = SettingsView(settings: settings, colors: colors, login: login)
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            hosting.layoutSubtreeIfNeeded()
            let fitting = hosting.fittingSize
            hosting.frame = NSRect(origin: .zero, size: fitting)
            hosting.layoutSubtreeIfNeeded()

            hosting.wantsLayer = true
            let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            if let rep { hosting.cacheDisplay(in: hosting.bounds, to: rep) }
            let image = NSImage(size: hosting.bounds.size)
            if let rep {
                rep.size = hosting.bounds.size
                image.addRepresentation(rep)
            }
            images.append((image, hosting.bounds.size))
        }

        let scale: CGFloat = 2
        let padding: CGFloat = 20
        let gap: CGFloat = 16
        let width = (images.map { $0.1.width }.max() ?? 430) + padding * 2
        let rowHeight = images.map { $0.1.height }.max() ?? 500
        let height = rowHeight * CGFloat(images.count) + gap + padding * 2

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedWhite: 0.5, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var cursorY = height - padding
        for (image, size) in images {
            cursorY -= size.height
            image.draw(in: NSRect(x: padding, y: cursorY, width: size.width, height: size.height))
            cursorY -= gap
        }
        NSGraphicsContext.restoreGraphicsState()

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("设置预览: \(url.path)  (\(Int(width))×\(Int(height)) @2x)")
        }
    }

    // MARK: - Popover 预览

    private static func renderPopover(to url: URL) {
        let sample = MonitorSnapshot(
            cpu: 42, gpu: 31, memoryPressure: .warning,
            cpuUser: 27, cpuSystem: 11, cpuIdle: 62,
            perCoreCPU: [55, 48, 61, 44, 39, 33, 12, 9, 7, 5],
            loadAverage: [3.21, 2.87, 2.44],
            gpuSource: "硬件活跃占比",
            memoryUsedBytes: 26_700_000_000,
            memoryCachedBytes: 6_600_000_000,
            memoryFreeBytes: 1_800_000_000,
            memoryCompressedBytes: 4_200_000_000,
            memoryWiredBytes: 3_100_000_000,
            swapUsedBytes: 5_600_000_000,
            timestamp: Date()
        )
        let store = MonitorStore(snapshot: sample)

        var images: [(NSImage, NSSize)] = []
        for dark in [false, true] {
            let hosting = NSHostingView(
                rootView: MonitorPopoverView(
                    store: store,
                    colors: PressureColorSettings.shared,
                    onSettings: {},
                    onQuit: {}
                )
            )
            hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            hosting.frame = NSRect(origin: .zero, size: NSSize(width: 286, height: 220))
            hosting.layoutSubtreeIfNeeded()
            let fitting = hosting.fittingSize
            hosting.frame = NSRect(origin: .zero, size: NSSize(width: 286, height: fitting.height))
            hosting.layoutSubtreeIfNeeded()
            hosting.wantsLayer = true
            let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            if let rep {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
            }
            let image: NSImage
            if let rep {
                image = NSImage(size: hosting.bounds.size)
                rep.size = hosting.bounds.size
                image.addRepresentation(rep)
            } else {
                image = NSImage(size: hosting.bounds.size)
            }
            images.append((image, hosting.bounds.size))
        }

        let scale: CGFloat = 2
        let padding: CGFloat = 20
        let gap: CGFloat = 16
        let width = (images.map { $0.1.width }.max() ?? 286) + padding * 2
        let height = images.map { $0.1.height }.reduce(0, +) + gap + padding * 2

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedWhite: 0.5, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        var cursorY = height - padding
        for (image, size) in images {
            cursorY -= size.height
            image.draw(in: NSRect(x: padding, y: cursorY, width: size.width, height: size.height))
            cursorY -= gap
        }
        NSGraphicsContext.restoreGraphicsState()

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("Popover 预览: \(url.path)")
        }
    }
}
