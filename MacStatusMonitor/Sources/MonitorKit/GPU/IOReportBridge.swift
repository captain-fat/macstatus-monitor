import Foundation
import Darwin

/// IOReport 动态桥接（私有框架，全部 dlsym）。
///
/// macOS 26/27 已没有 IOReport.framework 目录，框架只在 dyld 共享缓存里，
/// 通过 `/usr/lib/libIOReport.dylib` 可 dlopen；老系统走 framework 路径。
/// 不把私有库写进 LC_LOAD_DYLIB，符号缺失时降级而不是崩溃。
public final class IOReportBridge {

    public static let shared = IOReportBridge()

    public private(set) var isAvailable = false
    public private(set) var loadError: String?

    public typealias Report = CFDictionary

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
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }

        guard
            let copy = bind("IOReportCopyChannelsInGroup", CopyChannelsInGroupFn.self),
            let subscribe = bind("IOReportCreateSubscription", CreateSubscriptionFn.self),
            let samples = bind("IOReportCreateSamples", CreateSamplesFn.self),
            let delta = bind("IOReportCreateSamplesDelta", CreateSamplesDeltaFn.self),
            let group = bind("IOReportChannelGetGroup", ChannelGetStringFn.self),
            let subgroup = bind("IOReportChannelGetSubGroup", ChannelGetStringFn.self),
            let name = bind("IOReportChannelGetChannelName", ChannelGetStringFn.self),
            let format = bind("IOReportChannelGetFormat", ChannelGetFormatFn.self),
            let unit = bind("IOReportChannelGetUnitLabel", ChannelGetStringFn.self),
            let simple = bind("IOReportSimpleGetIntegerValue", SimpleGetIntegerFn.self),
            let stateCount = bind("IOReportStateGetCount", StateGetCountFn.self),
            let stateName = bind("IOReportStateGetNameForIndex", StateGetNameFn.self),
            let stateResidency = bind("IOReportStateGetResidency", StateGetResidencyFn.self)
        else {
            loadError = "IOReport 关键符号缺失"
            return
        }

        copyChannelsInGroup = copy
        createSubscription = subscribe
        createSamples = samples
        createSamplesDelta = delta
        channelGetGroup = group
        channelGetSubGroup = subgroup
        channelGetName = name
        channelGetFormat = format
        channelGetUnitLabel = unit
        simpleGetInteger = simple
        stateGetCount = stateCount
        stateGetName = stateName
        stateGetResidency = stateResidency
        getChannelCount = bind("IOReportGetChannelCount", GetChannelCountFn.self)
        histogramBucketCount = bind("IOReportHistogramGetBucketCount", HistogramBucketCountFn.self)
        histogramBucketHits = bind("IOReportHistogramGetBucketHits", HistogramBucketHitsFn.self)
        histogramBucketMin = bind("IOReportHistogramGetBucketMinValue", HistogramBucketBoundsFn.self)
        histogramBucketMax = bind("IOReportHistogramGetBucketMaxValue", HistogramBucketBoundsFn.self)
        isAvailable = true
    }

    // MARK: - 频道元数据

    /// 实测枚举：1 = simple，2 = state，3 = histogram（4 = simpleArray）
    public enum ChannelFormat: Int32, Sendable {
        case invalid = 0
        case simple = 1
        case state = 2
        case histogram = 3
        case simpleArray = 4
        case unknown = -1
    }

    public func format(_ channel: Report) -> ChannelFormat {
        ChannelFormat(rawValue: channelGetFormat(channel)) ?? .unknown
    }

    public func group(_ channel: Report) -> String {
        channelGetGroup(channel).map { $0.takeUnretainedValue() as String } ?? ""
    }

    public func subgroup(_ channel: Report) -> String {
        channelGetSubGroup(channel).map { $0.takeUnretainedValue() as String } ?? ""
    }

    public func name(_ channel: Report) -> String {
        channelGetName(channel).map { $0.takeUnretainedValue() as String } ?? ""
    }

    public func unitLabel(_ channel: Report) -> String {
        channelGetUnitLabel(channel).map { $0.takeUnretainedValue() as String } ?? ""
    }

    public func simpleValue(_ channel: Report, index: Int32 = 0) -> Int64 {
        simpleGetInteger(channel, index)
    }

    public func stateResidencies(_ channel: Report) -> [(name: String, residency: Int64)] {
        let count = stateGetCount(channel)
        guard count > 0, count < 4096 else { return [] }
        var result: [(String, Int64)] = []
        result.reserveCapacity(Int(count))
        for index in 0..<count {
            let stateName = stateGetName(channel, index).map { $0.takeUnretainedValue() as String } ?? "state\(index)"
            result.append((stateName, stateGetResidency(channel, index)))
        }
        return result
    }

    // MARK: - 订阅

    public final class Subscription {
        let subscription: Report
        let channels: Report
        private let bridge: IOReportBridge

        init?(bridge: IOReportBridge, group: String, subgroup: String?) {
            guard let channels = bridge.copyChannelsInGroup(group as CFString, subgroup as CFString?, 0, 0, 0)?
                .takeRetainedValue() else { return nil }
            if let count = bridge.getChannelCount, count(channels) <= 0 { return nil }

            var subscribed: Unmanaged<Report>?
            guard let subscription = bridge.createSubscription(nil, channels, &subscribed, 0, nil)?
                .takeRetainedValue() else { return nil }
            self.bridge = bridge
            self.channels = subscribed?.takeRetainedValue() ?? channels
            self.subscription = subscription
        }

        public func sample() -> Report? {
            bridge.createSamples(subscription, channels, nil)?.takeRetainedValue()
        }

        public func delta(previous: Report, current: Report) -> Report? {
            bridge.createSamplesDelta(previous, current, nil)?.takeRetainedValue()
        }
    }

    public func subscription(group: String, subgroup: String? = nil) -> Subscription? {
        guard isAvailable else { return nil }
        return Subscription(bridge: self, group: group, subgroup: subgroup)
    }

    // MARK: - 样本遍历

    public struct ChannelSample {
        public let group: String
        public let subgroup: String
        public let name: String
        public let format: ChannelFormat
        public let unit: String
        public let dictionary: Report
    }

    /// 样本结构：`{ "IOReportChannels" = [ channelDict, ... ] }`，channelDict 带 `RawElements`。
    public func allChannels(in samples: Report) -> [ChannelSample] {
        var result: [ChannelSample] = []
        let key = Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque()
        guard let raw = CFDictionaryGetValue(samples, key) else { return result }
        let object = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        guard CFGetTypeID(object) == CFArrayGetTypeID() else { return result }
        let array = object as! CFArray
        let count = CFArrayGetCount(array)
        guard count > 0, count < 16384 else { return result }

        for index in 0..<count {
            guard let item = CFArrayGetValueAtIndex(array, index) else { continue }
            let value = Unmanaged<AnyObject>.fromOpaque(item).takeUnretainedValue()
            guard CFGetTypeID(value) == CFDictionaryGetTypeID() else { continue }
            let dict = value as! Report
            let channelFormat = format(dict)
            guard (1...4).contains(channelFormat.rawValue) else { continue }
            result.append(ChannelSample(
                group: group(dict),
                subgroup: subgroup(dict),
                name: name(dict),
                format: channelFormat,
                unit: unitLabel(dict),
                dictionary: dict
            ))
        }
        return result
    }

    // MARK: - 直方图

    public func histogramMean(_ channel: Report) -> Double? {
        guard let countFn = histogramBucketCount, let hitsFn = histogramBucketHits,
              let minFn = histogramBucketMin, let maxFn = histogramBucketMax else { return nil }
        let count = countFn(channel)
        guard count > 0, count < 4096 else { return nil }
        var totalHits = 0.0
        var weighted = 0.0
        for index in 0..<count {
            let hits = Double(max(hitsFn(channel, index), 0))
            guard hits > 0 else { continue }
            let mid = Double(minFn(channel, index) + maxFn(channel, index)) / 2.0
            totalHits += hits
            weighted += hits * mid
        }
        guard totalHits > 0 else { return nil }
        return weighted / totalHits
    }

    public func histogramBuckets(_ channel: Report) -> [(min: Int64, max: Int64, hits: Int64)] {
        guard let countFn = histogramBucketCount, let hitsFn = histogramBucketHits,
              let minFn = histogramBucketMin, let maxFn = histogramBucketMax else { return [] }
        let count = countFn(channel)
        guard count > 0, count < 4096 else { return [] }
        return (0..<count).map { (minFn(channel, $0), maxFn(channel, $0), hitsFn(channel, $0)) }
    }
}
