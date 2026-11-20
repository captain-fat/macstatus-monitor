import AppKit
import SwiftUI

/// 设置窗口。只创建一次，关闭后保留实例（再次打开更快）。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    init(settings: AppSettings, colors: PressureColorSettings, login: LoginItemManager) {
        let hosting = NSHostingController(
            rootView: SettingsView(settings: settings, colors: colors, login: login)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "MacStatus Monitor 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 关窗即结束设置会话；实例保留以复用尺寸与位置
        NSApp.deactivate()
    }
}
