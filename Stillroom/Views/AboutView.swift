import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text("Stillroom")
                .font(.largeTitle.bold())
            Text("Version \(AppInfo.version) (build \(AppInfo.build))")
                .font(.title3)
            VStack(alignment: .leading, spacing: 16) {
                Text("Plays complete Photos albums, including photos stored only in iCloud.")
                Text("Requires tvOS 18 or later.")
                Text(
                    "Privacy: photos are read through Apple’s Photos framework and kept only in memory while they’re "
                        + "on screen or about to be. Stillroom saves no copies, has no accounts, and sends nothing "
                        + "to any server. Diagnostics stay on this Apple TV."
                )
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: 1300, alignment: .leading)
            Spacer()
        }
        .padding(80)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
