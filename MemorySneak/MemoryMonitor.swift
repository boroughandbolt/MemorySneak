import AppKit
import Combine
import Darwin
import SwiftUI
import UserNotifications

enum MemoryLevel: Int {
    case okay = 0, watch = 1, danger = 2

    var color: Color {
        switch self {
        case .okay: return .green
        case .watch: return .orange
        case .danger: return .red
        }
    }

    var nsColor: NSColor {
        switch self {
        case .okay: return .systemGreen
        case .watch: return .systemOrange
        case .danger: return .systemRed
        }
    }

    var title: String {
        switch self {
        case .okay: return "All good"
        case .watch: return "Getting tight"
        case .danger: return "Close apps now"
        }
    }

    var dotImage: NSImage {
        let color = nsColor
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct AppUsage: Identifiable {
    let id: String
    let name: String
    let bytes: UInt64
    let bundlePath: String?
}

struct MemorySnapshot {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var pressure: Int32 = 1
    var swapUsedBytes: UInt64 = 0
    var freeDiskBytes: Int64 = 0
    var topApps: [AppUsage] = []
    var wineGames: [String] = []
    var nativeGames: [String] = []
    var gameBundles: Set<String> = []

    var isGaming: Bool { !wineGames.isEmpty || !nativeGames.isEmpty }
    var gameName: String? { wineGames.first ?? nativeGames.first }

    var usedPercent: Int {
        guard totalBytes > 0 else { return 0 }
        return min(100, Int(Double(usedBytes) / Double(totalBytes) * 100))
    }

    var pressureText: String {
        switch pressure {
        case 4: return "Critical"
        case 2: return "Elevated"
        default: return "Normal"
        }
    }

    var level: MemoryLevel {
        let gb: Int64 = 1_000_000_000
        if pressure == 4 || freeDiskBytes < 5 * gb || swapUsedBytes > totalBytes * 2 { return .danger }
        if pressure == 2 || freeDiskBytes < 20 * gb || swapUsedBytes > totalBytes { return .watch }
        return .okay
    }

    /// The biggest app worth quitting, only offered when memory is getting tight.
    var suggestion: AppUsage? {
        guard level != .okay else { return nil }
        return topApps.first { app in
            guard let path = app.bundlePath, !gameBundles.contains(path) else { return false }
            return !path.hasPrefix("/System/Library/") && !path.hasSuffix("/MemorySneak.app")
        }
    }

    var reason: String {
        let gb: Int64 = 1_000_000_000
        if freeDiskBytes < 20 * gb {
            return "Your disk is low. The Mac uses free disk space as extra memory, so clear some space too."
        }
        if pressure >= 2 { return "Your Mac is struggling for memory. Quit an app below." }
        if swapUsedBytes > totalBytes { return "A lot of memory has spilled onto your disk. Quit an app below." }
        return "Plenty of room right now."
    }
}

final class MemoryMonitor: ObservableObject {
    @Published private(set) var snapshot = MemorySnapshot()
    @Published private(set) var history: [Double] = []
    @Published private(set) var gameModeOn = false
    @Published private(set) var gameModeError: String?

    var level: MemoryLevel { snapshot.level }

    private let interval: TimeInterval = 5
    private let historyLength = 120
    private let queue = DispatchQueue(label: "MemorySneak.sampler", qos: .utility)
    private var timer: Timer?
    private var lastAlertLevel = MemoryLevel.okay
    private var lastAlertDate = Date.distantPast
    private let gameMode = GameModeController()
    private var gameModeBusy = false
    private var samplesWithoutWineGame = 0

    init() {
        UserDefaults.standard.register(defaults: [PrefKeys.quietWhileGaming: true, PrefKeys.forceGameMode: true])
        if gameMode.wasForced {
            gameMode.set(on: false) { _ in }
            gameMode.wasForced = false
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.gameModeOn else { return }
            self.gameMode.resetNow()
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refresh()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        queue.async { [weak self] in
            let sample = MemorySampler.sample()
            DispatchQueue.main.async { self?.apply(sample) }
        }
    }

    func quit(_ app: AppUsage) {
        guard let path = app.bundlePath else { return }
        let bundleName = URL(fileURLWithPath: path).lastPathComponent
        for running in NSWorkspace.shared.runningApplications {
            guard let url = running.bundleURL else { continue }
            let samePath = url.resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let builtInApp = url.lastPathComponent == bundleName
                && (url.path.contains("/Cryptexes/") || path.contains("/Cryptexes/"))
            if samePath || builtInApp { running.terminate() }
        }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    private func apply(_ newSample: MemorySnapshot) {
        var sample = newSample
        let natives = GameDetector.nativeGames()
        sample.nativeGames = natives.map { $0.name }
        sample.gameBundles.formUnion(natives.map { $0.bundle })
        snapshot = sample
        updateGameMode(for: sample)
        history.append(Double(sample.usedPercent) / 100)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
        alertIfNeeded(sample)
    }

    private func updateGameMode(for sample: MemorySnapshot) {
        let wanted = UserDefaults.standard.bool(forKey: PrefKeys.forceGameMode) && GameModeController.isAvailable
        let wineGameRunning = !sample.wineGames.isEmpty
        samplesWithoutWineGame = wineGameRunning ? 0 : samplesWithoutWineGame + 1
        let gameEnded = samplesWithoutWineGame >= 3
        if gameEnded && !gameModeOn { gameModeError = nil }
        guard !gameModeBusy else { return }

        if wanted && wineGameRunning && !gameModeOn && gameModeError == nil {
            gameModeBusy = true
            gameMode.set(on: true) { [weak self] error in
                guard let self else { return }
                self.gameModeBusy = false
                self.gameModeError = error
                if error == nil {
                    self.gameModeOn = true
                    self.gameMode.wasForced = true
                }
            }
        } else if gameModeOn && (!wanted || gameEnded) {
            gameModeBusy = true
            gameMode.set(on: false) { [weak self] error in
                guard let self else { return }
                self.gameModeBusy = false
                self.gameModeOn = false
                self.gameMode.wasForced = false
                self.gameModeError = error
            }
        }
    }

    private func alertIfNeeded(_ sample: MemorySnapshot) {
        if sample.isGaming && UserDefaults.standard.bool(forKey: PrefKeys.quietWhileGaming) { return }
        let level = sample.level
        defer { if level == .okay { lastAlertLevel = .okay } }
        guard level != .okay else { return }
        let isWorse = level.rawValue > lastAlertLevel.rawValue
        let isRepeat = Date().timeIntervalSince(lastAlertDate) > 1800
        guard isWorse || isRepeat else { return }
        lastAlertLevel = level
        lastAlertDate = Date()

        let content = UNMutableNotificationContent()
        content.title = "Memory: \(level.title)"
        if let app = sample.suggestion {
            let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: app.bytes), countStyle: .memory)
            content.body = "\(sample.reason) Quitting \(app.name) would free about \(size)."
        } else {
            content.body = sample.reason
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

enum MemorySampler {
    static func sample() -> MemorySnapshot {
        var result = MemorySnapshot()
        result.totalBytes = ProcessInfo.processInfo.physicalMemory
        result.usedBytes = usedMemory()
        result.pressure = pressureLevel()
        result.swapUsedBytes = swapUsed()
        result.freeDiskBytes = freeDisk()
        let scan = scanProcesses()
        result.topApps = scan.apps
        result.wineGames = scan.wineGames
        result.gameBundles = scan.gameBundles
        return result
    }

    private static func usedMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        let appPages = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        let pages = appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    private static func pressureLevel() -> Int32 {
        var value: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0)
        return value
    }

    private static func swapUsed() -> UInt64 {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return 0 }
        return swap.xsu_used
    }

    private static func freeDisk() -> Int64 {
        let values = try? URL(fileURLWithPath: "/")
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    private static func scanProcesses() -> (apps: [AppUsage], wineGames: [String], gameBundles: Set<String>) {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return ([], [], []) }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard found > 0 else { return ([], [], []) }

        var groups: [String: (name: String, bytes: UInt64, bundle: String?)] = [:]
        var wineGames: [String] = []
        var gameNamesByBundle: [String: String] = [:]
        for pid in pids.prefix(min(Int(found), pids.count)) where pid > 0 {
            guard let path = executablePath(of: pid) else { continue }
            let bundle = appBundlePath(in: path)

            if GameDetector.isWineProcess(path: path), let game = GameDetector.windowsGame(pid: pid, bundle: bundle) {
                if !wineGames.contains(game) { wineGames.append(game) }
                if let bundle { gameNamesByBundle[bundle] = game }
            }

            guard let bytes = footprint(of: pid) else { continue }
            let key = bundle ?? path
            let name = bundle.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                ?? URL(fileURLWithPath: path).lastPathComponent
            var group = groups[key] ?? (name: name, bytes: 0, bundle: bundle)
            group.bytes += bytes
            groups[key] = group
        }
        let apps = groups
            .map { key, value -> AppUsage in
                var name = value.name
                if let bundle = value.bundle, let game = gameNamesByBundle[bundle], game != name {
                    name = "\(game) (\(name))"
                }
                return AppUsage(id: key, name: name, bytes: value.bytes, bundlePath: value.bundle)
            }
            .sorted { $0.bytes > $1.bytes }
            .prefix(6)
            .map { $0 }
        return (apps, wineGames, Set(gameNamesByBundle.keys))
    }

    private static func footprint(of pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? usage.ri_phys_footprint : nil
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    private static func appBundlePath(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}
