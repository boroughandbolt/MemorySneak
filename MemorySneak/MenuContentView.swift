import AppKit
import ServiceManagement
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var monitor: MemoryMonitor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(PrefKeys.quietWhileGaming) private var quietWhileGaming = true
    @AppStorage(PrefKeys.forceGameMode) private var forceGameMode = true

    private var snapshot: MemorySnapshot { monitor.snapshot }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if snapshot.isGaming {
                gamingBanner
            }
            if let app = snapshot.suggestion {
                suggestionRow(for: app)
            }
            ProgressView(value: Double(snapshot.usedPercent), total: 100)
                .tint(monitor.level.color)
            HistoryGraph(values: monitor.history, color: monitor.level.color)
                .frame(height: 44)
            Divider()
            detail("Memory pressure", snapshot.pressureText)
            detail("Spilled to disk (swap)", format(snapshot.swapUsedBytes))
            detail("Free disk space", formatDisk(snapshot.freeDiskBytes))
            Divider()
            Text("Using the most").font(.caption).foregroundStyle(.secondary)
            ForEach(snapshot.topApps) { app in
                AppRow(app: app, size: format(app.bytes)) { monitor.quit(app) }
            }
            Divider()
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            Toggle("Quiet while gaming", isOn: $quietWhileGaming)
            Toggle("Game Mode for Wine games", isOn: $forceGameMode)
                .disabled(!GameModeController.isAvailable)
                .onChange(of: forceGameMode) { _, _ in monitor.refresh() }
                .help(GameModeController.isAvailable
                      ? "Turns on Game Mode for Sikarugir, CrossOver and other Wine games"
                      : "Needs Xcode installed")
            HStack {
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                Spacer()
                Button("Quit Memory Sneak") { NSApplication.shared.terminate(nil) }
            }
            Text("Version \(appVersion)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(14)
        .frame(width: 310)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(snapshot.usedPercent)%").font(.system(size: 30, weight: .semibold).monospacedDigit())
                Text("\(format(snapshot.usedBytes)) of \(format(snapshot.totalBytes))")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(monitor.level.title).font(.callout.weight(.semibold)).foregroundStyle(monitor.level.color)
            }
            Text(snapshot.reason).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gamingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "gamecontroller.fill").foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Playing \(snapshot.gameName ?? "a game")").font(.callout.weight(.semibold))
                Text(gamingStatus).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = monitor.gameModeError {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private var gamingStatus: String {
        var parts = [quietWhileGaming ? "Alerts paused" : "Alerts on"]
        if !snapshot.wineGames.isEmpty {
            if monitor.gameModeOn {
                parts.append("Game Mode on")
            } else if !forceGameMode || !GameModeController.isAvailable {
                parts.append("Game Mode not forced")
            }
        } else {
            parts.append("macOS handles Game Mode")
        }
        return parts.joined(separator: " · ")
    }

    private func suggestionRow(for app: AppUsage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb.fill").foregroundStyle(monitor.level.color)
            Text("Quitting \(app.name) would free about \(format(app.bytes))")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Quit") { monitor.quit(app) }.controlSize(.small)
        }
        .padding(8)
        .background(monitor.level.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    private func formatDisk(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct AppRow: View {
    let app: AppUsage
    let size: String
    let quit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(app.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            if hovering, app.bundlePath != nil {
                Button("Quit", action: quit).controlSize(.small)
            } else {
                Text(size).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(height: 20)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct HistoryGraph: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let line = path(in: proxy.size)
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5))
                line.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .accessibilityLabel("Memory use over the last ten minutes")
    }

    private func path(in size: CGSize) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = size.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(value)))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
