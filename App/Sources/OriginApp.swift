import SwiftUI
import OriginKit

@main
struct OriginApp: App {
    @StateObject private var store = OriginStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: OriginStore

    var body: some View {
        TabView {
            NavigationView { RepositoryListView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("Sources", systemImage: "shippingbox") }

            NavigationView { BackupsView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("Backups", systemImage: "clock.arrow.circlepath") }

            NavigationView { SettingsView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onAppear { store.reload() }
    }
}
