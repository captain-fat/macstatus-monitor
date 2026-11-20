import AppKit
import MonitorKit

/// 菜单栏里的自绘视图。
///
/// 布局（默认）：
/// ```
/// ╭────────────────────────╮
/// │ CPU ▰▰▰▰▰▱▱  42%        │   ← 内存压力：包住两行的圆角外框
/// │ GPU ▰▰▱▱▱▱▱  31%        │      Normal 绿 / Warning 黄 / Critical 红
/// ╰────────────────────────╯
/// ```
///
/// 为什么不用 SwiftUI：菜单栏高度只有 22pt，自绘能精确控制 0.5pt 级别的对齐、
/// 圆角与描边，重绘成本也远低于 hosting view。
final class StatusItemView: NSView {

    // MARK: - 数据与设置

    var snapshot: MonitorSnapshot = .placeholder {
        didSet {
            guard snapshot != oldValue else { return }
            updateToolTip()
            needsDisplay = true
        }
    }

    var showsCPUPercent: Bool = true {
        didSet { invalidateWidth() }
    }

    var showsGPUPercent: Bool = true {
        didSet { invalidateWidth() }
    }

    var labelStyle: MetricLabelStyle = .full {
        didSet { invalidateWidth() }
    }

    /// 是否显示进度条（关掉后只留标签与百分比）
    var showsBar: Bool = true {
        didSet { invalidateWidth() }
    }

    /// 进度条长度（pt）
    var barWidth: CGFloat = 30 {
        didSet {
            guard barWidth != oldValue else { return }
            invalidateWidth()
        }
    }

    /// 内存压力三色（可在设置里改）
    var palette: PressurePalette = .system {
        didSet { needsDisplay = true }
    }

    // MARK: - 尺寸常量

    private enum Metrics {
        static let height: CGFloat = 22
        /// 外框相对视图边缘的 inset（描边居中，留 1pt 防止被裁）
        static let borderInset: CGFloat = 1
        /// 外框内左右留白
        static let horizontalPadding: CGFloat = 6
        static let barHeight: CGFloat = 4
        static let barToPercentGap: CGFloat = 4
        static let percentWidth: CGFloat = 24
        static let rowGap: CGFloat = 1.5
        static let verticalPadding: CGFloat = 1
        static let cornerRadius: CGFloat = 7
    }

