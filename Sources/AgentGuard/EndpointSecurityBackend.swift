import EndpointSecurity
import Combine
import Foundation

enum EndpointSecurityState: Equatable {
    case notStarted
    case available
    case unavailable(reason: String)

    var label: String {
        switch self {
        case .notStarted: "未检测"
        case .available: "可用"
        case .unavailable: "未启用"
        }
    }

    var detail: String {
        switch self {
        case .notStarted: "尚未探测 Endpoint Security"
        case .available: "客户端已建立，尚未订阅或改变任何文件操作"
        case .unavailable(let reason): reason
        }
    }
}

/// Capability probe and lifecycle seam for the future file-event backend.
/// This version deliberately subscribes to nothing and never changes a file verdict.
@MainActor
final class EndpointSecurityBackend: ObservableObject {
    @Published private(set) var state: EndpointSecurityState = .notStarted
    private var client: OpaquePointer?

    func probe() {
        guard client == nil else {
            state = .available
            return
        }

        var newClient: OpaquePointer?
        let result = es_new_client(&newClient) { _, _ in
            // No events are subscribed in this increment. Keep the callback inert.
        }
        guard result == ES_NEW_CLIENT_RESULT_SUCCESS, let newClient else {
            state = .unavailable(reason: Self.reason(for: result))
            return
        }
        client = newClient
        state = .available
    }

    func stop() {
        guard let client else { return }
        _ = es_delete_client(client)
        self.client = nil
        state = .notStarted
    }

    private static func reason(for result: es_new_client_result_t) -> String {
        switch result {
        case ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED:
            "缺少 Endpoint Security entitlement（开发预览未申请）"
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED:
            "系统未授予 Endpoint Security 权限"
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED:
            "需要受支持的特权部署方式"
        case ES_NEW_CLIENT_RESULT_ERR_TOO_MANY_CLIENTS:
            "系统中的 Endpoint Security 客户端数量已达上限"
        default:
            "Endpoint Security 返回错误：\(result.rawValue)"
        }
    }
}
