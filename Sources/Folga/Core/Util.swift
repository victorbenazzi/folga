import AppKit
import Foundation
import SwiftUI

// MARK: - Formatting

enum Fmt {
    private static let fileFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()

    private static let memFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useMB, .useGB]
        return f
    }()

    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.unitsStyle = .full
        return f
    }()

    static func bytes(_ v: Int64) -> String { v <= 0 ? "0 KB" : fileFormatter.string(fromByteCount: v) }
    static func mem(_ v: Int64) -> String { memFormatter.string(fromByteCount: max(0, v)) }
    static func ago(_ d: Date?) -> String {
        guard let d else { return "nunca" }
        return relFormatter.localizedString(for: d, relativeTo: Date())
    }
    static func pct(_ v: Double) -> String { String(format: "%.1f%%", v) }
}

// MARK: - Paths

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static func expand(_ p: String) -> String {
        p.hasPrefix("~") ? home + p.dropFirst() : p
    }

    /// Expands `~` and shell wildcards. Returns only paths that exist.
    static func glob(_ pattern: String) -> [String] {
        let pat = expand(pattern)
        if !pat.contains("*") && !pat.contains("?") && !pat.contains("[") {
            return exists(pat) ? [pat] : []
        }
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pat, 0, nil, &g) == 0 else { return [] }
        var out: [String] = []
        for i in 0..<Int(g.gl_pathc) {
            if let c = g.gl_pathv[i] { out.append(String(cString: c)) }
        }
        return out
    }

    static func exists(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0
    }

    static func isDir(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func mtime(_ p: String) -> Date? {
        var st = stat()
        guard lstat(p, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    static func children(_ p: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: p))?.map { p + "/" + $0 } ?? []
    }

    static func pretty(_ p: String) -> String {
        p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    static func isOwnedByUser(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0 && st.st_uid == getuid()
    }
}

// MARK: - Disk size (fts, fast, no Foundation overhead)

enum DiskSize {
    /// Allocated bytes of a file or directory tree. Does not follow symlinks or cross volumes.
    static func of(_ path: String) -> Int64 {
        var total: Int64 = 0
        walk(path) { ent in
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_F || info == FTS_SL || info == FTS_SLNONE || info == FTS_DEFAULT,
               let st = ent.pointee.fts_statp {
                total += Int64(st.pointee.st_blocks) * 512
            }
            return .go
        }
        return total
    }

    static func of(_ paths: [String]) -> Int64 { paths.reduce(0) { $0 + of($1) } }

    /// Sizes many paths in parallel.
    static func many(_ paths: [String]) -> [String: Int64] {
        let lock = NSLock()
        var out: [String: Int64] = [:]
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            let s = of(paths[i])
            lock.lock(); out[paths[i]] = s; lock.unlock()
        }
        return out
    }

    enum Action { case go, skip, stop }

    static func walk(_ root: String, _ visit: (UnsafeMutablePointer<FTSENT>) -> Action) {
        root.withCString { c in
            guard let dup = strdup(c) else { return }
            defer { free(dup) }
            var argv: [UnsafeMutablePointer<CChar>?] = [dup, nil]
            guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
            defer { fts_close(fts) }
            while let ent = fts_read(fts) {
                switch visit(ent) {
                case .go: break
                case .skip: fts_set(fts, ent, FTS_SKIP)
                case .stop: return
                }
            }
        }
    }

    @inline(__always) static func name(_ e: UnsafeMutablePointer<FTSENT>) -> String {
        let off = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name)!
        return String(cString: (UnsafeRawPointer(e) + off).assumingMemoryBound(to: CChar.self))
    }

    @inline(__always) static func path(_ e: UnsafeMutablePointer<FTSENT>) -> String {
        String(cString: e.pointee.fts_path)
    }
}

// MARK: - Shell

enum Shell {
    struct Result { let status: Int32; let out: String; let err: String; var ok: Bool { status == 0 } }

