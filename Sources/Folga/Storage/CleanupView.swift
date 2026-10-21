import AppKit
import SwiftUI

struct CleanItem: Identifiable, Hashable {
    let path: String
    let size: Int64
    let mtime: Date?
    var id: String { path }
    /// Big items inside generic targets are often model or dataset caches: shown, but not preselected.
    var isBig: Bool { size >= 2_000_000_000 }
}

struct CleanResult: Identifiable {
    let target: CleanTarget
    var items: [CleanItem]
    var probe: String?
    var id: String { target.id }
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

enum CleanupScanner {
    static func scan(progress: @escaping (String) -> Void) -> [CleanResult] {
        let targets = Catalog.all.filter { t in t.requiresTool.map { Shell.which($0) != nil } ?? true }
        let now = Date()

        // Resolve patterns. Specific targets first so generic ones can skip what is already claimed.
        var resolved: [String: [String]] = [:]
        var claimed: [String] = []
        for t in targets.sorted(by: { !$0.generic && $1.generic }) {
            var paths: [String] = []
            for pat in t.patterns { paths += Paths.glob(pat) }
            let excl = t.exclude.map(Paths.expand)
            paths = paths.filter { p in !excl.contains { p.contains($0) } }
            if let days = t.olderThanDays {
                let limit = now.addingTimeInterval(-Double(days) * 86_400)
                paths = paths.filter { (Paths.mtime($0) ?? now) < limit }
            }
            paths = Array(Set(paths)).filter { $0 != Paths.home && $0 != "/" }
            if t.generic {
                paths = paths.filter { p in !claimed.contains { c in c == p || c.hasPrefix(p + "/") || p.hasPrefix(c + "/") } }
            }
            claimed += paths
            resolved[t.id] = paths
        }

        progress("Medindo \(claimed.count) itens...")
        let sizes = DiskSize.many(claimed)

        var probes: [String: String] = [:]
        let lock = NSLock()
        let probeList = targets.compactMap { t in Catalog.probes[t.id].map { (t.id, $0) } }
        DispatchQueue.concurrentPerform(iterations: probeList.count) { i in
            let r = Shell.sh(probeList[i].1, timeout: 20)
            let txt = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            lock.lock(); probes[probeList[i].0] = txt.isEmpty ? nil : txt; lock.unlock()
        }

        return targets.compactMap { t in
            let items = (resolved[t.id] ?? []).map { CleanItem(path: $0, size: sizes[$0] ?? 0, mtime: Paths.mtime($0)) }
                .filter { $0.size > 0 || t.isCommand }
                .sorted { $0.size > $1.size }
            let probe = probes[t.id]
            if items.isEmpty && !(t.isCommand && t.patterns.isEmpty) && probe == nil { return nil }
            return CleanResult(target: t, items: items, probe: probe)
        }
    }

    struct Report { var freed: Int64 = 0; var failed: [String] = []; var log: [String] = [] }

    static func clean(_ results: [CleanResult], selected: Set<String>, commands: Set<String>) -> Report {
        var rep = Report()
        var adminPaths: [String] = []
        var adminCmds: [String] = []
        for r in results {
            switch r.target.action {
            case .info:
                continue
            case .command(let cmd):
                guard commands.contains(r.id) else { continue }
                let res = Shell.sh(cmd, timeout: 1800)
                rep.log.append("\(r.target.title): \(res.ok ? "ok" : res.err.prefix(200))")
                if res.ok { rep.freed += r.total }
            case .adminCommand(let cmd):
                if commands.contains(r.id) { adminCmds.append(cmd); rep.freed += r.total }
            case .adminDelete:
                for i in r.items where selected.contains(i.path) { adminPaths.append(i.path); rep.freed += i.size }
            case .delete:
                for i in r.items where selected.contains(i.path) {
                    if FileOps.remove(i.path) { rep.freed += i.size } else if Paths.exists(i.path) { rep.failed.append(i.path) }
                }
            case .trash:
                for i in r.items where selected.contains(i.path) {
                    if FileOps.trash(i.path) { rep.freed += i.size } else { rep.failed.append(i.path) }
                }
            }
        }
        if !adminPaths.isEmpty || !adminCmds.isEmpty {
            let cmd = (adminCmds + (adminPaths.isEmpty ? [] : ["/bin/rm -rf " + adminPaths.map(Shell.q).joined(separator: " ")])).joined(separator: "; ")
            let res = Shell.admin(cmd + "; true")
            if !res.ok { rep.log.append("Itens de admin cancelados.") }
        }
        return rep
    }
}

@MainActor
@Observable
final class CleanupStore {
    var results: [CleanResult] = []
    var selected: Set<String> = []
    var commands: Set<String> = []
    var scanning = false
    var cleaning = false
    var status = ""
    var report: CleanupScanner.Report?
    var scannedOnce = false

