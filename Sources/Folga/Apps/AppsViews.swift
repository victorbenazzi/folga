import AppKit
import SwiftUI

// MARK: - Leftovers

struct LeftoverGroup: Identifiable {
    let key: String
    var items: [(hit: Leftovers.Hit, size: Int64)]
    var id: String { key }
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
    var confidence: Leftovers.Confidence { items.contains { $0.hit.confidence == .high } ? .high : .low }
    var safety: Safety { confidence == .high ? .safe : .caution }
    var needsAdmin: Bool { items.contains { $0.hit.admin } }
}

@MainActor
@Observable
final class LeftoversStore {
    var groups: [LeftoverGroup] = []
    var selected: Set<String> = []
    var scanning = false
    var message: String?
    var scannedOnce = false

    var selectedBytes: Int64 { groups.filter { selected.contains($0.key) }.reduce(0) { $0 + $1.total } }

    func scan() async {
        scanning = true
        let res = await Task.detached(priority: .userInitiated) { () -> [LeftoverGroup] in
            let known = Known.build(Inventory.apps())
            let hits = Leftovers.scan(known: known)
            let sizes = DiskSize.many(hits.map(\.path))
            var g: [String: LeftoverGroup] = [:]
            for h in hits { g[h.key, default: LeftoverGroup(key: h.key, items: [])].items.append((h, sizes[h.path] ?? 0)) }
            return g.values.map { var x = $0; x.items.sort { $0.size > $1.size }; return x }.sorted { $0.total > $1.total }
        }.value
        groups = res
        selected = Set(res.filter { $0.confidence == .high && !$0.needsAdmin }.map(\.key))
        scanning = false
        scannedOnce = true
    }

    func remove() async {
        let chosen = groups.filter { selected.contains($0.key) }
        let (count, failed) = await Task.detached { () -> (Int, Int) in
            var n = 0, f = 0
            var admin: [String] = []
            for g in chosen {
                for (h, _) in g.items {
                    if h.admin { admin.append(h.path) } else if FileOps.trash(h.path) { n += 1 } else { f += 1 }
                }
            }
            if !admin.isEmpty {
                // Unload launchd jobs before moving their plists.
                for p in admin where p.hasSuffix(".plist") && p.contains("/Launch") {
                    if let label = (NSDictionary(contentsOfFile: p)?["Label"] as? String) {
                        _ = Shell.admin("/bin/launchctl bootout system/\(label) 2>/dev/null; true")
                    }
                }
                if FileOps.adminTrash(admin) { n += admin.count } else { f += admin.count }
            }
            return (n, f)
        }.value
        message = "\(count) item(ns) na Lixeira\(failed > 0 ? ", \(failed) falharam" : ""). Esvazie a Lixeira para liberar o espaço."
        await scan()
    }
}

struct LeftoversView: View {
    @Environment(LeftoversStore.self) private var store
    @State private var expanded: Set<String> = []
    @State private var confirm = false
    @State private var onlyHigh = false

    var visible: [LeftoverGroup] { store.groups.filter { !onlyHigh || $0.confidence == .high } }

