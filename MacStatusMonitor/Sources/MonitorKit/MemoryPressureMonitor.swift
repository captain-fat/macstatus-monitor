import Foundation
import Darwin
import Dispatch

/// 内存明细（只用于 Popover 展示，不参与压力等级判定）。
public struct MemoryDetails: Sendable {
    public var totalBytes: UInt64
    /// 活动监视器的「已使用内存」= App Memory + Wired + Compressed
    public var usedBytes: UInt64
    /// 活动监视器的「已缓存文件」= 文件页 + 可清除页
    public var cachedBytes: UInt64
    /// 其中：App Memory（匿名页 − 可清除页）
    public var appBytes: UInt64
    public var compressedBytes: UInt64
    public var wiredBytes: UInt64
    public var freeBytes: UInt64
    public var swapUsedBytes: UInt64
    public var rawLevel: Int32
}

/// 内存压力监控。
///
/// 两条独立通道：
/// 1. `DispatchSource.makeMemoryPressureSource` —— 事件驱动，状态变化时立即回调；
/// 2. `sysctl kern.memorystatus_vm_pressure_level` —— 只用于启动时补初值
///    （dispatch source 不会在创建时给出当前状态）。
///
/// 明确不使用"已用内存百分比 / 剩余内存阈值"来推导压力等级。
public final class MemoryPressureMonitor {

    /// 状态变化回调（在内部队列触发，调用方自行切线程）
    public var onLevelChange: ((MemoryPressureLevel) -> Void)?

    private var source: DispatchSourceMemoryPressure?
    private let queue = DispatchQueue(label: "com.captainslow667.MacStatusMonitor.memory", qos: .utility)
    private let host: host_t
    private let stateLock = NSLock()
    private var _level: MemoryPressureLevel = .normal

    public private(set) var level: MemoryPressureLevel {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _level
        }
        set {
            stateLock.lock()
            _level = newValue
            stateLock.unlock()
        }
    }

    public init() {
        host = mach_host_self()
        if let initial = MemoryPressureLevel(rawLevel: Self.readRawLevel()) {
            _level = initial
        }
    }

    deinit {
        stop()
        mach_port_deallocate(mach_task_self_, host)
    }

    public func start() {
        guard source == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: queue
        )
        // dispatch 事件只当"该刷新了"的信号：真正的等级以 sysctl 当前值为准。
        // 这样即使错过一次恢复事件（实测会卡在旧的 warning），下一次 tick 也能自愈。
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let refreshed = self.refreshLevel()
            self.onLevelChange?(refreshed)
        }
        src.resume()
        source = src
    }

    public func stop() {
        source?.setEventHandler {}
        source?.cancel()
        source = nil
    }

    /// 主动读一次内核当前等级并同步到 `level`。
    ///
    /// 以 sysctl 为准而不是缓存事件状态：macOS 并不保证每次恢复到正常都会
    /// 再投递一次 `.normal` 事件，只靠事件会在压力回落之后仍然显示黄色。
    @discardableResult
    public func refreshLevel() -> MemoryPressureLevel {
        let raw = Self.readRawLevel()
        guard let mapped = MemoryPressureLevel(rawLevel: raw) else {
            return level   // 0 / 未知值：保持当前判断，不自行猜阈值
        }
        if mapped != level {
            level = mapped
        }
        return mapped
    }

    /// 启动时的初始压力等级（读 sysctl）
    public static func currentLevel() -> MemoryPressureLevel? {
        MemoryPressureLevel(rawLevel: readRawLevel())
    }

    public static func readRawLevel() -> Int32 {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else {
            return 0
        }
        return value
    }

    public func details() -> MemoryDetails {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }

        var total: UInt64 = 0
        var app: UInt64 = 0
        var wired: UInt64 = 0
        var compressed: UInt64 = 0
        var cached: UInt64 = 0
        var free: UInt64 = 0

        if result == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(vm.internal_page_count)
            let externalPages = UInt64(vm.external_page_count)
            let purgeablePages = UInt64(vm.purgeable_count)

            // 与活动监视器口径一致：
            //   App Memory   = 匿名页 − 可清除页
            //   Cached Files = 文件页 + 可清除页
            //   Memory Used  = App + Wired + Compressed
            app = (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * page
            wired = UInt64(vm.wire_count) * page
            compressed = UInt64(vm.compressor_page_count) * page
            cached = (externalPages + purgeablePages) * page
            free = UInt64(vm.free_count) * page
            total = ProcessInfo.processInfo.physicalMemory
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed: UInt64
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            swapUsed = swap.xsu_used
        } else {
            swapUsed = 0
        }

        return MemoryDetails(
            totalBytes: total,
            usedBytes: app + wired + compressed,
            cachedBytes: cached,
            appBytes: app,
            compressedBytes: compressed,
            wiredBytes: wired,
            freeBytes: free,
            swapUsedBytes: swapUsed,
            rawLevel: Self.readRawLevel()
        )
    }
}
