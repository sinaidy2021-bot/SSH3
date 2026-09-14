import SwiftUI
import Foundation
import UIKit
import Security
import Crypto
import CoreText
import NIOCore
import NIOPosix
import NIOSSH
import SwiftTerm

typealias Color = SwiftUI.Color

// MARK: - 字体：注册内置 Sarasa Mono SC（中英文等宽），查找时多重兜底
enum FontLoader {
    static func registerFonts() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) else { return }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
    static func monoFont(size: CGFloat) -> UIFont {
        let names = ["SarasaMonoSC-Regular", "SarasaMonoSC", "Sarasa Mono SC"]
        for n in names {
            if let f = UIFont(name: n, size: size) { return f }
        }
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

// MARK: - 主题
enum Theme {
    static let blue = Color(red: 0.00, green: 0.48, blue: 1.00)
    static let blueSoft = Color(red: 0.00, green: 0.48, blue: 1.00).opacity(0.15)
    static let bg = Color(red: 0.02, green: 0.04, blue: 0.08)
    static let bgElev = Color(red: 0.06, green: 0.09, blue: 0.15)
    static let stroke = Color.white.opacity(0.08)
    static let text = Color.white.opacity(0.92)
    static let textDim = Color.white.opacity(0.55)
    static let red = Color(red: 1.00, green: 0.30, blue: 0.30)
    static let orange = Color(red: 1.00, green: 0.58, blue: 0.00)
    static let magenta = Color(red: 1.00, green: 0.40, blue: 0.80)
    static let green = Color(red: 0.20, green: 0.85, blue: 0.40)
}

// MARK: - 命令历史
struct CommandRecord: Identifiable {
    let id = UUID()
    var command: String
    var output: String = ""
}

// MARK: - 着色
enum TerminalColorizer {
    static let reset = "\u{1B}[0m"
    static let red = "\u{1B}[31m"
    static let green = "\u{1B}[32m"
    static let yellow = "\u{1B}[33m"
    static let blue = "\u{1B}[34m"
    static let cyan = "\u{1B}[36m"
    static let underline = "\u{1B}[4m"
    static let errorK = ["error","failed","fail","fatal","denied","refused","exception"]
    static let successK = ["success","ok","done","complete","finished","running"]
    static let warnK = ["warning","warn","deprecated"]
    static func colorize(_ text: String) -> String {
        if text.contains("\u{1B}[") { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        for line in lines {
            if line.isEmpty { out.append(line); continue }
            let lower = line.lowercased()
            var c = line
            if errorK.contains(where: { lower.contains($0) }) { c = red + line + reset }
            else if successK.contains(where: { lower.contains($0) }) { c = green + line + reset }
            else if warnK.contains(where: { lower.contains($0) }) { c = yellow + line + reset }
            else if line.range(of: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, options: .regularExpression) != nil { c = cyan + line + reset }
            else if line.contains("http://") || line.contains("https://") { c = blue + underline + line + reset }
            out.append(c)
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - 快捷指令
struct Shortcut: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var command: String
}
@MainActor class ShortcutStore: ObservableObject {
    @Published var shortcuts: [Shortcut] = []
    private let key = "sshblack.shortcuts.v1"
    init() { load() }
    func load() {
        guard let d = UserDefaults.standard.data(forKey: key), let l = try? JSONDecoder().decode([Shortcut].self, from: d) else {
            shortcuts = [Shortcut(name:"输入 k 菜单",command:"k"),Shortcut(name:"面板管理 (x-ui)",command:"x-ui"),Shortcut(name:"查看文件 (ls)",command:"ls -la"),Shortcut(name:"磁盘空间",command:"df -h")]
            return
        }
        shortcuts = l
    }
    func save() { if let d = try? JSONEncoder().encode(shortcuts) { UserDefaults.standard.set(d, forKey: key) } }
    func add(_ s: Shortcut) { shortcuts.append(s); save() }
    func delete(_ s: Shortcut) { shortcuts.removeAll { $0.id == s.id }; save() }
}

// MARK: - 会话
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
    func load() { if let d = UserDefaults.standard.data(forKey: key), let l = try? JSONDecoder().decode([Session].self, from: d) { sessions = l } }
    func save() { if let d = try? JSONEncoder().encode(sessions) { UserDefaults.standard.set(d, forKey: key) } }
    func upsert(_ s: Session) { if let i = sessions.firstIndex(where: {$0.id == s.id}) { sessions[i]=s } else { sessions.append(s) }; save() }
    func delete(_ s: Session) { sessions.removeAll { $0.id == s.id }; KeychainHelper.delete(account: "session.\(s.id.uuidString).password"); save() }
    func password(for s: Session) -> String { KeychainHelper.read(account: "session.\(s.id.uuidString).password") ?? "" }
    func setPassword(_ p: String, for s: Session) { KeychainHelper.save(p, account: "session.\(s.id.uuidString).password") }
}

// MARK: - Keychain
enum KeychainHelper {
    private static let service = "com.example.sshblack"
    static func save(_ v: String, account: String) {
        guard !v.isEmpty else { delete(account: account); return }
        let q: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
        SecItemDelete(q as CFDictionary); var a = q
        a[kSecValueData as String] = Data(v.utf8); a[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(a as CFDictionary, nil)
    }
    static func read(account: String) -> String? {
        let q: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var i: AnyObject?; guard SecItemCopyMatching(q as CFDictionary, &i) == errSecSuccess, let d = i as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(account: String) {
        let q: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - SSH 认证
enum SSHClientError: Error, LocalizedError {
    case notConnected, hostKeyChanged(String)
    var errorDescription: String? {
        switch self { case .notConnected: return "未连接"; case .hostKeyChanged(let f): return "⚠️ 主机密钥变更：\(f)" }
    }
}
final class PasswordAuth: NIOSSHClientUserAuthenticationDelegate {
    let u: String; let p: String
    init(u: String, p: String) { self.u = u; self.p = p }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: u, serviceName: "ssh-connection", offer: .password(.init(password: p))))
    }
}
final class TOFUHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    let host: String; let port: Int
    init(host: String, port: Int) { self.host = host; self.port = port }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let desc = String(describing: hostKey)
        let fp = SHA256.hash(data: Data(desc.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        let acct = "hostkey.\(host):\(port)"
        if let saved = KeychainHelper.read(account: acct) {
            saved == fp ? validationCompletePromise.succeed(()) : validationCompletePromise.fail(SSHClientError.hostKeyChanged(fp))
        } else { KeychainHelper.save(fp, account: acct); validationCompletePromise.succeed(()) }
    }
}
final class DataHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let onData: (Data) -> Void; let onClose: () -> Void
    init(onData: @escaping (Data) -> Void, onClose: @escaping () -> Void) { self.onData = onData; self.onClose = onClose }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        if case .byteBuffer(var b) = d.data, let bytes = b.readBytes(length: b.readableBytes) { onData(Data(bytes)) }
    }
    func channelInactive(context: ChannelHandlerContext) { onClose(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { onClose(); context.close(promise: nil) }
}

// MARK: - SSH 服务
@MainActor
class SSHService: ObservableObject, Identifiable {
    let id = UUID()
    @Published var isConnected = false
    @Published var statusText = "未连接"
    @Published var commandHistory: [CommandRecord] = []

    private var group: MultiThreadedEventLoopGroup?
    private var parent: Channel?
    private var child: Channel?
    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?

    private var initialBuffer = ""
    private var isFiltering = false
    private var timeoutWork: DispatchWorkItem?
    private var pendingInput = ""

    func connect(session: Session, password: String) async {
        await disconnect()
        statusText = "正在连接…"
        isFiltering = true; initialBuffer = ""; commandHistory.removeAll(); pendingInput = ""
        do {
            let g = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let keyDel = TOFUHostKeyDelegate(host: session.host, port: session.port)
            let bs = ClientBootstrap(group: g).channelInitializer { ch in
                ch.pipeline.addHandler(NIOSSHHandler(
                    role: .client(.init(userAuthDelegate: PasswordAuth(u: session.username, p: password), serverAuthDelegate: keyDel)),
                    allocator: ch.allocator, inboundChildChannelInitializer: nil))
            }
            let ch = try await bs.connect(host: session.host, port: session.port).get()
            self.group = g; self.parent = ch
            try await openShell(cols: 80, rows: 24)
            self.isConnected = true
            self.statusText = "已连接 · \(session.username)@\(session.host)"

            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self = self, self.isFiltering else { return }
                    self.isFiltering = false
                    if !self.initialBuffer.isEmpty {
                        let c = TerminalColorizer.colorize(self.initialBuffer)
                        if let d = c.data(using: .utf8) { self.onData?(d) }
                        self.initialBuffer = ""
                    }
                }
            }
            self.timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
        } catch {
            self.isConnected = false
            self.statusText = "连接失败：\(error.localizedDescription)"
            isFiltering = false
            await disconnect()
        }
    }

    private func openShell(cols: Int, rows: Int) async throws {
        guard let p = parent else { throw SSHClientError.notConnected }
        let h = try await p.pipeline.handler(type: NIOSSHHandler.self).get()
        let cp = p.eventLoop.makePromise(of: Channel.self)
        h.createChannel(cp, channelType: .session) { [weak self] child, _ in
            guard let self = self else { return child.eventLoop.makeFailedFuture(SSHClientError.notConnected) }
            return child.pipeline.addHandler(DataHandler(
                onData: { [weak self] d in
                    Task { @MainActor in
                        guard let self = self else { return }
                        if self.isFiltering {
                            if let s = String(data: d, encoding: .utf8) {
                                self.initialBuffer += s
                                if let r = self.initialBuffer.range(of: "Last login:") {
                                    self.isFiltering = false
                                    self.timeoutWork?.cancel()
                                    let keep = String(self.initialBuffer[r.lowerBound...])
                                    let c = TerminalColorizer.colorize(keep)
                                    if let kd = c.data(using: .utf8) { self.onData?(kd) }
                                    self.initialBuffer = ""
                                }
                            } else { self.isFiltering = false; self.onData?(d) }
                        } else {
                            if let s = String(data: d, encoding: .utf8) {
                                if !self.commandHistory.isEmpty {
                                    self.commandHistory[self.commandHistory.count - 1].output += s
                                }
                                let c = TerminalColorizer.colorize(s)
                                self.onData?(Data(c.utf8))
                            } else { self.onData?(d) }
                        }
                    }
                },
                onClose: { [weak self] in Task { @MainActor in self?.isConnected = false; self?.statusText = "连接已断开"; self?.onClose?() } }
            ))
        }
        let c = try await cp.futureResult.get()
        self.child = c
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(wantReply: true, term: "xterm-256color", terminalCharacterWidth: max(cols,20), terminalRowHeight: max(rows,5), terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
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
        let bytes = [UInt8](data)
        c.eventLoop.execute {
            var b = c.allocator.buffer(capacity: bytes.count)
            b.writeBytes(bytes)
            c.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(b))), promise: nil)
        }
    }

    func appendInput(_ s: String) {
        pendingInput += s
        send(Data(s.utf8))
    }

    func backspace() {
        if !pendingInput.isEmpty { pendingInput.removeLast() }
        send(Data([0x7F]))
    }

    func cancelInput() {
        pendingInput = ""
        send(Data([0x03]))
    }

    func commitInput() {
        let cmd = pendingInput.trimmingCharacters(in: .whitespaces)
        if !cmd.isEmpty {
            commandHistory.append(CommandRecord(command: cmd))
        }
        pendingInput = ""
        send(Data([0x0D]))
    }

    func sendCommand(_ command: String) {
        commandHistory.append(CommandRecord(command: command))
        send(Data((command + "\n").utf8))
    }

    func sendRawKey(_ code: UInt8) {
        send(Data([code]))
    }

    func resize(cols: Int, rows: Int) {
        guard let c = child else { return }
        let r = SSHChannelRequestEvent.WindowChangeRequest(terminalCharacterWidth: max(cols,20), terminalRowHeight: max(rows,5), terminalPixelWidth: 0, terminalPixelHeight: 0)
        c.triggerUserOutboundEvent(r, promise: nil)
    }

    func disconnect() async {
        timeoutWork?.cancel(); timeoutWork = nil
        if let c = child { try? await c.close().get() }
        if let p = parent { try? await p.close().get() }
        if let g = group { try? await g.shutdownGracefully() }
        child = nil; parent = nil; group = nil; isConnected = false; statusText = "未连接"; pendingInput = ""
    }
}

