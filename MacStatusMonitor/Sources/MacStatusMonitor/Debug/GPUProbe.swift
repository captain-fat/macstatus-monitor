import Foundation
import MonitorKit

/// GPU 采集链路的分步诊断：对比「整组订阅」与「过滤订阅」两种 delta 的结果。
enum GPUProbe {

    static func run(seconds: Int) {
        let bridge = IOReportBridge.shared
        print("IOReport 可用: \(bridge.isAvailable) \(bridge.loadError ?? "")")
        print("硬件采样器 isAvailable: \(IOReportGPUSampler().isAvailable)")

        let full = bridge.subscription(group: "GPU Stats")
        let activeFiltered = bridge.subscription(group: "GPU Stats", subgroup: "Active Time Histogram")
        let idleFiltered = bridge.subscription(group: "GPU Stats", subgroup: "Idle Time Histogram")

        var fullPrev = full?.sample()
        var activePrev = activeFiltered?.sample()
        var idlePrev = idleFiltered?.sample()

        for tick in 1...seconds {
            Thread.sleep(forTimeInterval: 1.0)
            print("── t=\(tick) ──")

            if let full, let p = fullPrev, let cur = full.sample(), let delta = full.delta(previous: p, current: cur) {
                for channel in bridge.allChannels(in: delta) where channel.subgroup.contains("Time Histogram") {
                    let buckets = bridge.histogramBuckets(channel.dictionary)
                    let nonEmpty = buckets.filter { $0.hits > 0 }.prefix(3)
                    print("   桶: \(channel.subgroup) unit=\(channel.unit) rate=\(GPUUtilization.tickRate(fromUnit: channel.unit))")
                    for b in nonEmpty { print("      [\(b.min), \(b.max)] hits=\(b.hits)") }
                }
                if let reading = GPUUtilization.busyTime(activeDelta: delta, idleDelta: delta, bridge: bridge) {
                    print(String(format: "整组订阅: busy=%.1f%% active=%.3fs idle=%.3fs hits=%d",
                                 reading.fraction, reading.activeSeconds, reading.idleSeconds, reading.activePeriods))
                } else {
                    print("整组订阅: busyTime = nil")
                }
                fullPrev = cur
            }

            if let activeFiltered, let idleFiltered,
               let ap = activePrev, let ip = idlePrev,
               let aCur = activeFiltered.sample(), let iCur = idleFiltered.sample(),
               let aDelta = activeFiltered.delta(previous: ap, current: aCur),
               let iDelta = idleFiltered.delta(previous: ip, current: iCur) {
                if let a = GPUUtilization.seconds(delta: aDelta, subgroup: "Active Time Histogram", bridge: bridge),
                   let i = GPUUtilization.seconds(delta: iDelta, subgroup: "Idle Time Histogram", bridge: bridge) {
                    print(String(format: "过滤订阅: active=%.3fs idle=%.3fs total=%.3fs",
                                 a.seconds, i.seconds, a.seconds + i.seconds))
                }
                activePrev = aCur
                idlePrev = iCur
            }

            print("采样器输出: \(GPUUtilizationGPUSamplerOutput())")
        }
    }

    private static func GPUUtilizationGPUSamplerOutput() -> String {
        let sampler = IOReportGPUSampler()
        _ = sampler.sample(interval: 1.0)
        Thread.sleep(forTimeInterval: 0.9)
        guard let sample = sampler.sample(interval: 1.0) else { return "nil" }
        return String(format: "%.1f%% (%@)", sample.utilization, sample.source)
    }
}
