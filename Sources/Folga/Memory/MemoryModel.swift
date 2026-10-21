import AppKit
import Darwin
import Foundation

// MARK: - System memory

struct MemorySnapshot {
    var total: Int64 = 0
    var app: Int64 = 0
    var wired: Int64 = 0
    var compressed: Int64 = 0
    var cached: Int64 = 0
    var free: Int64 = 0
    var swapUsed: Int64 = 0
    var swapTotal: Int64 = 0
    var pressure: Int32 = 1

    var used: Int64 { app + wired + compressed }

    var pressureLabel: String {
        switch pressure {
        case 4: "Crítica"
        case 2: "Alta"
        default: "Normal"
        }
    }

    static func read() -> MemorySnapshot {
        var s = MemorySnapshot()
        s.total = Int64(ProcessInfo.processInfo.physicalMemory)
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = Int64(vm_kernel_page_size)
            s.app = (Int64(vm.internal_page_count) - Int64(vm.purgeable_count)) * page
            s.wired = Int64(vm.wire_count) * page
            s.compressed = Int64(vm.compressor_page_count) * page
            s.cached = (Int64(vm.external_page_count) + Int64(vm.purgeable_count)) * page
            s.free = (Int64(vm.free_count) + Int64(vm.speculative_count)) * page
        }
        var sw = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &len, nil, 0) == 0 {
            s.swapUsed = Int64(sw.xsu_used)
            s.swapTotal = Int64(sw.xsu_total)
        }
        var lvl: Int32 = 1
        len = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &lvl, &len, nil, 0) == 0 { s.pressure = lvl }
        return s
    }
}

// MARK: - Processes

struct ProcInfo: Identifiable, Hashable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let name: String
    let path: String
    let memory: Int64
    let cpuNs: UInt64
    let threads: Int32
    let responsible: pid_t
    var cpu: Double = 0

    var id: pid_t { pid }
    var isMine: Bool { uid == getuid() }
}

enum ProcessReader {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(max(tb.denom, 1)))
    }()

    private typealias RespFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: RespFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: RespFn.self)
    }()

    static func all() -> [ProcInfo] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var out: [ProcInfo] = []
        out.reserveCapacity(Int(got))
        for pid in pids.prefix(Int(max(got, 0))) {
            if let p = read(pid) { out.append(p) }
        }
        return out
    }

    static func read(_ pid: pid_t) -> ProcInfo? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else {
            if pid == 0 { return kernel() }
            return nil
        }
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let hasTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize

        var mem: Int64 = hasTask ? Int64(task.pti_resident_size) : 0
        var ri = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        if r == 0 && ri.ri_phys_footprint > 0 { mem = Int64(ri.ri_phys_footprint) }

        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let plen = proc_pidpath(pid, &buf, UInt32(buf.count))
        let path = plen > 0 ? String(cString: buf) : ""

        var name = withUnsafeBytes(of: bsd.pbi_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        if name.isEmpty { name = withUnsafeBytes(of: bsd.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } }
        if !path.isEmpty, name.count >= 15 { name = (path as NSString).lastPathComponent }
        // Versioned binaries (~/.local/share/claude/versions/2.1.3) get the tool name instead.
        if !path.isEmpty, name.allSatisfy({ $0.isNumber || $0 == "." }) {
            let parts = path.split(separator: "/")
            if parts.count >= 3 { name = String(parts[parts.count - 3]) }
        }

        let ticks = hasTask ? task.pti_total_user + task.pti_total_system : 0
        let ns = ticks &* timebase.numer / timebase.denom
        let resp = responsibleFn?(pid) ?? pid

        return ProcInfo(pid: pid, ppid: pid_t(bsd.pbi_ppid), uid: bsd.pbi_uid, name: name, path: path,
                        memory: mem, cpuNs: ns, threads: hasTask ? task.pti_threadnum : 0,
                        responsible: resp > 0 ? resp : pid)
    }

    private static func kernel() -> ProcInfo? {
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let ok = proc_pidinfo(0, PROC_PIDTASKINFO, 0, &task, size) == size
        return ProcInfo(pid: 0, ppid: 0, uid: 0, name: "kernel_task", path: "", memory: ok ? Int64(task.pti_resident_size) : 0,
                        cpuNs: ok ? (task.pti_total_user + task.pti_total_system) &* timebase.numer / timebase.denom : 0,
                        threads: ok ? task.pti_threadnum : 0, responsible: 0)
    }
}

