import AppKit
import SwiftUI

struct Artifact: Identifiable, Hashable {
    let path: String
    let kind: String
    let size: Int64
    let safety: Safety
    var id: String { path }
}

struct DevProject: Identifiable {
    let path: String
    var name: String { (path as NSString).lastPathComponent }
    var artifacts: [Artifact]
    var lastActivity: Date?
    var isGit: Bool
    var id: String { path }
    var total: Int64 { artifacts.reduce(0) { $0 + $1.size } }
    var idleDays: Int { lastActivity.map { Int(Date().timeIntervalSince($0) / 86_400) } ?? 9999 }
}

enum ProjectScanner {
    static let defaultRoots = ["~/Documents", "~/Developer", "~/Projects", "~/projects", "~/Code", "~/code", "~/dev", "~/Dev", "~/src",
                               "~/repos", "~/Repos", "~/workspace", "~/Workspace", "~/GitHub", "~/github", "~/git", "~/Sites", "~/Desktop", "~/Downloads", "~/www"]

    /// name -> (label, sibling marker files that confirm it, safety). Empty markers = always.
    static let rules: [String: (String, [String], Safety)] = [
        "node_modules": ("node_modules", [], .safe),
        ".next": ("Next.js build", [], .safe),
        ".nuxt": ("Nuxt build", [], .safe),
        ".output": ("Nitro output", ["nuxt.config.ts", "nuxt.config.js", "package.json"], .safe),
        ".svelte-kit": ("SvelteKit", [], .safe),
        ".turbo": ("Turborepo cache", [], .safe),
        ".parcel-cache": ("Parcel cache", [], .safe),
        ".angular": ("Angular cache", [], .safe),
        ".expo": ("Expo", [], .safe),
        ".docusaurus": ("Docusaurus", [], .safe),
        ".vercel": ("Vercel output", ["package.json"], .safe),
        ".wrangler": ("Wrangler", [], .safe),
        "storybook-static": ("Storybook build", [], .safe),
        "dist": ("dist", ["package.json", "pyproject.toml", "setup.py", "vite.config.ts", "tsconfig.json"], .safe),
        "build": ("build", ["package.json", "build.gradle", "build.gradle.kts", "pubspec.yaml", "CMakeLists.txt", "setup.py", "pyproject.toml"], .safe),
        "out": ("out", ["package.json", "next.config.js", "next.config.mjs", "next.config.ts"], .safe),
        "coverage": ("coverage", ["package.json", "pyproject.toml"], .safe),
        "target": ("Rust/Maven target", ["Cargo.toml", "pom.xml"], .safe),
        ".build": ("SwiftPM .build", ["Package.swift"], .safe),
        "DerivedData": ("DerivedData", [], .safe),
        "Pods": ("CocoaPods Pods", ["Podfile"], .caution),
        ".gradle": ("Gradle", ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], .safe),
        ".dart_tool": ("Dart tool", ["pubspec.yaml"], .safe),
        ".venv": ("Python venv", [], .caution),
        "venv": ("Python venv", [], .caution),
        ".tox": ("tox", [], .safe),
        ".mypy_cache": ("mypy cache", [], .safe),
        ".pytest_cache": ("pytest cache", [], .safe),
        ".ruff_cache": ("ruff cache", [], .safe),
        ".terraform": ("Terraform providers", [], .caution),
        "vendor": ("vendor (Composer/Bundler)", ["composer.json", "Gemfile"], .caution),
        ".zig-cache": ("Zig cache", [], .safe),
        "zig-cache": ("Zig cache", [], .safe),
        "zig-out": ("Zig out", ["build.zig"], .safe),
        "_build": ("Elixir _build", ["mix.exs"], .safe),
        "deps": ("Elixir deps", ["mix.exs"], .caution),
        "elm-stuff": ("Elm", [], .safe),
        ".stack-work": ("Haskell stack", [], .safe),
        "bin": (".NET bin", ["*.csproj"], .safe),
        "obj": (".NET obj", ["*.csproj"], .safe),
    ]

    static let skipDirs: Set<String> = [".git", "Library", ".Trash", "Applications", "Pictures", "Movies", "Music", ".cache", ".npm", ".cargo", ".rustup", "go", ".gradle-home"]

    static func roots(extra: [String]) -> [String] {
        var seen: [String] = []
        for r in (defaultRoots.map(Paths.expand) + extra) where Paths.isDir(r) {
            let real = (r as NSString).resolvingSymlinksInPath
            if !seen.contains(where: { real == $0 || real.hasPrefix($0 + "/") }) {
                seen.removeAll { $0.hasPrefix(real + "/") }
                seen.append(real)
            }
        }
        return seen
    }

    static func scan(extraRoots: [String], progress: @escaping (String) -> Void) -> [DevProject] {
        var found: [(path: String, kind: String, safety: Safety)] = []
        let fm = FileManager.default
        for root in roots(extra: extraRoots) {
            progress("Varredura: \(Paths.pretty(root))")
            DiskSize.walk(root) { e in
                let info = Int32(e.pointee.fts_info)
                guard info == FTS_D else { return .go }
                if e.pointee.fts_level > 9 { return .skip }
                let name = DiskSize.name(e)
                if e.pointee.fts_level > 0 && skipDirs.contains(name) { return .skip }
                if name.hasSuffix(".app") || name.hasSuffix(".photoslibrary") || name.hasSuffix(".xcarchive") || name.hasSuffix(".fcpbundle") { return .skip }
                guard let rule = rules[name], e.pointee.fts_level > 0 else { return .go }
                let path = DiskSize.path(e)
                let parent = (path as NSString).deletingLastPathComponent
                if !rule.1.isEmpty {
                    let ok = rule.1.contains { m in
                        m.hasPrefix("*") ? ((try? fm.contentsOfDirectory(atPath: parent))?.contains { $0.hasSuffix(String(m.dropFirst())) } ?? false)
                                         : Paths.exists(parent + "/" + m)
                    }
                    if !ok { return .go }
                }
                if (name == "venv" || name == ".venv") && !Paths.exists(path + "/pyvenv.cfg") { return .go }
                found.append((path, rule.0, rule.2))
                return .skip
            }
        }
        progress("Medindo \(found.count) pastas...")
        let sizes = DiskSize.many(found.map(\.path))
        var byProject: [String: DevProject] = [:]
        for f in found {
            let parent = (f.path as NSString).deletingLastPathComponent
            let a = Artifact(path: f.path, kind: f.kind, size: sizes[f.path] ?? 0, safety: f.safety)
            guard a.size > 0 else { continue }
            byProject[parent, default: DevProject(path: parent, artifacts: [], lastActivity: nil, isGit: Paths.exists(parent + "/.git"))].artifacts.append(a)
        }
        // Nested artifacts (e.g. packages/x/node_modules in a monorepo) collapse into their git root when there is one.
        for (k, p) in byProject {
            byProject[k]?.lastActivity = lastActivity(p.path, skip: Set(p.artifacts.map(\.path)))
        }
        return byProject.values.sorted { $0.total > $1.total }
    }

    /// Most recent mtime of the project's own top level entries (ignoring build artifacts).
    static func lastActivity(_ dir: String, skip: Set<String>) -> Date? {
        var best: Date?
        for c in Paths.children(dir) where !skip.contains(c) {
            let n = (c as NSString).lastPathComponent
            if n == ".DS_Store" { continue }
            if let m = Paths.mtime(n == ".git" ? c + "/index" : c), best == nil || m > best! { best = m }
        }
        return best
    }
}

