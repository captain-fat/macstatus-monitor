import Foundation

/// 阶段一核心验证：把已知的 GPU 占空比作为「真值」，看各个候选指标是否随真值单调/线性变化。
///
/// 手法：Metal compute 以固定节奏（忙 onMs / 闲 offMs）跑 N 秒，形成可控占空比；
/// 同时采样硬件计数器。比较：
///   - IOAccelerator「Device Utilization %」（驱动自己报的百分比）
///   - GPU Active/Idle Time 直方图 → 硬件时间戳忙闲占比
///   - GPU Performance States 的「非 OFF 驻留」
///   - GPU Energy 每秒增量（独立交叉验证：负载真的作用在 GPU 上）
struct MatrixRow {
    var targetDuty: Double
    var measuredDuty: Double
    var ioAcc: Double?
    var busy: Double?
    var nonOff: Double?
    var energyPerSec: Double?
    var costMs: Double
    var topState: String
}

func runMatrix(dwell: Double = 8, measureIdle: Double = 0) {
    guard let generator = GPULoadGenerator() else { print("Metal 不可用"); return }
    print("GPU: \(generator.deviceName)")
    let iters = generator.calibrate(targetMs: 100)
    _ = generator.burst(iterations: iters)
    Thread.sleep(forTimeInterval: 1.5)

    let gpuA = IOAcceleratorGPUSampler()
    _ = gpuA.open()
    let bridge = IOReportBridge.shared
    let gpuSub = bridge.subscription(group: "GPU Stats")
    let energySub = bridge.subscription(group: "Energy Model")

    var gpuPrev = gpuSub?.sample()
    var energyPrev = energySub?.sample()

    print(pad("目标", 6, right: true) + pad("实测", 7, right: true) + pad("IOAcc%", 8, right: true)
          + pad("忙占比%", 9, right: true) + pad("非OFF%", 8, right: true)
          + pad("GPU能量/s", 12, right: true) + pad("采样ms", 8, right: true) + "   主状态")

    var rows: [MatrixRow] = []
    var schedule: [(Double, Double)] = [0.0, 20.0, 40.0, 60.0, 80.0, 100.0].map { ($0, dwell) }
    if measureIdle > 0 { schedule.insert((0.0, measureIdle), at: 0) }

    for (duty, period) in schedule {
        let onMs = 100.0
        let offMs = duty >= 99.9 ? 0 : onMs * (100 - duty) / duty
        let stopAt = Date().addingTimeInterval(period)

        var ioAcc = Stats(), busy = Stats(), nonOff = Stats(), energy = Stats(), cost = Stats()
        var bursts: [Double] = []
        let lock = NSLock()
        let group = DispatchGroup()
        group.enter()
        if duty > 0 {
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                while Date() < stopAt {
                    let t = generator.burst(iterations: iters)
                    lock.lock(); bursts.append(t); lock.unlock()
                    if offMs > 0 { Thread.sleep(forTimeInterval: offMs / 1000.0) }
                }
            }
        } else {
            group.leave()
        }

        var lastStates: [(String, Double)] = []
        while Date() < stopAt {
            let tickStart = Date()
            Thread.sleep(forTimeInterval: 0.05)
            ioAcc.add(gpuA.sample()?.deviceUtilization)

            if let sub = gpuSub, let cur = sub.sample() {
                if let p = gpuPrev, let d = sub.delta(previous: p, current: cur) {
                    if let b = GPUUtilization.busyTime(delta: d, bridge: bridge) {
                        busy.add(b.fraction)
                    }
                    let states = GPUUtilization.perfStateResidency(delta: d, bridge: bridge)
                    lastStates = states
                    if !states.isEmpty {
                        nonOff.add(100 - (states.first(where: { $0.0 == "OFF" })?.1 ?? 0))
                    }
                }
                gpuPrev = cur
            }
            if let sub = energySub, let cur = sub.sample() {
                if let p = energyPrev, let d = sub.delta(previous: p, current: cur) {
                    for c in bridge.allChannels(in: d) where c.name == "GPU Energy" && c.format == .simple {
                        energy.add(Double(bridge.simpleValue(c.dictionary)))
                    }
                }
                energyPrev = cur
            }
            cost.add(Date().timeIntervalSince(tickStart) * 1000)
            let elapsed = Date().timeIntervalSince(tickStart)
            Thread.sleep(forTimeInterval: max(0, 0.25 - elapsed))
        }
        group.wait()

        lock.lock(); let b = bursts; lock.unlock()
        let meanOn = b.isEmpty ? 0 : b.reduce(0, +) / Double(b.count)
        let measured = b.isEmpty ? 0 : meanOn / (meanOn + offMs / 1000.0) * 100
        let top = lastStates.sorted { $0.1 > $1.1 }.prefix(2)
            .map { "\($0.0)=\(String(format: "%.0f", $0.1))%" }.joined(separator: " ")
        let row = MatrixRow(targetDuty: duty, measuredDuty: measured, ioAcc: ioAcc.mean,
                            busy: busy.mean, nonOff: nonOff.mean, energyPerSec: energy.mean,
                            costMs: cost.mean ?? 0, topState: top)
        rows.append(row)
        print(pad(String(format: "%.0f%%", duty), 6, right: true)
              + pad(String(format: "%.1f%%", measured), 7, right: true)
              + pad(f1(row.ioAcc), 8, right: true) + pad(f1(row.busy), 9, right: true)
              + pad(f1(row.nonOff), 8, right: true)
              + pad(row.energyPerSec.map { String(format: "%.0f", $0) } ?? "N/A", 12, right: true)
              + pad(String(format: "%.2f", row.costMs), 8, right: true)
              + "   " + top)
    }

    print("\n说明：忙占比% = Active Time / (Active Time + Idle Time)，硬件 24MHz 时间戳累加。")
}