// MARK: - 全局管理
@MainActor class SSHManager: ObservableObject {
    static let shared = SSHManager()
    @Published var services: [UUID: SSHService] = [:]
    func service(for s: Session) -> SSHService {
        if let x = services[s.id] { return x }
        let x = SSHService(); services[s.id] = x; return x
    }
}

// MARK: - 终端桥接
extension Terminal {
    func getVisibleText() -> String {
        var r = ""
        for y in 0..<self.rows { if let l = self.getLine(row: y) { r += l.translateToString() + "\n" } }
        return r
    }
}
final class TerminalBridge: NSObject, TerminalViewDelegate {
    weak var terminalView: TerminalView?
    var onInput: ((Data) -> Void)?; var onResize: ((Int, Int) -> Void)?
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

// MARK: - 键盘三态
enum KeyboardMode { case custom, system, hidden }
class CustomTerminalView: TerminalView {
    var allowSystemKeyboard: Bool = false
    override var canBecomeFirstResponder: Bool { return allowSystemKeyboard }
    override func becomeFirstResponder() -> Bool {
        let r = super.becomeFirstResponder()
        if r { self.inputAccessoryView = nil; self.inputView = self.allowSystemKeyboard ? nil : UIView(); self.reloadInputViews() }
        return r
    }
}
struct TerminalWrapper: UIViewRepresentable {
    @ObservedObject var ssh: SSHService
    let bridge: TerminalBridge
    @Binding var keyboardMode: KeyboardMode
    func makeUIView(context: Context) -> CustomTerminalView {
        let v = CustomTerminalView(frame: .zero)
        v.terminalDelegate = bridge
        bridge.terminalView = v
        v.backgroundColor = UIColor(Theme.bg); v.nativeBackgroundColor = UIColor(Theme.bg); v.nativeForegroundColor = UIColor(Theme.text)
        v.font = FontLoader.monoFont(size: 15)
        v.allowSystemKeyboard = false
        v.inputView = UIView(); v.inputAccessoryView = nil
        ssh.onData = { [weak v] d in guard let v = v else { return }; DispatchQueue.main.async { v.feed(byteArray: [UInt8](d)[...]) } }
        bridge.onInput = { [weak ssh] d in ssh?.send(d) }
        bridge.onResize = { [weak ssh] c, r in ssh?.resize(cols: c, rows: r) }
        DispatchQueue.main.async { let d = v.getTerminal().getDims(); ssh.resize(cols: d.cols, rows: d.rows) }
        return v
    }
    func updateUIView(_ v: CustomTerminalView, context: Context) {
        let want = (keyboardMode == .system)
        if v.allowSystemKeyboard != want {
            v.allowSystemKeyboard = want
            if want { v.inputView = nil; v.inputAccessoryView = nil; v.reloadInputViews(); if !v.isFirstResponder { _ = v.becomeFirstResponder() } }
            else { if v.isFirstResponder { v.resignFirstResponder() }; v.inputView = UIView(); v.inputAccessoryView = nil; v.reloadInputViews() }
        }
    }
}

// MARK: - 主界面
struct RootView: View { var body: some View { NavigationStack { SessionListView() }.tint(Theme.blue) } }

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
                        Image(systemName: "slider.horizontal.3").font(.system(size: 18, weight: .bold)).foregroundColor(Theme.blue).frame(width: 40, height: 40).background(Circle().fill(Theme.blueSoft))
                    }
                    Button { isNew = true; editing = Session(name: "", host: "", username: "") } label: {
                        Image(systemName: "plus").font(.system(size: 18, weight: .bold)).foregroundColor(.black).frame(width: 40, height: 40).background(Circle().fill(Theme.blue))
                    }
                }.padding()
                if store.sessions.isEmpty { Spacer(); Text("还没有会话").foregroundColor(Theme.textDim); Spacer() }
                else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.sessions) { s in
                                NavigationLink { TerminalScreen(session: s) } label: {
                                    HStack { Text(s.shortName).font(.headline).foregroundColor(Theme.text); Spacer(); Text(s.displayHost).font(.caption).foregroundColor(Theme.textDim) }
                                        .padding().background(RoundedRectangle(cornerRadius: 12).fill(Theme.bgElev))
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
    @State var newName = ""; @State var newCmd = ""
    var body: some View {
        NavigationStack {
            List {
                Section("添加快捷指令") {
                    TextField("名称", text: $newName); TextField("命令", text: $newCmd)
                    Button("添加") { guard !newName.isEmpty, !newCmd.isEmpty else { return }; store.add(Shortcut(name: newName, command: newCmd)); newName=""; newCmd="" }
                }
                Section("已保存") {
                    ForEach(store.shortcuts) { s in
                        HStack {
                            VStack(alignment: .leading) { Text(s.name).font(.headline); Text(s.command).font(.caption).foregroundColor(.gray) }
                            Spacer()
                            Button(role: .destructive) { store.delete(s) } label: { Image(systemName: "trash") }
                        }
                    }
                }
            }.navigationTitle("快捷指令管理").toolbar { Button("关闭") { dismiss() } }
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
                TextField("名称", text: $session.name); TextField("主机", text: $session.host)
                TextField("端口", value: $session.port, format: .number); TextField("用户名", text: $session.username)
                SecureField("密码", text: $password)
                Button("保存") {
                    if session.name.isEmpty { session.name = session.host }
                    store.upsert(session); store.setPassword(password, for: session); dismiss()
                }
            }.navigationTitle(isNew ? "新建" : "编辑").toolbar { Button("取消") { dismiss() } }
        }.onAppear { password = store.password(for: session) }
    }
}

