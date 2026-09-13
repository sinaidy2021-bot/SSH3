import SwiftUI

struct SessionListView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var editing: Session?
    @State private var isNew = false

    var body: some View {
        ZStack {
            // 背景：深色 + 霓虹光晕
            Theme.bg.ignoresSafeArea()
            RadialGradient(
                colors: [Theme.violet.opacity(0.18), .clear],
                center: .topTrailing, startRadius: 20, endRadius: 480
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [Theme.neon.opacity(0.15), .clear],
                center: .bottomLeading, startRadius: 20, endRadius: 520
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                content
            }
        }
        .sheet(item: $editing) { session in
            SessionEditView(session: session, isNew: isNew)
                .environmentObject(store)
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SSH 黑")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.neonGradient)
                Text("\(store.sessions.count) 个会话")
                    .font(.caption)
                    .foregroundColor(Theme.textDim)
            }

            Spacer()

            Button {
                isNew = true
                editing = Session(name: "", host: "", port: 22, username: "")
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.neonGradient))
                    .shadow(color: Theme.neon.opacity(0.6), radius: 12)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    // MARK: - 列表内容

    @ViewBuilder
    private var content: some View {
        if store.sessions.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.sessions) { session in
                        NavigationLink {
                            TerminalScreen(session: session)
                        } label: {
                            SessionCard(session: session)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                isNew = false
                                editing = session
                            } label: {
                                Label("编辑", systemImage: "square.and.pencil")
                            }
                            Button(role: .destructive) {
                                store.delete(session)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Theme.neonSoft)
                    .frame(width: 110, height: 110)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(Theme.neonGradient)
            }
            Text("还没有会话")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundColor(Theme.text)
            Text("点击右上角 + 添加你的第一台服务器")
                .font(.subheadline)
                .foregroundColor(Theme.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }
}

// MARK: - 会话卡片

struct SessionCard: View {
    let session: Session

    var body: some View {
        HStack(spacing: 14) {
            // 头像
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.neon.opacity(0.85), Theme.violet.opacity(0.85)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                Text(initial)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundColor(.black)
            }
            .shadow(color: Theme.neon.opacity(0.35), radius: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.shortName)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)

                Text(session.displayHost)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textDim)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.bgElev)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    private var initial: String {
        let base = session.shortName
        return String(base.prefix(1)).uppercased()
    }
}
