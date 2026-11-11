import AppKit
import Darwin
import Foundation

enum PrefKeys {
    static let quietWhileGaming = "quietWhileGaming"
    static let forceGameMode = "forceGameModeForWineGames"
    static let gameModeWasForced = "gameModeWasForced"
}

/// Works out whether a game is running: native Mac games, plus Windows games
/// running through Wine wrappers such as Sikarugir, Wineskin, CrossOver or Whisky.
enum GameDetector {
    private static var nativeCache: [String: Bool] = [:]

    private static let launcherBundleIDs: Set<String> = [
        "com.valvesoftware.steam",
        "com.epicgames.EpicGamesLauncher",
        "com.gog.galaxy",
        "net.battle.app",
        "net.battle.bootstrapper",
    ]

    /// Native Mac games that are open right now. Call on the main thread.
    static func nativeGames() -> [(name: String, bundle: String)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  let url = app.bundleURL,
                  !launcherBundleIDs.contains(app.bundleIdentifier ?? ""),
                  isNativeGame(url) else { return nil }
            return (app.localizedName ?? url.deletingPathExtension().lastPathComponent, url.path)
        }
    }

    private static func isNativeGame(_ url: URL) -> Bool {
        if let known = nativeCache[url.path] { return known }
        var result = url.path.lowercased().contains("/steamapps/common/")
        if !result,
           let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
           let category = info["LSApplicationCategoryType"] as? String {
            result = category.lowercased().contains("games")
        }
        nativeCache[url.path] = result
        return result
    }

    // MARK: Wine games

    static func isWineProcess(path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        return lower.contains("/wine/") || name.hasPrefix("wine")
    }

    /// The Windows game a Wine process is running, or nil for Wine's own helpers and game launchers.
    static func windowsGame(pid: pid_t, bundle: String?) -> String? {
        let info = processStrings(of: pid)
        for argument in info.arguments {
            let name = argument
                .split(whereSeparator: { $0 == "\\" || $0 == "/" })
                .last.map(String.init) ?? argument
            let lower = name.lowercased()
            guard lower.hasSuffix(".exe"), isGameExecutable(lower) else { continue }
            return displayName(program: argument, fileName: name, pid: pid, environment: info.environment, bundle: bundle)
        }
        return nil
    }

    // MARK: Real game names

    private static var steamNameCache: [String: String] = [:]

    /// Prefers the name Steam shows for the game ("Marvel Rivals"), then the game's
    /// folder name, then the program's file name.
    private static func displayName(program: String, fileName: String, pid: pid_t,
                                     environment: [String: String], bundle: String?) -> String {
        var unixPaths: [String] = []
        if program.hasPrefix("/") {
            unixPaths.append(program)
        } else if let path = unixPath(forWindowsPath: program, environment: environment, bundle: bundle) {
            unixPaths.append(path)
        }
        if let folder = workingFolder(of: pid) { unixPaths.append(folder) }

        for path in unixPaths {
            if let name = steamName(forPath: path) { return name }
        }
        if let folder = folderAfterSteamCommon(in: program) { return spacedOut(folder) }
        return prettyName(fileName)
    }

    private static func unixPath(forWindowsPath path: String, environment: [String: String], bundle: String?) -> String? {
        let parts = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        guard let drive = parts.first, drive.count == 2, drive.hasSuffix(":") else { return nil }
        let rest = parts.dropFirst().joined(separator: "/")

        var prefixes: [String] = []
        if let prefix = environment["WINEPREFIX"] { prefixes.append(prefix) }
        if let bundle {
            prefixes += ["\(bundle)/Contents/SharedSupport/prefix", "\(bundle)/Contents/Resources", "\(bundle)/Contents"]
        }
        let letter = drive.lowercased()
        for prefix in prefixes {
            for root in ["\(prefix)/dosdevices/\(letter)", "\(prefix)/drive_\(letter.dropLast())"] {
                let candidate = "\(root)/\(rest)"
                if FileManager.default.fileExists(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    private static func steamName(forPath path: String) -> String? {
        guard let range = path.range(of: "/steamapps/common/", options: .caseInsensitive) else { return nil }
        let steamapps = String(path[..<range.lowerBound]) + "/steamapps"
        guard let folder = path[range.upperBound...].split(separator: "/").first.map(String.init) else { return nil }

        let key = steamapps + "|" + folder
        if let cached = steamNameCache[key] { return cached }

        var result = spacedOut(folder)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: steamapps)) ?? []
        for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
            guard let text = try? String(contentsOfFile: steamapps + "/" + file, encoding: .utf8),
                  manifestValue("installdir", in: text)?.caseInsensitiveCompare(folder) == .orderedSame,
                  let name = manifestValue("name", in: text) else { continue }
            result = name
            break
        }
        steamNameCache[key] = result
        return result
    }

    private static func manifestValue(_ key: String, in text: String) -> String? {
        let pattern = "\"\(key)\"\\s+\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func folderAfterSteamCommon(in path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard let range = normalized.range(of: "/steamapps/common/", options: .caseInsensitive) else { return nil }
        return normalized[range.upperBound...].split(separator: "/").first.map(String.init)
    }

    /// "MarvelRivals" becomes "Marvel Rivals".
    private static func spacedOut(_ folder: String) -> String {
        var result = ""
        var previous: Character?
        for character in folder.replacingOccurrences(of: "_", with: " ") {
            if character.isUppercase, let previous, previous.isLowercase { result.append(" ") }
            result.append(character)
            previous = character
        }
        return result
    }

    private static func workingFolder(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    private static let ignoredPrograms: Set<String> = [
        "steam.exe", "explorer.exe", "services.exe", "winedevice.exe", "plugplay.exe",
        "svchost.exe", "rpcss.exe", "conhost.exe", "start.exe", "wineboot.exe",
        "winemenubuilder.exe", "rundll32.exe", "tabtip.exe", "winecfg.exe", "regedit.exe",
        "cmd.exe", "control.exe", "msiexec.exe", "iexplore.exe", "notepad.exe", "taskmgr.exe",
        "wineconsole.exe", "mscorsvw.exe", "ngen.exe", "dxdiag.exe", "reg.exe", "cscript.exe",
        "wscript.exe", "powershell.exe", "xalia.exe", "galaxyclient.exe", "eadesktop.exe",
        "origin.exe", "battle.net.exe", "agent.exe", "upc.exe", "ubisoftconnect.exe",
        "epicgameslauncher.exe", "riotclientservices.exe", "rockstarlauncher.exe",
    ]

    private static let ignoredWords = [
        "setup", "install", "unins", "redist", "crash", "helper", "update", "launcher",
        "service", "overlay", "cefprocess", "anticheat", "battleye", "reporter",
    ]

    private static func isGameExecutable(_ lower: String) -> Bool {
        !ignoredPrograms.contains(lower) && !ignoredWords.contains { lower.contains($0) }
    }

    private static func prettyName(_ name: String) -> String {
        var result = String(name.dropLast(4))
        for suffix in ["-Win64-Shipping", "-Win32-Shipping", "_x64", "64"] where result.hasSuffix(suffix) && result.count > suffix.count {
            result = String(result.dropLast(suffix.count))
            break
        }
        return result
    }

    private static func processStrings(of pid: pid_t) -> (arguments: [String], environment: [String: String]) {
        var maxSize: Int32 = 0
        var sizeOfMax = MemoryLayout<Int32>.size
        var argmaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMIB, 2, &maxSize, &sizeOfMax, nil, 0) == 0, maxSize > 0 else { return ([], [:]) }

        var size = Int(maxSize)
        var buffer = [UInt8](repeating: 0, count: size)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return ([], [:]) }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }   // skip the executable path
        while index < size && buffer[index] == 0 { index += 1 }   // skip padding

        var result: [String] = []
        while index < size && result.count < Int(argc) {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }

        var environment: [String: String] = [:]
        while index < size && buffer[index] != 0 {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            let entry = String(decoding: buffer[start..<index], as: UTF8.self)
            if let equals = entry.firstIndex(of: "=") {
                environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
            }
            index += 1
        }
        return (result, environment)
    }
}