@MainActor
@Observable
final class ProjectsStore {
    var projects: [DevProject] = []
    var selected: Set<String> = []
    var scanning = false
    var status = ""
    var freed: Int64?
    var extraRoots: [String] = (UserDefaults.standard.array(forKey: "extraRoots") as? [String]) ?? []

    var selectedBytes: Int64 { projects.flatMap(\.artifacts).filter { selected.contains($0.path) }.reduce(0) { $0 + $1.size } }

    func scan() async {
        scanning = true
        let extra = extraRoots
        projects = await Task.detached(priority: .userInitiated) {
            ProjectScanner.scan(extraRoots: extra) { m in Task { @MainActor in self.status = m } }
        }.value
        selected = []
        scanning = false
    }

    func selectIdle(_ days: Int) {
        selected = Set(projects.filter { $0.idleDays >= days }.flatMap { $0.artifacts.filter { $0.safety == .safe }.map(\.path) })
    }

    func addRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        if p.runModal() == .OK {
            extraRoots += p.urls.map(\.path)
            UserDefaults.standard.set(extraRoots, forKey: "extraRoots")
        }
    }

    func clean() async {
        let paths = Array(selected)
        let sizes = Dictionary(projects.flatMap(\.artifacts).map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
        freed = await Task.detached(priority: .userInitiated) {
            var total: Int64 = 0
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                if FileOps.remove(paths[i]) { lock.lock(); total += sizes[paths[i]] ?? 0; lock.unlock() }
            }
            return total
        }.value
        await scan()
    }
}

