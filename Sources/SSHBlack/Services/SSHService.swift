import Foundation
import NIOCore
import NIOPosix
import NIOSSH

enum SSHClientError: Error, LocalizedError {
    case notConnected
    case invalidChannelType
    case ptyOpenFailed(String)
    case shellOpenFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:      return "尚未连接服务器"
        case .invalidChannelType: return "无法创建会话通道"
        case .ptyOpenFailed(let s):   return "申请终端失败：\(s)"
        case .shellOpenFailed(let s): return "打开 Shell 失败：\(s)"
        }
    }
}

/// 把底层错误翻译成中文
func chineseErrorText(_ error: Error) -> String {
    if let e = error as? SSHClientError {
        return e.errorDescription ?? "未知错误"
    }

    let ns = error as NSError
    switch ns.code {
    case 1:  return "操作不被允许"
    case 8:  return "网络已断开"
    case 50: return "网络已断开"
    case 51: return "网络连接丢失"
    case 54: return "连接被重置"
    case 60: return "连接超时"
    case 61: return "连接被拒绝"
    case 65: return "网络不可达"
    default: return "网络错误（代码 \(ns.code)）"
    }
}

@MainActor
final class SSHService: ObservableObject {
    @Published var isConnected = false
    @Published var statusText = "未连接"

    private var group: MultiThreadedEventLoopGroup?
    private var parentChannel: Channel?
    private var childChannel: Channel?

    /// SSH → 终端
    var onData: ((Data) -> Void)?
    /// 断开
    var onClose: (() -> Void)?

    func connect(session: Session, password: String, passphrase: String) async {
        await disconnect()
        statusText = "正在连接…"

        do {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(
                        NIOSSHHandler(
                            role: .client(.init(
                                userAuthDelegate: PasswordAuthDelegate(
                                    username: session.username,
                                    password: password
                                ),
                                serverAuthDelegate: AcceptAllHostKeysDelegate()
                            )),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                    )
                }

            let channel = try await bootstrap
                .connect(host: session.host, port: session.port)
                .get()

            self.group = group
            self.parentChannel = channel

            try await openShell(cols: 80, rows: 24)

            self.isConnected = true
            self.statusText = "已连接 · \(session.username)@\(session.host)"
        } catch {
            self.isConnected = false
            self.statusText = "连接失败：\(chineseErrorText(error))"
            await disconnect()
        }
    }

    private func openShell(cols: Int, rows: Int) async throws {
        guard let parentChannel else { throw SSHClientError.notConnected }

        let sshHandler = try await parentChannel.pipeline
            .handler(type: NIOSSHHandler.self)
            .get()

        let childPromise = parentChannel.eventLoop.makePromise(of: Channel.self)

        sshHandler.createChannel(childPromise, channelType: .session) { [weak self] child, channelType in
            guard channelType == .session else {
                return child.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType)
            }

            let handler = InteractiveHandler(
                onData: { data in
                    Task { @MainActor in self?.onData?(data) }
                },
                onClose: {
                    Task { @MainActor in
                        self?.isConnected = false
                        self?.statusText = "连接已关闭"
                        self?.onClose?()
                    }
                }
            )
            return child.pipeline.addHandler(handler)
        }

        let child = try await childPromise.futureResult.get()
        self.childChannel = child

        // 申请 PTY
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: max(cols, 20),
            terminalRowHeight: max(rows, 5),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        let ptyPromise = child.eventLoop.makePromise(of: Void.self)
        child.triggerUserOutboundEvent(ptyRequest, promise: ptyPromise)
        do { try await ptyPromise.futureResult.get() }
        catch { throw SSHClientError.ptyOpenFailed(chineseErrorText(error)) }

        // 请求 Shell
        let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        let shellPromise = child.eventLoop.makePromise(of: Void.self)
        child.triggerUserOutboundEvent(shellRequest, promise: shellPromise)
        do { try await shellPromise.futureResult.get() }
        catch { throw SSHClientError.shellOpenFailed(chineseErrorText(error)) }
    }

    func send(_ data: Data) {
        guard let childChannel else { return }
        var buffer = childChannel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        childChannel.writeAndFlush(NIOAny(channelData), promise: nil)
    }

    func send(text: String) {
        send(Data(text.utf8))
    }

    func resize(cols: Int, rows: Int) {
        guard let childChannel else { return }
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            wantReply: false,
            terminalCharacterWidth: max(cols, 20),
            terminalRowHeight: max(rows, 5),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        childChannel.triggerUserOutboundEvent(request, promise: nil)
    }

    func disconnect() async {
        if let childChannel { try? await childChannel.close().get() }
        if let parentChannel { try? await parentChannel.close().get() }
        if let group { try? await group.shutdownGracefully() }
        childChannel = nil
        parentChannel = nil
        group = nil
        isConnected = false
        statusText = "未连接"
    }
}
