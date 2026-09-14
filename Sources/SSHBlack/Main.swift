import SwiftUI
import Foundation
import UIKit
import Security
import NIOCore
import NIOPosix
import NIOSSH
import SwiftTerm

typealias Color = SwiftUI.Color

// MARK: - 主题
enum Theme {
    static let neon = Color(red: 0.00, green: 0.93, blue: 0.62)
    static let neonSoft = Color(red: 0.00, green: 0.93, blue: 0.62).opacity(0.15)
    static let violet = Color(red: 0.55, green: 0.42, blue: 1.00)
    static let magenta = Color(red: 1.00, green: 0.30, blue: 0.72)
    static let bg = Color(red: 0.02, green: 0.02, blue: 0.04)
    static let bgElev = Color(red: 0.06, green: 0.06, blue: 0.09)
    static let stroke = Color.white.opacity(0.08)
    static let text = Color.white.opacity(0.92)
    static let textDim = Color.white.opacity(0.55)
    static var neonGradient: LinearGradient {
        LinearGradient(colors: [neon, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct PulsingDot: View {
    let color: Color
    @State private var animate = false
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).frame(width: 18, height: 18).scaleEffect(animate ? 1.4 : 0.9).opacity(animate ? 0 : 1)
            Circle().fill(color).frame(width: 8, height: 8)
        }.onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { animate = true } }
    }
}

// MARK: - 模型与存储
struct Session: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    var shortName: String { name.isEmpty ? host : name }
    var displayHost: String { "\(username)@\(host):\(port)" }
}

@MainActor
class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    private let storageKey = "sshblack.sessions.v1"
    init() { load() }
    func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([Session].self, from: data) else { return }
        sessions = list
    }
    func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
    func upsert(_ session: Session) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) { sessions[idx] = session }
        else { sessions.append(session) }
        save()
    }
    func delete(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
        KeychainHelper.delete(account: "session.\(session.id.uuidString).password")
        save()
    }
    func password(for session: Session) -> String { KeychainHelper.read(account: "session.\(session.id.uuidString).password") ?? "" }
    func setPassword(_ password: String, for session: Session) { KeychainHelper.save(password, account: "session.\(session.id.uuidString).password") }
}

// MARK: - Keychain
enum KeychainHelper {
    private static let service = "com.example.sshblack"
    static func save(_ value: String, account: String) {
        guard !value.isEmpty else { delete(account: account); return }
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }
    static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - SSH 认证与处理器
final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String
    init(username: String, password: String) { self.username = username; self.password = password }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "ssh-connection", offer: .password(.init(password: password))))
    }
}

final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

final class InteractiveHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private let onData: (Data) -> Void
    private let onClose: () -> Void
    init(onData: @escaping (Data) -> Void, onClose: @escaping () -> Void) { self.onData = onData; self.onClose = onClose }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        if case .byteBuffer(var buffer) = channelData.data {
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                onData(Data(bytes))
            }
        }
    }
    func channelInactive(context: ChannelHandlerContext) { onClose(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { onClose(); context.close(promise: nil) }
}

// MARK: - SSH 服务
enum SSHClientError: Error, LocalizedError {
    case notConnected, invalidChannelType, ptyOpenFailed(String), shellOpenFailed(String)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "尚未连接服务器"
        case .invalidChannelType: return "无法创建会话通道"
        case .ptyOpenFailed(let s): return "申请终端失败：\(s)"
        case .shellOpenFailed(let s): return "打开 Shell 失败：\(s)"
        }
    }
}

@MainActor
class SSHService: ObservableObject {
    @Published var isConnected = false
    @Published var statusText = "未连接"
    private var group: MultiThreadedEventLoopGroup?
    private var parentChannel: Channel?
    private var childChannel: Channel?
    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?

    func connect(session: Session, password: String) async {
        await disconnect()
        statusText = "正在连接…"
        do {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let bootstrap = ClientBootstrap(group: group).channelInitializer { channel in
                channel.pipeline.addHandler(NIOSSHHandler(
                    role: .client(.init(userAuthDelegate: PasswordAuthDelegate(username: session.username, password: password), serverAuthDelegate: AcceptAllHostKeysDelegate())),
                    allocator: channel.allocator, inboundChildChannelInitializer: nil
                ))
            }
            let channel = try await bootstrap.connect(host: session.host, port: session.port).get()
            self.group = group
            self.parentChannel = channel
            try await openShell(cols: 80, rows: 24)
            self.isConnected = true
            self.statusText = "已连接 · \(session.username)@\(session.host)"
        } catch {
            self.isConnected = false
            self.statusText = "连接失败：\(error.localizedDescription)"
            await disconnect()
        }
    }

