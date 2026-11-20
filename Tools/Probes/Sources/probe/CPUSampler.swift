import Foundation
import Darwin

/// 单个 CPU 核心在两次采样之间的 tick 增量
struct CoreTicks {
    var user: UInt64 = 0
    var system: UInt64 = 0
    var idle: UInt64 = 0
    var nice: UInt64 = 0

    var total: UInt64 { user + system + idle + nice }
    var busy: UInt64 { user + system + nice }
}

struct CPUSample {
    var total: Double            // 0...100
    var user: Double             // 0...100（用于详情面板）
    var system: Double           // 0...100
    var idle: Double             // 0...100
    var perCore: [Double]        // 每个核心 0...100
    var loadAverage: [Double]    // 1/5/15 分钟
    var coreCount: Int
}

/// 基于 Mach host_statistics(host_processor_info) 的 CPU 采样器。
///
/// 设计要点：
/// - host_t 只获取一次（mach_host_self() 是 send right，重复调用会泄漏 right）；
/// - 每次采样分配的内存必须 vm_deallocate，否则 1Hz 运行会持续泄漏；
/// - 使用「相邻两次 tick 差值」而不是累加值，避免开机时长影响；
/// - 首次采样必然没有基准，返回 nil，由调用方显示占位符。
final class CPUSampler {
    private let host: host_t
    private var previous: [CoreTicks] = []
    private var previousTimestamp: DispatchTime?

    init() {
        host = mach_host_self()
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    /// 采样一次。首次调用（没有基准）时返回 nil。
    func sample() -> CPUSample? {
        guard let ticks = readTicks() else { return nil }
        defer { previous = ticks }
        guard previous.count == ticks.count, !previous.isEmpty else { return nil }

        var perCore: [Double] = []
        perCore.reserveCapacity(ticks.count)
        var sumUser = 0.0, sumSystem = 0.0, sumIdle = 0.0, sumTotal = 0.0

        for i in ticks.indices {
            let a = previous[i], b = ticks[i]
            // tick 计数器是 32 位，回绕时用无符号减法仍能得到正确增量
            let dUser = Double(b.user &- a.user)
            let dSystem = Double(b.system &- a.system)
            let dIdle = Double(b.idle &- a.idle)
            let dNice = Double(b.nice &- a.nice)
            let total = dUser + dSystem + dIdle + dNice
            let usage = total > 0 ? (dUser + dSystem + dNice) / total * 100.0 : 0
            perCore.append(min(max(usage, 0), 100))
            sumUser += dUser
            sumSystem += dSystem
            sumIdle += dIdle
            sumTotal += total
        }

        let total = sumTotal > 0 ? (sumUser + sumSystem + (sumTotal - sumUser - sumSystem - sumIdle)) / sumTotal * 100 : 0
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)

        previousTimestamp = .now()
        return CPUSample(
            total: min(max(total, 0), 100),
            user: sumTotal > 0 ? sumUser / sumTotal * 100 : 0,
            system: sumTotal > 0 ? sumSystem / sumTotal * 100 : 0,
            idle: sumTotal > 0 ? sumIdle / sumTotal * 100 : 0,
            perCore: perCore,
            loadAverage: loads,
            coreCount: ticks.count
        )
    }

    private func readTicks() -> [CoreTicks]? {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount)
        guard result == KERN_SUCCESS, let info = infoArray else {
            return nil
        }
        // 必须释放内核返回的这块内存
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
