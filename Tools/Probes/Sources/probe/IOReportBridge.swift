import Foundation
import Darwin

/// IOReport 是 Apple 的私有性能计数器框架（IOKit 的一部分）。
///
/// 从 macOS 26/27 起磁盘上不再有 IOReport.framework 目录，框架只存在于
/// dyld 共享缓存，`/usr/lib/libIOReport.dylib` 仍可 dlopen 到；老系统
/// （14/15）则有 `/System/Library/PrivateFrameworks/IOReport.framework/IOReport`。
///
/// 全部通过 dlsym 动态绑定：不在 LC_LOAD_DYLIB 中留下私有依赖，
/// 符号缺失时可以降级为 N/A 而不是启动崩溃。
final class IOReportBridge {

    static let shared = IOReportBridge()

    private(set) var isAvailable = false
    private(set) var loadError: String?

    typealias Report = CFDictionary

    private typealias CopyChannelsInGroupFn = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<Report>?
    private typealias CreateSubscriptionFn = @convention(c) (UnsafeMutableRawPointer?, Report, UnsafeMutablePointer<Unmanaged<Report>?>?, UInt64, CFTypeRef?) -> Unmanaged<Report>?
    private typealias CreateSamplesFn = @convention(c) (Report, Report, CFTypeRef?) -> Unmanaged<Report>?
    private typealias CreateSamplesDeltaFn = @convention(c) (Report, Report, CFTypeRef?) -> Unmanaged<Report>?
    private typealias ChannelGetStringFn = @convention(c) (Report) -> Unmanaged<CFString>?
    private typealias ChannelGetFormatFn = @convention(c) (Report) -> Int32
    private typealias SimpleGetIntegerFn = @convention(c) (Report, Int32) -> Int64
    private typealias StateGetCountFn = @convention(c) (Report) -> Int32
    private typealias StateGetNameFn = @convention(c) (Report, Int32) -> Unmanaged<CFString>?
    private typealias StateGetResidencyFn = @convention(c) (Report, Int32) -> Int64
    private typealias GetChannelCountFn = @convention(c) (Report) -> Int32
    private typealias HistogramBucketCountFn = @convention(c) (Report) -> Int32
    private typealias HistogramBucketHitsFn = @convention(c) (Report, Int32) -> Int64
    private typealias HistogramBucketBoundsFn = @convention(c) (Report, Int32) -> Int64

    private var copyChannelsInGroup: CopyChannelsInGroupFn!
    private var createSubscription: CreateSubscriptionFn!
    private var createSamples: CreateSamplesFn!
    private var createSamplesDelta: CreateSamplesDeltaFn!
    private var channelGetGroup: ChannelGetStringFn!
    private var channelGetSubGroup: ChannelGetStringFn!
    private var channelGetName: ChannelGetStringFn!
    private var channelGetFormat: ChannelGetFormatFn!
    private var channelGetUnitLabel: ChannelGetStringFn!
    private var simpleGetInteger: SimpleGetIntegerFn!
    private var stateGetCount: StateGetCountFn!
    private var stateGetName: StateGetNameFn!
    private var stateGetResidency: StateGetResidencyFn!
    private var getChannelCount: GetChannelCountFn?
    private var histogramBucketCount: HistogramBucketCountFn?
    private var histogramBucketHits: HistogramBucketHitsFn?
    private var histogramBucketMin: HistogramBucketBoundsFn?
    private var histogramBucketMax: HistogramBucketBoundsFn?

