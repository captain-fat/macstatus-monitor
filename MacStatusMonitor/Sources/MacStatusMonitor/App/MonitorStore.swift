import Foundation
import Combine
import MonitorKit

/// UI 唯一的数据源。
///
/// 阶段二：只有占位快照，证明菜单栏与 Popover 的渲染管线可用。
/// 阶段三：由 `SystemMonitor` 的 1 Hz 循环驱动 `apply(_:)`，UI 不做任何采集。
@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var snapshot: MonitorSnapshot
    @Published private(set) var lastUpdate: Date?

    init(snapshot: MonitorSnapshot = .placeholder) {
        self.snapshot = snapshot
        self.lastUpdate = snapshot.cpu == nil && snapshot.gpu == nil ? nil : snapshot.timestamp
    }

    func apply(_ snapshot: MonitorSnapshot) {
        lastUpdate = snapshot.timestamp
        // Equatable 忽略 timestamp：数值没变化就不发布，避免无意义重绘
        if self.snapshot != snapshot {
            self.snapshot = snapshot
        }
    }
}
