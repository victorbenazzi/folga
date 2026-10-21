import AppKit
import CoreServices
import Foundation

struct InstalledApp: Identifiable, Hashable {
    let path: String
    let name: String
    let bundleId: String
    let version: String
    let nestedIds: [String]
    var size: Int64 = 0
    var lastUsed: Date?
    var id: String { path }
    var isApple: Bool { bundleId.hasPrefix("com.apple.") }
    var isSystem: Bool { path.hasPrefix("/System/") }
}

enum Inventory {
    static let appDirs = ["/Applications", "/Applications/Utilities", Paths.home + "/Applications", "/System/Applications",
                          "/System/Applications/Utilities", "/Applications/Setapp"]

    static func apps(includeSpotlight: Bool = true) -> [InstalledApp] {
        var paths = Set<String>()
        for d in appDirs {
            for c in Paths.children(d) {
                if c.hasSuffix(".app") { paths.insert(c) }
                else if Paths.isDir(c) { for cc in Paths.children(c) where cc.hasSuffix(".app") { paths.insert(cc) } }
            }
        }
        if includeSpotlight {
            let r = Shell.run("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"], timeout: 12)
            for line in r.out.split(separator: "\n") {
                let p = String(line)
                if p.contains(".app/") || p.hasPrefix("/Volumes/") || p.contains("/.Trash/") || p.contains("/Library/Developer/") { continue }
                if p.contains("/.build/") || p.contains("/DerivedData/") || p.contains("/node_modules/") { continue }
                paths.insert(p)
            }
        }
        return paths.compactMap(read).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func read(_ path: String) -> InstalledApp? {
        guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String else { return nil }
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var nested: [String] = []
        for pat in ["Contents/Library/LoginItems/*.app", "Contents/PlugIns/*.appex", "Contents/Library/LaunchServices/*", "Contents/Helpers/*.app",
                    "Contents/XPCServices/*.xpc", "Contents/Frameworks/*.app", "Contents/Library/SystemExtensions/*"] {
            for p in Paths.glob(path + "/" + pat) {
                if let d = NSDictionary(contentsOfFile: p + "/Contents/Info.plist"), let nid = d["CFBundleIdentifier"] as? String { nested.append(nid) }
                else { nested.append((p as NSString).lastPathComponent) }
            }
        }
        return InstalledApp(path: path, name: name, bundleId: id, version: info["CFBundleShortVersionString"] as? String ?? "", nestedIds: nested)
    }

    static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

/// Everything known to be installed: app bundle ids, names, Homebrew and CLI tools.
struct Known {
    var ids: Set<String> = []
    var vendors: Set<String> = []
    var names: Set<String> = []
    var tools: Set<String> = []

    static func norm(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }

    static func build(_ apps: [InstalledApp]) -> Known {
        var k = Known()
        for a in apps {
            for id in [a.bundleId] + a.nestedIds {
                let l = id.lowercased()
                k.ids.insert(l)
                let c = l.split(separator: ".")
                if c.count >= 2 { k.vendors.insert(c.prefix(2).joined(separator: ".")) }
            }
            k.names.insert(norm(a.name))
            k.names.insert(norm(((a.path as NSString).lastPathComponent as NSString).deletingPathExtension))
        }
        for r in NSWorkspace.shared.runningApplications { if let b = r.bundleIdentifier { k.ids.insert(b.lowercased()) } }
        for d in ["/opt/homebrew/Cellar", "/opt/homebrew/Caskroom", "/usr/local/Cellar", "/usr/local/Caskroom", "/opt/homebrew/bin", "/usr/local/bin",
                  Paths.home + "/.local/bin", Paths.home + "/.cargo/bin", Paths.home + "/.bun/bin", Paths.home + "/go/bin", Paths.home + "/.npm-global/bin"] {
            for c in Paths.children(d) { k.tools.insert(norm((c as NSString).lastPathComponent)) }
        }
        return k
    }
}

enum Leftovers {
    struct Location { let dir: String; let label: String; let plainNamesOK: Bool; let admin: Bool }

