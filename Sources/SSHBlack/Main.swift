import SwiftUI
import Foundation
import UIKit
import Security
import NIOCore
import NIOPosix
import NIOSSH
import SwiftTerm

typealias Color = SwiftUI.Color

// MARK: - 蓝黑主题
enum Theme {
    static let blue        = Color(red: 0.00, green: 0.48, blue: 1.00)
    static let blueSoft    = Color(red: 0.00, green: 0.48, blue: 1.00).opacity(0.15)
    static let bg          = Color(red: 0.02, green: 0.04, blue: 0.08)
    static let bgElev      = Color(red: 0.06, green: 0.09, blue: 0.15)
    static let stroke      = Color.white.opacity(0.08)
    static let text        = Color.white.opacity(0.92)
    static let textDim     = Color.white.opacity(0.55)
    static let red         = Color(red: 1.00, green: 0.30, blue: 0.30)
    static let orange      = Color(red: 1.00, green: 0.58, blue: 0.00)
    static let magenta     = Color(red: 1.00, green: 0.40, blue: 0.80)
}

// MARK: - 快捷指令模型
struct Shortcut: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var command: String
}

@MainActor
class ShortcutStore: ObservableObject {
    @Published var shortcuts: [Shortcut] = []
    private let key = "sshblack.shortcuts.v1"
    
    init() { load() }
    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Shortcut].self, from: data) else {
            shortcuts = [
                Shortcut(name: "输入 k 菜单", command: "k"),
                Shortcut(name: "面板管理 (x-ui)", command: "x-ui"),
                Shortcut(name: "查看文件 (ls)", command: "ls -la"),
                Shortcut(name: "磁盘空间", command: "df -h")
            ]
            return
        }
        shortcuts = list
    }
    func save() {
        guard let data = try? JSONEncoder().encode(shortcuts) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    func add(_ s: Shortcut) { shortcuts.append(s); save() }
    func delete(_ s: Shortcut) { shortcuts.removeAll { $0.id == s.id }; save() }
}

// MARK: - 会话模型
struct Session: Identifiable, Codable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    var shortName: String { name.isEmpty ? host : name }
    var displayHost: String { "\(username)@\(host):\(port)" }
}

class SessionStore: ObservableObject {
    @Published var sessions: [Session] = []
    private let key = "sshblack.sessions.v1"
    init() { load() }
    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Session].self, from: data) else { return }
        sessions = list
    }
    func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    func upsert(_ s: Session) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s }
        else { sessions.append(s) }
        save()
    }
    func delete(_ s: Session) {
        sessions.removeAll { $0.id == s.id }
        KeychainHelper.delete(account: "session.\(s.id.uuidString).password")
        save()
    }
    func password(for s: Session) -> String { KeychainHelper.read(account: "session.\(s.id.uuidString).password") ?? "" }
    func setPassword(_ p: String, for s: Session) { KeychainHelper.save(p, account: "session.\(s.id.uuidString).password") }
}

enum KeychainHelper {
    static func save(_ value: String, account: String) {
        guard !value.isEmpty else { delete(account: account); return }
        let data = Data(value.utf8)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "sshblack", kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var attrs = q
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }
    static func read(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "sshblack", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data, let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }
    static func delete(account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "sshblack", kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - SSH 服务
final class PasswordAuth: NIOSSHClientUserAuthenticationDelegate {
    let u: String; let p: String
    init(u: String, p: String) { self.u = u; self.p = p }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: u, serviceName: "ssh-connection", offer: .password(.init(password: p))))
    }
}

final class AcceptAllHostKeys: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