    private let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    private let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)

    /// 菜单栏项需要的宽度。切换标签/百分比后由控制器重新设置 statusItem.length。
    /// 压力外框包住整个视图，不单独占一列。
    var preferredWidth: CGFloat {
        var width = Metrics.horizontalPadding * 2 + labelStyle.width + labelStyle.gap
        if showsBar { width += barWidth }
        if showsCPUPercent || showsGPUPercent {
            if showsBar { width += Metrics.barToPercentGap }
            width += Metrics.percentWidth
        }
        // 只留标签时也给一点最小宽度，避免外框挤成一条线
        return ceil(max(width, 28))
    }

    var preferredSize: NSSize {
        NSSize(width: preferredWidth, height: Metrics.height)
    }

    private func invalidateWidth() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
        onPreferredWidthChange?(preferredWidth)
    }

    /// 宽度变化回调（控制器用来同步 statusItem.length）
    var onPreferredWidthChange: ((CGFloat) -> Void)?

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        updateToolTip()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("MacStatus Monitor")
    }

    /// 点击交给 NSStatusBarButton 处理（否则收不到 action）
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: NSView.noIntrinsicMetric)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(true)

        drawPressureContainer()

        let rows = rowRects()
        drawRow(
            label: "CPU",
            value: snapshot.cpu,
            showsPercent: showsCPUPercent,
            isGPU: false,
            accent: .systemBlue,
            row: rows.top
        )
        drawRow(
            label: "GPU",
            value: snapshot.gpu,
            showsPercent: showsGPUPercent,
            isGPU: true,
            accent: .systemPurple,
            row: rows.bottom
        )
    }

    /// 内存压力：一个包住 CPU/GPU 两行的圆角外框，只有颜色，不占额外宽度
    private func drawPressureContainer() {
        let rect = bounds.insetBy(dx: Metrics.borderInset, dy: Metrics.borderInset)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        )
        let color = pressureColor
        color.setStroke()
        path.lineWidth = snapshot.memoryPressure == nil ? 1.2 : 1.6
        path.stroke()
    }

    private var pressureColor: NSColor {
        palette.color(for: snapshot.memoryPressure)
    }

    private func rowRects() -> (top: NSRect, bottom: NSRect) {
        let inset = Metrics.borderInset + Metrics.verticalPadding
        let available = bounds.height - inset * 2 - Metrics.rowGap
        let rowHeight = floor(available / 2)
        let top = NSRect(x: 0, y: inset, width: bounds.width, height: rowHeight)
        let bottom = NSRect(x: 0, y: top.maxY + Metrics.rowGap, width: bounds.width, height: rowHeight)
        return (top, bottom)
    }

    private func drawRow(
        label: String,
        value: Double?,
        showsPercent: Bool,
        isGPU: Bool,
        accent: NSColor,
        row: NSRect
    ) {
        let midY = row.midY

        // 标签（可隐藏 / 缩写）
        let labelWidth = labelStyle.width
        if labelWidth > 0 {
            let labelRect = NSRect(
                x: Metrics.horizontalPadding,
                y: midY - 5,
                width: labelWidth,
                height: 10
            )
            drawText(
                labelStyle.text(for: label),
                in: labelRect,
                font: labelFont,
                color: NSColor.labelColor.withAlphaComponent(0.75),
                alignment: .left
            )
        }

        // 进度条（可隐藏）
        var cursorX = Metrics.horizontalPadding + labelWidth + labelStyle.gap
        if showsBar {
            let barRect = NSRect(
                x: cursorX,
                y: midY - Metrics.barHeight / 2,
                width: barWidth,
                height: Metrics.barHeight
            )
            drawBar(in: barRect, value: value, accent: accent)
            cursorX = barRect.maxX + Metrics.barToPercentGap
        }

        // 百分比；没有进度条时靠右对齐
        if showsPercent {
            let textWidth = Metrics.percentWidth
            let percentX = showsBar ? cursorX : bounds.width - Metrics.horizontalPadding - textWidth
            let percentRect = NSRect(
                x: percentX,
                y: midY - 5,
                width: textWidth,
                height: 10
            )
            drawText(
                percentText(value: value, isGPU: isGPU),
                in: percentRect,
                font: percentFont,
                color: NSColor.labelColor,
                alignment: .right
            )
        }
    }

    /// GPU 拿不到数据时显示 N/A（而不是 "—"），明确区分"还没采到"和"不可用"
    private func percentText(value: Double?, isGPU: Bool) -> String {
        if let value, value.isFinite {
            return String(format: "%.0f%%", value)
        }
        if isGPU, snapshot.gpuUnavailableReason != nil {
            return "N/A"
        }
        return "—"
    }

    private func drawBar(in rect: NSRect, value: Double?, accent: NSColor) {
        let radius = rect.height / 2

        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        track.fill()

        guard let value, value.isFinite else { return }

        let clamped = min(max(value, 0), 100) / 100.0
        guard clamped > 0 else { return }

        // 极小值也给 3pt 的可视宽度，避免"明明有负载却是空的"
        let fillWidth = max(rect.height * 0.75, rect.width * CGFloat(clamped))
        let fillRect = NSRect(
            x: rect.minX,
            y: rect.minY,
            width: min(fillWidth, rect.width),
            height: rect.height
        )
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        accent.setFill()
        fill.fill()
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment
    ) {
        guard !text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    // MARK: - 辅助

    private func updateToolTip() {
        toolTip = "MacStatus Monitor · 点击查看详情"
        setAccessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let cpu = snapshot.cpu.map { String(format: "CPU %.0f%%", $0) } ?? "CPU 无数据"
        let gpu: String
        if let value = snapshot.gpu {
            gpu = String(format: "GPU %.0f%%", value)
        } else if snapshot.gpuUnavailableReason != nil {
            gpu = "GPU 不可用"
        } else {
            gpu = "GPU 无数据"
        }
        let memory = snapshot.memoryPressure?.displayName ?? "内存压力未知"
        return "\(cpu)，\(gpu)，\(memory)"
    }
}
