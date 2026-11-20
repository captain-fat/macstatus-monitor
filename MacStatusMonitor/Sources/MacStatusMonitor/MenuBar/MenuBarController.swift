import AppKit
import SwiftUI
import Combine
import MonitorKit

/// 菜单栏控制器：持有 NSStatusItem、自绘视图与 Popover。
///
/// 职责边界：只做"把快照画出来"，不碰任何系统采集逻辑。
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {

    private let statusItem: NSStatusItem
    private let statusView: StatusItemView
    private var popover: NSPopover?
    private let store: MonitorStore
    private let settings: AppSettings
    private let colors: PressureColorSettings
    private let onOpenSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()
    private let contextMenu = NSMenu()
    private let labelSubmenu = NSMenu()

    init(
        store: MonitorStore,
        settings: AppSettings,
        colors: PressureColorSettings,
        onOpenSettings: @escaping () -> Void
    ) {
        self.store = store
        self.settings = settings
        self.colors = colors
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusView = StatusItemView(frame: .zero)
        super.init()

        configureStatusItem()
        configureMenu()
        bind()
    }

    // MARK: - 组装

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        statusView.showsCPUPercent = settings.showCPUPercent
        statusView.showsGPUPercent = settings.showGPUPercent
        statusView.labelStyle = settings.labelStyle
        statusView.showsBar = settings.showsBar
        statusView.barWidth = CGFloat(settings.barWidth)
        statusView.palette = colors.palette
        statusView.snapshot = store.snapshot
        statusView.onPreferredWidthChange = { [weak self] width in
            self?.statusItem.length = width
        }

        // 先定长度，再用约束把视图钉满按钮；
        // 不用 autoresizingMask——它在 statusItem 首次布局时会算出错误的宽度（实测 214pt）。
        statusItem.length = statusView.preferredWidth
        statusView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(statusView)
        NSLayoutConstraint.activate([
            statusView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            statusView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            statusView.topAnchor.constraint(equalTo: button.topAnchor),
            statusView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])

        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "MacStatus Monitor"
    }

    private func makePopoverIfNeeded() -> NSPopover {
        if let popover { return popover }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: MonitorPopoverView(
                store: store,
                colors: colors,
                onSettings: { [weak self] in
                    self?.popover?.performClose(nil)
                    self?.onOpenSettings()
                },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        let size = NSSize(
            width: fitting.width > 1 ? fitting.width : 286,
            height: fitting.height > 1 ? fitting.height : 196
        )
        hosting.preferredContentSize = size
        popover.contentViewController = hosting
        popover.contentSize = size
        self.popover = popover
        return popover
    }

    private func configureMenu() {
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        contextMenu.addItem(settingsItem)
        contextMenu.addItem(.separator())

        let labelItem = NSMenuItem(title: "标签", action: nil, keyEquivalent: "")
        for style in MetricLabelStyle.allCases {
            let item = NSMenuItem(title: style.displayName, action: #selector(selectLabelStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            labelSubmenu.addItem(item)
        }
        labelItem.submenu = labelSubmenu
        contextMenu.addItem(labelItem)

        let about = NSMenuItem(title: "关于 MacStatus Monitor", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        contextMenu.addItem(.separator())
        contextMenu.addItem(about)
        contextMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        contextMenu.addItem(quit)
        syncLabelMenuChecks()
    }

    private func syncLabelMenuChecks() {
        for item in labelSubmenu.items {
            item.state = (item.representedObject as? String) == settings.labelStyle.rawValue ? .on : .off
        }
    }

    @objc private func selectLabelStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = MetricLabelStyle(rawValue: raw) else { return }
        settings.labelStyle = style
    }

    private func bind() {
        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.statusView.snapshot = snapshot
            }
            .store(in: &cancellables)

        settings.$showCPUPercent
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.statusView.showsCPUPercent = value
            }
            .store(in: &cancellables)

        settings.$showGPUPercent
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.statusView.showsGPUPercent = value
            }
            .store(in: &cancellables)

        settings.$labelStyle
            .receive(on: RunLoop.main)
            .sink { [weak self] style in
                self?.statusView.labelStyle = style
                self?.syncLabelMenuChecks()
            }
            .store(in: &cancellables)

        settings.$showsBar
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.statusView.showsBar = value
            }
            .store(in: &cancellables)

        settings.$barWidth
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.statusView.barWidth = CGFloat(value)
            }
            .store(in: &cancellables)

        // objectWillChange 在赋值前触发，延迟到下一个 runloop 再取 palette
        colors.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.statusView.palette = self.colors.palette
            }
            .store(in: &cancellables)
    }

    // MARK: - 交互

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showContextMenu(from: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    private func togglePopover(from sender: NSStatusBarButton) {
        let popover = makePopoverIfNeeded()
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu(from sender: NSStatusBarButton) {
        contextMenu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.height + 4),
            in: sender
        )
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 调试

    /// 供离屏渲染验证布局用
    func makeStatusViewForPreview() -> StatusItemView { statusView }

    /// 自检用：用与点击相同的代码路径打开 Popover
    @discardableResult
    func debugShowPopover() -> Bool {
        guard let button = statusItem.button else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let popover = makePopoverIfNeeded()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        return popover.isShown
    }

    var debugLength: CGFloat { statusItem.length }
    var debugWindowFrame: NSRect { statusItem.button?.window?.frame ?? .zero }
    var debugItemVisible: Bool { statusItem.isVisible }
    var debugWidthState: String {
        String(
            format: "settings=%d view=%d preferred=%.0f length=%.0f",
            settings.showCPUPercent ? 1 : 0,
            statusView.showsCPUPercent ? 1 : 0,
            statusView.preferredWidth,
            statusItem.length
        )
    }

    /// 自检用：同时切换两个百分比开关，验证宽度联动。
    /// 直接改视图而不是 settings —— 自检不应污染用户的持久化设置。
    func debugTogglePercents() {
        statusView.showsCPUPercent.toggle()
        statusView.showsGPUPercent.toggle()
    }

    var debugPalette: PressurePalette { statusView.palette }
    var debugPopoverShown: Bool { popover?.isShown ?? false }
    var debugPopoverSize: NSSize { popover?.contentSize ?? .zero }

    /// 自检：把 status item 的实际安装状态打印出来（不依赖屏幕录制权限）
    func diagnostics() -> String {
        guard let button = statusItem.button else { return "statusItem.button == nil" }
        let window = button.window
        let windowFrame = window?.frame ?? .zero
        let screenFrame: NSRect
        if let window, let screen = window.screen {
            screenFrame = window.convertToScreen(window.contentLayoutRect)
            _ = screen
        } else {
            screenFrame = .zero
        }
        let appearance = window?.effectiveAppearance.name.rawValue ?? "?"

        // 标签样式对宽度的影响（同步计算，随后还原）
        let originalStyle = statusView.labelStyle
        var widthReport: [String] = []
        for style in MetricLabelStyle.allCases {
            statusView.labelStyle = style
            widthReport.append("\(style.rawValue)=\(Int(statusView.preferredWidth))")
        }
        statusView.labelStyle = originalStyle

        // 进度条长度 / 隐藏时的宽度
        let originalShowsBar = statusView.showsBar
        let originalBarWidth = statusView.barWidth
        var barReport: [String] = []
        for width in [20.0, 30.0, 40.0] {
            statusView.barWidth = CGFloat(width)
            barReport.append("\(Int(width))=\(Int(statusView.preferredWidth))")
        }
        statusView.showsBar = false
        barReport.append("hidden=\(Int(statusView.preferredWidth))")
        statusView.showsBar = originalShowsBar
        statusView.barWidth = originalBarWidth
        statusItem.length = statusView.preferredWidth

        let menuDescription = contextMenu.items.map { item -> String in
            guard let submenu = item.submenu else { return item.title }
            let children = submenu.items.map { "\($0.title)=\($0.state == .on ? "on" : "off")" }
            return "\(item.title)[\(children.joined(separator: ","))]"
        }.joined(separator: " | ")

        return """
        statusItem.length = \(statusItem.length)
        view.preferredWidth = \(statusView.preferredWidth)  view.frame = \(statusView.frame)
        button.frame = \(button.frame)  isHidden = \(button.isHidden)
        window = \(window != nil)  visible = \(window?.isVisible ?? false)  frame = \(windowFrame)
        screenRect = \(screenFrame)
        appearance = \(appearance)
        标签宽度: \(widthReport.joined(separator: "  "))
        条宽: \(barReport.joined(separator: "  "))
        右键菜单: \(menuDescription)
        snapshot = cpu \(String(describing: store.snapshot.cpu)) gpu \(String(describing: store.snapshot.gpu)) pressure \(String(describing: store.snapshot.memoryPressure)) sysctl=\(MemoryPressureMonitor.readRawLevel())
        """
    }
}
