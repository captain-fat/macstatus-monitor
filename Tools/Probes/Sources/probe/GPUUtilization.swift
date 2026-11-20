import Foundation

/// 从 IOReport delta 中提取 GPU 利用率。
///
/// 依据（阶段一实测，Apple M5 / macOS 27）：
/// - `GPU Stats` → `UT Engagement centi-% Histogram` 是硬件侧对 GPU 利用率
///   （0…10000 百分之一百分比）的采样直方图，delta 后的命中数就是这一秒内
///   落在各区间的采样次数；用「按桶中点加权平均」即可得到区间平均利用率。
/// - `GPU Stats` → `GPU Performance States` 的 OFF/P1…P15 是**频率/功耗状态**
///   驻留，不是利用率：GPU 可以停在 P1 且 100% 忙。因此它只作为诊断信息，
///   绝不拿来当利用率。
enum GPUUtilization {

    struct Reading {
        var utilization: Double?          // 0...100
        var sampleCount: Int64            // 直方图采样数，用于判断数据是否有效
        var source: String
    }

    static func read(delta: CFDictionary, bridge: IOReportBridge) -> Reading {
        let channels = bridge.allChannels(in: delta)

        for channel in channels
        where channel.subgroup == "UT Engagement centi-% Histogram" && channel.format == .histogram {
            guard let mean = bridge.histogramMean(channel.dictionary) else { continue }
            let buckets = bridge.histogramBuckets(channel.dictionary)
            let hits = buckets.reduce(Int64(0)) { $0 + $1.hits }
            guard hits > 0 else { continue }
            let percent = min(max(mean / 100.0, 0), 100)
            return Reading(utilization: percent, sampleCount: hits, source: "UT histogram")
        }
        return Reading(utilization: nil, sampleCount: 0, source: "无可用频道")
    }

    /// 便捷入口：只要百分比
    static func percent(delta: CFDictionary, bridge: IOReportBridge) -> Double? {
        read(delta: delta, bridge: bridge).utilization
    }

    /// 真·时间型忙闲：`GPU Active Time` / `GPU Idle Time` 直方图。
    ///
    /// 两个频道由 AGX 用 24MHz 时间戳统计「每个活跃/空闲区间的时长」，
    /// 在 delta 窗口内对 (命中数 × 桶中点时长) 求和，就得到窗口内
    /// GPU 真正处于活跃 / 空闲的秒数。二者之和应约等于窗口长度，
    /// 因此 busy = active / (active + idle) 是硬件侧的忙闲占比。
    struct BusyReading {
        var fraction: Double          // 0...100
        var activeSeconds: Double
        var idleSeconds: Double
        var activePeriods: Int64
        var averageActiveMs: Double
        var totalSeconds: Double      // active + idle，应接近采样窗口
    }

    static func busyTime(delta: CFDictionary, bridge: IOReportBridge) -> BusyReading? {
        let channels = bridge.allChannels(in: delta)
        func totalSeconds(subgroup: String) -> (seconds: Double, hits: Int64)? {
            guard let channel = channels.first(where: { $0.subgroup == subgroup && $0.format == .histogram })
            else { return nil }
            let hz = tickRate(fromUnit: channel.unit)
            guard hz > 0 else { return nil }
            let buckets = bridge.histogramBuckets(channel.dictionary)
            var ticks = 0.0
            var hits: Int64 = 0
            for b in buckets where b.hits > 0 {
                ticks += Double(b.hits) * Double(b.min + b.max) / 2.0
                hits += b.hits
            }
            guard hits > 0 else { return nil }
            return (ticks / hz, hits)
        }

        guard let active = totalSeconds(subgroup: "Active Time Histogram"),
              let idle = totalSeconds(subgroup: "Idle Time Histogram"),
              active.seconds + idle.seconds > 0 else { return nil }

        let total = active.seconds + idle.seconds
        return BusyReading(
            fraction: min(max(active.seconds / total * 100, 0), 100),
            activeSeconds: active.seconds,
            idleSeconds: idle.seconds,
            activePeriods: active.hits,
            averageActiveMs: active.hits > 0 ? active.seconds / Double(active.hits) * 1000 : 0,
            totalSeconds: total
        )
    }

    /// 从 unit 标签（"24Mticks" / "1GHz" / "ticks"）解析计数频率
    static func tickRate(fromUnit unit: String) -> Double {
        let u = unit.trimmingCharacters(in: .whitespaces)
        if u.isEmpty { return 0 }
        let lowered = u.lowercased()
        var multiplier = 1.0
        if lowered.contains("ghz") { multiplier = 1e9 }
        else if lowered.contains("mhz") { multiplier = 1e6 }
        else if lowered.contains("khz") { multiplier = 1e3 }
        var digits = ""
        for ch in u {
            if ch.isNumber || ch == "." { digits.append(ch) } else { break }
        }
        guard let value = Double(digits), value > 0 else { return 0 }
        return value * multiplier
    }

    /// 诊断：GPU 频率状态驻留（OFF / P1…P15）
    static func perfStateResidency(delta: CFDictionary, bridge: IOReportBridge) -> [(String, Double)] {
        let channels = bridge.allChannels(in: delta)
        guard let channel = channels.first(where: { $0.subgroup == "GPU Performance States" }) else { return [] }
        let states = bridge.stateResidencies(channel.dictionary)
        let total = Double(states.reduce(Int64(0)) { $0 + max($1.residency, 0) })
        guard total > 0 else { return [] }
        return states.map { ($0.name, Double(max($0.residency, 0)) / total * 100.0) }
    }
}