// MARK: - 终端页面
struct TerminalScreen: View {
    let session: Session
    @EnvironmentObject var shortcutStore: ShortcutStore
    @Environment(\.dismiss) var dismiss
    @StateObject private var ssh: SSHService
    @State private var bridge = TerminalBridge()
    @State private var showLog = false
    @State private var showShortcuts = false
    @State private var keyboardMode: KeyboardMode = .custom

    init(session: Session) { self.session = session; _ssh = StateObject(wrappedValue: SSHManager.shared.service(for: session)) }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                // 顶部：返回 + 状态 + 收起键盘 + 复制
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.blue).padding(8).background(Circle().fill(Theme.blueSoft))
                    }
                    Circle().fill(ssh.isConnected ? Color.green : Theme.red).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.shortName).font(.system(.subheadline, design: .rounded).weight(.semibold)).foregroundColor(Theme.text).lineLimit(1)
                        Text(ssh.statusText).font(.caption2.monospaced()).foregroundColor(Theme.textDim).lineLimit(1)
                    }
                    Spacer()
                    Button { keyboardMode = .hidden } label: {
                        Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.blue).padding(8).background(Circle().fill(Theme.blueSoft))
                    }
                    Button { showLog = true } label: {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.blue).padding(8).background(Circle().fill(Theme.blueSoft))
                    }
                }.padding(.horizontal, 12).padding(.vertical, 10).background(Color.black.opacity(0.8))

                // 快捷指令
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button { showShortcuts = true } label: {
                            Text("+ 添加").font(.system(.caption, design: .rounded).weight(.medium)).foregroundColor(Theme.blue)
                                .padding(.horizontal, 12).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.blueSoft))
                        }
                        ForEach(shortcutStore.shortcuts) { s in
                            Button { ssh.sendCommand(s.command) } label: {
                                Text(s.name).font(.system(.caption, design: .rounded).weight(.medium)).foregroundColor(Theme.blue)
                                    .padding(.horizontal, 12).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.blueSoft))
                            }
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 6)
                }.background(Color.black.opacity(0.5))
                .sheet(isPresented: $showShortcuts) { ShortcutEditView().environmentObject(shortcutStore) }

                // 终端
                ZStack {
                    TerminalWrapper(ssh: ssh, bridge: bridge, keyboardMode: $keyboardMode).background(Theme.bg)
                    if keyboardMode == .hidden { Color.clear.contentShape(Rectangle()).onTapGesture { keyboardMode = .custom } }
                }

                // 键盘面板
                if keyboardMode == .custom {
                    CustomKeyPanel(
                        onInput: { ssh.appendInput($0) },
                        onBackspace: { ssh.backspace() },
                        onCtrlC: { ssh.cancelInput() },
                        onEnter: { ssh.commitInput() },
                        onPaste: { if let s = UIPasteboard.general.string { ssh.appendInput(s) } },
                        onShortcut: { ssh.sendCommand($0) },
                        onEsc: { ssh.sendRawKey(0x1B) },
                        onHide: { keyboardMode = .hidden },
                        onSwitchToSystem: { keyboardMode = .system }
                    )
                } else if keyboardMode == .hidden {
                    HStack {
                        Button { keyboardMode = .custom } label: {
                            HStack(spacing: 4) { Image(systemName: "keyboard"); Text("微缩键盘") }
                                .font(.system(size: 13, weight: .medium)).foregroundColor(Theme.blue)
                                .padding(.horizontal, 12).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.blueSoft))
                        }
                        Spacer()
                        Text("已在线").font(.caption).foregroundColor(Theme.textDim)
                        Spacer()
                        Button { ssh.commitInput() } label: {
                            Text("回车").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                                .padding(.horizontal, 20).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.blue))
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 6).background(Color.black.opacity(0.8))
                }
            }
        }
        .navigationBarBackButtonHidden(true).toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showLog) { CommandHistorySheet(records: ssh.commandHistory) }
        .task {
            let pw = KeychainHelper.read(account: "session.\(session.id.uuidString).password") ?? ""
            if !ssh.isConnected { await ssh.connect(session: session, password: pw) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            if keyboardMode == .system { keyboardMode = .custom }
        }
    }
}