    private func openShell(cols: Int, rows: Int) async throws {
        guard let parentChannel = parentChannel else { throw SSHClientError.notConnected }
        let sshHandler = try await parentChannel.pipeline.handler(type: NIOSSHHandler.self).get()
        let childPromise = parentChannel.eventLoop.makePromise(of: Channel.self)
        sshHandler.createChannel(childPromise, channelType: .session) { [weak self] child, channelType in
            guard let self = self, channelType == .session else { return child.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType) }
            return child.pipeline.addHandler(InteractiveHandler(
                onData: { [weak self] data in Task { @MainActor in self?.onData?(data) } },
                onClose: { [weak self] in Task { @MainActor in self?.isConnected = false; self?.statusText = "连接已关闭"; self?.onClose?() } }
            ))
        }
        let child = try await childPromise.futureResult.get()
        self.childChannel = child
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(wantReply: true, term: "xterm-256color", terminalCharacterWidth: max(cols, 20), terminalRowHeight: max(rows, 5), terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
        let ptyPromise = child.eventLoop.makePromise(of: Void.self)
        child.triggerUserOutboundEvent(ptyRequest, promise: ptyPromise)
        do { try await ptyPromise.futureResult.get() } catch { throw SSHClientError.ptyOpenFailed("\(error)") }
        let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        let shellPromise = child.eventLoop.makePromise(of: Void.self)
        child.triggerUserOutboundEvent(shellRequest, promise: shellPromise)
        do { try await shellPromise.futureResult.get() } catch { throw SSHClientError.shellOpenFailed("\(error)") }
    }

    func send(_ data: Data) {
        guard let childChannel = childChannel else { return }
        var buffer = childChannel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        childChannel.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
    }
    func sendText(_ text: String) { send(Data(text.utf8)) }
    func resize(cols: Int, rows: Int) {
        guard let childChannel = childChannel else { return }
        let request = SSHChannelRequestEvent.WindowChangeRequest(terminalCharacterWidth: max(cols, 20), terminalRowHeight: max(rows, 5), terminalPixelWidth: 0, terminalPixelHeight: 0)
        childChannel.triggerUserOutboundEvent(request, promise: nil)
    }
    func disconnect() async {
        if let childChannel = childChannel { try? await childChannel.close().get() }
        if let parentChannel = parentChannel { try? await parentChannel.close().get() }
        if let group = group { try? await group.shutdownGracefully() }
        childChannel = nil; parentChannel = nil; group = nil; isConnected = false; statusText = "未连接"
    }
}

// MARK: - SwiftTerm 终端桥接
extension Terminal {
    func getVisibleText() -> String {
        var result = ""
        for y in 0..<self.rows {
            if let line = self.getLine(row: y) { result += line.translateToString() + "\n" }
        }
        return result
    }
}

