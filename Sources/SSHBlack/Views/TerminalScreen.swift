import SwiftUI
import SwiftTerm
import UIKit

struct TerminalScreen: View {
    let session: Session
    @Environment(\.dismiss) private var dismiss

    @StateObject private var ssh = SSHService()
    @State private var bridge = TerminalBridge()
    @State private var toast: String?
    @State private var showBufferSheet = false
    @State private var bufferLines: [String] = []

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                statusBar
                terminalArea
                bottomToolbar
                QuickKeyBar { key in
                    ssh.send(key.bytes)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) { toastView }
        .sheet(isPresented: $showBufferSheet) {
            BufferSheet(lines: bufferLines) { text in
                copy(text, tip: "已复制该行")
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task {
            let pw = KeychainHelper.read(account: "session.\(session.id.uuidString).password") ?? ""
            let pp = KeychainHelper.read(account: "session.\(session.id.uuidString).passphrase") ?? ""
            await ssh.connect(session: session, password: pw, passphrase: pp)
        }
        .onDisappear {
            Task { await ssh.disconnect() }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    await ssh.disconnect()
                    dismiss()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.neon)
                    .padding(8)
                    .background(Circle().fill(Theme.neonSoft))
            }

            PulsingDot(color: ssh.isConnected ? Theme.neon : .red)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.shortName)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)

                Text(ssh.statusText)
                    .font(.caption2.monospaced())
                    .foregroundColor(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                collectBufferAndOpen()
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.neon)
                    .padding(8)
                    .background(Circle().fill(Theme.neonSoft))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.95), Color.black.opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .overlay(
            Rectangle().frame(height: 1).foregroundColor(Theme.stroke),
            alignment: .bottom
        )
    }

    private var terminalArea: some View {
        TerminalViewWrapper(ssh: ssh, bridge: bridge)
            .background(Theme.bg)
    }

    private var bottomToolbar: some View {
        HStack(spacing: 10) {
            // 👇 修复：使用 SwiftUI.Color
            toolButton(icon: "doc.on.doc.fill", title: "复制屏幕", tint: SwiftUI.Color(Theme.neon)) {
                copyScreen()
            }
            toolButton(icon: "doc.on.clipboard", title: "粘贴", tint: SwiftUI.Color(Theme.violet)) {
                pasteFromClipboard()
            }
            toolButton(icon: "eraser.fill", title: "清屏", tint: SwiftUI.Color(Theme.magenta)) {
                ssh.send(Data([0x0C]))
            }
            Spacer()
            toolButton(icon: "keyboard", title: "键盘", tint: SwiftUI.Color(Theme.neon)) {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.becomeFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.85))
        .overlay(
            Rectangle().frame(height: 1).foregroundColor(Theme.stroke),
            alignment: .top
        )
    }

    private func toolButton(
        icon: String,
        title: String,
        tint: SwiftUI.Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(.footnote, design: .rounded).weight(.medium))
            }
            .foregroundColor(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tint.opacity(0.13))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(tint.opacity(0.35), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var toastView: some View {
        Group {
            if let toast {
                Text(toast)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.neon))
                    .shadow(color: Theme.neon.opacity(0.5), radius: 10)
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: toast)
    }

    private func copyScreen() {
        guard let view = bridge.terminalView else {
            showToast("暂无可复制内容")
            return
        }
        // 👇 修复：改用我们自己的方法
        let text = view.getTerminal().getVisibleText()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast("屏幕为空")
            return
        }
        copy(text, tip: "已复制整屏内容")
    }

    private func pasteFromClipboard() {
        guard let str = UIPasteboard.general.string, !str.isEmpty else {
            showToast("剪贴板为空")
            return
        }
        ssh.send(text: str)
        showToast("已粘贴")
    }

    private func collectBufferAndOpen() {
        guard let view = bridge.terminalView else {
            showToast("暂无可复制内容")
            return
        }
        let raw = view.getTerminal().getVisibleText()
        bufferLines = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        showBufferSheet = true
    }

    private func copy(_ text: String, tip: String) {
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showToast(tip)
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation { toast = nil }
        }
    }
}

struct BufferSheet: View {
    let lines: [String]
    let onCopy: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                if lines.isEmpty {
                    Text("暂无输出")
                        .foregroundColor(Theme.textDim)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(line)
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(Theme.text)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Button {
                                        onCopy(line)
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
            .navigationTitle("输出历史")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}
