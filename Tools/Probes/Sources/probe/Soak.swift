import Foundation

/// 长跑测试：1Hz 采样三项指标，周期性输出自身 CPU / 内存占用，用于评估"轻量"目标。
func runSoak(seconds: Double) {
    let cpu = CPUSampler()
    let mem = MemoryPressureSampler()
    let gpuA = IOAcceleratorGPUSampler()
    _ = gpuA.open()
    let bridge = IOReportBridge.shared
    let gpuSub = bridge.subscription(group: "GPU Stats")
    var prev = gpuSub?.sample()

    mem.start()
    var cpuVal: Double?, gpuVal: Double?, busyVal: Double?, level = mem.level
    mem.onLevelChange = { level = $0 }

    _ = cpu.sample()
    var last = readSelfCost()
    var lastWall = Date()
    var frames = 0
    let start = Date()

    print(pad("时间", 13) + pad("CPU%", 6, right: true) + pad("GPU忙%", 8, right: true)
          + pad("IOAcc%", 8, right: true) + pad("压力", 9, right: true)
          + pad("自身CPU%", 10, right: true) + pad("RSS_MB", 9, right: true) + pad("采样ms", 8, right: true))

    while Date().timeIntervalSince(start) < seconds {
        let tickStart = Date()
        cpuVal = cpu.sample()?.total
        if let s = gpuSub, let p = prev, let cur = s.sample(), let d = s.delta(previous: p, current: cur) {
            busyVal = GPUUtilization.busyTime(delta: d, bridge: bridge)?.fraction
            prev = cur
        }
        gpuVal = gpuA.sample()?.deviceUtilization
        frames += 1
        let sampleMs = Date().timeIntervalSince(tickStart) * 1000

        let now = Date()
        if now.timeIntervalSince(lastWall) >= 10 {
            let cost = readSelfCost()
            let wall = now.timeIntervalSince(lastWall)
            let ownCPU = (cost.cpuSeconds - last.cpuSeconds) / wall * 100
            print(pad(hms(), 13) + pad(f1(cpuVal), 6, right: true) + pad(f1(busyVal), 8, right: true)
                  + pad(f1(gpuVal), 8, right: true) + pad(level.description, 9, right: true)
                  + pad(String(format: "%.2f", ownCPU), 10, right: true)
                  + pad(String(format: "%.1f", Double(cost.maxRSSBytes) / 1e6), 9, right: true)
                  + pad(String(format: "%.2f", sampleMs), 8, right: true))
            last = cost
            lastWall = now
        }
        Thread.sleep(forTimeInterval: max(0, 1.0 - Date().timeIntervalSince(tickStart)))
    }

    let cost = readSelfCost()
    let wall = Date().timeIntervalSince(start)
    print(String(format: "\n%d 帧 / %.0fs；自身平均 CPU %.2f%%，峰值 RSS %.1f MB，累计 CPU %.3fs",
                 frames, wall, cost.cpuSeconds / wall * 100, Double(cost.maxRSSBytes) / 1e6, cost.cpuSeconds))
}
