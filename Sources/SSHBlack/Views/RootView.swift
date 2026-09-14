import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationStack {
            SessionListView()
        }
        .tint(Theme.neon)
    }
}
