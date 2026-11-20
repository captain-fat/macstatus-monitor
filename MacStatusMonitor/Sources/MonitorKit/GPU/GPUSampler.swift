import Foundation
import IOKit

/// 一次 GPU 读数。
public struct GPUSample: Sendable {
    public var utilization: Double   // 0...100
    public var source: String        // 给 UI 显示的口径名
    public var detail: String?       // 附加说明

    public init(utilization: Double, source: String, detail: String? = nil) {
        self.utilization = utilization
        self.source = source
        self.detail = detail
    }
}

public protocol GPUSampling: AnyObject {
    var isAvailable: Bool { get }
    /// interval 是两次采样之间预期的秒数，用于校验直方图窗口是否合理
    func sample(interval: TimeInterval) -> GPUSample?
}

// MARK: - 硬件忙时占比（IOReport）

/// 主方案：`GPU Stats / Active Time Histogram` + `Idle Time Histogram`。
///
/// 两个子组各用一个过滤订阅（0.16 ms/帧），比整组订阅（133 频道，0.63 ms）省 4 倍。
/// 数据是 24 MHz 硬件时间戳累计的忙/闲时长，再除以总时长得到占比。
public final class IOReportGPUSampler: GPUSampling {

    private let bridge = IOReportBridge.shared
    private var subscription: IOReportBridge.Subscription?
    private var previous: IOReportBridge.Report?

    /// 最近一次失败原因（诊断用，不影响 UI 决策）
    public private(set) var lastFailure: String?

    public init() {
        guard bridge.isAvailable else { return }
        // 只需要频率状态驻留这一个子组（1 个频道），比整组 133 频道省 6 倍开销。
        // 驻留是连续累加的计数器，过滤订阅在满载时也不会缺数据（与直方图不同）。
        subscription = bridge.subscription(group: "GPU Stats", subgroup: "GPU Performance States")
    }

    public var isAvailable: Bool { subscription != nil }

    public func sample(interval: TimeInterval) -> GPUSample? {
        guard let subscription, let current = subscription.sample() else {
            lastFailure = "订阅采样失败"
            return nil
        }
        defer { previous = current }

        guard let previous, let delta = subscription.delta(previous: previous, current: current) else {
            lastFailure = "delta 失败"
            return nil
        }
        guard let reading = GPUUtilization.activeResidency(delta: delta, bridge: bridge) else {
            lastFailure = "状态驻留解码失败"
            return nil
        }

        let expected = max(interval, 0.05)
        guard reading.totalSeconds > expected * 0.5,
              reading.totalSeconds < max(4.0, expected * 3.0)
        else {
            lastFailure = String(
                format: "窗口异常 total=%.2fs expected=%.2fs",
                reading.totalSeconds, expected
            )
            return nil
        }
        lastFailure = nil

        return GPUSample(
            utilization: reading.fraction,
            source: "硬件活跃占比",
            detail: String(format: "OFF 驻留 %.0f%%", reading.offPercent)
        )
    }
}

// MARK: - 驱动自报百分比（IOAccelerator）

/// 降级方案：读 AGX 驱动的 `PerformanceStatistics["Device Utilization %"]`。
/// 免 root、免私有框架，但高负载段会压缩（阶段一实测：40%→100% 真值只从 85 涨到 99）。
public final class IOAcceleratorGPUSampler: GPUSampling {

    private var service: io_service_t = 0
    private var serviceName: String = ""

    public init() {
        open()
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    private func open() {
        guard service == 0, let matching = IOServiceMatching("IOAccelerator") else { return }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        while case let candidate = IOIteratorNext(iterator), candidate != 0 {
            if let statistics = Self.performanceStatistics(candidate), !statistics.isEmpty {
                service = candidate
                var nameBuffer = [CChar](repeating: 0, count: 128)
                IORegistryEntryGetName(candidate, &nameBuffer)
                serviceName = String(cString: nameBuffer)
                return
            }
            IOObjectRelease(candidate)
        }
    }

    public var isAvailable: Bool { service != 0 }

    public func sample(interval: TimeInterval) -> GPUSample? {
        guard service != 0, let statistics = Self.performanceStatistics(service) else { return nil }
        guard let value = Self.number(statistics["Device Utilization %"]) else { return nil }
        return GPUSample(
            utilization: min(max(value, 0), 100),
            source: "驱动自报百分比",
            detail: serviceName.isEmpty ? nil : serviceName
        )
    }

    private static func performanceStatistics(_ entry: io_registry_entry_t) -> [String: Any]? {
        guard let property = IORegistryEntryCreateCFProperty(
            entry,
            "PerformanceStatistics" as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        return property.takeRetainedValue() as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let double as Double: return double
        case let int as Int: return Double(int)
        default: return nil
        }
    }
}

// MARK: - 口径选择与降级

/// 按设置选择 GPU 口径。
///
/// - `.automatic`：优先硬件忙时占比；某帧失败时临时用驱动百分比兜底，不永久降级，
///   这样满载/空闲切换时不会卡在错误口径上；
/// - `.hardwareBusy`：只信硬件计数器，拿不到就 N/A；
/// - `.driverReported`：只用驱动百分比。
public final class CompositeGPUSampler {

    public private(set) var metric: GPUMetric
    public private(set) var unavailableReason: String?

    private let hardware = IOReportGPUSampler()
    private let driver = IOAcceleratorGPUSampler()
    private var consecutiveHardwareFailures = 0

    public init(metric: GPUMetric) {
        self.metric = metric
    }

    public func setMetric(_ metric: GPUMetric) {
        guard metric != self.metric else { return }
        self.metric = metric
        consecutiveHardwareFailures = 0
        unavailableReason = nil
    }

    public var isAvailable: Bool {
        hardware.isAvailable || driver.isAvailable
    }

    /// 硬件口径最近一次失败原因（诊断用）
    public var lastHardwareFailure: String? { hardware.lastFailure }

    public func sample(interval: TimeInterval) -> GPUSample? {
        switch metric {
        case .hardwareBusy:
            if let sample = hardware.sample(interval: interval) {
                unavailableReason = nil
                return sample
            }
            unavailableReason = hardware.isAvailable
                ? "硬件计数器暂时没有返回有效窗口"
                : "当前系统未提供 GPU 硬件计数器"
            return nil

        case .driverReported:
            if let sample = driver.sample(interval: 0) {
                unavailableReason = nil
                return sample
            }
            unavailableReason = "未找到 IOAccelerator 性能统计"
            return nil

        case .automatic:
            if let sample = hardware.sample(interval: interval) {
                consecutiveHardwareFailures = 0
                unavailableReason = nil
                return sample
            }
            consecutiveHardwareFailures += 1
            if let sample = driver.sample(interval: 0) {
                unavailableReason = "硬件计数器暂不可用，当前显示驱动百分比"
                return sample
            }
            unavailableReason = hardware.isAvailable
                ? "GPU 计数器没有返回有效数据"
                : "当前系统未提供 GPU 硬件计数器"
            return nil
        }
    }
}
