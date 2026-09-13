import SwiftUI

struct SessionEditView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State var session: Session
    let isNew: Bool

    @State private var password: String = ""
    @State private var passphrase: String = ""
    @State private var showError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        fieldCard {
                            iconField(icon: "textformat", title: "名称") {
                                TextField("例如：生产服务器", text: $session.name)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }

                        fieldCard {
                            iconField(icon: "globe", title: "主机") {
                                TextField("IP 或域名", text: $session.host)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.URL)
                            }
                            divider
                            iconField(icon: "number", title: "端口") {
                                TextField("22", value: $session.port, format: .number)
                                    .keyboardType(.numberPad)
                            }
                        }

                        fieldCard {
                            iconField(icon: "person", title: "用户名") {
                                TextField("root", text: $session.username)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }

                        // 认证方式
                        fieldCard {
                            Picker("认证方式", selection: $session.authKind) {
                                ForEach(Session.AuthKind.allCases, id: \.self) { kind in
                                    Text(kind.label).tag(kind)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)

                            divider

                            if session.authKind == .password {
                                iconField(icon: "lock", title: "密码") {
                                    SecureField("登录密码", text: $password)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "key.horizontal")
                                            .foregroundColor(Theme.neon)
                                            .frame(width: 20)
                                        Text("私钥内容")
                                            .font(.system(.subheadline, design: .rounded))
                                            .foregroundColor(Theme.text)
                                        Spacer()
                                    }
                                    TextEditor(text: Binding(
                                        get: { session.privateKey ?? "" },
                                        set: { session.privateKey = $0 }
                                    ))
                                    .frame(minHeight: 120)
                                    .font(.system(.caption, design: .monospaced))
                                    .scrollContentBackground(.hidden)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color.black.opacity(0.4))
                                    )
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)

                                divider

                                iconField(icon: "lock.shield", title: "私钥口令") {
                                    SecureField("没有可留空", text: $passphrase)
                                }
                            }
                        }

                        if let showError {
                            Text(showError)
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding(.horizontal, 4)
                        }

                        Button {
                            saveAndClose()
                        } label: {
                            Text(isNew ? "保存并完成" : "保存修改")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(NeonButtonStyle(enabled: canSave))
                        .disabled(!canSave)
                        .padding(.top, 4)
                    }
                    .padding(20)
                }
            }
            .navigationTitle(isNew ? "新建会话" : "编辑会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.text)
                }
            }
        }
        .onAppear {
            password = store.password(for: session)
            passphrase = store.passphrase(for: session)
        }
    }

    // MARK: - 组件

    private func fieldCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.bgElev)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Theme.stroke, lineWidth: 1)
                    )
            )
    }

    private func iconField<Content: View>(
        icon: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.neon)
                .frame(width: 22)
            Text(title)
                .font(.system(.subheadline, design: .rounded))
                .foregroundColor(Theme.textDim)
                .frame(width: 52, alignment: .leading)
            content()
                .foregroundColor(Theme.text)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle()
            .frame(height: 1)
            .foregroundColor(Theme.stroke)
            .padding(.leading, 44)
    }

    private var canSave: Bool {
        !session.host.isEmpty && !session.username.isEmpty
    }

    // MARK: - 保存

    private func saveAndClose() {
        if session.name.isEmpty {
            session.name = session.host
        }

        store.upsert(session)
        store.setPassword(password, for: session)
        store.setPassphrase(passphrase, for: session)

        dismiss()
    }
}
