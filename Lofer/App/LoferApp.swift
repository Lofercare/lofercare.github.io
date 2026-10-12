import SwiftUI

/// App entry point. Everything starts here: fonts are registered, the shared AppModel
/// (services + navigation) is created, and RootView decides which screen to show.
@main
struct LoferApp: App {
    // Voice provider from the launch arguments: the mock by default, -LoferVoice elevenlabs for real speech.
    @State private var app = AppModel(voice: VoiceConfig.fromLaunchArguments().makeAgent())
    init() { LoferFont.registerBundledFonts() }
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
        }
    }
}
