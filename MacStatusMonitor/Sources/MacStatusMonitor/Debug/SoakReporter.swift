import Foundation
import Darwin
import AppKit

/// 进程自身开销：用于验证"空闲时几乎不占 CPU"。
struct ProcessCost {
    var cpuSeconds: Double
    var residentBytes: UInt64

    static func read() -> ProcessCost {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000.0

        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return ProcessCost(
            cpuSeconds: cpu,
            residentBytes: result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
        )
    }
}

/// 常驻模式下的自检：定期打印自身 CPU% 与 RSS，秒数到后退出。
@MainActor
final class SoakReporter {
    private var timer: Timer?
    private var lastCost = ProcessCost.read()
    private var lastDate = Date()
    private let startedAt = Date()
    private let duration: TimeInterval

    init(duration: TimeInterval) {
        self.duration = duration
    }

    func start() {
        print(String(format: "自检开始：%.0f 秒，每 5 秒输出一次自身开销", duration))
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        let cost = ProcessCost.read()
        let wall = now.timeIntervalSince(lastDate)
        let ownCPU = wall > 0 ? (cost.cpuSeconds - lastCost.cpuSeconds) / wall * 100 : 0
        print(String(format: "[%5.0fs] 自身 CPU %.2f%%   RSS %.1f MB",
                     now.timeIntervalSince(startedAt), ownCPU, Double(cost.residentBytes) / 1e6))
        lastCost = cost
        lastDate = now

        if now.timeIntervalSince(startedAt) >= duration {
            timer?.invalidate()
            timer = nil
            print("自检结束")
            NSApp.terminate(nil)
        }
    }
}
