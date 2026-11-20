import SwiftUI
import MonitorKit

/// 点击菜单栏图标后展开的详情面板。
///
/// 阶段二：展示占位数据，验证布局与深色模式；
/// 阶段三起由 `MonitorStore` 的实时快照驱动。
struct MonitorPopoverView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var colors: PressureColorSettings
    var onSettings: () -> Void
    var onQuit: () -> Void

    private var snapshot: MonitorSnapshot { store.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 14)
            VStack(spacing: 10) {
                MetricRow(
                    title: "CPU",
                    value: snapshot.cpu,
                    accent: .blue,
                    detail: cpuDetail
                )
                MetricRow(
                    title: "GPU",
                    value: snapshot.gpu,
                    accent: .purple,
                    detail: snapshot.gpuSource ?? "—"
                )
                pressureRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider().padding(.horizontal, 14)
            footer
        }
        .frame(width: 286)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        Text("MacStatus Monitor")
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
    }

    private var cpuDetail: String {
        guard let user = snapshot.cpuUser, let system = snapshot.cpuSystem, let idle = snapshot.cpuIdle else {
            return "—"
        }
        return String(format: "用户 %.0f%% · 系统 %.0f%% · 空闲 %.0f%%", user, system, idle)
    }

    private var pressureRow: some View {
        HStack(spacing: 8) {
            Text("内存压力")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(pressureColor, lineWidth: 1.6)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(pressureColor.opacity(0.12))
                )
                .frame(width: 18, height: 18)

            Text(pressureText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(snapshot.memoryPressure == nil ? .secondary : .primary)

            Spacer(minLength: 0)

            if let free = snapshot.memoryFreeBytes, snapshot.physicalMemoryBytes > 0 {
                Text(String(format: "可用 %.1f GB", Double(free) / 1e9))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var pressureColor: Color {
        Color(nsColor: colors.palette.color(for: snapshot.memoryPressure))
    }

    private var pressureText: String {
        snapshot.memoryPressure?.displayName ?? "未知"
    }

    private var footer: some View {
        HStack {
            Button("设置…", action: onSettings)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("退出", action: onQuit)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct MetricRow: View {
    var title: String
    var value: Double?
    var accent: Color
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .leading)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(nsColor: .quaternaryLabelColor))
                        Capsule()
                            .fill(accent)
                            .frame(width: barWidth(in: geometry.size.width))
                    }
                }
                .frame(height: 5)

                Text(value.map { String(format: "%.0f%%", $0) } ?? "—")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
            Text(detail)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .padding(.leading, 54)
        }
    }

    private func barWidth(in total: CGFloat) -> CGFloat {
        guard let value, value.isFinite else { return 0 }
        let ratio = min(max(value, 0), 100) / 100
        return max(total * ratio, value > 0 ? 3 : 0)
    }
}
