import SwiftUI
struct ContentView: View {
    @StateObject var session = SSHSession()
    @State var host = ""
    @State var username = "root"
    @State var password = ""
    @State var showSession = false
    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("IP 例如 8.8.8.8", text: $host)
                    TextField("用户名", text: $username)
                    SecureField("密码", text: $password)
                }
                Button("连接") {
                    session.host = host
                    session.username = username
                    session.password = password
                    session.connect()
                    showSession = true
                }
            }
           .navigationTitle("MySSH")
           .navigationDestination(isPresented: $showSession) {
                SessionView(session: session)
            }
        }
    }
}