// MARK: - Categories & groups

enum ProcCategory: String, CaseIterable, Identifiable {
    case dev = "Dev"
    case ai = "IA"
    case browser = "Navegadores"
    case apps = "Apps"
    case system = "Sistema"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .dev: "hammer.fill"
        case .ai: "sparkles"
        case .browser: "globe"
        case .apps: "square.grid.2x2"
        case .system: "gearshape.2.fill"
        }
    }
}

struct ProcGroup: Identifiable {
    let id: String
    var name: String
    var bundlePath: String?
    var category: ProcCategory
    var safety: Safety
    var reason: String
    var processes: [ProcInfo]

    var memory: Int64 { processes.reduce(0) { $0 + $1.memory } }
    var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
    var needsAdmin: Bool { processes.contains { !$0.isMine } }
    var mainPid: pid_t { processes.min { $0.pid < $1.pid }?.pid ?? 0 }
    var runningApp: NSRunningApplication? {
        for p in processes { if let a = NSRunningApplication(processIdentifier: p.pid), a.activationPolicy == .regular { return a } }
        return nil
    }
}

enum Classifier {
    static func bundle(of path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    // Exact process or app names (lowercased).
    static let devNames: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "java", "go", "gopls", "cargo", "rustc", "rust-analyzer",
        "tsserver", "esbuild", "vite", "next-server", "webpack", "turbo", "turbopack", "postgres", "postmaster", "mysqld", "mariadbd",
        "redis-server", "mongod", "nginx", "php", "php-fpm", "swift", "swift-frontend", "sourcekit-lsp", "sourcekitservice",
        "clangd", "lldb", "debugserver", "git", "gh", "ssh", "colima", "limactl", "vfkit", "podman", "kubectl", "minikube", "watchman",
        "zsh", "bash", "fish", "sh", "tmux", "screen", "make", "cmake", "ninja", "xcodebuild", "ibtoold", "pnpm", "yarn", "npm", "npx",
        "flutter", "dart", "gradle", "kotlin", "java_home", "mutagen", "ngrok", "cloudflared", "caddy", "terraform", "supabase",
        "vercel", "railway", "docker", "dockerd", "containerd", "qemu-system-aarch64", "mcp", "uv", "uvicorn", "gunicorn", "pm2",
        "tsx", "ts-node", "nodemon", "jest", "vitest", "playwright", "chromedriver", "xcbbuildservice", "simctl", "simulator",
        "launchd_sim", "copilot-language-server", "typescript-language-server", "eslint_d", "prettierd", "biome", "rome"
    ]

    static let devBundleWords = [
        "xcode", "simulator", "docker", "visual studio code", "/code.app", "code helper", "/cursor.app", "windsurf", "/zed.app", "sublime",
        "intellij", "pycharm", "webstorm", "goland", "android studio", "/rider.app", "clion", "datagrip", "rubymine", "phpstorm", "/fleet.app",
        "ghostty", "iterm", "terminal.app", "/warp.app", "alacritty", "/kitty.app", "wezterm", "github desktop", "tableplus", "postman",
        "insomnia", "/bruno.app", "sourcetree", "/fork.app", "/tower.app", "dbeaver", "orbstack", "/utm.app", "parallels", "vmware", "proxyman",
        "/charles.app", "rapidapi", "/dash.app", "sequel ace", "mongodb compass", "redisinsight", "/lens.app", "coresimulator", "/instruments.app",
        "kaleidoscope", "/nova.app", "bbedit", "textmate", "vscodium", "antigravity", "/kiro.app"
    ]