final class DataHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let onData: (Data) -> Void
    let onClose: () -> Void
    init(onData: @escaping (Data) -> Void, onClose: @escaping () -> Void) { self.onData = onData; self.onClose = onClose }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        if case .byteBuffer(var b) = d.data {
            if let bytes = b.readBytes(length: b.readableBytes) { onData(Data(bytes)) }
        }
    }
    func channelInactive(context: ChannelHandlerContext) { onClose(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { onClose(); context.close(promise: nil) }
}

@MainActor
class SSHService: ObservableObject, Identifiable {
    let id = UUID()
    @Published var isConnected = false
    @Published var statusText = "未连接"
    private var group: MultiThreadedEventLoopGroup?
    private var parent: Channel?
    private var child: Channel?
    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?
    
    func connect(session: Session, password: String) async {
        await disconnect()
        statusText = "正在连接…"
        do {
            let g = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let bootstrap = ClientBootstrap(group: g).channelInitializer { ch in
                ch.pipeline.addHandler(NIOSSHHandler(
                    role: .client(.init(userAuthDelegate: PasswordAuth(u: session.username, p: password), serverAuthDelegate: AcceptAllHostKeys())),
                    allocator: ch.allocator, inboundChildChannelInitializer: nil
                ))
            }
            let ch = try await bootstrap.connect(host: session.host, port: session.port).get()
            self.group = g; self.parent = ch
            try await openShell(cols: 80, rows: 24)
            self.isConnected = true
            self.statusText = "已连接 · \(session.username)@\(session.host)"
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.sendText("clear\n")
            }
        } catch {
            self.isConnected = false
            self.statusText = "连接失败：\(error.localizedDescription)"
            await disconnect()
        }
    }
    
    private func openShell(cols: Int, rows: Int) async throws {
        guard let p = parent else { throw NSError(domain: "ssh", code: 1) }
        let h = try await p.pipeline.handler(type: NIOSSHHandler.self).get()
        let cp = p.eventLoop.makePromise(of: Channel.self)
        h.createChannel(cp, channelType: .session) { [weak self] child, _ in
            guard let self = self else { return child.eventLoop.makeFailedFuture(NSError(domain: "ssh", code: 2)) }
            return child.pipeline.addHandler(DataHandler(
                onData: { [weak self] d in Task { @MainActor in self?.onData?(d) } },
                onClose: { [weak self] in Task { @MainActor in self?.isConnected = false; self?.statusText = "连接已断开"; self?.onClose?() } }
            ))
        }
        let c = try await cp.futureResult.get()
        self.child = c
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(wantReply: true, term: "xterm-256color", terminalCharacterWidth: max(cols, 20), terminalRowHeight: max(rows, 5), terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
        let pp = c.eventLoop.makePromise(of: Void.self)
        c.triggerUserOutboundEvent(pty, promise: pp)
        try await pp.futureResult.get()
        let sh = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        let sp = c.eventLoop.makePromise(of: Void.self)
        c.triggerUserOutboundEvent(sh, promise: sp)
        try await sp.futureResult.get()
    }
    
    func send(_ data: Data) {
        guard let c = child else { return }
        var b = c.allocator.buffer(capacity: data.count)
        b.writeBytes(data)
        c.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(b))), promise: nil)
    }
    func sendText(_ t: String) { send(Data(t.utf8)) }
    func resize(cols: Int, rows: Int) {
        guard let c = child else { return }
        let r = SSHChannelRequestEvent.WindowChangeRequest(terminalCharacterWidth: max(cols, 20), terminalRowHeight: max(rows, 5), terminalPixelWidth: 0, terminalPixelHeight: 0)
        c.triggerUserOutboundEvent(r, promise: nil)
    }
    func disconnect() async {
        if let c = child { try? await c.close().get() }
        if let p = parent { try? await p.close().get() }
        if let g = group { try? await g.shutdownGracefully() }
        child = nil; parent = nil; group = nil; isConnected = false; statusText = "未连接"
    }
}

// MARK: - 全局 SSH 管理器
@MainActor
class SSHManager: ObservableObject {
    static let shared = SSHManager()
    @Published var services: [UUID: SSHService] = [:]
    func service(for session: Session) -> SSHService {
        if let s = services[session.id] { return s }
        let s = SSHService()
        services[session.id] = s
        return s
    }
}

// MARK: - SwiftTerm 终端桥接
extension Terminal {
    func getVisibleText() -> String {
        var r = ""
        for y in 0..<self.rows {
            if let line = self.getLine(row: y) { r += line.translateToString() + "\n" }
        }
        return r
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
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) { if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s } }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
}

// MARK: - 键盘互斥核心逻辑
enum KeyboardMode {
    case custom
    case system
    case hidden
}

struct TerminalWrapper: UIViewRepresentable {
    @ObservedObject var ssh: SSHService
    let bridge: TerminalBridge
    @Binding var keyboardMode: KeyboardMode

