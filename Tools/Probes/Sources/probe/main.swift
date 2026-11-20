import Foundation
import Darwin

// MARK: - 入口

setvbuf(stdout, nil, _IONBF, 0)   // 崩溃时也能看到已输出的行
let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "help"

switch command {
case "explore-gpu":
    runExploreGPU()
case "watch":
    let seconds = args.count > 2 ? (Double(args[2]) ?? 15) : 15
    runWatch(seconds: seconds)
case "load":
    runLoadTest(seconds: args.count > 2 ? (Double(args[2]) ?? 20) : 20,
                onMs: args.count > 3 ? (Double(args[3]) ?? 100) : 100,
                offMs: args.count > 4 ? (Double(args[4]) ?? 0) : 0)
case "mempressure":
    runMemoryPressureTest(seconds: args.count > 2 ? (Double(args[2]) ?? 12) : 12)
case "soak":
    runSoak(seconds: args.count > 2 ? (Double(args[2]) ?? 120) : 120)
case "bench":
    runBench()
case "hist":
    runHistDiag(seconds: args.count > 2 ? (Double(args[2]) ?? 5) : 5)
case "matrix":
    runMatrix(dwell: args.count > 2 ? (Double(args[2]) ?? 8) : 8)
case "ut":
    runUT(seconds: args.count > 2 ? (Double(args[2]) ?? 6) : 6)
case "dump":
    runDump()
case "cputest":
    runCPUTest(seconds: args.count > 2 ? (Double(args[2]) ?? 10) : 10)
default:
    print("""
    MacStatus Monitor · 阶段一探针

    用法: probe <命令> [参数]

      explore-gpu                 枚举 IOReport GPU 频道并打印两帧样本结构
      watch [秒数]                1Hz 时间序列：CPU / GPU-A / GPU-B / 内存压力
      load [秒数] [忙ms] [闲ms]   施加 Metal GPU 负载并同步采样，用于验证 GPU 数据真实性
      cputest [秒数]              施加 CPU 负载并验证 CPU 采样
      mempressure [秒数]          监听内存压力事件（可配合 memory_pressure -S 模拟）
    """)
}

// MARK: - explore-gpu

func runExploreGPU() {
    let bridge = IOReportBridge.shared
    print("IOReport 可用: \(bridge.isAvailable)  \(bridge.loadError ?? "")")
    guard bridge.isAvailable else { return }

    let iokitGPU = IOAcceleratorGPUSampler()
    let opened = iokitGPU.open()
    print("IOAccelerator 可用: \(opened)  service=\(iokitGPU.serviceName)")
    if let s = iokitGPU.sample() {
        print("PerformanceStatistics keys:")
        for key in s.raw.keys.sorted() {
            print("   \(pad(key, 34)) = \(s.raw[key] ?? "nil")")
        }
    }

    for group in ["GPU Stats", "Energy Model", "GPU UT Engagement"] {
        guard let sub = bridge.subscription(group: group) else {
            print("\n[\(group)] 订阅失败")
            continue
        }
        print("\n==================== GROUP: \(group) ====================")
        guard let first = sub.sample() else {
            print("采样失败")
            continue
        }
        if let nested = first as? [String: Any] {
            for (subgroupKey, subgroupValue) in nested.sorted(by: { $0.key < $1.key }) {
                guard let channels = subgroupValue as? [String: Any] else { continue }
                print("  subgroup: \(subgroupKey)  (\(channels.count) channels)")
                for key in channels.keys.sorted() {
                    print("      - \(key)")
                }
            }
        }

        Thread.sleep(forTimeInterval: 1.0)
        guard let second = sub.sample(), let delta = sub.delta(previous: first, current: second) else {
            continue
        }
        let samples = bridge.allChannels(in: delta)
        print("  ---- delta 频道 (\(samples.count)) ----")
        for c in samples.sorted(by: { ($0.group, $0.subgroup, $0.name) < ($1.group, $1.subgroup, $1.name) }) {
            var extra = ""
            switch c.format {
            case .simple:
                extra = "simple = \(bridge.simpleValue(c.dictionary))"
            case .state:
                let states = bridge.stateResidencies(c.dictionary)
                let total = states.reduce(Int64(0)) { $0 + max($1.residency, 0) }
                let detail = states.map { "\($0.name):\($0.residency)" }.joined(separator: " ")
                extra = "state total=\(total) [\(detail)]"
            case .histogram:
                extra = "histogram"
            default:
                extra = "format=\(c.format.rawValue)"
            }
            print("   \(pad(c.subgroup, 34)) \(pad(c.name.isEmpty ? "(unnamed)" : c.name, 38)) fmt=\(c.format.rawValue) unit=\(c.unit)  \(extra)")
        }
    }
}

