import SwiftUI

/// 底部快捷键条
struct QuickKeyBar: View {
    let onKey: (QuickKey) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(QuickKey.allCases, id: \.self) { key in
                    Button {
                        onKey(key)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(key.label)
                            .font(.system(.footnote, design: .monospaced).weight(.medium))
                            .foregroundColor(Theme.neon)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Theme.neonSoft)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Theme.neon.opacity(0.35), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.black.opacity(0.6))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Theme.stroke),
            alignment: .top
        )
    }
}

enum QuickKey: CaseIterable {
    case esc, tab, ctrlC, ctrlD, ctrlL, ctrlZ
    case arrowUp, arrowDown, arrowLeft, arrowRight
    case pipe, tilde, slash, dash, star, dollar

    var label: String {
        switch self {
        case .esc: return "Esc"
        case .tab: return "Tab"
        case .ctrlC: return "^C"
        case .ctrlD: return "^D"
        case .ctrlL: return "^L"
        case .ctrlZ: return "^Z"
        case .arrowUp: return "↑"
        case .arrowDown: return "↓"
        case .arrowLeft: return "←"
        case .arrowRight: return "→"
        case .pipe: return "|"
        case .tilde: return "~"
        case .slash: return "/"
        case .dash: return "-"
        case .star: return "*"
        case .dollar: return "$"
        }
    }

    var bytes: Data {
        switch self {
        case .esc: return Data([0x1B])
        case .tab: return Data([0x09])
        case .ctrlC: return Data([0x03])
        case .ctrlD: return Data([0x04])
        case .ctrlL: return Data([0x0C])
        case .ctrlZ: return Data([0x1A])
        case .arrowUp:    return Data([0x1B, 0x5B, 0x41])
        case .arrowDown:  return Data([0x1B, 0x5B, 0x42])
        case .arrowRight: return Data([0x1B, 0x5B, 0x43])
        case .arrowLeft:  return Data([0x1B, 0x5B, 0x44])
        case .pipe:   return Data("|".utf8)
        case .tilde:  return Data("~".utf8)
        case .slash:  return Data("/".utf8)
        case .dash:   return Data("-".utf8)
        case .star:   return Data("*".utf8)
        case .dollar: return Data("$".utf8)
        }
    }
}
