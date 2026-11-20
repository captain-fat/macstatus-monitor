import Foundation
import Darwin

/// 单次 CPU 采样结果。
public struct CPUSample: Sendable {
    public var total: Double      // 0...100
    public var user: Double       // 0...100，占全部 tick 的比例
    public var system: Double
    public var idle: Double
    public var perCore: [Double]  // 每核 0...100
    public var loadAverage: [Double]
    public var coreCount: Int
}

/// 基于 Mach host statistics 的 CPU 采样。
///
/// 关键约束（阶段一验证过）：
/// - `mach_host_self()` 只取一次，deinit 释放，否则每次采样泄漏一个 send right；
/// - `host_processor_info` 返回的内核内存必须 `vm_deallocate`；
/// - 用相邻两次 tick 的差值，32 位计数回绕用无符号减法；
/// - 首次调用没有基准，返回 nil（UI 显示占位符，而不是假的 0%）。
public final class CPUMonitor {
    private let host: host_t
    private var previous: [CoreTicks] = []

    private struct CoreTicks {
        var user: UInt64
        var system: UInt64
        var idle: UInt64
        var nice: UInt64
    }

    public init() {
        host = mach_host_self()
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    public func sample() -> CPUSample? {
        guard let ticks = readTicks() else { return nil }
        defer { previous = ticks }
        guard previous.count == ticks.count, !ticks.isEmpty else { return nil }

        var perCore: [Double] = []
        perCore.reserveCapacity(ticks.count)
        var sumUser = 0.0, sumSystem = 0.0, sumIdle = 0.0, sumNice = 0.0, sumTotal = 0.0

        for index in ticks.indices {
            let a = previous[index], b = ticks[index]
            let dUser = Double(b.user &- a.user)
            let dSystem = Double(b.system &- a.system)
            let dIdle = Double(b.idle &- a.idle)
            let dNice = Double(b.nice &- a.nice)
            let total = dUser + dSystem + dIdle + dNice
            perCore.append(total > 0 ? min(max((dUser + dSystem + dNice) / total * 100, 0), 100) : 0)
            sumUser += dUser
            sumSystem += dSystem
            sumIdle += dIdle
            sumNice += dNice
            sumTotal += total
        }
        guard sumTotal > 0 else { return nil }

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)

        return CPUSample(
            total: min(max((sumUser + sumSystem + sumNice) / sumTotal * 100, 0), 100),
            user: sumUser / sumTotal * 100,
            system: sumSystem / sumTotal * 100,
            idle: sumIdle / sumTotal * 100,
            perCore: perCore,
            loadAverage: loads,
            coreCount: ticks.count
        )
    }

    private func readTicks() -> [CoreTicks]? {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount) == KERN_SUCCESS,
              let info = infoArray else { return nil }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let stride = Int(CPU_STATE_MAX)
        var ticks: [CoreTicks] = []
        ticks.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * stride
            guard base + stride <= Int(infoCount) else { break }
            ticks.append(CoreTicks(
                user: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])),
                system: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])),
                idle: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])),
                nice: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            ))
        }
        return ticks
    }
}