    static let aiWords = [
        "claude", "chatgpt", "openai", "ollama", "lm studio", "lmstudio", "llama", "perplexity", "copilot.app", "gemini", "deepseek",
        "grok", "/msty.app", "/jan.app", "mlx_lm", "mlx-lm", "whisper", "comfyui", "codex", "opencode", "superwhisper", "macwhisper", "pieces",
        "diffusionbee", "draw things", "anythingllm", "gpt4all", "koboldcpp", "aider", "goose", "chatbox", "boltai", "elephas"
    ]

    static let browserWords = [
        "google chrome", "chromium", "safari", "firefox", "/arc.app", "brave browser", "microsoft edge", "/opera.app", "vivaldi", "/orion.app",
        "/zen.app", "zen browser", "/dia.app", "/comet.app", "sigmaos", "duckduckgo", "com.apple.webkit", "thorium", "librewolf", "floorp"
    ]

    static let criticalNames: Set<String> = [
        "kernel_task", "launchd", "windowserver", "loginwindow", "logd", "opendirectoryd", "securityd", "trustd", "configd",
        "notifyd", "diskarbitrationd", "coreservicesd", "fseventsd", "powerd", "syslogd", "usereventagent", "cfprefsd",
        "distnoted", "kernelmanagerd", "airportd", "bluetoothd", "hidd", "runningboardd", "watchdogd", "sandboxd", "tccd",
        "lsd", "launchservicesd", "mds", "apfsd", "diskmanagementd", "keybagd", "secd", "sharedfilelistd", "authd",
        "endpointsecurityd", "corebrightnessd", "thermalmonitord", "mdnsresponder", "wifid", "symptomsd", "nsurlsessiond",
        "backboardd", "contextstored", "coreduetd", "dasd", "biometrickitd", "systemstats", "cryptexd", "bootinstalld", "taskgated"
    ]

    static let restartingSystemUI: Set<String> = [
        "dock", "finder", "systemuiserver", "controlcenter", "notificationcenter", "spotlight", "textinputmenuagent",
        "coreaudiod", "mds_stores", "mdworker_shared", "photoanalysisd", "mediaanalysisd", "corespotlightd", "cloudd", "bird",
        "suggestd", "knowledge-agent", "siriknowledged", "photolibraryd", "assistantd", "intelligenceplatformd", "fileproviderd"
    ]

