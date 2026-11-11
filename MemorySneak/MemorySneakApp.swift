import SwiftUI

@main
struct MemorySneakApp: App {
    @StateObject private var monitor = MemoryMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(monitor)
        } label: {
            HStack(spacing: 4) {
                if monitor.snapshot.isGaming {
                    Image(systemName: "gamecontroller.fill")
                } else {
                    Image(nsImage: monitor.level.dotImage)
                }
                Text("\(monitor.snapshot.usedPercent)%")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