    func makeUIView(context: Context) -> TerminalView {
        let v = TerminalView(frame: .zero)
        v.terminalDelegate = bridge
        bridge.terminalView = v
        v.backgroundColor = UIColor(Theme.bg)
        v.nativeBackgroundColor = UIColor(Theme.bg)
        v.nativeForegroundColor = UIColor(Theme.text)
        
        // 使用 Menlo 等宽字体，解决中文宽度和字体发虚问题
        v.font = UIFont(name: "Menlo", size: 14) ?? UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        
        ssh.onData = { [weak v] d in
            guard let v = v else { return }
            DispatchQueue.main.async { v.feed(byteArray: [UInt8](d)[...]) }
        }
        bridge.onInput = { [weak ssh] d in ssh?.send(d) }
        bridge.onResize = { [weak ssh] c, r in ssh?.resize(cols: c, rows: r) }
        
        DispatchQueue.main.async {
            let d = v.getTerminal().getDims()
            ssh.resize(cols: d.cols, rows: d.rows)
        }
        return v
    }
    
    func updateUIView(_ v: TerminalView, context: Context) {
        // 核心修复：当不是系统键盘模式时，强制让它交出第一响应者
        if keyboardMode == .system {
            if !v.isFirstResponder {
                v.becomeFirstResponder()
            }
        } else {
            if v.isFirstResponder {
                v.resignFirstResponder()
            }
        }
    }
}

// MARK: - 主界面
struct RootView: View {
    var body: some View { NavigationStack { SessionListView() }.tint(Theme.blue) }
}

struct SessionListView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var shortcutStore: ShortcutStore
    @State var editing: Session?
    @State var isNew = false
    @State var showShortcuts = false
    
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SSH 黑").font(.system(size: 34, weight: .heavy, design: .rounded)).foregroundColor(Theme.blue)
                        Text("\(store.sessions.count) 个会话").font(.caption).foregroundColor(Theme.textDim)
                    }
                    Spacer()
                    Button { showShortcuts = true } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 18, weight: .bold)).foregroundColor(Theme.blue)
                            .frame(width: 40, height: 40).background(Circle().fill(Theme.blueSoft))
                    }
                    Button { isNew = true; editing = Session(name: "", host: "", username: "") } label: {
                        Image(systemName: "plus").font(.system(size: 18, weight: .bold)).foregroundColor(.black)
                            .frame(width: 40, height: 40).background(Circle().fill(Theme.blue))
                    }
                }.padding()
                
                if store.sessions.isEmpty {
                    Spacer()
                    Text("还没有会话").foregroundColor(Theme.textDim)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.sessions) { s in
                                NavigationLink {
                                    TerminalScreen(session: s)
                                } label: {
                                    HStack {
                                        Text(s.shortName).font(.headline).foregroundColor(Theme.text)
                                        Spacer()
                                        Text(s.displayHost).font(.caption).foregroundColor(Theme.textDim)
                                    }
                                    .padding()
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bgElev))
                                }
                                .contextMenu {
                                    Button { isNew = false; editing = s } label: { Label("编辑", systemImage: "square.and.pencil") }
                                    Button(role: .destructive) { store.delete(s) } label: { Label("删除", systemImage: "trash") }
                                }
                            }
                        }.padding()
                    }
                }
            }
        }
        .sheet(item: $editing) { s in SessionEditView(session: s, isNew: isNew).environmentObject(store) }
        .sheet(isPresented: $showShortcuts) { ShortcutEditView().environmentObject(shortcutStore) }
    }
}

struct ShortcutEditView: View {
    @EnvironmentObject var store: ShortcutStore
    @Environment(\.dismiss) var dismiss
    @State var newName = ""
    @State var newCmd = ""
    
    var body: some View {
        NavigationStack {
            List {
                Section("添加快捷指令") {
                    TextField("名称 (如: 查看磁盘)", text: $newName)
                    TextField("命令 (如: df -h)", text: $newCmd)
                    Button("添加") {
                        guard !newName.isEmpty, !newCmd.isEmpty else { return }
                        store.add(Shortcut(name: newName, command: newCmd))
                        newName = ""; newCmd = ""
                    }
                }
                Section("已保存") {
                    ForEach(store.shortcuts) { s in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(s.name).font(.headline)
                                Text(s.command).font(.caption).foregroundColor(.gray)
                            }
                            Spacer()
                            Button(role: .destructive) { store.delete(s) } label: { Image(systemName: "trash") }
                        }
                    }
                }
            }
            .navigationTitle("快捷指令管理")
            .toolbar { Button("关闭") { dismiss() } }
        }
    }
}

