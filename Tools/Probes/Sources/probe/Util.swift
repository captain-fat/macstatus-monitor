import Foundation

// MARK: - 输出辅助

func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
    let count = s.count
    guard count < width else { return s }
    let spaces = String(repeating: " ", count: width - count)
    return right ? spaces + s : s + spaces
}

func f1(_ v: Double?) -> String {
    guard let v, v.isFinite else { return "N/A" }
    return String(format: "%5.1f", v)
}

func f2(_ v: Double?) -> String {
    guard let v, v.isFinite else { return "N/A" }
    return String(format: "%6.2f", v)
}

func hms() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

/// 简单统计
struct Stats {
    private(set) var values: [Double] = []

    mutating func add(_ v: Double?) {
        guard let v, v.isFinite else { return }
        values.append(v)
    }

    var count: Int { values.count }
    var min: Double? { values.min() }
    var max: Double? { values.max() }
    var mean: Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
    var p50: Double? { percentile(50) }
    var p95: Double? { percentile(95) }

    func percentile(_ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = p / 100.0 * Double(sorted.count - 1)
        let lo = Int(floor(rank)), hi = Int(ceil(rank))
        if lo == hi { return sorted[lo] }
        let w = rank - Double(lo)
        return sorted[lo] * (1 - w) + sorted[hi] * w
    }
}

// MARK: - 进程自身开销

struct SelfCost {
    var cpuSeconds: Double
    var maxRSSBytes: UInt64
}

func readSelfCost() -> SelfCost {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000.0
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
        }
    }
    let rss = kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    return SelfCost(cpuSeconds: cpu, maxRSSBytes: rss)
}