    private init() {
        let candidates = [
            "/usr/lib/libIOReport.dylib",
            "/System/Library/PrivateFrameworks/IOReport.framework/IOReport",
        ]
        guard let handle = candidates.compactMap({ dlopen($0, RTLD_NOW) }).first else {
            loadError = String(cString: dlerror())
            return
        }

        func bind<T>(_ name: String, _ type: T.Type) -> T? {
            guard let sym = dlsym(handle, name) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }

        guard
            let cg = bind("IOReportCopyChannelsInGroup", CopyChannelsInGroupFn.self),
            let cs = bind("IOReportCreateSubscription", CreateSubscriptionFn.self),
            let sa = bind("IOReportCreateSamples", CreateSamplesFn.self),
            let sd = bind("IOReportCreateSamplesDelta", CreateSamplesDeltaFn.self),
            let gg = bind("IOReportChannelGetGroup", ChannelGetStringFn.self),
            let sg = bind("IOReportChannelGetSubGroup", ChannelGetStringFn.self),
            let gn = bind("IOReportChannelGetChannelName", ChannelGetStringFn.self),
            let gf = bind("IOReportChannelGetFormat", ChannelGetFormatFn.self),
            let gu = bind("IOReportChannelGetUnitLabel", ChannelGetStringFn.self),
            let sv = bind("IOReportSimpleGetIntegerValue", SimpleGetIntegerFn.self),
            let sc = bind("IOReportStateGetCount", StateGetCountFn.self),
            let sn = bind("IOReportStateGetNameForIndex", StateGetNameFn.self),
            let sr = bind("IOReportStateGetResidency", StateGetResidencyFn.self)
        else {
            loadError = "IOReport 关键符号缺失"
            return
        }

        copyChannelsInGroup = cg
        createSubscription = cs
        createSamples = sa
        createSamplesDelta = sd
        channelGetGroup = gg
        channelGetSubGroup = sg
        channelGetName = gn
        channelGetFormat = gf
        channelGetUnitLabel = gu
        simpleGetInteger = sv
        stateGetCount = sc
        stateGetName = sn
        stateGetResidency = sr
        getChannelCount = bind("IOReportGetChannelCount", GetChannelCountFn.self)
        histogramBucketCount = bind("IOReportHistogramGetBucketCount", HistogramBucketCountFn.self)
        histogramBucketHits = bind("IOReportHistogramGetBucketHits", HistogramBucketHitsFn.self)
        histogramBucketMin = bind("IOReportHistogramGetBucketMinValue", HistogramBucketBoundsFn.self)
        histogramBucketMax = bind("IOReportHistogramGetBucketMaxValue", HistogramBucketBoundsFn.self)
        isAvailable = true
    }

    // MARK: - 频道元数据

    enum ChannelFormat: Int32 {
        case invalid = 0
        case simple = 1
        case state = 2
        case histogram = 3
        case simpleArray = 4
        case unknown = -1
    }

    func format(_ channel: Report) -> ChannelFormat {
        ChannelFormat(rawValue: channelGetFormat(channel)) ?? .unknown
    }

    func group(_ channel: Report) -> String {
        channelGetGroup(channel).map { $0.takeUnretainedValue() as String } ?? ""
    }

    func subgroup(_ channel: Report) -> String {
        channelGetSubGroup(channel).map { $0.takeUnretainedValue() as String } ?? ""
    }

    func name(_ channel: Report) -> String {
        channelGetName(channel).map { $0.takeUnretainedValue() as String } ?? ""
    }

    func unitLabel(_ channel: Report) -> String {
        channelGetUnitLabel(channel).map { $0.takeUnretainedValue() as String } ?? ""
    }

    func simpleValue(_ channel: Report, index: Int32 = 0) -> Int64 {
        simpleGetInteger(channel, index)
    }

    func stateResidencies(_ channel: Report) -> [(name: String, residency: Int64)] {
        let count = stateGetCount(channel)
        guard count > 0, count < 4096 else { return [] }
        var result: [(String, Int64)] = []
        result.reserveCapacity(Int(count))
        for i in 0..<count {
            let n = stateGetName(channel, i).map { $0.takeUnretainedValue() as String } ?? "state\(i)"
            result.append((n, stateGetResidency(channel, i)))
        }
        return result
    }

    // MARK: - 订阅

    final class Subscription {
        let subscription: Report
        let channels: Report
        private let bridge: IOReportBridge

