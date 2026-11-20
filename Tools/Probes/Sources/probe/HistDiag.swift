import Foundation

/// 诊断：打印 GPU Stats 下所有直方图的桶信息与「总时间」，寻找真正的时间型计数器。
func runHistDiag(seconds: Double) {
    let bridge = IOReportBridge.shared
    guard let sub = bridge.subscription(group: "GPU Stats") else { print("订阅失败"); return }
    var prev = sub.sample()
    let gpuA = IOAcceleratorGPUSampler(); _ = gpuA.open()
    let deadline = Date().addingTimeInterval(seconds)
    var tick = 0
    while Date() < deadline {
        tick += 1
        Thread.sleep(forTimeInterval: 1.0)
        guard let p = prev, let cur = sub.sample(), let d = sub.delta(previous: p, current: cur) else { continue }
        prev = cur
        print("── \(hms())  IOAcc=\(f1(gpuA.sample()?.deviceUtilization))  ──")
        for c in bridge.allChannels(in: d) where c.format == .histogram {
            let buckets = bridge.histogramBuckets(c.dictionary)
            let hits = buckets.reduce(Int64(0)) { $0 + $1.hits }
            guard hits > 0 else { continue }
            // 单位形如 "24Mticks" → 24e6 ticks/s；桶边界也是 ticks
            var hz = 0.0
            if let r = c.unit.range(of: #"([0-9]+)M"#, options: .regularExpression) {
                let num = c.unit[r].dropLast()
                hz = (Double(num) ?? 0) * 1_000_000
            }
            var weightedTicks = 0.0
            for b in buckets where b.hits > 0 {
                weightedTicks += Double(b.hits) * Double(b.min + b.max) / 2.0
            }
            let secondsTotal = hz > 0 ? weightedTicks / hz : 0
            let detail = buckets.filter { $0.hits > 0 }.prefix(4)
                .map { "\($0.min)-\($0.max):\($0.hits)" }.joined(separator: " ")
            print("  \(pad(c.subgroup, 30)) \(pad(c.name.isEmpty ? "-" : c.name, 22)) buckets=\(buckets.count) hits=\(hits) 时长=\(String(format: "%.4f", secondsTotal))s unit=\(c.unit)  \(detail)")
        }
    }
}
