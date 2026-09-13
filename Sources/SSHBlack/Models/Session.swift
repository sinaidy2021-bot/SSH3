import Foundation

struct Session: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    var authKind: AuthKind = .password
    /// 私钥（仅 authKind == .privateKey 时使用，OpenSSH 格式文本）
    var privateKey: String? = nil
    /// 私钥口令（可选）
    var passphrase: String? = nil

    enum AuthKind: String, Codable, CaseIterable {
        case password
        case privateKey

        var label: String {
            switch self {
            case .password: return "密码"
            case .privateKey: return "私钥"
            }
        }
    }

    var displayHost: String {
        "\(username)@\(host):\(port)"
    }

    var shortName: String {
        name.isEmpty ? host : name
    }
}
