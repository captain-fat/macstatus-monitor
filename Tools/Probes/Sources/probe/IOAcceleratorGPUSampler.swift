import Foundation
import IOKit

struct GPUStats {
    var deviceUtilization: Double?   // 0...100, "Device Utilization %"
    var rendererUtilization: Double?
    var tilerUtilization: Double?
    var inUseSystemMemory: UInt64?
    var raw: [String: Any]
    var serviceName: String
}

/// GPU 采样方案 A：IOKit / IOAccelerator 驱动统计。
///
/// 原理：AGX 驱动（IOAccelerator 子类，如 AGXAcceleratorG17G）在 IORegistry 属性
/// `PerformanceStatistics` 中暴露驱动侧记账的忙闲百分比。它是公开的 IOKit 属性，
/// 不需要 root，不需要额外授权，也不会触发 GPU 唤醒以外的副作用。
final class IOAcceleratorGPUSampler {
    private var service: io_service_t = 0
    private(set) var serviceName: String = ""

    /// 打开第一个可用的 IOAccelerator 服务（只做一次）
    @discardableResult
    func open() -> Bool {
        guard service == 0 else { return true }
        guard let matching = IOServiceMatching("IOAccelerator") else { return false }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        while case let candidate = IOIteratorNext(iterator), candidate != 0 {
            if let stats = Self.readPerformanceStatistics(candidate), !stats.isEmpty {
                service = candidate
                var nameBuf = [CChar](repeating: 0, count: 128)
                IORegistryEntryGetName(candidate, &nameBuf)
                serviceName = String(cString: nameBuf)
                return true
            }
            IOObjectRelease(candidate)
        }
        return false
    }

    func close() {
        if service != 0 {
            IOObjectRelease(service)
            service = 0
        }
    }

    deinit { close() }

    func sample() -> GPUStats? {
        guard service != 0 else { return nil }
        guard let stats = Self.readPerformanceStatistics(service) else { return nil }
        return GPUStats(
            deviceUtilization: Self.number(stats["Device Utilization %"]).map { min(max($0, 0), 100) },
            rendererUtilization: Self.number(stats["Renderer Utilization %"]),
            tilerUtilization: Self.number(stats["Tiler Utilization %"]),
            inUseSystemMemory: Self.number(stats["In use system memory"]).map { UInt64($0) },
            raw: stats,
            serviceName: serviceName
        )
    }

    private static func readPerformanceStatistics(_ entry: io_registry_entry_t) -> [String: Any]? {
        guard let prop = IORegistryEntryCreateCFProperty(
            entry,
            "PerformanceStatistics" as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        return prop.takeRetainedValue() as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        default: return nil
        }
    }
}
