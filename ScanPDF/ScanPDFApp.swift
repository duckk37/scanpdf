import SwiftUI

@main
struct ScanPDFApp: App {
    @StateObject private var store = DocumentStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(Theme.teal)
                .preferredColorScheme(.light)
        }
    }
}