    static let locations: [Location] = [
        .init(dir: "~/Library/Application Support", label: "Application Support", plainNamesOK: true, admin: false),
        .init(dir: "~/Library/Caches", label: "Caches", plainNamesOK: true, admin: false),
        .init(dir: "~/Library/Preferences", label: "Preferências", plainNamesOK: false, admin: false),
        .init(dir: "~/Library/Containers", label: "Container", plainNamesOK: false, admin: false),
        .init(dir: "~/Library/Group Containers", label: "Group Container", plainNamesOK: false, admin: false),
        .init(dir: "~/Library/Saved Application State", label: "Estado salvo", plainNamesOK: false, admin: false),
        .init(dir: "~/Library/HTTPStorages", label: "HTTP Storage", plainNamesOK: false, admin: false),
        .init(dir: "~/Library/WebKit", label: "WebKit", plainNamesOK: false, admin: false),
        .init(dir: "~/Library/Logs", label: "Logs", plainNamesOK: true, admin: false),
        .init(dir: "~/Library/Cookies", label: "Cookies", plainNamesOK: false, admin: false),
        .init(dir: "~/Library/Application Scripts", label: "Scripts", plainNamesOK: false, admin: false),
        .init(dir: "~/Library/LaunchAgents", label: "LaunchAgent", plainNamesOK: false, admin: false),
        .init(dir: "/Library/Application Support", label: "Application Support (sistema)", plainNamesOK: true, admin: true),
        .init(dir: "/Library/LaunchAgents", label: "LaunchAgent (sistema)", plainNamesOK: false, admin: true),
        .init(dir: "/Library/LaunchDaemons", label: "LaunchDaemon", plainNamesOK: false, admin: true),
        .init(dir: "/Library/PrivilegedHelperTools", label: "Helper privilegiado", plainNamesOK: false, admin: true),
        .init(dir: "/Library/Preferences", label: "Preferências (sistema)", plainNamesOK: false, admin: true),
        .init(dir: "/Library/Caches", label: "Caches (sistema)", plainNamesOK: false, admin: true),
    ]

    static let tlds: Set<String> = ["com", "org", "net", "io", "app", "dev", "co", "me", "ai", "us", "de", "uk", "br", "fr", "ru", "jp", "cn", "tv", "info",
                                    "sh", "so", "xyz", "cc", "ly", "gg", "design", "studio", "tech", "eu", "ca", "au", "ch", "nl", "se", "it", "es", "pl",
                                    "cz", "at", "be", "dk", "fi", "no", "kr", "in", "is", "im", "to", "fm", "md", "pro", "group", "software", "cloud", "one", "systems"]

    static let genericWords = ["keystone", "update", "helper", "agent", "shared", "common", "crashpad", "framework", "launcher", "daemon", "service", "installer", "xpc", "plugin", "extension", "sync"]

    /// Plain-named folders that belong to macOS, shared runtimes or vendors.
    static let systemNames: Set<String> = [
        "addressbook", "callhistorydb", "callhistorytransactions", "cloudkit", "crashreporter", "dock", "icdd", "knowledge", "mobilesync", "syncservices",
        "fileprovider", "animoji", "accounts", "askpermission", "calendar", "contacts", "clouddocs", "familycircle", "locationaccessstored", "quicklook",
        "siri", "tipsd", "videoconference", "applepay", "assistant", "avatarcache", "backgroundtasks", "bluetooth", "coreparsec", "dataaccess", "default",
        "differentialprivacy", "facetime", "findmy", "gamekit", "geod", "homekit", "identityservices", "maps", "networkserviceproxy", "photos",
        "privatecloudcompute", "reminders", "screentime", "spotlight", "stocks", "translation", "voicememos", "weather", "wallpaper", "metadata",
        "sharedfilelist", "icloud", "ubiquity", "familyclient", "keychains", "coreservices", "audio", "storeassets", "storekit", "cloudphotos", "appstore",
        "privacy", "fonts", "colorsync", "imagecapture", "mail", "messages", "notes", "safari", "music", "tv", "podcasts", "books", "news", "freeform",
        "shortcuts", "journal", "passwords", "preview", "textedit", "xcode", "instruments", "simulator", "developer", "coresimulator", "sentry", "crashpad",
        "cef", "electron", "chromium", "google", "microsoft", "adobe", "jetbrains", "mozilla", "apple", "osanalytics", "diagnostics", "diskimages",
        "cache", "caches", "logs", "tmp", "temp", "homebrew", "node", "nodegyp", "npm", "pip", "yarn", "gobuild", "deno", "typescript", "msplaywright",
        "pnpm", "cocoapods", "carthage", "jetbrainstoolbox", "vscode", "code", "diagnosticreports", "powerlog", "retaildemo", "ammsd", "com", "org", "net",
        "networking", "configurationprofiles", "scripteditor", "automator", "dictionary", "systemsettings", "systempreferences", "keyboardservices",
        "intelligenceplatform", "generativemodels", "modelcatalog", "siriprivate", "biome", "cloudsubscriptionfeatures", "familysettings", "dmd",
        "homeenergy", "sesstorage", "screensaver", "aerial", "dictation", "speech", "voicetrigger", "managedclient", "remotemanagement", "corespotlight",
        "spotlightknowledge", "audiounits", "midi", "garageband", "logic", "imovie", "finalcut", "motion", "compressor", "keynote", "pages", "numbers",
        "printers", "cups", "sharedframeworks", "apfs", "softwareupdate", "installer", "mds", "applemediaservices", "gamecontroller", "gamecenter",
        "quicktime", "coreml", "mlx", "metal", "osxfuse", "macfuse", "pkgutil", "receipts", "script", "scripts", "launchagents", "launchdaemons",
        "dropboxhelpertools", "askpermissiond", "cloudstorage", "mobiledocuments", "group", "containers", "httpstorages", "webkit", "cookies", "preferences", "savedstate"
    ]

