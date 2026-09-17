import SwiftUI

@main
struct MidiToMp3App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 660, minHeight: 520)
        }
        .windowResizability(.contentSize)
    }
}