/// Turns macOS Game Mode on for games macOS doesn't recognize, using the
/// gamepolicyctl tool that comes with Xcode, and hands control back afterwards.
final class GameModeController {
    static let toolPath: String? = [
        "/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl",
        "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/gamepolicyctl",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    static var isAvailable: Bool { toolPath != nil }

    private let queue = DispatchQueue(label: "MemorySneak.gamemode")

    var wasForced: Bool {
        get { UserDefaults.standard.bool(forKey: PrefKeys.gameModeWasForced) }
        set { UserDefaults.standard.set(newValue, forKey: PrefKeys.gameModeWasForced) }
    }

    /// Forces Game Mode on, or back to automatic. Calls back on the main thread with an error, if any.
    func set(on: Bool, completion: @escaping (String?) -> Void) {
        guard let tool = Self.toolPath else {
            completion("Game Mode needs Xcode installed.")
            return
        }
        queue.async {
            let error = Self.run(tool, on: on)
            DispatchQueue.main.async { completion(error) }
        }
    }

    /// Hands Game Mode back to macOS straight away, for when Memory Sneak is quitting.
    func resetNow() {
        guard let tool = Self.toolPath else { return }
        _ = Self.run(tool, on: false)
        wasForced = false
    }

    private static func run(_ tool: String, on: Bool) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["game-mode", "set", on ? "on" : "auto"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "Couldn't change Game Mode: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Couldn't change Game Mode (code \(process.terminationStatus))." : text
    }
}
