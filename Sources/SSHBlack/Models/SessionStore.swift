import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    private let storageKey = "sshblack.sessions.v1"

    init() { load() }

    func load() {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let list = try? JSONDecoder().decode([Session].self, from: data)
        else {
            sessions = []
            return
        }
        sessions = list
    }

    func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    func upsert(_ session: Session) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        } else {
            sessions.append(session)
        }
        save()
    }

    func delete(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
        KeychainHelper.delete(account: keychainAccount(for: session, field: "password"))
        KeychainHelper.delete(account: keychainAccount(for: session, field: "passphrase"))
        save()
    }

    // MARK: - 凭据（Keychain）

    func password(for session: Session) -> String {
        KeychainHelper.read(account: keychainAccount(for: session, field: "password")) ?? ""
    }

    func setPassword(_ password: String, for session: Session) {
        KeychainHelper.save(password, account: keychainAccount(for: session, field: "password"))
    }

    func passphrase(for session: Session) -> String {
        KeychainHelper.read(account: keychainAccount(for: session, field: "passphrase")) ?? ""
    }

    func setPassphrase(_ pass: String, for session: Session) {
        KeychainHelper.save(pass, account: keychainAccount(for: session, field: "passphrase"))
    }

    private func keychainAccount(for session: Session, field: String) -> String {
        "session.\(session.id.uuidString).\(field)"
    }
}