// MARK: - 命令历史复制面板
struct CommandHistorySheet: View {
    let records: [CommandRecord]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                if records.isEmpty { Text("还没有执行过命令").foregroundColor(Theme.textDim) }
                else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(records.reversed()) { rec in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("$ \(rec.command)").font(.caption).foregroundColor(Theme.textDim).lineLimit(1)
                                        Spacer()
                                        Button {
                                            UIPasteboard.general.string = "$ \(rec.command)\n\(rec.output)"
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        } label: {
                                            HStack(spacing: 4) { Image(systemName: "doc.on.doc"); Text("整段") }
                                                .font(.caption).foregroundColor(Theme.blue)
                                                .padding(.horizontal, 8).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 6).fill(Theme.blueSoft))
                                        }
                                        Button {
                                            UIPasteboard.general.string = rec.output
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        } label: {
                                            HStack(spacing: 4) { Image(systemName: "doc.text"); Text("输出") }
                                                .font(.caption).foregroundColor(Theme.blue)
                                                .padding(.horizontal, 8).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 6).fill(Theme.blueSoft))
                                        }
                                    }
                                    Text(rec.output).font(.system(.footnote, design: .monospaced)).foregroundColor(Theme.text)
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Theme.bgElev))
                            }
                        }.padding(12)
                    }
                }
            }
            .navigationTitle("命令历史").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("复制全部") {
                        UIPasteboard.general.string = records.map { "$ \($0.command)\n\($0.output)" }.joined(separator: "\n\n")
                    }
                }
            }
        }.preferredColorScheme(.dark)
    }
}