    var selectedBytes: Int64 {
        results.reduce(0) { acc, r in
            if r.target.isCommand { return acc + (commands.contains(r.id) ? r.total : 0) }
            return acc + r.items.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.size }
        }
    }

    func total(_ g: CleanGroup) -> Int64 { results.filter { $0.target.group == g }.reduce(0) { $0 + $1.total } }

    func scan() async {
        scanning = true
        status = "Procurando..."
        let res = await Task.detached(priority: .userInitiated) {
            CleanupScanner.scan { msg in Task { @MainActor in self.status = msg } }
        }.value
        results = res
        selected = []
        commands = []
        for r in res where r.target.safety == .safe {
            switch r.target.action {
            case .delete: selected.formUnion(r.items.filter { !(r.target.generic && $0.isBig) }.map(\.path))
            case .command: commands.insert(r.id)
            default: break
            }
        }
        scanning = false
        scannedOnce = true
        status = ""
    }

    func clean() async {
        cleaning = true
        let r = results, s = selected, c = commands
        report = await Task.detached(priority: .userInitiated) { CleanupScanner.clean(r, selected: s, commands: c) }.value
        cleaning = false
        await scan()
    }

    func isOn(_ r: CleanResult) -> Bool? {
        if r.target.isCommand { return commands.contains(r.id) }
        let n = r.items.filter { selected.contains($0.path) }.count
        return n == 0 ? false : n == r.items.count ? true : nil
    }

    func toggle(_ r: CleanResult) {
        if r.target.isCommand {
            if commands.contains(r.id) { commands.remove(r.id) } else { commands.insert(r.id) }
            return
        }
        if isOn(r) == true { selected.subtract(r.items.map(\.path)) } else { selected.formUnion(r.items.map(\.path)) }
    }
}

struct CleanupView: View {
    @Environment(CleanupStore.self) private var store
    @State private var group: CleanGroup? = nil
    @State private var expanded: Set<String> = []
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            if !SystemInfo.hasFullDiskAccess { FDABanner() }
            HStack(spacing: 6) {
                chip(nil, "Tudo", store.results.reduce(0) { $0 + $1.total }, "square.grid.2x2")
                ForEach(CleanGroup.allCases) { g in chip(g, g.rawValue, store.total(g), g.symbol) }
                Spacer()
            }
            .padding(12)
            Divider()
            if !store.scannedOnce && !store.scanning {
                ContentUnavailableView {
                    Label("Limpeza", systemImage: "sparkles")
                } description: {
                    Text("Caches, logs, temporários, builds do Xcode, node, Python, Rust, Go, Docker, modelos de IA, navegadores e mais. Nada é apagado sem você confirmar.")
                } actions: {
                    Button("Analisar agora") { Task { await store.scan() } }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            } else {
                List {
                    ForEach(CleanGroup.allCases.filter { group == nil || $0 == group }) { g in
                        let rows = store.results.filter { $0.target.group == g }
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { row($0) }
                            } header: {
                                HStack { Label(g.rawValue, systemImage: g.symbol); Spacer(); Text(Fmt.bytes(store.total(g))) }
                            }
                        }
                    }
                }
                .overlay { if store.scanning { ProgressView(store.status).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
            }
            Divider()
            footer
        }
        .navigationTitle("Limpeza")
        .toolbar { Button { Task { await store.scan() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.scanning) }
        .confirmationDialog("Limpar \(Fmt.bytes(store.selectedBytes))?", isPresented: $confirm) {
            Button("Limpar", role: .destructive) { Task { await store.clean() } }
        } message: {
            Text("Caches e builds são apagados de vez (são recriáveis). Itens marcados como Lixeira vão para a Lixeira. Itens de sistema pedem sua senha.")
        }
    }

