import SwiftUI

@main
struct AlbumLoopApp: App {
    @State private var library = PhotoLibraryModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .preferredColorScheme(.dark)
        }
    }
}