final class TerminalBridge: NSObject, TerminalViewDelegate {
    weak var terminalView: TerminalView?
    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    func send(source: TerminalView, data: ArraySlice<UInt8>) { onInput?(Data(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { onResize?(newCols, newRows) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    func clipboardCopy(source: TerminalView, content: Data) { if let str = String(data: content, encoding: .utf8) { UIPasteboard.general.string = str } }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }
}

struct TerminalViewWrapper: UIViewRepresentable {
    @ObservedObject var ssh: SSHService
    let bridge: TerminalBridge
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = bridge
        bridge.terminalView = view
        view.backgroundColor = UIColor(Theme.bg)
        view.nativeBackgroundColor = UIColor(Theme.bg)
        view.nativeForegroundColor = UIColor(Theme.text)
        view.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ssh.onData = { [weak view] data in
            guard let view = view else { return }
            DispatchQueue.main.async { view.feed(byteArray: [UInt8](data)[...]) }
        }
        bridge.onInput = { [weak ssh] data in ssh?.send(data) }
        bridge.onResize = { [weak ssh] cols, rows in ssh?.resize(cols: cols, rows: rows) }
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }
    func updateUIView(_ uiView: TerminalView, context: Context) {}
}

// MARK: - 界面
struct RootView: View {
    var body: some View { NavigationStack { SessionListView() }.tint(Theme.neon) }
}

struct SessionListView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var editing: Session?
    @State private var isNew = false
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            RadialGradient(colors: [Theme.violet.opacity(0.18), .clear], center: .topTrailing, startRadius: 20, endRadius: 480).ignoresSafeArea()
            RadialGradient(colors: [Theme.neon.opacity(0.15), .clear], center: .bottomLeading, startRadius: 20, endRadius: 520).ignoresSafeArea()
            VStack(spacing: 0) { header; content }
        }
        .sheet(item: $editing) { session in SessionEditView(session: session, isNew: isNew).environmentObject(store) }
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("SSH 黑").font(.system(size: 34, weight: .heavy, design: .rounded)).foregroundStyle(Theme.neonGradient)
                Text("\(store.sessions.count) 个会话").font(.caption).foregroundColor(Theme.textDim)
            }
            Spacer()
            Button { isNew = true; editing = Session(name: "", host: "", username: "") } label: {
                Image(systemName: "plus").font(.system(size: 18, weight: .bold)).foregroundColor(.black)
                    .frame(width: 44, height: 44).background(Circle().fill(Theme.neonGradient))
                    .shadow(color: Theme.neon.opacity(0.6), radius: 12)
            }.buttonStyle(.plain)
        }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
    }
    @ViewBuilder private var content: some View {
        if store.sessions.isEmpty {
            VStack(spacing: 18) {
                Spacer()
                ZStack { Circle().fill(Theme.neonSoft).frame(width: 110, height: 110); Image(systemName: "terminal.fill").font(.system(size: 44, weight: .bold)).foregroundStyle(Theme.neonGradient) }
                Text("还没有会话").font(.system(.title3, design: .rounded).weight(.semibold)).foregroundColor(Theme.text)
                Text("点击右上角 + 添加你的第一台服务器").font(.subheadline).foregroundColor(Theme.textDim).multilineTextAlignment(.center).padding(.horizontal, 40)
                Spacer(); Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.sessions) { session in
                        NavigationLink { TerminalScreen(session: session) } label: { SessionCard(session: session) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { isNew = false; editing = session } label: { Label("编辑", systemImage: "square.and.pencil") }
                                Button(role: .destructive) { store.delete(session) } label: { Label("删除", systemImage: "trash") }
                            }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 20)
            }
        }
    }
}

struct SessionCard: View {
    let session: Session
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LinearGradient(colors: [Theme.neon.opacity(0.85), Theme.violet.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 52, height: 52)
                Text(String(session.shortName.prefix(1)).uppercased()).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundColor(.black)
            }.shadow(color: Theme.neon.opacity(0.35), radius: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.shortName).font(.system(.headline, design: .rounded).weight(.semibold)).foregroundColor(Theme.text).lineLimit(1)
                Text(session.displayHost).font(.system(.caption, design: .monospaced)).foregroundColor(Theme.textDim).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.textDim)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bgElev).overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke, lineWidth: 1)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}

struct SessionEditView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State var session: Session
    let isNew: Bool
    @State private var password: String = ""
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        fieldCard { iconField(icon: "textformat", title: "名称") { TextField("例如：生产服务器", text: $session.name).textInputAutocapitalization(.never).autocorrectionDisabled() } }
                        fieldCard { iconField(icon: "globe", title: "主机") { TextField("IP 或域名", text: $session.host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL) }; divider; iconField(icon: "number", title: "端口") { TextField("22", value: $session.port, format: .number).keyboardType(.numberPad) } }
                        fieldCard { iconField(icon: "person", title: "用户名") { TextField("root", text: $session.username).textInputAutocapitalization(.never).autocorrectionDisabled() } }
                        fieldCard { iconField(icon: "lock", title: "密码") { SecureField("登录密码", text: $password) } }
                        Button { saveAndClose() } label: { Text(isNew ? "保存并完成" : "保存修改").frame(maxWidth: .infinity) }
                            .buttonStyle(NeonButtonStyle(enabled: !session.host.isEmpty && !session.username.isEmpty))
                            .disabled(session.host.isEmpty || session.username.isEmpty)
                            .padding(.top, 4)
                    }.padding(20)
                }
            }
            .navigationTitle(isNew ? "新建会话" : "编辑会话").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.foregroundColor(Theme.text) } }
        }.onAppear { password = store.password(for: session) }
    }
    private func fieldCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.bgElev).overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.stroke, lineWidth: 1)))
    }
    private func iconField<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.neon).frame(width: 22)
            Text(title).font(.system(.subheadline, design: .rounded)).foregroundColor(Theme.textDim).frame(width: 52, alignment: .leading)
            content().foregroundColor(Theme.text)
        }.padding(.horizontal, 12).padding(.vertical, 12)
    }
    private var divider: some View { Rectangle().frame(height: 1).foregroundColor(Theme.stroke).padding(.leading, 44) }
    private func saveAndClose() { if session.name.isEmpty { session.name = session.host }; store.upsert(session); store.setPassword(password, for: session); dismiss() }
}