    var body: some View {
        VStack(spacing: 0) {
            if !SystemInfo.hasFullDiskAccess { FDABanner() }
            if !store.scannedOnce && !store.scanning {
                EmptyState(symbol: "puzzlepiece.extension", title: "Restos de apps",
                           text: "Compara ~/Library e /Library com todos os apps, ferramentas do Homebrew e CLIs instalados para achar o que ficou de apps que você já removeu.") {
                    Button("Procurar restos") { Task { await store.scan() } }.buttonStyle(.primary)
                }
            } else {
                PageHeader(title: "Restos de apps que você já desinstalou",
                           subtitle: "Seguro: nenhum app ou ferramenta instalada usa esse identificador. Cuidado: nome genérico ou de um fornecedor que ainda tem outro app, confira antes.") {
                    Toggle("Só os certeiros", isOn: $onlyHigh).toggleStyle(.checkbox).font(.system(size: 12.5)).fixedSize()
                }
                Hairline()
                List(visible) { g in
                    leftoverRow(g).cleanRow()
                }
                .cleanList()
                .overlay { if store.scanning { BusyPill(text: "Comparando com apps instalados...") } }
                ActionBar {
                    Text("\(visible.count) grupos · \(Fmt.bytes(visible.reduce(0) { $0 + $1.total }))").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                    if let m = store.message { Text(m).font(.system(size: 12.5)).foregroundStyle(Theme.text).lineLimit(1) }
                    Spacer()
                    Text("Selecionado").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                    Text(Fmt.bytes(store.selectedBytes)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    Button("Mover para a Lixeira") { confirm = true }.buttonStyle(.primary).disabled(store.selected.isEmpty || store.scanning)
                }
            }
        }
        .background(Theme.bg)
        .navigationTitle("Restos de apps")
        .toolbar { Button { Task { await store.scan() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.scanning).help("Procurar de novo") }
        .confirmationDialog("Mover \(store.selected.count) grupo(s) para a Lixeira?", isPresented: $confirm) {
            Button("Mover para a Lixeira", role: .destructive) { Task { await store.remove() } }
        } message: { Text("Tudo vai para a Lixeira, então dá para desfazer. Itens de /Library pedem senha.") }
    }

    private func leftoverRow(_ g: LeftoverGroup) -> some View {
        let open = expanded.contains(g.key)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                TriCheck(state: store.selected.contains(g.key)) {
                    if store.selected.contains(g.key) { store.selected.remove(g.key) } else { store.selected.insert(g.key) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(g.key).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(Set(g.items.map(\.hit.location)).sorted().joined(separator: ", ")).font(.system(size: 11.5)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if g.needsAdmin { Tag(text: "admin", fg: Theme.amber, bg: Theme.amberSoft) }
                SafetyBadge(safety: g.safety, help: g.confidence == .high ? "Nenhum app ou ferramenta instalada usa este identificador." : "Nome genérico ou de um fornecedor que ainda tem outro app instalado. Confira antes.")
                Text(Fmt.bytes(g.total)).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 78, alignment: .trailing)
                IconButton(symbol: open ? "chevron.up" : "chevron.down", help: "Ver arquivos") { if open { expanded.remove(g.key) } else { expanded.insert(g.key) } }
            }
            if open {
                VStack(spacing: 0) {
                    ForEach(g.items, id: \.hit.path) { it in
                        HStack(spacing: 10) {
                            Text(it.hit.location).font(.system(size: 11.5)).foregroundStyle(Theme.text2).frame(width: 170, alignment: .leading)
                            Text(Paths.pretty(it.hit.path)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(Fmt.bytes(it.size)).font(.system(size: 12)).monospacedDigit()
                            IconButton(symbol: "folder", help: "Mostrar no Finder") { FileOps.reveal(it.hit.path) }
                        }
                        .frame(minHeight: 30)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.subtle))
                .padding(.leading, 32)
                .padding(.top, 12)
            }
        }
    }
}

// MARK: - Apps (uninstaller)

@MainActor
@Observable
final class AppsStore {
    var apps: [InstalledApp] = []
    var loading = false
    var related: [String: [(hit: Leftovers.Hit, size: Int64)]] = [:]
    var message: String?

    func load() async {
        loading = true
        let list = await Task.detached(priority: .userInitiated) { () -> [InstalledApp] in
            var a = Inventory.apps(includeSpotlight: false).filter { !$0.isSystem }
            let sizes = DiskSize.many(a.map(\.path))
            for i in a.indices {
                a[i].size = sizes[a[i].path] ?? 0
                a[i].lastUsed = Inventory.lastUsed(a[i].path)
            }
            return a
        }.value
        apps = list
        loading = false
    }

    func loadRelated(_ app: InstalledApp) async {
        let r = await Task.detached { () -> [(hit: Leftovers.Hit, size: Int64)] in
            let hits = Leftovers.related(to: app)
            let sizes = DiskSize.many(hits.map(\.path))
            return hits.map { ($0, sizes[$0.path] ?? 0) }.sorted { $0.1 > $1.1 }
        }.value
        related[app.id] = r
    }

    func uninstall(_ app: InstalledApp) async {
        let rel = related[app.id] ?? []
        message = await Task.detached { () -> String in
            for r in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId) { r.terminate() }
            usleep(1_500_000)
            for r in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId) { r.forceTerminate() }
            var user = [app.path], admin: [String] = []
            for h in rel { if h.hit.admin { admin.append(h.hit.path) } else { user.append(h.hit.path) } }
            var failed = 0
            for p in user where !FileOps.trash(p) {
                if p == app.path { admin.append(p) } else { failed += 1 }
            }
            if !admin.isEmpty && !FileOps.adminTrash(admin) { failed += admin.count }
            return failed == 0 ? "\(app.name) foi para a Lixeira com \(rel.count) arquivo(s) relacionados." : "\(app.name): \(failed) item(ns) não puderam ser movidos."
        }.value
        await load()
    }
}

struct AppsView: View {
    @Environment(AppsStore.self) private var store
    @State private var selection: InstalledApp.ID?
    @State private var sort = [KeyPathComparator(\InstalledApp.size, order: .reverse)]
    @State private var confirm: InstalledApp?
    @State private var search = ""

    var rows: [InstalledApp] {
        store.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleId.localizedCaseInsensitiveContains(search) }.sorted(using: sort)
    }