struct ProjectsView: View {
    @Environment(ProjectsStore.self) private var store
    @State private var idleFilter = 0
    @State private var confirm = false
    @State private var expanded: Set<String> = []

    var visible: [DevProject] { store.projects.filter { $0.idleDays >= idleFilter } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("node_modules, builds, venvs e caches dentro dos seus projetos").font(.headline)
                    Text("Tudo aqui é recriável com npm install, cargo build, pod install etc. venvs e Pods pedem reinstalação.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Parados há", selection: $idleFilter) {
                    Text("Todos").tag(0); Text("7+ dias").tag(7); Text("30+ dias").tag(30); Text("90+ dias").tag(90); Text("1+ ano").tag(365)
                }
                .frame(width: 190)
                Menu("Selecionar") {
                    Button("Parados há 30+ dias") { store.selectIdle(30) }
                    Button("Parados há 90+ dias") { store.selectIdle(90) }
                    Button("Todos os seguros") { store.selectIdle(0) }
                    Button("Nenhum") { store.selected = [] }
                }
                .frame(width: 110)
            }
            .padding(16)
            Divider()
            if store.projects.isEmpty && !store.scanning {
                ContentUnavailableView {
                    Label("Projetos", systemImage: "folder.badge.gearshape")
                } description: {
                    Text("Procura em ~/Documents, ~/Developer, ~/Projects, ~/code, ~/GitHub, ~/Desktop, ~/Downloads e nas pastas que você adicionar.")
                } actions: {
                    Button("Procurar projetos") { Task { await store.scan() } }.buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Adicionar pasta...") { store.addRoot() }
                }
            } else {
                List {
                    ForEach(visible) { p in row(p) }
                }
                .overlay { if store.scanning { ProgressView(store.status).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
            }
            Divider()
            HStack {
                Text("\(visible.count) projetos · \(Fmt.bytes(visible.reduce(0) { $0 + $1.total }))").foregroundStyle(.secondary)
                if let f = store.freed { Text("Liberado: \(Fmt.bytes(f))").fontWeight(.semibold) }
                Spacer()
                Button("Adicionar pasta...") { store.addRoot() }
                Text("Selecionado: \(Fmt.bytes(store.selectedBytes))").monospacedDigit()
                Button("Apagar selecionados") { confirm = true }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.selected.isEmpty || store.scanning)
            }
            .padding(12)
        }
        .navigationTitle("Projetos")
        .toolbar { Button { Task { await store.scan() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.scanning) }
        .confirmationDialog("Apagar \(store.selected.count) pastas (\(Fmt.bytes(store.selectedBytes)))?", isPresented: $confirm) {
            Button("Apagar de vez", role: .destructive) { Task { await store.clean() } }
        } message: { Text("São apagadas direto, sem Lixeira. Para recriar: npm/pnpm install, cargo build, pod install, pip install -r ...") }
    }

    private func row(_ p: DevProject) -> some View {
        let open = expanded.contains(p.id)
        let paths = p.artifacts.map(\.path)
        let n = paths.filter { store.selected.contains($0) }.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                TriCheck(state: n == 0 ? false : n == paths.count ? true : nil) {
                    if n == paths.count { store.selected.subtract(paths) } else { store.selected.formUnion(paths) }
                }
                Image(systemName: p.isGit ? "arrow.triangle.branch" : "folder").foregroundStyle(.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).fontWeight(.medium)
                    Text(Paths.pretty(p.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(p.artifacts.map(\.kind).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("mexido \(Fmt.ago(p.lastActivity))").font(.caption).foregroundStyle(p.idleDays > 90 ? .orange : .secondary).frame(width: 130, alignment: .trailing)
                Text(Fmt.bytes(p.total)).monospacedDigit().fontWeight(.semibold).frame(width: 80, alignment: .trailing)
                Button { if open { expanded.remove(p.id) } else { expanded.insert(p.id) } } label: {
                    Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0))
                }.buttonStyle(.borderless)
            }
            if open {
                ForEach(p.artifacts) { a in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { store.selected.contains(a.path) }, set: { if $0 { store.selected.insert(a.path) } else { store.selected.remove(a.path) } }))
                            .toggleStyle(.checkbox).labelsHidden()
                        Text(a.kind).frame(width: 150, alignment: .leading)
                        Text(Paths.pretty(a.path)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        SafetyBadge(safety: a.safety)
                        Text(Fmt.bytes(a.size)).font(.callout).monospacedDigit().frame(width: 75, alignment: .trailing)
                        Button { FileOps.reveal(a.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                    }
                    .padding(.leading, 28)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
