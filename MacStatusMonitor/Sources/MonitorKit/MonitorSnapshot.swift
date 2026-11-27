import Foundation

/// 内存压力等级。
///
/// 只由系统事件（DispatchSource / sysctl）驱动，**绝不**由"已用内存百分比"推导。
public enum MemoryPressureLevel: Int, Sendable, CaseIterable {
    case normal = 1
    case warning = 2
    case critical = 4

    public var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    /// 由内核 `kern.memorystatus_vm_pressure_level` 原始值映射。
    /// XNU 定义：1 = normal，2 = warn，4 = critical；其他值视为未知。
    public init?(rawLevel: Int32) {
        self.init(rawValue: Int(rawLevel))
    }
}

/// 菜单栏与 Popover 共用的只读数据快照。
///
/// 采集层每次刷新产出一个快照，UI 层整体替换。
/// `==` 刻意忽略 `timestamp`：数值没变就不触发重绘。
public struct MonitorSnapshot: Sendable {
    /// CPU 总使用率 0...100；nil 表示尚未采到（首次采样）
    public var cpu: Double?
    /// GPU 使用率 0...100；nil 表示不可用
    public var gpu: Double?
    /// 内存压力；nil 表示未知
    public var memoryPressure: MemoryPressureLevel?

    // 详情（Popover 用）
    public var cpuUser: Double?
    public var cpuSystem: Double?
    public var cpuIdle: Double?
    public var perCoreCPU: [Double]
    public var loadAverage: [Double]

    /// GPU 口径名，例如"硬件忙时占比"
    public var gpuSource: String?
    /// GPU 附加说明（活跃段数等）
    public var gpuDetail: String?
    /// 为什么拿不到 GPU 数据（nil 表示正常）。UI 有值且 gpu == nil 时显示 N/A
    public var gpuUnavailableReason: String?
    /// 硬件采样器最近一次失败的具体原因（诊断用，不显示在 UI）
    public var gpuDiagnostics: String?

    /// 活动监视器口径的「已使用内存」（App + Wired + Compressed）
    public var memoryUsedBytes: UInt64?
    /// 活动监视器口径的「已缓存文件」
    public var memoryCachedBytes: UInt64?
    public var memoryFreeBytes: UInt64?
    public var memoryCompressedBytes: UInt64?
    public var memoryWiredBytes: UInt64?
    public var swapUsedBytes: UInt64?
    public var physicalMemoryBytes: UInt64

    public var timestamp: Date

    public init(
        cpu: Double? = nil,
        gpu: Double? = nil,
        memoryPressure: MemoryPressureLevel? = nil,
        cpuUser: Double? = nil,
        cpuSystem: Double? = nil,
        cpuIdle: Double? = nil,
        perCoreCPU: [Double] = [],
        loadAverage: [Double] = [],
        gpuSource: String? = nil,
        gpuDetail: String? = nil,
        gpuUnavailableReason: String? = nil,
        gpuDiagnostics: String? = nil,
        memoryUsedBytes: UInt64? = nil,
        memoryCachedBytes: UInt64? = nil,
        memoryFreeBytes: UInt64? = nil,
        memoryCompressedBytes: UInt64? = nil,
        memoryWiredBytes: UInt64? = nil,
        swapUsedBytes: UInt64? = nil,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        timestamp: Date = Date()
    ) {
        self.cpu = cpu
        self.gpu = gpu
        self.memoryPressure = memoryPressure
        self.cpuUser = cpuUser
        self.cpuSystem = cpuSystem
        self.cpuIdle = cpuIdle
        self.perCoreCPU = perCoreCPU
        self.loadAverage = loadAverage
        self.gpuSource = gpuSource
        self.gpuDetail = gpuDetail
        self.gpuUnavailableReason = gpuUnavailableReason
        self.gpuDiagnostics = gpuDiagnostics
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryCachedBytes = memoryCachedBytes
        self.memoryFreeBytes = memoryFreeBytes
        self.memoryCompressedBytes = memoryCompressedBytes
        self.memoryWiredBytes = memoryWiredBytes
        self.swapUsedBytes = swapUsedBytes
        self.physicalMemoryBytes = physicalMemoryBytes
        self.timestamp = timestamp
    }

    /// 阶段二占位：没有任何数据，UI 显示 "—" 与灰框，不伪造数值。
    public static let placeholder = MonitorSnapshot()
}

extension MonitorSnapshot: Equatable {
    public static func == (lhs: MonitorSnapshot, rhs: MonitorSnapshot) -> Bool {
        lhs.cpu == rhs.cpu
            && lhs.gpu == rhs.gpu
            && lhs.memoryPressure == rhs.memoryPressure
            && lhs.cpuUser == rhs.cpuUser
            && lhs.cpuSystem == rhs.cpuSystem
            && lhs.cpuIdle == rhs.cpuIdle
            && lhs.perCoreCPU == rhs.perCoreCPU
            && lhs.loadAverage == rhs.loadAverage
            && lhs.gpuSource == rhs.gpuSource
            && lhs.gpuDetail == rhs.gpuDetail
            && lhs.gpuUnavailableReason == rhs.gpuUnavailableReason
            && lhs.memoryUsedBytes == rhs.memoryUsedBytes
            && lhs.memoryCachedBytes == rhs.memoryCachedBytes
            && lhs.memoryFreeBytes == rhs.memoryFreeBytes
            && lhs.memoryCompressedBytes == rhs.memoryCompressedBytes
            && lhs.memoryWiredBytes == rhs.memoryWiredBytes
            && lhs.swapUsedBytes == rhs.swapUsedBytes
            && lhs.physicalMemoryBytes == rhs.physicalMemoryBytes
    }
}

/// GPU 利用率口径。用户可在设置中切换。
///
/// - `automatic`: 优先 hardwareBusy，连续失败时降级 driverReported
/// - `hardwareBusy`: IOReport Active/Idle Time 直方图（硬件时间戳），推荐
/// - `driverReported`: IOAccelerator "Device Utilization %"（驱动自报，高负载会饱和）
public enum GPUMetric: String, Sendable, CaseIterable {
    case automatic
    case hardwareBusy
    case driverReported

    public var displayName: String {
        switch self {
        case .automatic: return "自动（推荐）"
        case .hardwareBusy: return "硬件活跃占比"
        case .driverReported: return "驱动自报百分比"
        }
    }

    public var explanation: String {
        switch self {
        case .automatic:
            return "优先使用硬件活跃占比；不可用时自动降级为驱动百分比。"
        case .hardwareBusy:
            return "GPU 频率状态驻留（非 OFF 时间占比），连续累加、随负载线性；含系统合成活动。"
        case .driverReported:
            return "读取 AGX 驱动的 Device Utilization %，兼容性好，但高负载段会压缩到 100%。"
        }
    }
}
