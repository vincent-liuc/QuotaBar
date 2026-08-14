import Foundation
import ServiceManagement

protocol LaunchAtLoginManaging {
    var statusDescription: String { get }
    func setEnabled(_ enabled: Bool, refreshRegistration: Bool) throws
}

final class LaunchAtLoginManager: LaunchAtLoginManaging {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "开机启动已启用"
        case .requiresApproval:
            return "需要在系统设置的登录项中允许"
        case .notRegistered:
            return "开机启动未启用"
        case .notFound:
            return "请先将应用安装到“应用程序”文件夹"
        @unknown default:
            return "无法读取开机启动状态"
        }
    }

    func setEnabled(_ enabled: Bool, refreshRegistration: Bool = false) throws {
        let service = SMAppService.mainApp
        if enabled {
            if refreshRegistration && service.status == .enabled {
                try service.unregister()
            }
            guard service.status != .enabled && service.status != .requiresApproval else { return }
            try service.register()
        } else {
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try service.unregister()
        }
    }
}
