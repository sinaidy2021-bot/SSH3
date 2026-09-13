import SwiftUI
struct SessionView: View {
    @ObservedObject var session: SSHSession
    @State var input = ""
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading, spacing: 12) {
                        ForEach(session.history) { item in
                            TerminalCardView(item: item).id(item.id)
                        }
                    }.padding()
                }
               .onChange(of: session.history.count) { _ in
                    if let last = session.history.last { proxy.scrollTo(last.id, anchor:.bottom) }
                }
            }
            Divider()
            HStack {
                TextField("输入命令回车发送", text: $input, onCommit: { send() })
                   .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("发送") { send() }
            }.padding()
            HStack {
                Button("Ctrl+C") { session.sendCtrlC() }
                Button("Tab") { session.sendTab() }
                Spacer()
                Button("断开") { session.disconnect() }.tint(.red)
            }.font(.caption).padding(.horizontal).padding(.bottom, 8)
        }.navigationTitle(session.host)
    }
    func send() {
        let c = input.trimmingCharacters(in:.whitespacesAndNewlines)
        if c.isEmpty { return }
        session.sendCommand(c)
        input = ""
    }
}