        init?(bridge: IOReportBridge, group: String, subgroup: String?) {
            guard let channels = bridge.copyChannelsInGroup(group as CFString, subgroup as CFString?, 0, 0, 0)?
                .takeRetainedValue() else { return nil }
            if let count = bridge.getChannelCount, count(channels) <= 0 { return nil }

            var subbed: Unmanaged<Report>?
            guard let subscription = bridge.createSubscription(nil, channels, &subbed, 0, nil)?
                .takeRetainedValue() else { return nil }
            self.bridge = bridge
            self.channels = subbed?.takeRetainedValue() ?? channels
            self.subscription = subscription
        }

        func sample() -> Report? {
            bridge.createSamples(subscription, channels, nil)?.takeRetainedValue()
        }

        func delta(previous: Report, current: Report) -> Report? {
            bridge.createSamplesDelta(previous, current, nil)?.takeRetainedValue()
        }
    }

    func subscription(group: String, subgroup: String? = nil) -> Subscription? {
        guard isAvailable else { return nil }
        return Subscription(bridge: self, group: group, subgroup: subgroup)
    }

    // MARK: - 样本遍历

    struct ChannelSample {
        let group: String
        let subgroup: String
        let name: String
        let format: ChannelFormat
        let unit: String
        let dictionary: Report
    }

    /// IOReport 的 samples/delta 结构：
    /// `{ "IOReportChannels" = [ channelDict, ... ] }`，
    /// channelDict 带 `RawElements`(CFData) 与 LegendChannel 元数据。
    func allChannels(in samples: Report) -> [ChannelSample] {
        var out: [ChannelSample] = []
        let key = Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque()
        guard let raw = CFDictionaryGetValue(samples, key) else { return out }
        let object = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        guard CFGetTypeID(object) == CFArrayGetTypeID() else { return out }
        let array = object as! CFArray
        let count = CFArrayGetCount(array)
        guard count > 0, count < 16384 else { return out }
        for i in 0..<count {
            guard let item = CFArrayGetValueAtIndex(array, i) else { continue }
            let value = Unmanaged<AnyObject>.fromOpaque(item).takeUnretainedValue()
            guard CFGetTypeID(value) == CFDictionaryGetTypeID() else { continue }
            let dict = value as! Report
            let fmt = format(dict)
            guard (1...4).contains(fmt.rawValue) else { continue }
            out.append(ChannelSample(
                group: group(dict),
                subgroup: subgroup(dict),
                name: name(dict),
                format: fmt,
                unit: unitLabel(dict),
                dictionary: dict
            ))
        }
        return out
    }

    // MARK: - 直方图

    /// 直方图均值：Σ(hits × 桶中点) / Σhits
    func histogramMean(_ channel: Report) -> Double? {
        guard let countFn = histogramBucketCount, let hitsFn = histogramBucketHits,
              let minFn = histogramBucketMin, let maxFn = histogramBucketMax else { return nil }
        let count = countFn(channel)
        guard count > 0, count < 4096 else { return nil }
        var totalHits = 0.0
        var weighted = 0.0
        for i in 0..<count {
            let hits = Double(max(hitsFn(channel, i), 0))
            guard hits > 0 else { continue }
            let mid = Double(minFn(channel, i) + maxFn(channel, i)) / 2.0
            totalHits += hits
            weighted += hits * mid
        }
        guard totalHits > 0 else { return nil }
        return weighted / totalHits
    }

    func histogramBuckets(_ channel: Report) -> [(min: Int64, max: Int64, hits: Int64)] {
        guard let countFn = histogramBucketCount, let hitsFn = histogramBucketHits,
              let minFn = histogramBucketMin, let maxFn = histogramBucketMax else { return [] }
        let count = countFn(channel)
        guard count > 0, count < 4096 else { return [] }
        return (0..<count).map { (minFn(channel, $0), maxFn(channel, $0), hitsFn(channel, $0)) }
    }
}