// MARK: - watch

func runWatch(seconds: Double) {
    let cpu = CPUSampler()
    let mem = MemoryPressureSampler()
    let gpuA = IOAcceleratorGPUSampler()
    let bridge = IOReportBridge.shared
    _ = gpuA.open()

    var level = mem.snapshot().level
    mem.onLevelChange = { new in level = new }
    mem.start()

    // GPU-B：订阅 GPU Stats 全组
    let gpuSub = bridge.subscription(group: "GPU Stats")
    var prev = gpuSub?.sample()
    var gpuBStats = Stats()
    var gpuAStats = Stats()

    // 首次 CPU 采样建立基准
    _ = cpu.sample()
    Thread.sleep(forTimeInterval: 1.0)

    print(pad("时间", 13) + pad("CPU%", 6, right: true) + pad("GPU-A%", 8, right: true)
          + pad("GPU-B%", 8, right: true) + pad("压力", 10, right: true) + "  备注")
    print(String(repeating: "─", count: 62))

    let start = Date()
    var tick = 0
    while Date().timeIntervalSince(start) < seconds {
        tick += 1
        let sampleStart = Date()
        let cpuSample = cpu.sample()
        let gpuASample = gpuA.sample()?.deviceUtilization

        var gpuB: Double?
        if let sub = gpuSub, let cur = sub.sample() {
            if let p = prev, let delta = sub.delta(previous: p, current: cur) {
                gpuB = GPUUtilization.percent(delta: delta, bridge: bridge)
            }
            prev = cur
        }

        gpuAStats.add(gpuASample)
        gpuBStats.add(gpuB)

        var note = ""
        if let s = cpuSample {
            note = String(format: "cores=%d load=%.1f", s.coreCount, s.loadAverage[0])
        }
        print(pad(hms(), 13) + pad(f1(cpuSample?.total), 6, right: true)
              + pad(f1(gpuASample), 8, right: true) + pad(f1(gpuB), 8, right: true)
              + pad(level.map { $0.description } ?? "?", 10, right: true) + "  " + note)

        let elapsed = Date().timeIntervalSince(sampleStart)
        let sleepFor = max(0, 1.0 - elapsed)
        Thread.sleep(forTimeInterval: sleepFor)
    }

    mem.stop()
    print("\n汇总(\(tick) 帧):")
    print("  GPU-A(IOAccelerator) mean=\(f1(gpuAStats.mean)) min=\(f1(gpuAStats.min)) max=\(f1(gpuAStats.max))")
    print("  GPU-B(IOReport)      mean=\(f1(gpuBStats.mean)) min=\(f1(gpuBStats.min)) max=\(f1(gpuBStats.max))")
}

// MARK: - GPU 真值对照