    var body: some View {
        HStack(spacing: 0) {
            Table(rows, selection: $selection, sortOrder: $sort) {
                TableColumn("App", value: \.name) { a in
                    HStack(spacing: 8) {
                        Image(nsImage: SystemInfo.icon(a.path)).resizable().frame(width: 20, height: 20)
                        Text(a.name).foregroundStyle(Theme.text).lineLimit(1)
                    }
                }
                .width(min: 150, ideal: 200)
                TableColumn("Usado", value: \.lastUsedSort) { a in
                    Text(Fmt.ago(a.lastUsed)).foregroundStyle(a.lastUsed.map { Date().timeIntervalSince($0) > 90 * 86_400 } ?? true ? Theme.amber : Theme.text2)
                }
                .width(min: 90, ideal: 120)
                TableColumn("Versão", value: \.version) { a in Text(a.version).foregroundStyle(Theme.text3) }.width(min: 60, ideal: 80)
                TableColumn("Tamanho", value: \.size) { a in Text(Fmt.bytes(a.size)).monospacedDigit().fontWeight(.medium) }.width(80)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .frame(minWidth: 420)
            .overlay { if store.loading && store.apps.isEmpty { BusyPill(text: "Medindo apps...") } }

            Rectangle().fill(Theme.line).frame(width: 1)
            detail.frame(width: 340).frame(maxHeight: .infinity).background(Theme.bg)
        }
        .background(Theme.bg)
        .navigationTitle("Aplicativos")
        .searchable(text: $search, placement: .toolbar, prompt: "Buscar app")
        .toolbar { Button { Task { await store.load() } } label: { Image(systemName: "arrow.clockwise") }.help("Atualizar") }
        .task { if store.apps.isEmpty { await store.load() } }
        .onChange(of: selection) { _, id in
            if let a = store.apps.first(where: { $0.id == id }), store.related[a.id] == nil { Task { await store.loadRelated(a) } }
        }
        .confirmationDialog("Desinstalar \(confirm?.name ?? "")?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Mover app e arquivos para a Lixeira", role: .destructive) { if let a = confirm { Task { await store.uninstall(a) } } }
        } message: { Text("O app é encerrado e vai para a Lixeira junto com caches, preferências e containers dele.") }
    }

    @ViewBuilder
    private var detail: some View {
        if let a = store.apps.first(where: { $0.id == selection }) {
            let rel = store.related[a.id]
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(nsImage: SystemInfo.icon(a.path)).resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(a.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(a.bundleId).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text3).textSelection(.enabled).lineLimit(1)
                    }
                }
                VStack(spacing: 0) {
                    info("App", Fmt.bytes(a.size))
                    info("Arquivos do app", rel.map { Fmt.bytes($0.reduce(0) { $0 + $1.size }) } ?? "...")
                    info("Último uso", Fmt.ago(a.lastUsed))
                    info("Local", Paths.pretty(a.path), last: true)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.subtle))
                if a.isApple { Notice(text: "App da Apple. Remover pode exigir reinstalar pela App Store.", symbol: "applelogo") }
                Text("Arquivos relacionados").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                if let rel {
                    if rel.isEmpty { Text("Nada encontrado fora do bundle.").font(.system(size: 12.5)).foregroundStyle(Theme.text2) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(rel, id: \.hit.path) { r in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.hit.location).font(.system(size: 11)).foregroundStyle(Theme.text3)
                                        Text(Paths.pretty(r.hit.path)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 8)
                                    Text(Fmt.bytes(r.size)).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Theme.text2)
                                    IconButton(symbol: "folder", help: "Mostrar no Finder") { FileOps.reveal(r.hit.path) }
                                }
                            }
                        }
                    }
                } else { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                if let m = store.message { Text(m).font(.system(size: 12)).foregroundStyle(Theme.text2) }
                HStack(spacing: 8) {
                    Button("Mostrar no Finder") { FileOps.reveal(a.path) }.buttonStyle(.app)
                    Spacer()
                    Button("Desinstalar") { confirm = a }.buttonStyle(AppButtonStyle(kind: .danger, large: true)).disabled(rel == nil)
                }
            }
            .padding(22)
        } else {
            EmptyState(symbol: "app.dashed", title: "Escolha um app",
                       text: "Veja o tamanho real (app + caches + containers) e desinstale levando tudo junto.") { EmptyView() }
        }
    }

    private func info(_ k: String, _ v: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(k).foregroundStyle(Theme.text2)
                Spacer(minLength: 12)
                Text(v).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 12)
            .frame(height: 34)
            if !last { Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 12) }
        }
    }
}

extension InstalledApp {
    var lastUsedSort: Date { lastUsed ?? .distantPast }
}
