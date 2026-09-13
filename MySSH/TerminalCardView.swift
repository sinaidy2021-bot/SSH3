import SwiftUI
struct TerminalCardView: View {
    let item: CommandHistoryItem
    var body: some View {
        VStack(alignment:.leading, spacing: 0) {
            HStack {
                Text(item.command)
                   .font(.system(.callout, design:.monospaced).bold())
                   .textSelection(.enabled)
                Spacer()
                Button {
                    UIPasteboard.general.string = "> \(item.command)\n\(item.output)"
                } label: {
                    Text("复制整段").font(.caption.bold()).padding(8).background(Color.blue).foregroundColor(.white).clipShape(Capsule())
                }
            }.padding(12)
            Divider()
            Text(item.output.isEmpty? " " : item.output)
               .font(.system(.footnote, design:.monospaced))
               .textSelection(.enabled)
               .frame(maxWidth:.infinity, alignment:.leading)
               .padding(12)
            if item.output.count > 200 {
                HStack {
                    Spacer()
                    Button { UIPasteboard.general.string = item.output } label: { Text("复制输出").font(.caption) }
                    Button { UIPasteboard.general.string = "> \(item.command)\n\(item.output)" } label: { Text("复制整段").font(.caption.bold()).padding(8).background(Color(.secondarySystemFill)).clipShape(Capsule()) }
                }.padding(12)
            }
        }.background(Color(.secondarySystemBackground)).cornerRadius(12)
    }
}
