import Foundation

/// 性能基准：确认 1Hz 采样自身的开销足够低，并比较「整组订阅」与「按子组过滤订阅」。
func runBench() {
    let bridge = IOReportBridge.shared
    let gpuA = IOAcceleratorGPUSampler()
    _ = gpuA.open()

    func measure(_ label: String, iterations: Int = 30, _ body: () -> Void) {
        for _ in 0..<3 { body() }   // 预热
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations { body() }
        let ms = (CFAbsoluteTimeGetCurrent() - start) / Double(iterations) * 1000
        print(pad(label, 42) + String(format: "%7.3f ms/次", ms))
    }

    let full = bridge.subscription(group: "GPU Stats")
    var fullPrev = full?.sample()
    measure("IOReport 全组 sample+delta") {
        if let s = full, let p = fullPrev, let cur = s.sample() {
            _ = s.delta(previous: p, current: cur)
            fullPrev = cur
        }
    }

    var fullPrev2 = full?.sample()
    measure("IOReport 全组 + 解析 133 频道") {
        if let s = full, let p = fullPrev2, let cur = s.sample(), let d = s.delta(previous: p, current: cur) {
            _ = bridge.allChannels(in: d).count
            fullPrev2 = cur
        }
    }

    var busyPrev = full?.sample()
    measure("IOReport 全组 + 忙闲解析") {
        if let s = full, let p = busyPrev, let cur = s.sample(), let d = s.delta(previous: p, current: cur) {
            _ = GPUUtilization.busyTime(delta: d, bridge: bridge)
            busyPrev = cur
        }
    }

    let filtered = bridge.subscription(group: "GPU Stats", subgroup: "Active Time Histogram")
    var fPrev = filtered?.sample()
    measure("过滤订阅(Active Time) sample+delta+解析") {
        if let s = filtered, let p = fPrev, let cur = s.sample(), let d = s.delta(previous: p, current: cur) {
            _ = GPUUtilization.busyTime(delta: d, bridge: bridge)
            fPrev = cur
        }
    }
    if let s = filtered, let p = fPrev, let cur = s.sample(), let d = s.delta(previous: p, current: cur) {
        let chans = bridge.allChannels(in: d)
        print("过滤订阅频道数: \(chans.count) -> " + chans.map { "\($0.subgroup)/\($0.name)" }.joined(separator: ", "))
    }

    let activeSub = bridge.subscription(group: "GPU Stats", subgroup: "Active Time Histogram")
    let idleSub = bridge.subscription(group: "GPU Stats", subgroup: "Idle Time Histogram")
    var aPrev = activeSub?.sample(), iPrev = idleSub?.sample()
    measure("双过滤订阅(Active+Idle) sample+delta") {
        if let a = activeSub, let ia = idleSub,
           let ap = aPrev, let ip = iPrev,
           let ac = a.sample(), let ic = ia.sample() {
            _ = a.delta(previous: ap, current: ac)
            _ = ia.delta(previous: ip, current: ic)
            aPrev = ac; iPrev = ic
        }
    }
    if let a = activeSub, let ap = aPrev, let ac = a.sample(), let d = a.delta(previous: ap, current: ac) {
        print("Active 子组频道: " + bridge.allChannels(in: d).map { "\($0.subgroup)/\($0.name)" }.joined(separator: ", "))
    }

    measure("IOAccelerator 读 PerformanceStatistics") {
        _ = gpuA.sample()?.deviceUtilization
    }

    let cpu = CPUSampler()
    _ = cpu.sample()
    measure("CPU host_processor_info + 差值", iterations: 50) {
        _ = cpu.sample()
    }

    let mem = MemoryPressureSampler()
    measure("内存压力 sysctl + vm_statistics64", iterations: 50) {
        _ = mem.snapshot()
    }

    let after = readSelfCost()
    print(String(format: "自身累计 CPU 时间 %.3fs, RSS %.1f MB", after.cpuSeconds, Double(after.maxRSSBytes) / 1e6))
}