struct SessionEditView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) var dismiss
    @State var session: Session
    let isNew: Bool
    @State var password = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $session.name)
                TextField("主机", text: $session.host)
                TextField("端口", value: $session.port, format: .number)
                TextField("用户名", text: $session.username)
                SecureField("密码", text: $password)
                Button("保存") {
                    if session.name.isEmpty { session.name = session.host }
                    store.upsert(session)
                    store.setPassword(password, for: session)
                    dismiss()
                }
            }
            .navigationTitle(isNew ? "新建" : "编辑")
            .toolbar { Button("取消") { dismiss() } }
        }
        .onAppear { password = store.password(for: session) }
    }
}

// MARK: - 终端页面
struct TerminalScreen: View {
    let session: Session
    @EnvironmentObject var shortcutStore: ShortcutStore
    @Environment(\.dismiss) var dismiss
    
    @StateObject private var ssh: SSHService
    @State private var bridge = TerminalBridge()
    @State private var toast: String?
    @State private var showLog = false
    @State private var lines: [String] = []
    @State private var showShortcuts = false
    @State private var keyboardMode: KeyboardMode = .custom
    
    init(session: Session) {
        self.session = session
        _ssh = StateObject(wrappedValue: SSHManager.shared.service(for: session))
    }
    
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.blue).padding(8).background(Circle().fill(Theme.blueSoft))
                    }
                    Circle().fill(ssh.isConnected ? Color.green : Theme.red).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.shortName).font(.system(.subheadline, design: .rounded).weight(.semibold)).foregroundColor(Theme.text).lineLimit(1)
                        Text(ssh.statusText).font(.caption2.monospaced()).foregroundColor(Theme.textDim).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button { collectAndOpen() } label: { Image(systemName: "doc.text.magnifyingglass").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.blue).padding(8).background(Circle().fill(Theme.blueSoft)) }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.black.opacity(0.8))
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button { showShortcuts = true } label: {
                            Text("+ 添加").font(.system(.caption, design: .rounded).weight(.medium)).foregroundColor(Theme.blue)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.blueSoft))
                        }
                        ForEach(shortcutStore.shortcuts) { s in
                            Button { ssh.sendText(s.command + "\n") } label: {
                                Text(s.name).font(.system(.caption, design: .rounded).weight(.medium)).foregroundColor(Theme.blue)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.blueSoft))
                            }
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 6)
                }
                .background(Color.black.opacity(0.5))
                .sheet(isPresented: $showShortcuts) { ShortcutEditView().environmentObject(shortcutStore) }
                
                ZStack {
                    TerminalWrapper(ssh: ssh, bridge: bridge, keyboardMode: $keyboardMode)
                        .background(Theme.bg)
                    
                    if keyboardMode == .hidden {
                        Color.clear.contentShape(Rectangle()).onTapGesture {
                            keyboardMode = .custom
                        }
                    }
                }
                
                if keyboardMode == .custom {
                    CustomKeyPanel(
                        onKey: { ssh.send($0) },
                        onText: { ssh.sendText($0) },
                        onHide: { keyboardMode = .hidden },
                        onSwitchToSystem: { keyboardMode = .system }
                    )
                } else if keyboardMode == .hidden {
                    HStack {
                        Button { keyboardMode = .custom } label: {
                            HStack(spacing: 4) { Image(systemName: "keyboard"); Text("微缩键盘") }
                                .font(.system(size: 13, weight: .medium)).foregroundColor(Theme.blue)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.blueSoft))
                        }
                        Spacer()
                        Text("已在线").font(.caption).foregroundColor(Theme.textDim)
                        Spacer()
                        Button { ssh.send(Data([0x0D])) } label: {
                            Text("回车").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                                .padding(.horizontal, 20).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.blue))
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color.black.opacity(0.8))
                }
            }
        }
        .navigationBarBackButtonHidden(true).toolbar(.hidden, for: .navigationBar).overlay(alignment: .top) { toastView }
        .sheet(isPresented: $showLog) {
            NavigationStack {
                List {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack {
                            Text(line).font(.footnote).textSelection(.enabled)
                            Spacer()
                            Button { UIPasteboard.general.string = line } label: { Image(systemName: "doc.on.doc").foregroundColor(Theme.blue) }
                        }
                    }
                }
                .navigationTitle("输出历史 / 快捷复制")
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("关闭") { showLog = false } }; ToolbarItem(placement: .topBarTrailing) { Button("复制全部") { UIPasteboard.general.string = lines.joined(separator: "\n") } } }
            }
        }
        .task {
            let pw = KeychainHelper.read(account: "session.\(session.id.uuidString).password") ?? ""
            if !ssh.isConnected { await ssh.connect(session: session, password: pw) }
        }
        .onDisappear { }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            if keyboardMode == .system { keyboardMode = .custom }
        }
    }
    
    private var toastView: some View {
        Group {
            if let toast = toast {
                Text(toast).font(.system(.caption, design: .rounded).weight(.medium)).foregroundColor(.black)
                    .padding(.horizontal, 14).padding(.vertical, 8).background(Capsule().fill(Theme.blue))
                    .padding(.top, 60).transition(.move(edge: .top).combined(with: .opacity))
            }
        }.animation(.spring(response: 0.3), value: toast)
    }
    
    private func collectAndOpen() {
        guard let v = bridge.terminalView else { return }
        let raw = v.getTerminal().getVisibleText()
        lines = raw.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        showLog = true
    }
}

