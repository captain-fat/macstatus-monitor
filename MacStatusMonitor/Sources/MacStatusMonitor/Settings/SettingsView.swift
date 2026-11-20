import SwiftUI
import MonitorKit

/// 设置窗口内容。
///
/// 所有控件绑定到本地 `@State`，只有用户真正改动时才写回 `AppSettings`。
/// 这样"打开设置窗口"本身绝不会修改持久化设置——SwiftUI 的 Picker/Toggle
/// 在初次布局时可能把"当前值"写回绑定，曾经因此把用户的百分比开关改掉。
struct SettingsView: View {
    let settings: AppSettings
    let colors: PressureColorSettings
    @ObservedObject var login: LoginItemManager

    @State private var labelStyle: MetricLabelStyle
    @State private var showCPUPercent: Bool
    @State private var showGPUPercent: Bool
    @State private var showsBar: Bool
    @State private var barWidth: Double
    @State private var refreshInterval: Double
    @State private var gpuMetric: GPUMetric
    @State private var normalColor: Color
    @State private var warningColor: Color
    @State private var criticalColor: Color

    private let refreshOptions: [Double] = [0.5, 1, 2, 5]

    init(settings: AppSettings, colors: PressureColorSettings, login: LoginItemManager) {
        self.settings = settings
        self.colors = colors
        self.login = login
        _labelStyle = State(initialValue: settings.labelStyle)
        _showCPUPercent = State(initialValue: settings.showCPUPercent)
        _showGPUPercent = State(initialValue: settings.showGPUPercent)
        _showsBar = State(initialValue: settings.showsBar)
        _barWidth = State(initialValue: settings.barWidth)
        _refreshInterval = State(initialValue: settings.refreshInterval)
        _gpuMetric = State(initialValue: settings.gpuMetric)
        _normalColor = State(initialValue: Color(nsColor: colors.normal))
        _warningColor = State(initialValue: Color(nsColor: colors.warning))
        _criticalColor = State(initialValue: Color(nsColor: colors.critical))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("菜单栏") {
                labeledRow("标签") {
                    Picker("", selection: $labelStyle) {
                        ForEach(MetricLabelStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 230)
                }
                separator
                Toggle("显示 CPU 百分比", isOn: $showCPUPercent)
                    .toggleStyle(.checkbox)
                Toggle("显示 GPU 百分比", isOn: $showGPUPercent)
                    .toggleStyle(.checkbox)
                separator
                Toggle("显示进度条", isOn: $showsBar)
                    .toggleStyle(.checkbox)
                labeledRow("进度条长度") {
                    Picker("", selection: $barWidth) {
                        Text("短（20 pt）").tag(20.0)
                        Text("标准（30 pt）").tag(30.0)
                        Text("长（40 pt）").tag(40.0)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(!showsBar)
                }
                separator
                labeledRow("刷新间隔") {
                    Picker("", selection: $refreshInterval) {
                        ForEach(refreshOptions, id: \.self) { interval in
                            Text(interval == 1 ? "1 秒（默认）" : "\(formatted(interval)) 秒").tag(interval)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            section("GPU 口径") {
                Picker("", selection: $gpuMetric) {
                    ForEach(GPUMetric.allCases, id: \.self) { metric in
                        Text(metric.displayName).tag(metric)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(gpuMetric.explanation)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("内存压力配色") {
                colorRow("Normal", binding: $normalColor)
                colorRow("Warning", binding: $warningColor)
                colorRow("Critical", binding: $criticalColor)
                HStack {
                    Spacer()
                    Button("恢复系统默认") {
                        colors.resetToDefaults()
                        normalColor = Color(nsColor: colors.normal)
                        warningColor = Color(nsColor: colors.warning)
                        criticalColor = Color(nsColor: colors.critical)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                    .disabled(colors.isDefault)
                }
            }

            section("通用") {
                Toggle("开机启动", isOn: Binding(
                    get: { login.isEnabled },
                    set: { login.setEnabled($0) }
                ))
                .toggleStyle(.checkbox)

                if let note = loginNote {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(width: 430)
        .onChange(of: labelStyle) { _, value in settings.labelStyle = value }
        .onChange(of: showCPUPercent) { _, value in settings.showCPUPercent = value }
        .onChange(of: showGPUPercent) { _, value in settings.showGPUPercent = value }
        .onChange(of: showsBar) { _, value in settings.showsBar = value }
        .onChange(of: barWidth) { _, value in settings.barWidth = value }
        .onChange(of: refreshInterval) { _, value in settings.refreshInterval = value }
        .onChange(of: gpuMetric) { _, value in settings.gpuMetric = value }
        .onChange(of: normalColor) { _, value in colors.normal = NSColor(value) }
        .onChange(of: warningColor) { _, value in colors.warning = NSColor(value) }
        .onChange(of: criticalColor) { _, value in colors.critical = NSColor(value) }
    }

    // MARK: - 组件

    private var separator: some View {
        Divider().opacity(0.5)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func labeledRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
            Spacer(minLength: 8)
            content()
        }
    }

    private func colorRow(_ label: String, binding: Binding<Color>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
            Spacer()
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44)
        }
    }

    // MARK: - 辅助

    private var loginNote: String? {
        login.message ?? "建议把应用放在 /Applications 再开启；同一应用存在多份副本时，系统可能注册到错误的那一份。"
    }

    private func formatted(_ interval: Double) -> String {
        interval == floor(interval) ? String(Int(interval)) : String(format: "%.1f", interval)
    }
}
