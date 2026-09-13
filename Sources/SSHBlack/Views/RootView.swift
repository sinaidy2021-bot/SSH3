import SwiftUI
import SwiftTerm
import UIKit

/// 终端输入 / 输出桥
final class TerminalBridge: NSObject, TerminalViewDelegate {
    weak var terminalView: TerminalView?
    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onResize?(newCols, newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(data: content, encoding: .utf8) {
            UIPasteboard.general.string = str
        }
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

struct TerminalViewWrapper: UIViewRepresentable {
    @ObservedObject var ssh: SSHService
    let bridge: TerminalBridge

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = bridge
        bridge.terminalView = view

        // 主题
        view.backgroundColor = UIColor(Theme.bg)
        view.nativeBackgroundColor = UIColor(Theme.bg)
        view.nativeForegroundColor = UIColor(Theme.text)
        view.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

        // SSH → 终端
        ssh.onData = { [weak view] data in
            guard let view else { return }
            DispatchQueue.main.async {
                view.feed(byteArray: [UInt8](data)[...])
            }
        }

        // 键盘 → SSH
        bridge.onInput = { [weak ssh] data in
            ssh?.send(data)
        }
        bridge.onResize = { [weak ssh] cols, rows in
            ssh?.resize(cols: cols, rows: rows)
        }

        DispatchQueue.main.async {
            view.becomeFirstResponder()
        }

        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}
}
