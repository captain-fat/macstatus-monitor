import AppKit
import MonitorKit

/// 内存压力三色。默认用系统语义色，用户可在设置里改，改完持久化到 UserDefaults。
@MainActor
final class PressureColorSettings: ObservableObject {
    static let shared = PressureColorSettings()

    @Published var normal: NSColor { didSet { persist() } }
    @Published var warning: NSColor { didSet { persist() } }
    @Published var critical: NSColor { didSet { persist() } }

    private enum Key {
        static let normal = "pressureColor.normal"
        static let warning = "pressureColor.warning"
        static let critical = "pressureColor.critical"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        normal = Self.load(Key.normal, from: defaults) ?? .systemGreen
        warning = Self.load(Key.warning, from: defaults) ?? .systemYellow
        critical = Self.load(Key.critical, from: defaults) ?? .systemRed
    }

    var palette: PressurePalette {
        PressurePalette(normal: normal, warning: warning, critical: critical)
    }

    var isDefault: Bool {
        Self.matches(normal, .systemGreen)
            && Self.matches(warning, .systemYellow)
            && Self.matches(critical, .systemRed)
    }

    /// 比较 sRGB 分量而不是 NSColor 对象：动态系统色与"从 UserDefaults 读回的 sRGB 色"
    /// 对象不相等，但视觉上是同一个颜色。
    private static func matches(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let a = lhs.usingColorSpace(.sRGB), let b = rhs.usingColorSpace(.sRGB) else { return false }
        let tolerance = 0.01
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }

    func resetToDefaults() {
        normal = .systemGreen
        warning = .systemYellow
        critical = .systemRed
        defaults.removeObject(forKey: Key.normal)
        defaults.removeObject(forKey: Key.warning)
        defaults.removeObject(forKey: Key.critical)
    }

    // MARK: - 持久化

    private func persist() {
        Self.save(normal, key: Key.normal, defaults: defaults)
        Self.save(warning, key: Key.warning, defaults: defaults)
        Self.save(critical, key: Key.critical, defaults: defaults)
    }

    private static func save(_ color: NSColor, key: String, defaults: UserDefaults) {
        guard let components = color.usingColorSpace(.sRGB) else { return }
        let values = [
            Double(components.redComponent),
            Double(components.greenComponent),
            Double(components.blueComponent),
            Double(components.alphaComponent),
        ]
        defaults.set(values, forKey: key)
    }

    private static func load(_ key: String, from defaults: UserDefaults) -> NSColor? {
        guard let values = defaults.array(forKey: key) as? [Double], values.count == 4 else { return nil }
        return NSColor(srgbRed: values[0], green: values[1], blue: values[2], alpha: values[3])
    }
}

/// 传给绘制层的不可变配色
public struct PressurePalette: Equatable {
    public var normal: NSColor
    public var warning: NSColor
    public var critical: NSColor

    public static let system = PressurePalette(
        normal: .systemGreen,
        warning: .systemYellow,
        critical: .systemRed
    )

    public func color(for level: MemoryPressureLevel?) -> NSColor {
        switch level {
        case .normal: return normal
        case .warning: return warning
        case .critical: return critical
        case nil: return NSColor.labelColor.withAlphaComponent(0.30)
        }
    }
}
