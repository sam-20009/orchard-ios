import SwiftUI

@main
struct AetherXRApp: App {
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(library)
                .preferredColorScheme(.dark)
        }
    }
}
