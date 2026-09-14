import Foundation
import UIKit
import Combine
import Citadel
import NIOCore
import NIOSSH

public struct CommandHistoryItem: Identifiable {
    public let id: UUID
    public let command: String
    public var output: String

    // 记录执行该命令时真实的 shell 提示符。
    public let prompt: String

    public init(command: String, output: String, prompt: String = "") {
        self.id = UUID()
        self.command = command
        self.output = output
        self.prompt = prompt
    }
}


@MainActor
final class SSHSession: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var history: [CommandHistoryItem] = []

    // 当前真实 shell 提示符，例如 root@vps:~#
    @Published private(set) var shellPrompt: String = ""

    private var client: SSHClient?
    private var activeWriter: TTYStdinWriter?

    var host: String = ""
    var port: Int = 22
    var username: String = "root"
    var password: String = ""

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var writeChain: Task<Void, Never>?

    // MARK: - 输出批处理
    // 大量输出时不要每个 SSH chunk 都触发 SwiftUI 重绘。
    private var pendingOutput = ""
    private var flushTask: Task<Void, Never>?

    // MARK: - 多命令队列
    // 每条命令单独保存，输出严格按发送顺序归属。
    private struct PendingCommand {
        let id: UUID
        let command: String
    }

    private var pendingCommands: [PendingCommand] = []
    private var activeInteractiveID: UUID?
    private var interactivePromptBuffer = ""
    private var markerBuffer = ""
    private var truncatedIDs = Set<UUID>()

    // 终端中用 shell marker 判断一条命令何时结束。
    private var commandEndMarker = "__MYSSH_DONE_7F3A9C__"

    // 防止单条命令超大输出拖垮 iPhone。
    private let maxOutputCharactersPerCommand = 300_000

    // 防止长期使用后历史无限增长。
    private let maxHistoryItems = 120

    // MARK: - ANSI 清理
    private enum ANSIState { case normal, escape, csi, osc, oscEscape }
    private var ansiState: ANSIState = .normal

    private func cleanANSI(_ raw: String) -> String {
        var result = ""
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            switch ansiState {
            case .normal:
                if v == 0x1B { ansiState = .escape }
                else if v == 0x9B { ansiState = .csi }
                else if v == 0x9D { ansiState = .osc }
                else if v == 0x0D || v == 0x07 { }
                else if v < 0x20 && v != 0x09 && v != 0x0A { }
                else { result.unicodeScalars.append(scalar) }
            case .escape:
                if v == 0x5B { ansiState = .csi }
                else if v == 0x5D { ansiState = .osc }
                else if v == 0x1B { ansiState = .escape }
                else { ansiState = .normal }
            case .csi:
                if v >= 0x40 && v <= 0x7E { ansiState = .normal }
            case .osc:
                if v == 0x07 { ansiState = .normal }
                else if v == 0x1B { ansiState = .oscEscape }
            case .oscEscape:
                if v == 0x5C || v == 0x07 { ansiState = .normal }
                else if v == 0x1B { ansiState = .oscEscape }
                else { ansiState = .osc }
            }
        }
        return result
    }

    // MARK: - 连接
    func connect() {
        guard !isConnected else { return }

        flushTask?.cancel()
        flushTask = nil
        pendingOutput = ""
        shellPrompt = ""
        pendingCommands.removeAll()
        activeInteractiveID = nil
        interactivePromptBuffer = ""
        markerBuffer = ""
        truncatedIDs.removeAll()
        ansiState = .normal
        commandEndMarker = "__MYSSH_DONE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"

        Task {
            do {
                let client = try await SSHClient.connect(
                    host: self.host,
                    port: .init(integerLiteral: self.port),
                    authenticationMethod: .passwordBased(
                        username: self.username,
                        password: self.password
                    ),
                    hostKeyValidator: .acceptAnything(),
                    reconnect: .never
                )

                self.client = client
                self.isConnected = true

                let ptyReq = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: 100,
                    terminalRowHeight: 40,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([.ECHO: 0])
                )

                try await client.withPTY(ptyReq) { [weak self] stream, writer in
                    guard let self = self else { return }

                    self.activeWriter = writer

                    for try await event in stream {
                        let buffer: ByteBuffer

                        switch event {
                        case .stdout(let b):
                            buffer = b
                        case .stderr(let b):
                            buffer = b
                        }

                        if let text = buffer.getString(
                            at: buffer.readerIndex,
                            length: buffer.readableBytes
                        ) {
                            self.receiveOutput(text)
                        }
                    }
                }

                if self.isConnected {
                    self.finishConnection(message: nil)
                }
            } catch {
                self.finishConnection(
                    message: "连接断开或异常: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - 输出接收/批处理
    private func receiveOutput(_ rawText: String) {
        let cleaned = cleanANSI(rawText)
        guard !cleaned.isEmpty else { return }

        pendingOutput.append(cleaned)

        // 约 80ms 合并一次 UI 更新。
        if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 80_000_000)

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self?.flushOutput()
                }
            }
        }

        // 极端大输出时不要让待处理缓冲无限涨。
        if pendingOutput.count >= 500_000 {
            flushOutput()
        }
    }

    private func flushOutput() {
        flushTask?.cancel()
        flushTask = nil

        guard !pendingOutput.isEmpty else { return }

        let text = pendingOutput
        pendingOutput = ""

        processOutput(text)
    }

    private func processOutput(_ text: String) {
        // x-ui / k 退出时，最后返回的提示符必须单独恢复，
        // 不能被当成交互程序的输出。
        if let interactiveID = activeInteractiveID {
            let split = splitTrailingShellPrompt(text)

            if !split.body.isEmpty {
                appendOutput(split.body, to: interactiveID)
            }

            if let prompt = split.prompt {
                shellPrompt = prompt
                activeInteractiveID = nil
                interactivePromptBuffer = ""
            } else {
                interactivePromptBuffer.append(text)
                if interactivePromptBuffer.count > 2000 {
                    interactivePromptBuffer = String(interactivePromptBuffer.suffix(1000))
                }
            }
            return
        }

        markerBuffer.append(text)

        while let range = markerBuffer.range(of: commandEndMarker) {
            let before = String(markerBuffer[..<range.lowerBound])
            appendOutputToCurrentCommand(before)

            if !pendingCommands.isEmpty {
                pendingCommands.removeFirst()
            }

            // marker 后面的内容通常就是 shell 恢复出来的 prompt。
            // 先保留，等完整 prompt 到齐后再解析。
            markerBuffer = String(markerBuffer[range.upperBound...])
        }

        // 没有待完成命令时，只捕获真实 prompt。
        // 这样首次登录、普通命令结束、x-ui 退出都能恢复命令符。
        if pendingCommands.isEmpty {
            let split = splitTrailingShellPrompt(markerBuffer)

            if let prompt = split.prompt {
                shellPrompt = prompt
                markerBuffer = split.body
            }

            // 欢迎信息等不属于命令历史，避免重新出现在终端底部。
            if shellPrompt.isEmpty && markerBuffer.count > 512 {
                markerBuffer = String(markerBuffer.suffix(256))
            }
            return
        }

        let maxPrefix = min(commandEndMarker.count - 1, markerBuffer.count)
        var splitIndex = markerBuffer.endIndex

        if maxPrefix > 0 {
            for length in stride(from: maxPrefix, through: 1, by: -1) {
                let idx = markerBuffer.index(markerBuffer.endIndex, offsetBy: -length)
                if markerBuffer[idx...].hasPrefix(String(commandEndMarker.prefix(length))) {
                    splitIndex = idx
                    break
                }
            }
        }

        if splitIndex != markerBuffer.endIndex {
            appendOutputToCurrentCommand(String(markerBuffer[..<splitIndex]))
            markerBuffer = String(markerBuffer[splitIndex...])
        } else {
            appendOutputToCurrentCommand(markerBuffer)
            markerBuffer = ""
        }
    }

    // 从 SSH 输出尾部提取真实 shell prompt。
    private func splitTrailingShellPrompt(_ text: String) -> (body: String, prompt: String?) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines = normalized.components(separatedBy: "\n")

        guard let index = lines.lastIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return (normalized, nil)
        }

        let candidate = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)

        guard candidate.range(
            of: #"^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+:.*[#$]$"#,
            options: .regularExpression
        ) != nil else {
            return (normalized, nil)
        }

        lines.remove(at: index)

        let body = lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)

        return (body.isEmpty ? "" : body + "\n", candidate)
    }


    private func appendOutputToCurrentCommand(_ text: String) {
        guard let pending = pendingCommands.first, !text.isEmpty else { return }
        appendOutput(text, to: pending.id, echoCommand: pending.command)
    }

    private func appendOutput(_ text: String, to id: UUID, echoCommand: String? = nil) {
        guard let index = history.firstIndex(where: { $0.id == id }), !truncatedIDs.contains(id) else { return }
        var output = history[index].output + text
        if let echoCommand {
            if output.hasPrefix(echoCommand + "\n") { output.removeFirst(echoCommand.count + 1) }
            else if output.hasPrefix(echoCommand) { output.removeFirst(echoCommand.count) }
        }
        if output.count >= maxOutputCharactersPerCommand {
            output = String(output.prefix(maxOutputCharactersPerCommand)) + "\n[输出过长，已限制显示]"
            truncatedIDs.insert(id)
        }
        history[index].output = output
    }

    private func shellPromptAppeared(in text: String) -> Bool {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? text
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.range(of: #"^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+:.*[#$] ?$"#, options: .regularExpression) != nil
    }

    private func appendHistory(_ item: CommandHistoryItem) {
        history.append(item)
        while history.count > maxHistoryItems {
            let protected = Set(pendingCommands.map { $0.id }).union(activeInteractiveID.map { [$0] } ?? [])
            guard let index = history.firstIndex(where: { !protected.contains($0.id) }) else { break }
            let removed = history.remove(at: index)
            truncatedIDs.remove(removed.id)
        }
    }

    // MARK: - 发送命令
    func sendCommand(_ command: String) {
        guard isConnected else { return }
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }

        let promptForCommand = shellPrompt.isEmpty
            ? "\(username)@\(host):~#"
            : shellPrompt

        shellPrompt = ""

        let item = CommandHistoryItem(
            command: cmd,
            output: "",
            prompt: promptForCommand
        )
        appendHistory(item)
        pendingCommands.append(PendingCommand(id: item.id, command: cmd))

        enqueueWrite("\(cmd)\nprintf '\\n\(commandEndMarker)\\n'\n") { [weak self] error in
            guard let self else { return }
            if let error { self.handleWriteFailure(id: item.id, error: error) }
        }
    }


    func sendInteractiveCommand(_ command: String) {
        guard isConnected else { return }
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        guard activeInteractiveID == nil else { return }

        let promptForCommand = shellPrompt.isEmpty
            ? "\(username)@\(host):~#"
            : shellPrompt

        shellPrompt = ""

        let item = CommandHistoryItem(
            command: cmd,
            output: "",
            prompt: promptForCommand
        )
        appendHistory(item)
        activeInteractiveID = item.id
        interactivePromptBuffer = ""

        enqueueWrite("\(cmd)\n") { [weak self] error in
            guard let self else { return }
            if let error {
                self.handleWriteFailure(id: item.id, error: error)
                if self.activeInteractiveID == item.id {
                    self.activeInteractiveID = nil
                    self.interactivePromptBuffer = ""
                    self.shellPrompt = promptForCommand
                }
            }
        }
    }


    private func handleWriteFailure(id: UUID, error: Error) {
        if let index = history.firstIndex(where: { $0.id == id }) {
            history[index].output = "写入失败：\(error.localizedDescription)"
        }
        pendingCommands.removeAll { $0.id == id }
        if activeInteractiveID == id {
            activeInteractiveID = nil
            interactivePromptBuffer = ""
        }
    }

    // MARK: - 控制键
    // 控制键直接进入同一个串行写入队列，不创建命令历史。
    func sendControl(_ value: String) {
        guard isConnected else { return }
        enqueueWrite(value)
    }

    func sendCtrlC() { sendControl("\u{03}") }
    func sendEscape() { sendControl("\u{1B}") }
    func sendSpace() { sendControl(" ") }
    func sendBackspace() { sendControl("\u{7F}") }

    // MARK: - 串行写入
    private func enqueueWrite(
        _ value: String,
        completion: ((Error?) -> Void)? = nil
    ) {
        guard let writer = activeWriter else {
            completion?(NSError(
                domain: "MySSH",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "SSH 写入通道不存在"]
            ))
            return
        }

        let previous = writeChain
        let task = Task { [weak self] in
            if let previous { await previous.value }
            guard let self else { return }

            do {
                var buffer = ByteBufferAllocator().buffer(capacity: value.utf8.count)
                buffer.writeString(value)
                try await writer.write(buffer)
                completion?(nil)
            } catch {
                completion?(error)
            }
        }
        writeChain = task
    }

    // MARK: - App 生命周期
    func appDidEnterBackground() {
        guard isConnected else { return }

        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "SSHKeepAlive"
        ) { [weak self] in
            self?.endBackgroundTask()
        }
    }

    func appWillEnterForeground() {
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: - 连接结束
    private func finishConnection(message: String?) {
        flushOutput()

        isConnected = false
        activeWriter = nil
        pendingCommands.removeAll()
        activeInteractiveID = nil
        interactivePromptBuffer = ""
        markerBuffer = ""

        if let message, !message.isEmpty {
            appendHistory(
                CommandHistoryItem(command: "system", output: message)
            )
        }
    }

    func disconnect() {
        flushOutput()
        endBackgroundTask()

        let clientToClose = client
        client = nil
        activeWriter = nil
        isConnected = false
        writeChain?.cancel()
        writeChain = nil
        pendingCommands.removeAll()
        activeInteractiveID = nil
        interactivePromptBuffer = ""
        markerBuffer = ""
        pendingOutput = ""
        shellPrompt = ""

        Task {
            try? await clientToClose?.close()
        }
    }
}


