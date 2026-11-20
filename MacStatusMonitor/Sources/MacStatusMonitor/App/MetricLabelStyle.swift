import Foundation

/// 菜单栏里 CPU/GPU 标签的显示方式。
///
/// 用户可以在设置里切换，直接影响状态栏宽度：
/// - `full`：CPU / GPU（默认）
/// - `short`：C / G
/// - `hidden`：只留进度条与百分比
public enum MetricLabelStyle: String, Sendable, CaseIterable {
    case full
    case short
    case hidden

    public var displayName: String {
        switch self {
        case .full: return "CPU / GPU"
        case .short: return "C / G"
        case .hidden: return "不显示"
        }
    }

    /// 每行标签占用的宽度（pt）
    public var width: CGFloat {
        switch self {
        case .full: return 20
        case .short: return 9
        case .hidden: return 0
        }
    }

    /// 标签与进度条的间距
    public var gap: CGFloat {
        self == .hidden ? 0 : 3
    }

    public func text(for cpuOrGpu: String) -> String {
        switch self {
        case .full: return cpuOrGpu
        case .short: return String(cpuOrGpu.prefix(1))
        case .hidden: return ""
        }
    }
}
