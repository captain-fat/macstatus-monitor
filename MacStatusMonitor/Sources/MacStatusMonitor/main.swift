import AppKit

// 调试入口：离屏渲染菜单栏视图，不启动常驻应用
let arguments = CommandLine.arguments
MainActor.assumeIsolated {
    if let index = arguments.firstIndex(of: "--render-previews"), index + 1 < arguments.count {
        PreviewRenderer.render(to: URL(fileURLWithPath: arguments[index + 1]))
        exit(0)
    }

    if CommandLine.arguments.contains("--gpu-probe") {
        GPUProbe.run(seconds: 3)
        exit(0)
    }

    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.run()
}