func runLoadTest(seconds: Double, onMs: Double, offMs: Double) {
    guard let generator = GPULoadGenerator() else {
        print("Metal 不可用，无法施加 GPU 负载")
        return
    }
    print("GPU: \(generator.deviceName)   计划占空比: \(Int(onMs))ms 忙 / \(Int(offMs))ms 闲")

    let cpu = CPUSampler()
    let gpuA = IOAcceleratorGPUSampler()
    _ = gpuA.open()
    let bridge = IOReportBridge.shared
    let gpuSub = bridge.subscription(group: "GPU Stats")
    var prev = gpuSub?.sample()

    _ = cpu.sample()
    _ = gpuA.sample()

    // 预热 Metal
    let iters = generator.calibrate(targetMs: onMs)
    print(String(format: "校准: iterations=%u  (单次 dispatch 约 %.1f ms)", iters, generator.burst(iterations: iters) * 1000))

    var lastStates: [(String, Double)] = []

    func sampleOnce() -> (cpu: Double?, gpuA: Double?, gpuB: Double?, active: Double?) {
        let c = cpu.sample()?.total
        let a = gpuA.sample()?.deviceUtilization
        var b: Double?
        var active: Double?
        if let sub = gpuSub, let cur = sub.sample() {
            if let p = prev, let delta = sub.delta(previous: p, current: cur) {
                b = GPUUtilization.percent(delta: delta, bridge: bridge)
                let states = GPUUtilization.perfStateResidency(delta: delta, bridge: bridge)
                lastStates = states
                if !states.isEmpty {
                    active = 100 - (states.first(where: { $0.0 == "OFF" })?.1 ?? 0)
                }
            }
            prev = cur
        }
        return (c, a, b, active)
    }

    // 阶段 1：空闲基线
    print("\n[基线] 无负载 5 秒")
    print(header())
    var idleA = Stats(), idleB = Stats(), idleActive = Stats()
    for _ in 0..<5 {
        let s = sampleOnce()
        idleA.add(s.gpuA); idleB.add(s.gpuB); idleActive.add(s.active)
        print(row(s))
        Thread.sleep(forTimeInterval: 1.0)
    }

    // 阶段 2：负载
    print("\n[负载] \(Int(seconds)) 秒")
    print(header())
    var loadA = Stats(), loadB = Stats(), loadActive = Stats()
    let group = DispatchGroup()
    let burstLock = NSLock()
    var burstTimes: [Double] = []
    group.enter()
    let stopAt = Date().addingTimeInterval(seconds)
    DispatchQueue.global(qos: .userInitiated).async {
        defer { group.leave() }
        while Date() < stopAt {
            let t = generator.burst(iterations: iters)
            burstLock.lock(); burstTimes.append(t); burstLock.unlock()
            if offMs > 0 { Thread.sleep(forTimeInterval: offMs / 1000.0) }
        }
    }

    while Date() < stopAt {
        let s = sampleOnce()
        loadA.add(s.gpuA); loadB.add(s.gpuB); loadActive.add(s.active)
        print(row(s))
        Thread.sleep(forTimeInterval: 1.0)
    }
    group.wait()

    burstLock.lock(); let bursts = burstTimes; burstLock.unlock()
    let meanOn = bursts.isEmpty ? 0 : bursts.reduce(0, +) / Double(bursts.count)
    let duty = meanOn / (meanOn + offMs / 1000.0) * 100

    print("\n汇总:")
    print(String(format: "  实际占空比: %.1f%%  (单次 dispatch %.1f ms, %d 次)", duty, meanOn * 1000, bursts.count))
    print("  GPU-A 空闲 mean=\(f1(idleA.mean))  负载 mean=\(f1(loadA.mean))  p95=\(f1(loadA.p95))  max=\(f1(loadA.max))")
    print("  GPU-B 空闲 mean=\(f1(idleB.mean))  负载 mean=\(f1(loadB.mean))  p95=\(f1(loadB.p95))  max=\(f1(loadB.max))")
    print("  状态驻留(非OFF) 空闲 mean=\(f1(idleActive.mean))  负载 mean=\(f1(loadActive.mean))")
    let top = lastStates.sorted { $0.1 > $1.1 }.prefix(5).map { "\($0.0)=\(String(format: "%.0f", $0.1))%" }.joined(separator: " ")
    print("  末帧状态分布: \(top)")
}

func header() -> String {
    pad("时间", 13) + pad("CPU%", 6, right: true) + pad("IOAcc%", 8, right: true)
        + pad("非OFF%", 8, right: true) + pad("UT%", 7, right: true)
}

func row(_ s: (cpu: Double?, gpuA: Double?, gpuB: Double?, active: Double?)) -> String {
    pad(hms(), 13) + pad(f1(s.cpu), 6, right: true) + pad(f1(s.gpuA), 8, right: true)
        + pad(f1(s.active), 8, right: true) + pad(f2(s.gpuB), 7, right: true)
}

// MARK: - CPU 对照

