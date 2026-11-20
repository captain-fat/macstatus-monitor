import Foundation
import Combine
import MonitorKit

/// 应用设置。阶段二只落地与布局相关的两项，其余在阶段四接设置界面。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let showCPUPercent = "showCPUPercent"
        static let showGPUPercent = "showGPUPercent"
        static let gpuMetric = "gpuMetric"
        static let refreshInterval = "refreshInterval"
        static let labelStyle = "labelStyle"
        static let showsBar = "showsBar"
        static let barWidth = "barWidth"
    }

    private let defaults: UserDefaults

    @Published var showCPUPercent: Bool {
        didSet { defaults.set(showCPUPercent, forKey: Key.showCPUPercent) }
    }

    @Published var showGPUPercent: Bool {
        didSet { defaults.set(showGPUPercent, forKey: Key.showGPUPercent) }
    }

    @Published var gpuMetric: GPUMetric {
        didSet { defaults.set(gpuMetric.rawValue, forKey: Key.gpuMetric) }
    }

    /// 秒。允许 0.5 / 1 / 2 / 5
    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) }
    }

    /// CPU/GPU 标签：完整、缩写、隐藏
    @Published var labelStyle: MetricLabelStyle {
        didSet { defaults.set(labelStyle.rawValue, forKey: Key.labelStyle) }
    }

    /// 是否显示进度条；关掉后只显示标签与百分比
    @Published var showsBar: Bool {
        didSet { defaults.set(showsBar, forKey: Key.showsBar) }
    }

    /// 进度条长度（pt）：短 20 / 标准 30 / 长 40
    @Published var barWidth: Double {
        didSet { defaults.set(barWidth, forKey: Key.barWidth) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showCPUPercent: true,
            Key.showGPUPercent: true,
            Key.gpuMetric: GPUMetric.automatic.rawValue,
            Key.refreshInterval: 1.0,
            Key.labelStyle: MetricLabelStyle.full.rawValue,
            Key.showsBar: true,
            Key.barWidth: 30.0,
        ])
        showCPUPercent = defaults.bool(forKey: Key.showCPUPercent)
        showGPUPercent = defaults.bool(forKey: Key.showGPUPercent)
        gpuMetric = GPUMetric(rawValue: defaults.string(forKey: Key.gpuMetric) ?? "") ?? .automatic
        let interval = defaults.double(forKey: Key.refreshInterval)
        refreshInterval = interval > 0 ? interval : 1.0
        labelStyle = MetricLabelStyle(rawValue: defaults.string(forKey: Key.labelStyle) ?? "") ?? .full
        showsBar = defaults.bool(forKey: Key.showsBar)
        let bar = defaults.double(forKey: Key.barWidth)
        barWidth = [20.0, 30.0, 40.0].contains(bar) ? bar : 30.0
    }
}