    static let dotFolders: [String: [String]] = [
        ".vscode": ["visualstudiocode", "code"], ".cursor": ["cursor"], ".windsurf": ["windsurf"], ".docker": ["docker", "orbstack"],
        ".android": ["androidstudio", "adb"], ".zoomus": ["zoom", "zoomus"], ".dropbox": ["dropbox"], ".lmstudio": ["lmstudio"],
        ".ollama": ["ollama"], ".orbstack": ["orbstack"], ".colima": ["colima"], ".vagrant.d": ["vagrant"], ".minikube": ["minikube"],
        ".cocoapods": ["pod", "cocoapods"], ".rustup": ["rustup", "cargo"], ".cargo": ["cargo", "rustup"], ".pyenv": ["pyenv"],
        ".conda": ["conda", "miniconda", "anaconda"], ".bun": ["bun"], ".deno": ["deno"], ".gradle": ["gradle", "androidstudio", "java", "intellijidea"],
        ".m2": ["mvn", "maven", "intellijidea"], ".expo": ["expo", "eas"], ".flutter": ["flutter"], ".pub-cache": ["flutter", "dart"],
        ".wdm": ["chromedriver"], ".kiro": ["kiro"], ".codeium": ["windsurf", "codeium"], ".continue": ["code", "cursor"], ".antigravity": ["antigravity"]
    ]

    /// Reverse-DNS ids used by toolchains and runtimes, not apps.
    static let toolPrefixes = ["org.swift.", "org.llvm.", "org.python.", "org.nodejs.", "org.rust-lang.", "org.golang.", "sh.brew.", "org.homebrew.",
                               "dev.deno.", "org.carthage.", "org.cocoapods.", "org.gradle.", "com.github.cli", "org.mozilla.sccache", "com.oracle.java",
                               "net.java.", "org.openjdk.", "com.microsoft.dotnet", "org.chromium.", "org.webkit.", "org.sparkle-project.", "org.git-scm."]

    enum Confidence { case high, low }

    struct Hit { let path: String; let location: String; let admin: Bool; let key: String; let confidence: Confidence }

