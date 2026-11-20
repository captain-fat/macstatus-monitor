import Foundation
import Darwin
import Dispatch

/// 内存压力等级。数值与内核 `kern.memorystatus_vm_pressure_level` 一致：
/// 1 = normal, 2 = warning, 4 = critical（0/其他 = 未知）。
enum MemoryPressureLevel: Int32, CustomStringConvertible {
    case normal = 1
    case warning = 2
    case critical = 4

    var description: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    /// 用于绘制外框的颜色语义键
    var semanticKey: String {
        switch self {
        case .normal: return "green"
        case .warning: return "yellow"
        case .critical: return "red"
        }
    }
}

struct MemorySnapshot {
    var level: MemoryPressureLevel?
    var rawLevel: Int32
    var freeBytes: UInt64
    var compressorBytes: UInt64
    var wiredBytes: UInt64
    var swapUsedBytes: UInt64
    var totalBytes: UInt64
}

/// 内存压力监控。
///
/// 两条独立通道：
/// 1. DispatchSource.makeMemoryPressureSource —— 系统事件驱动，状态变化时回调，
///    用于「及时更新界面」，不轮询。
/// 2. sysctl kern.memorystatus_vm_pressure_level —— 用于启动时读取初始状态
///    （DispatchSource 只在状态「变化」时触发，启动瞬间不会给初值）。
final class MemoryPressureSampler {

    /// 事件回调（主线程外也会触发，调用方需自行切到主线程）
    var onLevelChange: ((MemoryPressureLevel) -> Void)?
    /// 内核给出的原始等级值变化（含未知值），便于观察
    var onRawLevel: ((Int32) -> Void)?

    private var source: DispatchSourceMemoryPressure?
    private let queue = DispatchQueue(label: "probe.memorypressure", qos: .utility)

    /// 当前已知等级（由事件与 sysctl 共同维护）
    private(set) var level: MemoryPressureLevel = .normal

    func start() {
        guard source == nil else { return }

        // 初始状态：内核当前压力等级
        let initial = Self.readRawLevel()
        if let l = MemoryPressureLevel(rawValue: initial) {
            level = l
            onLevelChange?(l)
        }

        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = src.data
            let mapped: MemoryPressureLevel?
            if mask.contains(.critical) {
                mapped = .critical
            } else if mask.contains(.warning) {
                mapped = .warning
            } else if mask.contains(.normal) {
                mapped = .normal
            } else {
                mapped = nil
            }
            if let mapped {
                self.level = mapped
                self.onLevelChange?(mapped)
            }
            let raw = Self.readRawLevel()
            self.onRawLevel?(raw)
        }
        src.resume()
        source = src
    }

    func stop() {
        // 释放 dispatch source：先取消，事件处理器在 cancel 后不再触发
        source?.setEventHandler {}
        source?.cancel()
        source = nil
    }

    deinit { stop() }

    /// 内核当前压力等级原始值
    static func readRawLevel() -> Int32 {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rc = sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0)
        return rc == 0 ? value : 0
    }

    /// 详情面板用的 VM 统计（与压力等级无直接推导关系，仅作展示）
    func snapshot() -> MemorySnapshot {
        let raw = Self.readRawLevel()
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        var stats = MemorySnapshot(
            level: MemoryPressureLevel(rawValue: raw),
            rawLevel: raw,
            freeBytes: 0, compressorBytes: 0, wiredBytes: 0, swapUsedBytes: 0,
            totalBytes: ProcessInfo.processInfo.physicalMemory
        )
        let kr = withUnsafeMutablePointer(to: &vm) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            stats.freeBytes = UInt64(vm.free_count) * page
            stats.compressorBytes = UInt64(vm.compressor_page_count) * page
            stats.wiredBytes = UInt64(vm.wire_count) * page
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            stats.swapUsedBytes = swap.xsu_used
        }
        return stats
    }
}