struct NeonButtonStyle: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.body, design: .rounded).weight(.semibold)).foregroundColor(.black)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Group { if enabled { Theme.neonGradient } else { Color.white.opacity(0.1) } })
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: enabled ? Theme.neon.opacity(0.45) : .clear, radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25), value: configuration.isPressed)
    }
}

// MARK: - 终端页面
struct TerminalScreen: View {
    let session: Session
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ssh = SSHService()
    @State private var bridge = TerminalBridge()
    @State private var toast: String?
    @State private var showBufferSheet = false
    @State private var bufferLines: [String] = []
    @State private var showSystemKeyboard = false
    
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                statusBar
                terminalArea
                if !showSystemKeyboard {
                    CustomKeyPanel(
                        onKey: { key in ssh.send(key.bytes) },
                        onText: { text in ssh.sendText(text) },
                        onToggleKeyboard: { toggleKeyboard() }
                    )
                }
            }
        }
        .navigationBarBackButtonHidden(true).toolbar(.hidden, for: .navigationBar).overlay(alignment: .top) { toastView }
        .sheet(isPresented: $showBufferSheet) {
            BufferSheet(lines: bufferLines) { text in copy(text, tip: "已复制该行") }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            let pw = KeychainHelper.read(account: "session.\(session.id.uuidString).password") ?? ""
            await ssh.connect(session: session, password: pw)
        }
        .onDisappear { Task { await ssh.disconnect() } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in showSystemKeyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in showSystemKeyboard = false }
    }

    private func toggleKeyboard() {
        if showSystemKeyboard {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        } else {
            UIApplication.shared.sendAction(#selector(UIResponder.becomeFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Button { Task { await ssh.disconnect(); dismiss() } } label: { Image(systemName: "chevron.left").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.neon).padding(8).background(Circle().fill(Theme.neonSoft)) }
            PulsingDot(color: ssh.isConnected ? Theme.neon : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.shortName).font(.system(.subheadline, design: .rounded).weight(.semibold)).foregroundColor(Theme.text).lineLimit(1)
                Text(ssh.statusText).font(.caption2.monospaced()).foregroundColor(Theme.textDim).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            // 右上角：打开日志面板，支持单行/任意复制
            Button { collectBufferAndOpen() } label: { Image(systemName: "doc.text.magnifyingglass").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.neon).padding(8).background(Circle().fill(Theme.neonSoft)) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(LinearGradient(colors: [Color.black.opacity(0.95), Color.black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.stroke), alignment: .bottom)
    }

    private var terminalArea: some View { TerminalViewWrapper(ssh: ssh, bridge: bridge).background(Theme.bg) }

    private var toastView: some View {
        Group {
            if let toast = toast {
                Text(toast).font(.system(.caption, design: .rounded).weight(.medium)).foregroundColor(.black).padding(.horizontal, 14).padding(.vertical, 8).background(Capsule().fill(Theme.neon)).shadow(color: Theme.neon.opacity(0.5), radius: 10).padding(.top, 60).transition(.move(edge: .top).combined(with: .opacity))
            }
        }.animation(.spring(response: 0.3), value: toast)
    }

    private func collectBufferAndOpen() {
        guard let view = bridge.terminalView else { showToast("暂无可复制内容"); return }
        let raw = view.getTerminal().getVisibleText()
        bufferLines = raw.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        showBufferSheet = true
    }

    private func copy(_ text: String, tip: String) { UIPasteboard.general.string = text; UIImpactFeedbackGenerator(style: .medium).impactOccurred(); showToast(tip) }
    private func showToast(_ text: String) { withAnimation { toast = text }; DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { toast = nil } } }
}

// MARK: - 自定义底部键盘面板
struct CustomKeyPanel: View {
    let onKey: (TerminalKey) -> Void
    let onText: (String) -> Void
    let onToggleKeyboard: () -> Void
    
    var body: some View {
        VStack(spacing: 6) {
            // 第一行：控制栏
            HStack(spacing: 8) {
                // 左边：收起（隐藏键盘/面板）
                Button {
                    onToggleKeyboard()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "keyboard.chevron.compact.down")
                        Text("收起")
                    }
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.3)))
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // 中间：系统键盘
                Button {
                    onToggleKeyboard()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "keyboard")
                        Text("系统键盘")
                    }
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.2)))
                }
                .buttonStyle(.plain)
                
                // 粘贴按钮
                Button {
                    if let str = UIPasteboard.general.string {
                        onText(str)
                    }
                } label: {
                    Text("粘贴")
                        .font(.system(.footnote, design: .rounded).weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.5)))
                }
                .buttonStyle(.plain)
                
                // 回车键（大号蓝色）
                Button {
                    onKey(.enter)
                } label: {
                    Text("回车")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            
            // 第二行：数字及常用键
            HStack(spacing: 4) {
                ForEach(["1","2","3","4","5","6","7","8","9","0","-"], id: \.self) { digit in
                    Button {
                        onText(digit)
                    } label: {
                        Text(digit)
                            .font(.system(.footnote, design: .monospaced).weight(.medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            
            // 第三行：快捷键区
            HStack(spacing: 4) {
                // 字母/短语键
                Button { onText("x-ui") } label: { keyButtonLabel("x-ui", color: .gray.opacity(0.25)) }
                Button { onText("88") } label: { keyButtonLabel("88", color: .gray.opacity(0.25)) }
                Button { onText("k") } label: { keyButtonLabel("k", color: .gray.opacity(0.25)) }
                Button { onText(" ") } label: { keyButtonLabel("空格", color: .gray.opacity(0.25)) }
                Button { onKey(.backspace) } label: { keyButtonLabel("⌫", color: .gray.opacity(0.25)) }
                
                Spacer()
                
                // 特殊功能键（带颜色）
                Button { onKey(.ctrlC) } label: { keyButtonLabel("Ctrl+C", color: .red.opacity(0.7)) }
                Button { onKey(.esc) } label: { keyButtonLabel("ESC", color: .orange.opacity(0.7)) }
                Button { onKey(.tab) } label: { keyButtonLabel("Tab", color: .gray.opacity(0.25)) }
                Button { onKey(.arrowUp) } label: { keyButtonLabel("↑", color: .gray.opacity(0.25)) }
                Button { onKey(.arrowDown) } label: { keyButtonLabel("↓", color: .gray.opacity(0.25)) }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.stroke), alignment: .top)
    }
    
    private func keyButtonLabel(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(.footnote, design: .monospaced).weight(.medium))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(color))
    }
}

enum TerminalKey: CaseIterable {
    case esc, tab, ctrlC, arrowUp, arrowDown, enter, backspace
    var label: String {
        switch self {
        case .esc: return "Esc"
        case .tab: return "Tab"
        case .ctrlC: return "^C"
        case .arrowUp: return "↑"
        case .arrowDown: return "↓"
        case .enter: return "回车"
        case .backspace: return "⌫"
        }
    }
    var bytes: Data {
        switch self {
        case .esc: return Data([0x1B])
        case .tab: return Data([0x09])
        case .ctrlC: return Data([0x03])
        case .arrowUp: return Data([0x1B, 0x5B, 0x41])
        case .arrowDown: return Data([0x1B, 0x5B, 0x42])
        case .enter: return Data([0x0D])
        case .backspace: return Data([0x7F])
        }
    }
}

// MARK: - 输出历史/复制面板
struct BufferSheet: View {
    let lines: [String]
    let onCopy: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                if lines.isEmpty {
                    Text("暂无输出").foregroundColor(Theme.textDim)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(line)
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(Theme.text)
                                        .textSelection(.enabled) // 支持任意选中字符
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    // 单行复制按钮
                                    Button {
                                        onCopy(line)
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .font(.caption)
                                            .foregroundColor(Theme.neon)
                                            .padding(6)
                                            .background(Circle().fill(Theme.neonSoft))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Theme.bgElev)
                                )
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle("输出日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("复制全部") {
                        onCopy(lines.joined(separator: "\n"))
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - 应用入口
@main
struct SSHBlackApp: App {
    @StateObject private var store = SessionStore()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).preferredColorScheme(.dark)
        }
    }
}