    @discardableResult
    static func run(_ exe: String, _ args: [String] = [], timeout: TimeInterval = 60) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + Paths.home + "/.local/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(status: -1, out: "", err: error.localizedDescription) }
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let outData = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        g.wait()
        timer.cancel()
        return Result(status: p.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
    }

    /// Runs a command through /bin/zsh -lc so user tools (brew, docker, xcrun) resolve.
    @discardableResult
    static func sh(_ cmd: String, timeout: TimeInterval = 600) -> Result {
        run("/bin/zsh", ["-lc", cmd], timeout: timeout)
    }

    /// Runs a shell command as root. macOS shows its own password dialog.
    @discardableResult
    static func admin(_ cmd: String) -> Result {
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: 900)
    }

    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func which(_ tool: String) -> String? {
        for d in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", Paths.home + "/.local/bin", Paths.home + "/.cargo/bin", Paths.home + "/go/bin", Paths.home + "/.bun/bin"] {
            let p = d + "/" + tool
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}

// MARK: - File operations

enum FileOps {
    struct Outcome { var freed: Int64 = 0; var failed: [String] = []; var needsAdmin: [String] = [] }

    /// Permanently removes a path. Used for regenerable data (caches, builds).
    static func remove(_ path: String) -> Bool {
        do { try FileManager.default.removeItem(atPath: path); return true } catch {
            // Read-only trees (Go modules, some caches): make writable and retry.
            _ = Shell.run("/bin/chmod", ["-R", "u+w", path], timeout: 120)
            return (try? FileManager.default.removeItem(atPath: path)) != nil
        }
    }

    static func removeContents(_ dir: String) -> Bool {
        var ok = true
        for c in Paths.children(dir) where !remove(c) { ok = false }
        return ok
    }

    static func trash(_ path: String) -> Bool {
        (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)) != nil
    }

    static func adminRemove(_ paths: [String]) -> Bool {
        guard !paths.isEmpty else { return true }
        return Shell.admin("/bin/rm -rf " + paths.map(Shell.q).joined(separator: " ")).ok
    }

    static func adminTrash(_ paths: [String]) -> Bool {
        guard !paths.isEmpty else { return true }
        let trash = Paths.home + "/.Trash/"
        let cmd = paths.map { "/bin/mv -f \(Shell.q($0)) \(Shell.q(trash + (($0 as NSString).lastPathComponent) + ".\(Int(Date().timeIntervalSince1970))"))" }.joined(separator: "; ")
        return Shell.admin(cmd).ok
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

// MARK: - System

enum SystemInfo {
    static var hasFullDiskAccess: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: "/Library/Application Support/com.apple.TCC")) != nil
    }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    static func openLoginItemsSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    struct Disk { let total: Int64; let free: Int64; let important: Int64 }

    static func disk() -> Disk {
        let url = URL(fileURLWithPath: "/")
        let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return Disk(total: Int64(v?.volumeTotalCapacity ?? 0),
                    free: Int64(v?.volumeAvailableCapacity ?? 0),
                    important: v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    private static let iconCache = NSCache<NSString, NSImage>()

    static func icon(_ path: String) -> NSImage {
        if let c = iconCache.object(forKey: path as NSString) { return c }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 32, height: 32)
        iconCache.setObject(i, forKey: path as NSString)
        return i
    }
}

// MARK: - Safety

enum Safety: Int, Comparable, CaseIterable {
    case safe, caution, danger

    static func < (a: Safety, b: Safety) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .safe: "Seguro"
        case .caution: "Cuidado"
        case .danger: "Não mexa"
        }
    }


    var symbol: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        }
    }
}

struct SafetyBadge: View {
    let safety: Safety
    var help: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(safety.fg).frame(width: 6, height: 6)
            Text(safety.label).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(safety.fg)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(safety.soft))
        .help(help ?? safety.label)
        .fixedSize()
    }
}