// MARK: - 自定义键盘
struct CustomKeyPanel: View {
    let onInput: (String) -> Void
    let onBackspace: () -> Void
    let onCtrlC: () -> Void
    let onEnter: () -> Void
    let onPaste: () -> Void
    let onShortcut: (String) -> Void
    let onEsc: () -> Void
    let onHide: () -> Void
    let onSwitchToSystem: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button { onHide() } label: {
                    HStack(spacing: 4) { Image(systemName: "keyboard.chevron.compact.down"); Text("收起") }
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.3)))
                }.buttonStyle(.plain)
                Button { onSwitchToSystem() } label: {
                    HStack(spacing: 4) { Image(systemName: "keyboard"); Text("系统键盘") }
                        .font(.system(size: 13, weight: .medium)).foregroundColor(Theme.orange)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(RoundedRectangle(cornerRadius: 6).fill(Theme.orange.opacity(0.2)))
                }.buttonStyle(.plain)
                Spacer()
                Text("已连接").font(.system(size: 12, weight: .medium)).foregroundColor(Theme.green)
            }.padding(.horizontal, 8).padding(.top, 6)

            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 4) {
                    Text("已在线").font(.system(size: 12)).foregroundColor(Theme.textDim).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        ForEach(["1","2","3","4","5","k"], id: \.self) { k in
                            Button { onInput(k) } label: { keyLabel(k) }.buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 4) {
                        ForEach(["6","7","8","9","0","-"], id: \.self) { k in
                            Button { onInput(k) } label: { keyLabel(k) }.buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 4) {
                        Button { onCtrlC() } label: {
                            Text("Ctrl+C").font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 5).fill(Theme.red))
                        }.buttonStyle(.plain)
                        Button { onEsc() } label: {
                            Text("ESC").font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 5).fill(Theme.orange))
                        }.buttonStyle(.plain)
                        Button { onInput(" ") } label: {
                            Text("空格").font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.25)))
                        }.buttonStyle(.plain)
                        Button { onBackspace() } label: {
                            Image(systemName: "delete.left").font(.system(size: 14)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.25)))
                        }.buttonStyle(.plain)
                    }
                    HStack(spacing: 4) {
                        Button { onShortcut("x-ui") } label: { customKeyLabel("x-ui", color: Color.gray.opacity(0.25)) }.buttonStyle(.plain)
                        Button { onShortcut("88") } label: { customKeyLabel("88", color: Color.gray.opacity(0.25)) }.buttonStyle(.plain)
                        Button { onShortcut("q") } label: { customKeyLabel("q退出", color: Theme.magenta) }.buttonStyle(.plain)
                    }
                }
                VStack(spacing: 4) {
                    Button { onPaste() } label: {
                        VStack(spacing: 4) { Image(systemName: "doc.on.clipboard"); Text("粘贴").font(.system(size: 12, weight: .medium)) }
                            .foregroundColor(.white).frame(width: 80, height: 56).background(RoundedRectangle(cornerRadius: 8).fill(Theme.blue))
                    }.buttonStyle(.plain)
                    Button { onEnter() } label: {
                        VStack(spacing: 4) { Image(systemName: "return"); Text("回车").font(.system(size: 12, weight: .bold)) }
                            .foregroundColor(.white).frame(width: 80, height: 56).background(RoundedRectangle(cornerRadius: 8).fill(Theme.blue))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 8).padding(.bottom, 6)
        }
        .background(Color(red: 0.06, green: 0.09, blue: 0.15))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.stroke), alignment: .top)
    }
    private func keyLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 14, weight: .medium)).foregroundColor(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.25)))
    }
    private func customKeyLabel(_ t: String, color: Color) -> some View {
        Text(t).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 5).fill(color))
    }
}

@main
struct SSHBlackApp: App {
    @StateObject var store = SessionStore()
    @StateObject var shortcutStore = ShortcutStore()
    init() { FontLoader.registerFonts() }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).environmentObject(shortcutStore).preferredColorScheme(.dark)
        }
    }
}
