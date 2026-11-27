import Foundation
import Dispatch

/// 统一的监控调度器。
///
/// 设计约束（对应"性能要求"）：
/// - 全程只有 **一个** 定时器，1 秒默认间隔，可改；
/// - 所有采集都在串行队列上跑，不会重叠；
/// - 内存压力事件到来时额外补发一帧，保证颜色变化"及时"；
/// - `stop()` 真正取消 timer、停止 dispatch source，不留下后台任务。
public final class SystemMonitor {

    public struct Configuration: Sendable {
        public var interval: TimeInterval
        public var gpuMetric: GPUMetric

        public init(interval: TimeInterval = 1.0, gpuMetric: GPUMetric = .automatic) {
            self.interval = interval
            self.gpuMetric = gpuMetric
        }
    }

    /// 快照回调，固定在主线程调用
    public var onSnapshot: (@Sendable (MonitorSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "com.captainslow667.MacStatusMonitor.monitor", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let cpu = CPUMonitor()
    private let memory = MemoryPressureMonitor()
    private let gpu: CompositeGPUSampler
    private var config: Configuration
    private var timer: DispatchSourceTimer?
    private var started = false
    private var tickCount = 0
    private var tickDurationTotal: Double = 0

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
        self.gpu = CompositeGPUSampler(metric: configuration.gpuMetric)
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        stop()
    }

    // MARK: - 生命周期

    public func start() {
        onQueue {
            guard !self.started else { return }
            self.started = true

            self.memory.onLevelChange = { [weak self] _ in
                self?.onQueue { self?.tick() }
            }
            self.memory.start()

            // 建立 CPU / GPU 基准，保证第一次 tick 就有有效差值
            _ = self.cpu.sample()
            _ = self.gpu.sample(interval: self.config.interval)

            self.deliverInitial()
            self.scheduleTimer()
        }
    }

    public func stop() {
        onQueue {
            guard self.started else { return }
            self.started = false
            self.timer?.cancel()
            self.timer = nil
            self.memory.onLevelChange = nil
            self.memory.stop()
        }
    }

    public func setInterval(_ interval: TimeInterval) {
        guard interval >= 0.25 else { return }
        onQueue {
            guard self.config.interval != interval else { return }
            self.config.interval = interval
            if self.started { self.scheduleTimer() }
        }
    }

    public func setGPUMetric(_ metric: GPUMetric) {
        onQueue {
            self.config.gpuMetric = metric
            self.gpu.setMetric(metric)
        }
    }

    // MARK: - 内部

    private func scheduleTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + config.interval,
            repeating: config.interval,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// 启动瞬间先发一帧"只有内存压力"的快照，让外框颜色立刻正确，
    /// 而 CPU/GPU 保持 nil（显示占位符），而不是用 0.0001 秒的差值算出一个假数字。
    private func deliverInitial() {
        let details = memory.details()
        var snapshot = MonitorSnapshot(memoryPressure: memory.refreshLevel())
        snapshot.memoryUsedBytes = details.usedBytes
        snapshot.memoryCachedBytes = details.cachedBytes
        snapshot.memoryFreeBytes = details.freeBytes
        snapshot.memoryCompressedBytes = details.compressedBytes
        snapshot.memoryWiredBytes = details.wiredBytes
        snapshot.swapUsedBytes = details.swapUsedBytes
        snapshot.physicalMemoryBytes = details.totalBytes
        deliver(snapshot)
    }

    /// 诊断：返回 (帧数, 平均采样耗时 ms)
    public func tickStats() -> (count: Int, averageMilliseconds: Double) {
        var result = (count: 0, averageMilliseconds: 0.0)
        onQueue {
            result = (self.tickCount, self.tickCount > 0 ? self.tickDurationTotal / Double(self.tickCount) * 1000 : 0)
        }
        return result
    }

    private func tick() {
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {
            tickDurationTotal += CFAbsoluteTimeGetCurrent() - startedAt
            tickCount += 1
        }
        let cpuSample = cpu.sample()
        let gpuSample = gpu.sample(interval: config.interval)
        let details = memory.details()
        let pressure = memory.refreshLevel()

        var snapshot = MonitorSnapshot(
            cpu: cpuSample?.total,
            gpu: gpuSample?.utilization,
            memoryPressure: pressure,
            cpuUser: cpuSample?.user,
            cpuSystem: cpuSample?.system,
            cpuIdle: cpuSample?.idle,
            perCoreCPU: cpuSample?.perCore ?? [],
            loadAverage: cpuSample?.loadAverage ?? [],
            gpuSource: gpuSample?.source,
            gpuDetail: gpuSample?.detail,
            gpuUnavailableReason: gpuSample == nil ? (gpu.unavailableReason ?? "GPU 数据不可用") : nil,
            gpuDiagnostics: gpu.lastHardwareFailure,
            memoryUsedBytes: details.usedBytes,
            memoryCachedBytes: details.cachedBytes,
            memoryFreeBytes: details.freeBytes,
            memoryCompressedBytes: details.compressedBytes,
            memoryWiredBytes: details.wiredBytes,
            swapUsedBytes: details.swapUsedBytes,
            physicalMemoryBytes: details.totalBytes
        )
        snapshot.timestamp = Date()
        deliver(snapshot)
    }

    private func deliver(_ snapshot: MonitorSnapshot) {
        DispatchQueue.main.async { [weak self] in
            self?.onSnapshot?(snapshot)
        }
    }

    private func onQueue(_ body: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            body()
        } else {
            queue.sync(execute: body)
        }
    }
}
