import Foundation
import UIKit
import Citadel
import NIOCore
import NIOSSH

struct CommandHistoryItem: Identifiable {
    let id = UUID()
    let command: String
    var output: String
}

@MainActor
final class SSHSession: ObservableObject {
    @Published var isConnected = false
    @Published var history: [CommandHistoryItem] = []
    private var client: SSHClient?
    private var activeWriter: TTYStdinWriter?
    var host = ""
    var username = "root"
    var password = ""

    func connect() {
        Task {
            do {
                let client = try await SSHClient.connect(
                    host: host,
                    port: 22,
                    authenticationMethod:.passwordBased(username: username, password: password),
                    hostKeyValidator:.acceptAnything(),
                    reconnect:.never
                )
                self.client = client
                self.isConnected = true
                let pty = SSHChannelRequestEvent.PseudoTerminalRequest(wantReply: true, term: "xterm", terminalCharacterWidth: 80, terminalRowHeight: 40, terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes:.init([.ECHO: 0]))
                try await client.withPTY(pty) { stream, writer in
                    self.activeWriter = writer
                    for try await event in stream {
                        let buf: ByteBuffer
                        switch event {
                        case.stdout(let b): buf = b
                        case.stderr(let b): buf = b
                        }
                        if let s = buf.getString(at: buf.readerIndex, length: buf.readableBytes) {
                            let clean = s.replacingOccurrences(of: "\r", with: "")
                            if!clean.isEmpty {
                                if let idx = self.history.indices.last {
                                    self.history[idx].output += clean
                                }
                            }
                        }
                    }
                }
                self.isConnected = false
            } catch {
                self.history.append(CommandHistoryItem(command: "system", output: "连接失败: \(error.localizedDescription)"))
                self.isConnected = false
            }
        }
    }

    func sendCommand(_ cmd: String) {
        let item = CommandHistoryItem(command: cmd, output: "")
        history.append(item)
        let idx = history.count - 1
        Task {
            do {
                var buffer = ByteBufferAllocator().buffer(capacity: cmd.utf8.count + 2)
                buffer.writeString(cmd + "\n")
                try await self.activeWriter?.write(buffer)
            } catch {
                self.history[idx].output = "写入失败: \(error.localizedDescription)"
            }
        }
    }

    func sendCtrlC() {
        Task {
            var buffer = ByteBufferAllocator().buffer(capacity: 1)
            buffer.writeString("\u{03}")
            try? await self.activeWriter?.write(buffer)
        }
    }

    func sendTab() {
        Task {
            var buffer = ByteBufferAllocator().buffer(capacity: 1)
            buffer.writeString("\t")
            try? await self.activeWriter?.write(buffer)
        }
    }

    func disconnect() {
        Task { try? await self.client?.close() }
        isConnected = false
    }
}
