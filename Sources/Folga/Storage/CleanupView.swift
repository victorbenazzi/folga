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
            if !store.scannedOnce && !store.scanning {
                EmptyState(symbol: "sparkles", title: "Limpeza",
                           text: "Caches, logs, temporários, builds do Xcode, node, Python, Rust, Go, Docker, modelos de IA, navegadores e mais. Nada é apagado sem você confirmar.") {
                    Button("Analisar agora") { Task { await store.scan() } }.buttonStyle(.primary)
                }
            } else {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    Chip(title: "Tudo", value: Fmt.bytes(store.results.reduce(0) { $0 + $1.total }), selected: group == nil) { group = nil }
                    ForEach(CleanGroup.allCases) { g in
                        Chip(title: g.rawValue, value: Fmt.bytes(store.total(g)), symbol: g.symbol, selected: group == g) { group = g }
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                Hairline()
                List {
                    ForEach(CleanGroup.allCases.filter { group == nil || $0 == group }) { g in
                        let rows = store.results.filter { $0.target.group == g }
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { row($0).cleanRow() }
                            } header: {
                                SectionTitle(title: g.rawValue, symbol: g.symbol, value: Fmt.bytes(store.total(g)))
                                    .padding(.horizontal, Theme.pagePadding - 16)
                            }
                        }
                    }
                }
                .cleanList()
                .overlay { if store.scanning { BusyPill(text: store.status.isEmpty ? "Procurando..." : store.status) } }
                footer
            }
        }
        .background(Theme.bg)
        .navigationTitle("Limpeza")
        .toolbar { Button { Task { await store.scan() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.scanning).help("Analisar de novo") }
        .confirmationDialog("Limpar \(Fmt.bytes(store.selectedBytes))?", isPresented: $confirm) {
            Button("Limpar", role: .destructive) { Task { await store.clean() } }
        } message: {
            Text("Caches e builds são apagados de vez (são recriáveis). Itens marcados como Lixeira vão para a Lixeira. Itens de sistema pedem sua senha.")
        }
    }

    private var footer: some View {
        ActionBar {
            if let r = store.report {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Liberado: \(Fmt.bytes(r.freed))").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.green)
                    if !r.failed.isEmpty {
                        Text("\(r.failed.count) item(ns) em uso ou protegidos foram pulados.").font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                            .help(r.failed.prefix(30).joined(separator: "\n"))
                    }
                    if !r.log.isEmpty { Text(r.log.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineLimit(1) }
                }
            }
            Spacer()
            Text("Selecionado").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
            Text(Fmt.bytes(store.selectedBytes)).font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
            Button(store.cleaning ? "Limpando..." : "Limpar") { confirm = true }
                .buttonStyle(.primary)
                .disabled(store.cleaning || store.scanning || (store.selected.isEmpty && store.commands.isEmpty))
        }
    }

    @ViewBuilder
    private func row(_ r: CleanResult) -> some View {
        let open = expanded.contains(r.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                if case .info = r.target.action {
                    Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(Theme.text3).frame(width: 18).padding(.top, 1)
                } else {
                    TriCheck(state: store.isOn(r)) { store.toggle(r) }.padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(r.target.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                        actionTag(r.target.action)
                    }
                    Text(r.target.detail).font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    if let p = r.probe {
                        Text(p).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text2).lineLimit(6)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.subtle))
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SafetyBadge(safety: r.target.safety)
                Text(r.items.isEmpty ? "?" : Fmt.bytes(r.total)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.text).frame(width: 80, alignment: .trailing)
                IconButton(symbol: open ? "chevron.up" : "chevron.down", help: "Ver itens") {
                    if open { expanded.remove(r.id) } else { expanded.insert(r.id) }
                }
                .opacity(r.items.isEmpty ? 0 : 1)
                .disabled(r.items.isEmpty)
            }
            if open {
                VStack(spacing: 0) {
                    ForEach(r.items.prefix(300)) { i in
                        HStack(spacing: 10) {
                            if !r.target.isCommand {
                                Toggle("", isOn: Binding(get: { store.selected.contains(i.path) }, set: { on in if on { store.selected.insert(i.path) } else { store.selected.remove(i.path) } }))
                                    .toggleStyle(.checkbox).labelsHidden()
                            }
                            Text(Paths.pretty(i.path)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                            if r.target.generic && i.isBig {
                                Tag(text: "grande: confira", fg: Theme.amber, bg: Theme.amberSoft)
                                    .help("Pode ser cache de modelo ou dataset. Apagar obriga a baixar de novo.")
                            }
                            Spacer(minLength: 12)
                            Text(Fmt.ago(i.mtime)).font(.system(size: 11.5)).foregroundStyle(Theme.text3).fixedSize()
                            Text(Fmt.bytes(i.size)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 72, alignment: .trailing)
                            IconButton(symbol: "folder", help: "Mostrar no Finder") { FileOps.reveal(i.path) }
                        }
                        .frame(minHeight: 30)
                    }
                    if r.items.count > 300 {
                        Text("+ \(r.items.count - 300) itens").font(.system(size: 11.5)).foregroundStyle(Theme.text3).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.subtle))
                .padding(.leading, 32)
                .padding(.top, 12)
            }
        }
    }

    @ViewBuilder
    private func actionTag(_ a: CleanTarget.Action) -> some View {
        switch a {
        case .trash: Tag(text: "Lixeira", fg: Theme.accent, bg: Theme.accentSoft)
        case .command: Tag(text: "comando", fg: ProcCategory.dev.fg, bg: ProcCategory.dev.soft)
        case .adminCommand, .adminDelete: Tag(text: "admin", fg: Theme.amber, bg: Theme.amberSoft)
        case .info: Tag(text: "só informação")
        case .delete: EmptyView()
        }
    }
}

struct TriCheck: View {
    let state: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(state == false ? Theme.bg : Theme.accent)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(state == false ? Theme.lineStrong : Theme.accent, lineWidth: 1))
                if state != false {
                    Image(systemName: state == true ? "checkmark" : "minus").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                }
            }
            .frame(width: 16, height: 16)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct FDABanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill").foregroundStyle(Theme.amber)
            Text("Sem Acesso Total ao Disco: Lixeira, Safari, Mail e alguns containers ficam invisíveis.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.text)
            Spacer(minLength: 12)
            Button("Conceder acesso") { SystemInfo.openFullDiskAccessSettings() }.buttonStyle(.app)
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 10)
        .background(Theme.amberSoft)
    }
}
