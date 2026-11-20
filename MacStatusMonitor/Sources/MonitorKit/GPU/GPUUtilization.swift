import Foundation

/// GPU 利用率的口径计算（与采集无关，纯解码）。
public enum GPUUtilization {

    /// 硬件忙闲时间读数。
    public struct BusyReading: Sendable {
        public var fraction: Double        // 0...100
        public var activeSeconds: Double
        public var idleSeconds: Double
        public var activePeriods: Int64
        public var averageActiveMs: Double
        public var totalSeconds: Double    // active + idle，应接近采样窗口
    }

    /// 从 delta 里取某个子组的直方图总时长。
    public static func seconds(
        delta: IOReportBridge.Report,
        subgroup: String,
        bridge: IOReportBridge
    ) -> (seconds: Double, hits: Int64)? {
        let channels = bridge.allChannels(in: delta)
        guard let channel = channels.first(where: { $0.subgroup == subgroup && $0.format == .histogram })
        else { return nil }

        let tickRate = tickRate(fromUnit: channel.unit)
        guard tickRate > 0 else { return nil }

        var ticks = 0.0
        var hits: Int64 = 0
        for bucket in bridge.histogramBuckets(channel.dictionary) where bucket.hits > 0 {
            // 桶是 [min, max] 区间，用中点代表该桶时长
            ticks += Double(bucket.hits) * Double(bucket.min + bucket.max) / 2.0
            hits += bucket.hits
        }
        // hits 允许为 0：GPU 满载时一个窗口内可能没有任何 idle 区间，
        // 这不是"数据无效"，而是 idle = 0 秒。区分"频道缺失"和"区间为空"。
        return (ticks / tickRate, hits)
    }

    /// 由 Active / Idle 两个 delta 计算忙占比。
    /// 两个 delta 可以来自同一次整组订阅，也可以来自两个独立订阅。
    public static func busyTime(
        activeDelta: IOReportBridge.Report,
        idleDelta: IOReportBridge.Report,
        bridge: IOReportBridge
    ) -> BusyReading? {
        guard let active = seconds(delta: activeDelta, subgroup: "Active Time Histogram", bridge: bridge),
              let idle = seconds(delta: idleDelta, subgroup: "Idle Time Histogram", bridge: bridge)
        else { return nil }

        let total = active.seconds + idle.seconds
        guard total > 0 else { return nil }

        return BusyReading(
            fraction: min(max(active.seconds / total * 100, 0), 100),
            activeSeconds: active.seconds,
            idleSeconds: idle.seconds,
            activePeriods: active.hits,
            averageActiveMs: active.hits > 0 ? active.seconds / Double(active.hits) * 1000 : 0,
            totalSeconds: total
        )
    }

    /// "24Mticks" / "1GHz" / "ticks" → 计数频率
    public static func tickRate(fromUnit unit: String) -> Double {
        let text = unit.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return 0 }
        // 注意：GPU 直方图的单位是 "24Mticks"（M=10^6 ticks），不是 "MHz"。
        // 阶段一探针用正则匹配 "24M"，这里必须同时接受 Mticks / Kticks / Gticks。
        let lowered = text.lowercased()
        var multiplier = 1.0
        if lowered.contains("ghz") || lowered.contains("gticks") { multiplier = 1e9 }
        else if lowered.contains("mhz") || lowered.contains("mticks") { multiplier = 1e6 }
        else if lowered.contains("khz") || lowered.contains("kticks") { multiplier = 1e3 }

        var digits = ""
        for character in text {
            if character.isNumber || character == "." { digits.append(character) } else { break }
        }
        guard let value = Double(digits), value > 0 else { return 0 }
        return value * multiplier
    }

    /// 基于 GPU 频率状态驻留的"活跃占比"。
    ///
    /// 为什么不用 Active/Idle 直方图：直方图只统计**已经结束**的活跃/空闲区间，
    /// 1 秒窗口下如果 GPU 持续满载（区间一直不结束），窗口内累计时长会塌缩到几十毫秒，
    /// 这一帧就无法判读（阶段三实测）。状态驻留是**连续累加**的计数器，不存在这个问题。
    public struct ActiveResidency: Sendable {
        public var fraction: Double     // 0...100，非 OFF 时间占比
        public var totalSeconds: Double // 所有状态驻留之和，应接近采样窗口
        public var offPercent: Double
    }

    public static func activeResidency(
        delta: IOReportBridge.Report,
        bridge: IOReportBridge
    ) -> ActiveResidency? {
        let channels = bridge.allChannels(in: delta)
        guard let channel = channels.first(where: { $0.subgroup == "GPU Performance States" })
        else { return nil }

        let tickRate = tickRate(fromUnit: channel.unit)
        guard tickRate > 0 else { return nil }

        let states = bridge.stateResidencies(channel.dictionary)
        guard !states.isEmpty else { return nil }

        var total: Int64 = 0
        var off: Int64 = 0
        for state in states {
            let residency = max(state.residency, 0)
            total += residency
            if state.name.uppercased() == "OFF" { off += residency }
        }
        guard total > 0 else { return nil }

        let totalSeconds = Double(total) / tickRate
        let offPercent = Double(off) / Double(total) * 100
        return ActiveResidency(
            fraction: min(max(100 - offPercent, 0), 100),
            totalSeconds: totalSeconds,
            offPercent: offPercent
        )
    }

    /// 诊断：GPU 频率状态驻留（OFF / P1…P15），只用于详情展示，不作为利用率
    public static func perfStateResidency(
        delta: IOReportBridge.Report,
        bridge: IOReportBridge
    ) -> [(name: String, percent: Double)] {
        let channels = bridge.allChannels(in: delta)
        guard let channel = channels.first(where: { $0.subgroup == "GPU Performance States" }) else { return [] }
        let states = bridge.stateResidencies(channel.dictionary)
        let total = Double(states.reduce(Int64(0)) { $0 + max($1.residency, 0) })
        guard total > 0 else { return [] }
        return states.map { ($0.name, Double(max($0.residency, 0)) / total * 100) }
    }
}
