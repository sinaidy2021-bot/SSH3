import SwiftUI

/// 全局视觉风格：赛博霓虹
enum Theme {
    static let neon      = Color(red: 0.00, green: 0.93, blue: 0.62)   // 霓虹青绿
    static let neonSoft  = Color(red: 0.00, green: 0.93, blue: 0.62).opacity(0.15)
    static let violet    = Color(red: 0.55, green: 0.42, blue: 1.00)   // 电紫
    static let magenta   = Color(red: 1.00, green: 0.30, blue: 0.72)   // 品红
    static let bg        = Color(red: 0.02, green: 0.02, blue: 0.04)
    static let bgElev    = Color(red: 0.06, green: 0.06, blue: 0.09)
    static let stroke    = Color.white.opacity(0.08)
    static let text      = Color.white.opacity(0.92)
    static let textDim   = Color.white.opacity(0.55)

    static let mono = Font.system(.body, design: .monospaced)

    /// 霓虹渐变
    static var neonGradient: LinearGradient {
        LinearGradient(
            colors: [neon, violet],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 玻璃拟态背景
    static var glass: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

/// 呼吸灯效果
struct PulsingDot: View {
    let color: Color
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 18, height: 18)
                .scaleEffect(animate ? 1.4 : 0.9)
                .opacity(animate ? 0 : 1)

            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}

/// 主按钮：霓虹渐变
struct NeonButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                Group {
                    if enabled {
                        Theme.neonGradient
                    } else {
                        Color.white.opacity(0.1)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: enabled ? Theme.neon.opacity(0.45) : .clear, radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25), value: configuration.isPressed)
    }
}

/// 幽灵按钮
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.medium))
            .foregroundColor(Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.stroke, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25), value: configuration.isPressed)
    }
}