    private var footer: some View {
        HStack {
            if let r = store.report {
                VStack(alignment: .leading) {
                    Text("Liberado: \(Fmt.bytes(r.freed))").fontWeight(.semibold)
                    if !r.failed.isEmpty { Text("\(r.failed.count) item(ns) em uso ou protegidos foram pulados.").font(.caption).foregroundStyle(.secondary).help(r.failed.prefix(30).joined(separator: "\n")) }
                    if !r.log.isEmpty { Text(r.log.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
            Spacer()
            Text("Selecionado: \(Fmt.bytes(store.selectedBytes))").monospacedDigit()
            Button(store.cleaning ? "Limpando..." : "Limpar") { confirm = true }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(store.cleaning || store.scanning || (store.selected.isEmpty && store.commands.isEmpty))
        }
        .padding(12)
    }

    private func chip(_ g: CleanGroup?, _ title: String, _ bytes: Int64, _ symbol: String) -> some View {
        Button { group = g } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title)
                if store.scannedOnce { Text(Fmt.bytes(bytes)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(group == g ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func row(_ r: CleanResult) -> some View {
        let open = expanded.contains(r.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                if case .info = r.target.action {
                    Image(systemName: "info.circle").foregroundStyle(.secondary).frame(width: 18)
                } else {
                    TriCheck(state: store.isOn(r)) { store.toggle(r) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(r.target.title).fontWeight(.medium)
                        actionTag(r.target.action)
                    }
                    Text(r.target.detail).font(.caption).foregroundStyle(.secondary)
                    if let p = r.probe { Text(p).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(6) }
                }
                Spacer()
                SafetyBadge(safety: r.target.safety)
                Text(r.items.isEmpty ? "?" : Fmt.bytes(r.total)).monospacedDigit().fontWeight(.semibold).frame(width: 85, alignment: .trailing)
                Button { if open { expanded.remove(r.id) } else { expanded.insert(r.id) } } label: {
                    Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0))
                }
                .buttonStyle(.borderless)
                .opacity(r.items.isEmpty ? 0 : 1)
            }
            if open {
                ForEach(r.items.prefix(300)) { i in
                    HStack(spacing: 8) {
                        if !r.target.isCommand {
                            Toggle("", isOn: Binding(get: { store.selected.contains(i.path) }, set: { on in if on { store.selected.insert(i.path) } else { store.selected.remove(i.path) } }))
                                .toggleStyle(.checkbox).labelsHidden()
                        }
                        Text(Paths.pretty(i.path)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        if r.target.generic && i.isBig {
                            Text("grande: confira").font(.caption2).foregroundStyle(.orange).help("Pode ser cache de modelo ou dataset. Apagar obriga a baixar de novo.")
                        }
                        Spacer()
                        Text(Fmt.ago(i.mtime)).font(.caption).foregroundStyle(.secondary)
                        Text(Fmt.bytes(i.size)).font(.caption).monospacedDigit().frame(width: 75, alignment: .trailing)
                        Button { FileOps.reveal(i.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                    }
                    .padding(.leading, 28)
                }
                if r.items.count > 300 { Text("+ \(r.items.count - 300) itens").font(.caption).foregroundStyle(.secondary).padding(.leading, 28) }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func actionTag(_ a: CleanTarget.Action) -> some View {
        let (t, c): (String, Color) = {
            switch a {
            case .trash: ("Lixeira", .blue)
            case .command: ("comando", .purple)
            case .adminCommand, .adminDelete: ("admin", .orange)
            case .info: ("info", .gray)
            case .delete: ("", .clear)
            }
        }()
        if !t.isEmpty { Text(t).font(.caption2).foregroundStyle(c).padding(.horizontal, 5).background(c.opacity(0.12), in: Capsule()) }
    }
}

struct TriCheck: View {
    let state: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == true ? "checkmark.square.fill" : state == nil ? "minus.square.fill" : "square")
                .foregroundStyle(state == false ? Color.secondary : Color.accentColor)
                .font(.system(size: 15))
        }
        .buttonStyle(.plain)
        .frame(width: 18)
    }
}

struct FDABanner: View {
    var body: some View {
        HStack {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text("Sem Acesso Total ao Disco: Lixeira, Safari, Mail e alguns containers ficam invisíveis.").font(.callout)
            Spacer()
            Button("Conceder acesso") { SystemInfo.openFullDiskAccessSettings() }
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
    }
}
