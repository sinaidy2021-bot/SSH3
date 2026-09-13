import Foundation
import Citadel
import Combine

struct HistoryItem: Identifiable {
  var id = UUID()
  var command: String
  var output: String
}

class SSHSession: ObservableObject {
  @Published var history: [HistoryItem] = []
  @Published var isConnected = false
  var host = ""
  var username = ""
  var password = ""
  private var client: SSHClient?

  func connect() {
    Task {
      do {
        let settings = SSHClientSettings(
          host: host,
          authenticationMethod:.passwordBased(username: self.username, password: self.password),
          hostKeyValidator:.acceptAnything(),
          reconnect:.never
        )
        let client = try await SSHClient.connect(to: settings)
        self.client = client
        await MainActor.run {
          self.isConnected = true
          self.history.append(HistoryItem(command: "连接成功", output: "已连接到 \(self.host)"))
        }
      } catch {
        await MainActor.run {
          self.history.append(HistoryItem(command: "连接失败", output: "\(error)"))
        }
      }
    }
  }

  func sendCommand(_ cmd: String) {
    let trimmed = cmd.trimmingCharacters(in:.whitespacesAndNewlines)
    if trimmed.isEmpty { return }
    DispatchQueue.main.async {
      self.history.append(HistoryItem(command: trimmed, output: "执行中..."))
    }
    Task {
      do {
        guard let client = self.client else { return }
        let output = try await client.executeCommand(trimmed)
        let text = String(buffer: output)
        let clean = text.trimmingCharacters(in:.whitespacesAndNewlines)
        await MainActor.run {
          if!clean.isEmpty {
            let idx = self.history.count - 1
            if idx >= 0 { self.history[idx].output = clean }
          } else {
            let idx = self.history.count - 1
            if idx >= 0 { self.history[idx].output = "(无输出)" }
          }
        }
      }