func runCPUTest(seconds: Double) {
    let sampler = CPUSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1.0)

    let cores = ProcessInfo.processInfo.activeProcessorCount
    print("逻辑核心: \(cores)，先空闲 3 秒，再用 \(cores) 线程满载 5 秒")
    print(pad("时间", 13) + pad("总CPU%", 8, right: true) + "  每核%")

    let deadline = Date().addingTimeInterval(seconds)
    let loadStart = Date().addingTimeInterval(3)
    let loadEnd = loadStart.addingTimeInterval(5)

    DispatchQueue.global(qos: .userInitiated).async {
        DispatchQueue.concurrentPerform(iterations: cores) { _ in
            var x = 1.0
            while Date() < loadEnd {
                if Date() >= loadStart {
                    for _ in 0..<20_000 { x = x * 1.000001 + 0.000001 }
                    if x > 1e9 { x = 1.0 }
                } else {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
    }

    var announced = false
    while Date() < deadline {
        if !announced && Date() >= loadStart {
            announced = true
            print("  ── 开始 CPU 负载 ──")
        }
        if let s = sampler.sample() {
            let perCore = s.perCore.map { String(format: "%4.0f", $0) }.joined(separator: " ")
            print(pad(hms(), 13) + pad(f1(s.total), 8, right: true) + "  " + perCore
                  + String(format: "   u=%.0f s=%.0f i=%.0f", s.user, s.system, s.idle))
        }
        Thread.sleep(forTimeInterval: 1.0)
    }
}

// MARK: - 内存压力

func runMemoryPressureTest(seconds: Double) {
    let sampler = MemoryPressureSampler()
    let initial = sampler.snapshot()
    print("启动时: raw=\(initial.rawLevel) level=\(initial.level?.description ?? "unknown")")
    print(String(format: "总内存 %.1f GB, free %.2f GB, compressor %.2f GB, wired %.2f GB, swap used %.2f GB",
                 Double(initial.totalBytes) / 1e9,
                 Double(initial.freeBytes) / 1e9,
                 Double(initial.compressorBytes) / 1e9,
                 Double(initial.wiredBytes) / 1e9,
                 Double(initial.swapUsedBytes) / 1e9))

    sampler.onLevelChange = { level in
        print("[\(hms())] DispatchSource 事件 -> \(level.description) (semantic=\(level.semanticKey))")
    }
    sampler.onRawLevel = { raw in
        print("[\(hms())] sysctl raw = \(raw)")
    }
    sampler.start()
    print("开始监听 \(Int(seconds)) 秒（可用 memory_pressure -S -l warn -s 5 触发）...")

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        let s = sampler.snapshot()
        print("[\(hms())] sysctl=\(s.rawLevel) source=\(sampler.level.description) free=\(String(format: "%.2f", Double(s.freeBytes)/1e9))GB")
        Thread.sleep(forTimeInterval: 2.0)
    }
    sampler.stop()
    print("已停止")
}

// MARK: - 原始结构 dump

func runDump() {
    let bridge = IOReportBridge.shared
    guard bridge.isAvailable else { print("IOReport 不可用"); return }
    guard let sub = bridge.subscription(group: "GPU Stats", subgroup: "GPU Performance States") else {
        print("订阅失败")
        return
    }
    guard let s = sub.sample() else { print("采样失败"); return }
    print("=== sample 结构 ===")
    CFShow(s)
    print("count=\(CFDictionaryGetCount(s))")
    Thread.sleep(forTimeInterval: 1.0)
    guard let s2 = sub.sample(), let d = sub.delta(previous: s, current: s2) else { return }
    print("\n=== delta 结构 ===")
    CFShow(d)
}

// MARK: - UT Engagement 直方图观察

func runUT(seconds: Double) {
    let bridge = IOReportBridge.shared
    let gpuA = IOAcceleratorGPUSampler()
    _ = gpuA.open()
    guard let sub = bridge.subscription(group: "GPU Stats") else { print("订阅失败"); return }
    guard var prev = sub.sample() else { return }
    let deadline = Date().addingTimeInterval(seconds)
    print(pad("时间", 13) + pad("IOAcc%", 8, right: true) + pad("UT均值%", 9, right: true) + pad("命中数", 10, right: true) + "  非零桶")
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 1.0)
        guard let cur = sub.sample(), let delta = sub.delta(previous: prev, current: cur) else { continue }
        prev = cur
        let channels = bridge.allChannels(in: delta)
        var mean = Double.nan, hits: Int64 = 0, desc = ""
        for c in channels where c.subgroup == "UT Engagement centi-% Histogram" {
            let buckets = bridge.histogramBuckets(c.dictionary)
            let total = buckets.reduce(Int64(0)) { $0 + $1.hits }
            hits = total
            if let m = bridge.histogramMean(c.dictionary) { mean = m / 100.0 }
            desc = buckets.filter { $0.hits > 0 }.map { "\($0.min)-\($0.max):\($0.hits)" }.joined(separator: " ")
        }
        print(pad(hms(), 13) + pad(f1(gpuA.sample()?.deviceUtilization), 8, right: true)
              + pad(f2(mean), 9, right: true) + pad("\(hits)", 10, right: true) + "  " + desc)
    }
}
