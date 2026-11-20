import AppKit
import Foundation
import Combine
import MonitorKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController?
    private var monitor: SystemMonitor?
    private var settingsWindow: SettingsWindowController?
    private var soakReporter: SoakReporter?
    private var cancellables = Set<AnyCancellable>()

    private let store = MonitorStore()
    private let settings = AppSettings.shared
    private let colorSettings = PressureColorSettings.shared
    private lazy var loginManager = LoginItemManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let arguments = CommandLine.arguments
        let isDiagnostic = arguments.contains("--self-check")
            || arguments.contains("--soak")
            || arguments.contains("--dump")

        // 单实例：避免出现两个菜单栏图标（重复启动时把已有实例带到前台后自行退出）
        if !isDiagnostic, let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != getpid() }
            if let existing = others.first {
                existing.activate(options: [])
                NSApp.terminate(nil)
                return
            }
        }

        if arguments.contains("--login-test") {
            runLoginTest()
            return
        }

        if let index = arguments.firstIndex(of: "--login"), index + 1 < arguments.count {
            let manager = LoginItemManager()
            manager.setEnabled(arguments[index + 1] == "on")
            print("login status = \(manager.debugStatus)  enabled = \(manager.isEnabled)  message = \(manager.message ?? "-")")
            exit(0)
        }

        if let index = arguments.firstIndex(of: "--dump"), index + 1 < arguments.count {
            runDumpMode(seconds: TimeInterval(arguments[index + 1]) ?? 10)
            return
        }

        menuBar = MenuBarController(
            store: store,
            settings: settings,
            colors: colorSettings,
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        startMonitoring()

        if arguments.contains("--soak"),
           let index = arguments.firstIndex(of: "--soak"), index + 1 < arguments.count,
           let seconds = TimeInterval(arguments[index + 1]) {
            let reporter = SoakReporter(duration: seconds)
            reporter.start()
            soakReporter = reporter
        }

        if arguments.contains("--self-check") {
            runSelfCheck()
        }
    }

    private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                settings: settings,
                colors: colorSettings,
                login: loginManager
            )
        }
        settingsWindow?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        monitor = nil
        menuBar = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - 监控

    private func startMonitoring(onSnapshot: ((MonitorSnapshot) -> Void)? = nil) {
        let configuration = SystemMonitor.Configuration(
            interval: settings.refreshInterval,
            gpuMetric: settings.gpuMetric
        )
        let monitor = SystemMonitor(configuration: configuration)
        monitor.onSnapshot = { [weak self] snapshot in
            MainActor.assumeIsolated {
                self?.store.apply(snapshot)
                onSnapshot?(snapshot)
            }
        }
        monitor.start()
        self.monitor = monitor

        settings.$refreshInterval
            .receive(on: RunLoop.main)
            .sink { [weak monitor] interval in monitor?.setInterval(interval) }
            .store(in: &cancellables)

        settings.$gpuMetric
            .receive(on: RunLoop.main)
            .sink { [weak monitor] metric in monitor?.setGPUMetric(metric) }
            .store(in: &cancellables)
    }

    // MARK: - 登录项诊断

    private func runLoginTest() {
        var lines: [String] = []
        lines.append("bundle = \(Bundle.main.bundlePath)")
        lines.append("identifier = \(Bundle.main.bundleIdentifier ?? "nil")")
        lines.append("status before = \(SMAppService.mainApp.status.rawValue)")
        do {
            try SMAppService.mainApp.register()
            lines.append("register = ok")
        } catch {
            let ns = error as NSError
            lines.append("register error = \(ns.domain) \(ns.code): \(ns.localizedDescription)")
        }
        Thread.sleep(forTimeInterval: 1.0)
        lines.append("status after = \(SMAppService.mainApp.status.rawValue)")
        lines.append("enabled = \(SMAppService.mainApp.status == .enabled)")
        // 清理，避免影响用户
        try? SMAppService.mainApp.unregister()
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: URL(fileURLWithPath: "/tmp/msm-login-test.txt"), atomically: true, encoding: .utf8)
        print(text)
        exit(0)
    }

    // MARK: - 无界面数据输出（阶段三验证用）

    private func runDumpMode(seconds: TimeInterval) {
        print(String(format: "数据自检：%.0f 秒，口径 = %@", seconds, settings.gpuMetric.displayName))
        print(pad("时间", 10) + pad("CPU%", 7, right: true) + pad("GPU%", 7, right: true)
              + pad("压力", 9, right: true) + pad("空闲GB", 8, right: true) + "  来源 / 备注")

        var frames = 0
        let startedAt = Date()
        let costAtStart = ProcessCost.read()
        startMonitoring { snapshot in
            frames += 1
            let cpu = snapshot.cpu.map { String(format: "%.1f", $0) } ?? "—"
            let gpu = snapshot.gpu.map { String(format: "%.1f", $0) } ?? "N/A"
            let pressure = snapshot.memoryPressure?.displayName ?? "?"
            let free = snapshot.memoryFreeBytes.map { String(format: "%.2f", Double($0) / 1e9) } ?? "—"
            var note = snapshot.gpuSource ?? ""
            if let reason = snapshot.gpuUnavailableReason { note = reason }
            if let diagnostics = snapshot.gpuDiagnostics { note += "  [hw: \(diagnostics)]" }
            print(self.pad(self.clock(), 10) + self.pad(cpu, 7, right: true) + self.pad(gpu, 7, right: true)
                  + self.pad(pressure, 9, right: true) + self.pad(free, 8, right: true) + "  " + note)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let wall = Date().timeIntervalSince(startedAt)
            let cost = ProcessCost.read()
            let cpu = (cost.cpuSeconds - costAtStart.cpuSeconds) / max(wall, 0.001) * 100
            let stats = self.monitor?.tickStats()
            print(String(format: "输出 %d 帧，结束；自身 CPU %.2f%%，RSS %.1f MB，采样 %.3f ms/帧（%d 帧）",
                         frames, cpu, Double(cost.residentBytes) / 1e6,
                         stats?.averageMilliseconds ?? 0, stats?.count ?? 0))
            NSApp.terminate(nil)
        }
    }

    // MARK: - 自检

    private func runSelfCheck() {
        // 观察 status item 窗口是否被系统摆到菜单栏（启动初期可能短暂为 .zero）
        var ticks = 0
        var lastFrame = NSRect.zero
        let probe = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let menuBar = self.menuBar else { return }
                ticks += 1
                let frame = menuBar.debugWindowFrame
                if frame != lastFrame {
                    print("t=\(ticks)s frame=\(frame) visible=\(menuBar.debugItemVisible)")
                    lastFrame = frame
                }
                if ticks >= 5 { timer.invalidate() }
            }
        }
        _ = probe

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, let menuBar = self.menuBar else { return }
            print("===== 菜单栏自检 =====")
            print(menuBar.diagnostics())

            let before = menuBar.debugLength
            menuBar.debugTogglePercents()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                print("隐藏百分比: length \(before) -> \(menuBar.debugLength)")
                menuBar.debugTogglePercents()   // 还原用户设置
                // 验证自定义配色能实时传到绘制层
                self.colorSettings.normal = .systemPink
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    print("配色联动: \(menuBar.debugPalette.normal == .systemPink ? "OK" : "FAIL")")
                    self.colorSettings.resetToDefaults()
                }

                let shown = menuBar.debugShowPopover()
                self.openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    print("popover shown = \(shown) / \(menuBar.debugPopoverShown)  size = \(menuBar.debugPopoverSize)")
                    if let window = self.settingsWindow?.window {
                        print("settings window = \(window.frame.size)  visible=\(window.isVisible)")
                    }
                    print("login item status = \(self.loginManager.debugStatus)")
                    print("======================")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - 小工具

    private func clock() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    private func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        guard text.count < width else { return text }
        let spaces = String(repeating: " ", count: width - text.count)
        return right ? spaces + text : text + spaces
    }
}