    static let dbNames: Set<String> = ["postgres", "postmaster", "mysqld", "mariadbd", "redis-server", "mongod"]
    static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "tmux", "screen", "ssh"]

    static func category(name: String, path: String, bundle: String?) -> ProcCategory {
        let lname = name.lowercased()
        let hay = ((bundle ?? path) + " " + lname).lowercased()
        if aiWords.contains(where: { hay.contains($0) }) { return .ai }
        if browserWords.contains(where: { hay.contains($0) }) { return .browser }
        if devNames.contains(lname) || devBundleWords.contains(where: { hay.contains($0) })
            || path.contains("/.nvm/") || path.contains("/fnm") || path.contains("/node_modules/") || path.contains("/Cellar/") {
            return .dev
        }
        if isSystemPath(path) || path.isEmpty { return .system }
        return .apps
    }

    static func isSystemPath(_ p: String) -> Bool {
        p.hasPrefix("/System/") || p.hasPrefix("/usr/libexec/") || p.hasPrefix("/usr/sbin/") || p.hasPrefix("/sbin/")
            || p.hasPrefix("/usr/bin/") || p.hasPrefix("/bin/") || p.hasPrefix("/Library/Apple/") || p.hasPrefix("/private/var/")
            || p.hasPrefix("/System/Volumes/Preboot/Cryptexes/")
    }

    static func safety(name: String, path: String, category: ProcCategory, procs: [ProcInfo]) -> (Safety, String) {
        let n = name.lowercased()
        let pids = Set(procs.map(\.pid))
        if pids.contains(0) || pids.contains(1) || criticalNames.contains(n) {
            return (.danger, "Processo vital do macOS. Matar pode travar ou reiniciar o Mac.")
        }
        if pids.contains(getpid()) { return (.danger, "Este é o próprio Folga.") }
        if dbNames.contains(n) { return (.caution, "Banco de dados. Matar à força pode corromper dados; prefira parar pelo serviço (brew services stop).") }
        if n.contains("docker") || n.contains("com.docker") || n == "vfkit" || n.contains("orbstack") {
            return (.caution, "Derruba todos os containers em execução.")
        }
        if shellNames.contains(n) || ["ghostty", "iterm2", "terminal", "warp", "alacritty", "kitty", "wezterm"].contains(n) {
            return (.caution, "Fecha sessões de terminal abertas (e o que estiver rodando nelas).")
        }
        if n.contains("vpn") || n.contains("1password") || n.contains("sprinto") || n.contains("falcon") || n.contains("tailscale") {
            return (.caution, "Segurança, VPN ou senha. O serviço para até você abrir de novo.")
        }
        if category == .system {
            if restartingSystemUI.contains(n) { return (.caution, "Do sistema, mas o macOS reinicia sozinho. Pode piscar a interface ou pausar indexação.") }
            if procs.allSatisfy({ !$0.isMine }) { return (.danger, "Serviço do sistema rodando como root. Não mexa sem saber exatamente o que é.") }
            return (.caution, "Serviço do macOS. Normalmente volta sozinho, mas algo pode parar de funcionar até lá.")
        }
        if procs.contains(where: { NSRunningApplication(processIdentifier: $0.pid)?.activationPolicy == .regular }) {
            return (.safe, "App comum. Salve seu trabalho antes de encerrar.")
        }
        if procs.allSatisfy({ !$0.isMine }) { return (.caution, "Roda como root (helper de algum app). Exige senha e o app dono pode reclamar.") }
        return (.safe, "Processo de usuário. Pode encerrar; volta se o app dono precisar.")
    }

    static func group(_ procs: [ProcInfo]) -> [ProcGroup] {
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var buckets: [String: (name: String, bundle: String?, procs: [ProcInfo])] = [:]
        for p in procs {
            var bundle = bundle(of: p.path)
            // Attribute XPC helpers (WebKit, Electron) to the app responsible for them.
            if p.responsible != p.pid, let owner = byPid[p.responsible], let ob = Self.bundle(of: owner.path) {
                if bundle == nil || bundle!.hasPrefix("/System/Library/") { bundle = ob }
            }
            let key: String
            let name: String
            if let b = bundle {
                key = b
                name = ((b as NSString).lastPathComponent as NSString).deletingPathExtension
            } else {
                key = p.path.isEmpty ? "name:" + p.name : p.path
                name = p.name
            }
            buckets[key, default: (name, bundle, [])].procs.append(p)
        }
        return buckets.map { key, v in
            let cat = category(name: v.name, path: v.procs.first?.path ?? "", bundle: v.bundle)
            let (s, why) = safety(name: v.name, path: v.procs.first?.path ?? "", category: cat, procs: v.procs)
            return ProcGroup(id: key, name: v.name, bundlePath: v.bundle, category: cat, safety: s, reason: why,
                             processes: v.procs.sorted { $0.memory > $1.memory })
        }
    }
}

// MARK: - Killing

enum Killer {
    enum Mode { case quit, force }

    /// Returns an error message, or nil on success.
    static func stop(_ g: ProcGroup, mode: Mode) -> String? {
        if mode == .quit, let app = g.runningApp {
            if app.terminate() { return nil }
        }
        return signal(g.processes.map(\.pid), mode: mode)
    }

    static func signal(_ pids: [pid_t], mode: Mode) -> String? {
        let sig = mode == .force ? SIGKILL : SIGTERM
        var denied: [pid_t] = []
        for pid in pids where pid > 1 && pid != getpid() {
            if kill(pid, sig) != 0 && errno == EPERM { denied.append(pid) }
        }
        guard !denied.isEmpty else { return nil }
        let r = Shell.admin("/bin/kill -\(mode == .force ? 9 : 15) " + denied.map(String.init).joined(separator: " "))
        return r.ok ? nil : "Não foi possível encerrar \(denied.count) processo(s): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
