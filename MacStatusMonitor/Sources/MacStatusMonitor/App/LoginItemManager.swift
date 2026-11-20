import Foundation
import ServiceManagement

/// 开机启动（macOS 13+ 的 SMAppService）。
///
/// 注意：ad-hoc 签名、或 .app 不在 /Applications 时，注册会失败并抛出错误。
/// 这里把错误原样显示在设置界面，而不是静默失败。
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var message: String?

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        switch status {
        case .requiresApproval:
            message = "需要在「系统设置 → 通用 → 登录项」中允许。"
        default:
            message = nil
        }
    }

    var debugStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        case .requiresApproval: return "requiresApproval"
        @unknown default: return "unknown(\(SMAppService.mainApp.status.rawValue))"
        }
    }

    func setEnabled(_ enabled: Bool) {
        message = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let nsError = error as NSError
            message = "设置失败：\(nsError.localizedDescription)（\(nsError.domain) \(nsError.code)）。可到「系统设置 → 通用 → 登录项」手动添加。"
        }
        refresh()
        if isEnabled != enabled, message == nil {
            message = enabled
                ? "系统未接受注册请求，请重启应用后再试，或在「登录项」里手动添加。"
                : "系统未接受取消请求，请到「登录项」里移除。"
        }
    }
}