// MARK: - TerminalView

import SwiftUI
import UIKit

struct QuickCmd: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var cmd: String
}

struct TerminalView: View {
    let serverName: String
    let host: String
    let port: Int
    let username: String
    let password: String

    @StateObject private var session = SSHSession()
    @State private var inputCommand: String = ""
    @FocusState private var isSystemKeyboardFocused: Bool

    @State private var showMiniKeyboard: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    @State private var quickCommands: [QuickCmd] = []
    @State private var showingAddSheet = false
    @State private var newCmdName = ""
    @State private var newCmdContent = ""
    @State private var copiedTip: String? = nil

    private let storageKey = "SavedQuickCommands"

    // 单个历史块最多渲染 400 行，避免超长输出拖慢 SwiftUI。
    private let maxRenderedLinesPerBlock = 400

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // MARK: - 快捷命令栏
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button(action: { showingAddSheet = true }) {
                            HStack(spacing: 3) {
                                Image(systemName: "plus")
                                Text("添加")
                            }
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.blue.opacity(0.3))
                            .foregroundColor(.blue)
                            .cornerRadius(6)
                        }

                        Button(action: { copyAllQuickCommands() }) {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.on.doc")
                                Text("全复制")
                            }
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color(white: 0.18))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                        }
                        .disabled(quickCommands.isEmpty)

                        ForEach(quickCommands) { item in
                            Button(action: { runCommand(item.cmd, interactive: isInteractiveCommand(item.cmd, name: item.name)) }) {
                                Text(item.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(Color(white: 0.18))
                                    .foregroundColor(.white)
                                    .cornerRadius(6)
                            }
                            .contextMenu {
                                Button {
                                    copyBlock(item.cmd, tip: "已复制此命令")
                                } label: {
                                    Label("复制此命令", systemImage: "doc.on.doc")
                                }

                                Button {
                                    runCommand(item.cmd, interactive: isInteractiveCommand(item.cmd, name: item.name))
                                } label: {
                                    Label("执行此命令", systemImage: "play.fill")
                                }

                                Button(role: .destructive) {
                                    deleteQuickCmd(item)
                                } label: {
                                    Label("删除快捷键", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .background(Color(white: 0.12))

                // MARK: - 终端主体
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(session.history) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    if item.command == "system" {
                                        HStack {
                                            Text("[系统状态]")
                                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                .foregroundColor(.yellow.opacity(0.8))

                                            Spacer()

                                            Button(action: {
                                                copyBlock(item.output, tip: "已复制系统信息")
                                            }) {
                                                Image(systemName: "doc.on.doc")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.gray)
                                            }
                                        }

                                        renderOutputLines(item.output, defaultColor: .yellow)
                                    } else {
                                        HStack(alignment: .center) {
                                            Text("\(item.prompt.isEmpty ? "\(username)@\(host):~#" : item.prompt) \(item.command)")
                                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                                .foregroundColor(.cyan)
                                                .textSelection(.enabled)

                                            Spacer()

                                            Button(action: {
                                                let fullBlock = commandBlock(for: item)
                                                copyBlock(fullBlock, tip: "已复制整段命令与输出")
                                            }) {
                                                HStack(spacing: 3) {
                                                    Image(systemName: "doc.on.doc")
                                                    Text("复制整段")
                                                }
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(.gray)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(Color(white: 0.18))
                                                .cornerRadius(4)
                                            }
                                        }

                                        renderOutputLines(item.output, defaultColor: .green)

                                        if !item.output.isEmpty {
                                            HStack {
                                                Spacer()

                                                Button(action: {
                                                    let fullBlock = commandBlock(for: item)
                                                    copyBlock(fullBlock, tip: "已复制整段命令与输出")
                                                }) {
                                                    HStack(spacing: 3) {
                                                        Image(systemName: "doc.on.doc")
                                                        Text("复制整段")
                                                    }
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundColor(.gray)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 3)
                                                    .background(Color(white: 0.18))
                                                    .cornerRadius(4)
                                                }
                                            }
                                            .padding(.top, 4)
                                        }
                                    }
                                }
                                .padding(8)
                                .background(Color(white: 0.05))
                                .cornerRadius(6)
                                .contextMenu {
                                    Button {
                                        copyBlock(item.output, tip: "已复制本段输出")
                                    } label: {
                                        Label("复制本段输出", systemImage: "doc.on.doc")
                                    }

                                    if item.command != "system" {
                                        Button {
                                            copyBlock(item.command, tip: "已复制命令")
                                        } label: {
                                            Label("仅复制命令", systemImage: "terminal")
                                        }
                                    }
                                }
                                .id(item.id)
                            }

                            if session.isConnected && !session.shellPrompt.isEmpty {
                                HStack(spacing: 0) {
                                    Text(session.shellPrompt)
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundColor(.cyan)
                                    Text(" ")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.white)
                                }
                                .textSelection(.enabled)
                                .padding(.horizontal, 8)
                            }

                            Color.clear
                                .frame(height: 16)
                                .id("BOTTOM_ANCHOR")
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .background(Color.black)
                    .onTapGesture {
                        showMiniKeyboard = false
                        isSystemKeyboardFocused = false
                    }
                    .onChange(of: session.history.count) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: session.history.last?.output) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: session.shellPrompt) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                }

                // MARK: - 系统键盘隐式输入框
                TextField("", text: $inputCommand)
                    .focused($isSystemKeyboardFocused)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onSubmit {
                        executeCurrentInput()
                    }
                    .onChange(of: isSystemKeyboardFocused) { focused in
                        if focused {
                            showMiniKeyboard = false
                        }
                    }

                // MARK: - 微型键盘
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Button(action: { toggleMiniKeyboard() }) {
                            HStack(spacing: 4) {
                                Image(systemName: showMiniKeyboard ? "chevron.down" : "keyboard")
                                Text(showMiniKeyboard ? "收起" : "微型键盘")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(white: 0.18))
                            .cornerRadius(5)
                        }

                        Button(action: { toggleSystemKeyboard() }) {
                            HStack(spacing: 4) {
                                Image(systemName: isSystemKeyboardFocused ? "chevron.down" : "character.cursor.ibeam")
                                Text(isSystemKeyboardFocused ? "收起" : "系统键盘")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(white: 0.18))
                            .cornerRadius(5)
                        }

                        Spacer()

                        Text(session.isConnected ? "已连接" : "未连接")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(session.isConnected ? .green : .red)
                            .padding(.horizontal, 8)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)

                    HStack(spacing: 8) {
                        Text(inputCommand.isEmpty
                             ? (session.isConnected ? "已在线" : "未连接")
                             : inputCommand)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(inputCommand.isEmpty ? .gray : .green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)

                        if !inputCommand.isEmpty {
                            Button(action: { inputCommand = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)

                    if showMiniKeyboard {
                        HStack(alignment: .top, spacing: 6) {
                            VStack(spacing: 6) {
                                HStack(spacing: 5) {
                                    miniKey("1")
                                    miniKey("2")
                                    miniKey("3")
                                    miniKey("4")
                                    miniKey("5")
                                    miniKey("k")
                                }

                                HStack(spacing: 5) {
                                    miniKey("6")
                                    miniKey("7")
                                    miniKey("8")
                                    miniKey("9")
                                    miniKey("0")
                                    miniKey("-")
                                }

                                HStack(spacing: 5) {
                                    miniKey("Ctrl+C", color: .red) {
                                        session.sendCtrlC()
                                    }

                                    miniKey("ESC", color: .orange) {
                                        session.sendEscape()
                                    }

                                    miniKey("空格") {
                                        inputCommand.append(" ")
                                    }

                                    miniKey("退格", icon: "delete.left") {
                                        if !inputCommand.isEmpty {
                                            inputCommand.removeLast()
                                        }
                                    }
                                }

                                // 原来的 88 已删除。
                                // x-ui + q退出自动占满整行。
                                HStack(spacing: 5) {
                                    miniKey("x-ui") {
                                        runCommand("x-ui", interactive: true)
                                    }

                                    miniKey("q退出", color: .purple) {
                                        session.sendControl("q")
                                    }
                                }
                            }

                            VStack(spacing: 6) {
                                Button(action: {
                                    if let pasteString = UIPasteboard.general.string {
                                        inputCommand.append(pasteString)
                                        showToast("已粘贴剪贴板内容")
                                    } else {
                                        showToast("剪贴板为空")
                                    }
                                }) {
                                    VStack(spacing: 2) {
                                        Image(systemName: "doc.on.clipboard")
                                            .font(.system(size: 15))

                                        Text("粘贴")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 56)
                                    .background(Color.blue.opacity(0.35))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                                }

                                Button(action: {
                                    executeCurrentInput()
                                }) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "return")
                                            .font(.system(size: 20, weight: .bold))

                                        Text("回车")
                                            .font(.system(size: 14, weight: .bold))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(maxHeight: .infinity)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                                }
                            }
                            .frame(width: 78)
                        }
                        .frame(height: 176)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                }
                .background(Color(white: 0.08))
            }

            if let tip = copiedTip {
                VStack {
                    Spacer()

                    Text(tip)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(20)
                        .padding(.bottom, 60)
                }
                .transition(.opacity)
            }
        }
        .navigationTitle(serverName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(session.isConnected ? "断开" : "连接") {
                    if session.isConnected {
                        session.disconnect()
                    } else {
                        connectToServer()
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            NavigationView {
                Form {
                    Section(header: Text("快捷键属性")) {
                        TextField(
                            "按键名称 (例如: 3x-ui / x-ui)",
                            text: $newCmdName
                        )

                        TextField(
                            "执行命令 (例如: x-ui)",
                            text: $newCmdContent
                        )
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    }
                }
                .navigationTitle("添加快捷键")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            showingAddSheet = false
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            addQuickCmd()
                            showingAddSheet = false
                        }
                        .disabled(
                            newCmdName.trimmingCharacters(in: .whitespaces).isEmpty ||
                            newCmdContent.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                    }
                }
            }
        }
        .onAppear {
            loadQuickCommands()

            if !session.isConnected {
                connectToServer()
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                session.appDidEnterBackground()
            case .active:
                session.appWillEnterForeground()
            default:
                break
            }
        }
    }

    // MARK: - 复制
    private func copyBlock(_ text: String, tip: String) {
        let cleaned = stripANSIEscapeCodes(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            showToast("没有可复制的内容")
            return
        }

        UIPasteboard.general.string = cleaned
        showToast(tip)
    }

    private func commandBlock(for item: CommandHistoryItem) -> String {
        let prompt = item.prompt.isEmpty
            ? "\(username)@\(host):~#"
            : item.prompt

        let output = stripANSIEscapeCodes(item.output)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if output.isEmpty {
            return "\(prompt) \(item.command)"
        }

        return "\(prompt) \(item.command)\n\(output)"
    }

    // MARK: - ANSI
    private func stripANSIEscapeCodes(_ text: String) -> String {
        let pattern =
            "\u{1B}(\\[[0-9;?]*[ -/]*[@-~]|\\][^\u{07}]*\u{07}|[()][A-Za-z0-9]|[@-Z\\\\^_])"

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
    }

    @ViewBuilder
    private func renderOutputLines(
        _ fullText: String,
        defaultColor: Color
    ) -> some View {
        let cleaned = stripANSIEscapeCodes(fullText)
        let allLines = cleaned.components(separatedBy: "\n")

        let isTruncated = allLines.count > maxRenderedLinesPerBlock
        let lines = isTruncated
            ? Array(allLines.suffix(maxRenderedLinesPerBlock))
            : allLines

        LazyVStack(alignment: .leading, spacing: 2) {
            if isTruncated {
                Text("⚠️ 输出过长（共 \(allLines.count) 行），仅显示最后 \(maxRenderedLinesPerBlock) 行。点击“复制整段”可获取已接收内容。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
                    .padding(.bottom, 2)
            }

            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isPromptLine =
                    trimmed.hasPrefix("root@") ||
                    trimmed.hasPrefix("user@") ||
                    trimmed.contains("~#")

                let copyValue = copyValueForOutputLine(line)
                let isCopyableLine =
                    !isPromptLine &&
                    !trimmed.isEmpty &&
                    copyValue != nil

                if isCopyableLine {
                    HStack(alignment: .center, spacing: 6) {
                        Text(line)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(defaultColor)
                            .textSelection(.enabled)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )

                        Button {
                            if let value = copyValue {
                                UIPasteboard.general.string = value
                                showToast("已复制: \(value)")
                            }
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundColor(.cyan)
                                .padding(4)
                                .background(Color(white: 0.2))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(defaultColor)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func copyValueForOutputLine(_ line: String) -> String? {
        let trimmed =
            line.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("http://") ||
            trimmed.hasPrefix("https://") {
            return trimmed
        }

        guard let colon = trimmed.firstIndex(of: ":") else {
            return nil
        }

        let prefix = trimmed[..<colon]

        if prefix == "http" || prefix == "https" {
            return trimmed
        }

        let valueStart = trimmed.index(after: colon)

        return String(trimmed[valueStart...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 键盘
    private func toggleMiniKeyboard() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if showMiniKeyboard {
                showMiniKeyboard = false
            } else {
                isSystemKeyboardFocused = false
                showMiniKeyboard = true
            }
        }
    }

    private func toggleSystemKeyboard() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if isSystemKeyboardFocused {
                isSystemKeyboardFocused = false
            } else {
                showMiniKeyboard = false
                isSystemKeyboardFocused = true
            }
        }
    }

    private func showToast(_ msg: String) {
        withAnimation {
            copiedTip = msg
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation {
                copiedTip = nil
            }
        }
    }

    private func miniKey(
        _ label: String,
        icon: String? = nil,
        color: Color = Color(white: 0.22),
        action: (() -> Void)? = nil
    ) -> some View {
        Button(action: {
            if let action = action {
                action()
            } else {
                inputCommand.append(label)
            }
        }) {
            HStack(spacing: 2) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }

                Text(label)
                    .font(
                        .system(
                            size: 13,
                            weight: .medium,
                            design: .monospaced
                        )
                    )
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(6)
        }
    }

    // MARK: - 滚动
    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
        }
    }

    // MARK: - SSH
    private func connectToServer() {
        session.host = host
        session.port = port
        session.username = username
        session.password = password
        session.connect()
    }

    private func executeCurrentInput() {
        let cmd =
            inputCommand.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !cmd.isEmpty else {
            return
        }

        runCommand(cmd)
        inputCommand = ""
    }

    private func runCommand(_ cmd: String, interactive: Bool = false) {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if interactive || isInteractiveCommand(trimmed, name: nil) {
            session.sendInteractiveCommand(trimmed)
        } else {
            session.sendCommand(trimmed)
        }
    }

    private func isInteractiveCommand(_ cmd: String, name: String?) -> Bool {
        let value = cmd.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "x-ui" || value == "k" { return true }
        if let name {
            let n = name.lowercased()
            if n.contains("x-ui") || (n.contains("k") && n.contains("菜单")) { return true }
        }
        return false
    }

    // MARK: - 快捷命令
    private func loadQuickCommands() {
        if let data = UserDefaults.standard.data(
            forKey: storageKey
        ),
        let decoded = try? JSONDecoder().decode(
            [QuickCmd].self,
            from: data
        ) {
            quickCommands = decoded
        } else {
            quickCommands = [
                QuickCmd(name: "输入 k 菜单", cmd: "k"),
                QuickCmd(name: "面板管理 (x-ui)", cmd: "x-ui"),
                QuickCmd(name: "查看文件 (ls)", cmd: "ls -la"),
                QuickCmd(name: "磁盘空间 (df)", cmd: "df -h"),
                QuickCmd(name: "系统信息 (uname)", cmd: "uname -a")
            ]

            saveQuickCommands()
        }
    }

    private func copyAllQuickCommands() {
        guard !quickCommands.isEmpty else {
            showToast("暂无快捷命令")
            return
        }

        let text = quickCommands.map { item in
            "\(item.name) = \(item.cmd)"
        }.joined(separator: "\n")

        copyBlock(text, tip: "已复制全部快捷命令")
    }

    private func addQuickCmd() {
        let name =
            newCmdName.trimmingCharacters(in: .whitespaces)

        let cmd =
            newCmdContent.trimmingCharacters(in: .whitespaces)

        guard !name.isEmpty, !cmd.isEmpty else {
            return
        }

        quickCommands.append(
            QuickCmd(name: name, cmd: cmd)
        )

        saveQuickCommands()

        newCmdName = ""
        newCmdContent = ""
    }

    private func deleteQuickCmd(_ item: QuickCmd) {
        quickCommands.removeAll {
            $0.id == item.id
        }

        saveQuickCommands()
    }

    private func saveQuickCommands() {
        if let encoded = try? JSONEncoder().encode(
            quickCommands
        ) {
            UserDefaults.standard.set(
                encoded,
                forKey: storageKey
            )
        }
    }
}