struct CustomKeyPanel: View {
    let onKey: (Data) -> Void
    let onText: (String) -> Void
    let onHide: () -> Void
    let onSwitchToSystem: () -> Void
    
    let leftKeys: [[String]] = [
        ["1","2","3","4","5","k"],
        ["6","7","8","9","0","-"]
    ]
    
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button { onHide() } label: {
                    HStack(spacing: 4) { Image(systemName: "keyboard.chevron.compact.down"); Text("收起") }
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.3)))
                }.buttonStyle(.plain)
                
                Spacer()
                
                Button { onSwitchToSystem() } label: {
                    HStack(spacing: 4) { Image(systemName: "keyboard"); Text("系统键盘") }
                        .font(.system(size: 13, weight: .medium)).foregroundColor(Theme.orange)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.orange.opacity(0.2)))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.top, 6)
            
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 4) {
                    ForEach(leftKeys.indices, id: \.self) { idx in
                        HStack(spacing: 4) {
                            ForEach(leftKeys[idx], id: \.self) { key in
                                Button { onText(key) } label: {
                                    Text(key).font(.system(size: 14, weight: .medium)).foregroundColor(.white)
                                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.25)))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    
                    HStack(spacing: 4) {
                        Button { onKey(Data([0x03])) } label: {
                            Text("Ctrl+C").font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.red))
                        }.buttonStyle(.plain)
                        Button { onKey(Data([0x1B])) } label: {
                            Text("ESC").font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.orange))
                        }.buttonStyle(.plain)
                        Button { onText(" ") } label: {
                            Text("空格").font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.25)))
                        }.buttonStyle(.plain)
                        Button { onKey(Data([0x7F])) } label: {
                            Image(systemName: "delete.left").font(.system(size: 14)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.25)))
                        }.buttonStyle(.plain)
                    }
                    
                    HStack(spacing: 4) {
                        Button { onText("x-ui") } label: { keyButtonLabel("x-ui", color: Color.gray.opacity(0.25)) }
                        Button { onText("88") } label: { keyButtonLabel("88", color: Color.gray.opacity(0.25)) }
                        Button { onText("q") } label: { keyButtonLabel("q退出", color: Theme.magenta) }
                    }
                }
                
                VStack(spacing: 4) {
                    Button { 
                        if let str = UIPasteboard.general.string { onText(str) }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                            Text("粘贴").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(width: 80, height: 56)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.blue))
                    }.buttonStyle(.plain)
                    
                    Button { onKey(Data([0x0D])) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "return")
                            Text("回车").font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(width: 80, height: 56)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.blue))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
        }
        .background(Color(red: 0.06, green: 0.09, blue: 0.15))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.stroke), alignment: .top)
    }
    
    private func keyButtonLabel(_ title: String, color: Color) -> some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 5).fill(color))
    }
}

@main
struct SSHBlackApp: App {
    @StateObject var store = SessionStore()
    @StateObject var shortcutStore = ShortcutStore()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(shortcutStore)
                .preferredColorScheme(.dark)
        }
    }
}
