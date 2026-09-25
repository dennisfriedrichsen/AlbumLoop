import StillroomCore
import SwiftUI
import UIKit

@main
struct StillroomApp: App {
    @State private var library = PhotoLibraryModel()
    @State private var recents = RecentPlaybackStore()
    @State private var router = PlaybackRouter()

    init() {
        // Local-only diagnostics log in Caches (purgeable, never uploaded). Copy it off with:
        // xcrun devicectl device copy from --domain-type appDataContainer ... (see README).
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        DiagnosticFileLog.shared.configure(directory: caches.appendingPathComponent("Diagnostics"))
        StillroomLog.library.info(
            "Launched Stillroom \(AppInfo.version) (\(AppInfo.build)) on \(DeviceClass.modelIdentifier), "
                + "tvOS \(UIDevice.current.systemVersion)"
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(recents)
                .environment(router)
                .preferredColorScheme(.dark)
        }
    }
}
