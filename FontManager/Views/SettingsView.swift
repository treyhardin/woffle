import SwiftUI

/// Settings window (⌘,). The Updates section exists only in the open-source build — the
/// App Store build is updated by the App Store.
struct SettingsView: View {
    #if !APPSTORE
    @EnvironmentObject var updaterModel: UpdaterViewModel
    #endif

    var body: some View {
        Form {
            #if !APPSTORE
            UpdateSettingsSection(updater: updaterModel.updater)
            #endif
            MCPSettingsView()
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