    static func strip(_ raw: String) -> String {
        var n = raw
        for ext in [".plist", ".savedState", ".binarycookies", ".lockfile"] where n.hasSuffix(ext) { n = String(n.dropLast(ext.count)) }
        if let r = n.range(of: #"^[A-Z0-9]{10}\."#, options: .regularExpression) { n.removeSubrange(r) }
        if n.hasPrefix("group.") { n = String(n.dropFirst(6)) }
        return n
    }

    static func isBundleLike(_ n: String) -> Bool {
        let c = n.lowercased().split(separator: ".")
        return c.count >= 2 && tlds.contains(String(c[0])) && !n.contains(" ")
    }

    static func key(_ n: String) -> String {
        if isBundleLike(n) { return n.lowercased().split(separator: ".").prefix(3).joined(separator: ".") }
        return Known.norm(n)
    }

    /// nil = installed or system. Otherwise how sure we are it is a leftover.
    static func verdict(_ raw: String, known k: Known, plainOK: Bool, path: String) -> Confidence? {
        let n = strip(raw)
        let l = n.lowercased()
        if l.isEmpty || l.hasPrefix(".") || l.hasPrefix("com.apple") || l.hasPrefix("apple") || l.contains("com.apple.") { return nil }
        if toolPrefixes.contains(where: { l.hasPrefix($0) || l + "." == $0 }) { return nil }
        if isBundleLike(n) {
            if k.ids.contains(l) { return nil }
            for id in k.ids where l.hasPrefix(id + ".") || id.hasPrefix(l + ".") { return nil }
            let c = l.split(separator: ".").map(String.init)
            let product = c.count >= 3 ? Known.norm(c[2]) : Known.norm(c[1])
            if product.count >= 3 {
                if k.tools.contains(product) { return nil }
                for name in k.names where name.count >= 4 && (product.contains(name) || name.contains(product)) { return nil }
            }
            let vendor = c.prefix(2).joined(separator: ".")
            if k.vendors.contains(vendor) {
                // Helpers and daemons of an installed vendor belong to it.
                if path.contains("/Library/Privileged") || path.contains("/LaunchDaemons/") || path.contains("/LaunchAgents/") { return nil }
                if genericWords.contains(where: { l.contains($0) }) { return nil }
                return .low
            }
            return .high
        }
        guard plainOK else { return nil }
        let p = Known.norm(n)
        if p.count < 3 || systemNames.contains(p) || k.tools.contains(p) { return nil }
        for name in k.names where name == p || (name.count >= 4 && p.count >= 4 && (name.contains(p) || p.contains(name))) { return nil }
        for id in k.ids {
            let c = id.split(separator: ".")
            if c.count >= 3, Known.norm(String(c[2])).count >= 4, (Known.norm(String(c[2])) == p || Known.norm(String(c[2])).contains(p) || p.contains(Known.norm(String(c[2])))) { return nil }
        }
        if let m = Paths.mtime(path), Date().timeIntervalSince(m) < 30 * 86_400 { return nil }
        return .low
    }

    static func scan(known k: Known) -> [Hit] {
        var hits: [Hit] = []
        // Dev and browser caches already handled by the cleanup catalog are not leftovers.
        let catalogPaths = Set(Catalog.all.filter { !$0.generic }.flatMap { $0.patterns.flatMap(Paths.glob) })
        for loc in locations {
            let dir = Paths.expand(loc.dir)
            for path in Paths.children(dir) where !catalogPaths.contains(path) {
                let raw = (path as NSString).lastPathComponent
                var conf = verdict(raw, known: k, plainOK: loc.plainNamesOK, path: path)
                // launchd plists pointing to a program that no longer exists are leftovers for sure.
                if raw.hasSuffix(".plist"), loc.label.hasPrefix("Launch"), let d = NSDictionary(contentsOfFile: path) as? [String: Any] {
                    let prog = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first
                    if let prog, prog.hasPrefix("/"), !Paths.exists(prog) { conf = .high } else if conf != nil, prog.map(Paths.exists) == true { conf = .low }
                }
                if let conf { hits.append(Hit(path: path, location: loc.label, admin: loc.admin && !Paths.isOwnedByUser(path), key: key(strip(raw)), confidence: conf)) }
            }
        }
        for (dot, owners) in dotFolders {
            let p = Paths.home + "/" + dot
            guard Paths.exists(p) else { continue }
            let installed = owners.contains { o in k.tools.contains(o) || k.names.contains { $0.contains(o) || o.contains($0) && $0.count >= 4 } }
            if !installed { hits.append(Hit(path: p, location: "Pasta oculta em ~", admin: false, key: dot, confidence: .low)) }
        }
        return hits
    }

    /// Files that belong to a given app (for the uninstaller).
    static func related(to app: InstalledApp) -> [Hit] {
        let id = app.bundleId.lowercased()
        let nested = Set(app.nestedIds.map { $0.lowercased() })
        let names = Set([Known.norm(app.name), Known.norm(((app.path as NSString).lastPathComponent as NSString).deletingPathExtension)].filter { $0.count >= 3 })
        var hits: [Hit] = []
        for loc in locations {
            for path in Paths.children(Paths.expand(loc.dir)) {
                let n = strip((path as NSString).lastPathComponent).lowercased()
                let match = n == id || n.hasPrefix(id + ".") || nested.contains(n) || (loc.plainNamesOK && !isBundleLike(n) && names.contains(Known.norm(n)))
                if match { hits.append(Hit(path: path, location: loc.label, admin: loc.admin && !Paths.isOwnedByUser(path), key: id, confidence: .high)) }
            }
        }
        return hits
    }
}
