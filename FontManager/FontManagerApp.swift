import SwiftUI
import AppKit
#if !APPSTORE
import Sparkle
#endif

@main
struct FontManagerApp: App {
    #if !APPSTORE
    @StateObject private var updaterModel = UpdaterViewModel()
    #endif
    @StateObject private var toastCenter: ToastCenter
    @StateObject private var fontService: FontService
    @StateObject private var conversion: ConversionManager
    @StateObject private var mcpController = MCPServerController()

    init() {
        WelcomeView.skipForExistingUsers()
        AppTips.configure()
        let toast = ToastCenter()
        _toastCenter = StateObject(wrappedValue: toast)
        _fontService = StateObject(wrappedValue: FontService(toast: toast))
        _conversion = StateObject(wrappedValue: ConversionManager(toast: toast))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(fontService)
                .environmentObject(conversion)
                .environmentObject(toastCenter)
                .environmentObject(mcpController)
                #if !APPSTORE
                .environmentObject(updaterModel)
                #endif
                .task {
                    mcpController.fontService = fontService
                    mcpController.startIfEnabled()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1000, height: 700)
        .commands {
            #if !APPSTORE
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterModel.updater)
            }
            #endif
            CommandGroup(after: .newItem) {
                Button("Convert a Font…") {
                    conversion.showConvert = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Welcome to Font Manager") {
                    UserDefaults.standard.set(false, forKey: WelcomeView.hasSeenKey)
                }
                Divider()
                AcknowledgementsCommand()
            }
            CommandGroup(after: .textEditing) {
                Button("Find") {
                    fontService.focusSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(mcpController)
                #if !APPSTORE
                .environmentObject(updaterModel)
                #endif
        }

        Window("Acknowledgements", id: AcknowledgementsView.windowID) {
            AcknowledgementsView()
        }
        .windowResizability(.contentSize)
    }
}
