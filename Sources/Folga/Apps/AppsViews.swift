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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restos de apps que você já desinstalou").font(.headline)
                    Text("Compara ~/Library e /Library com todos os apps, ferramentas do Homebrew e CLIs instalados. Verde: o dono com certeza sumiu. Laranja: nome genérico, confira.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Só os certeiros", isOn: $onlyHigh).toggleStyle(.checkbox)
            }
            .padding(16)
            Divider()
            if !store.scannedOnce && !store.scanning {
                ContentUnavailableView {
                    Label("Restos de apps", systemImage: "puzzlepiece.extension")
                } actions: {
                    Button("Procurar restos") { Task { await store.scan() } }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            } else {
                List(visible) { g in
                    let open = expanded.contains(g.key)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(get: { store.selected.contains(g.key) }, set: { if $0 { store.selected.insert(g.key) } else { store.selected.remove(g.key) } }))
                                .toggleStyle(.checkbox).labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(g.key).fontWeight(.medium)
                                Text(Set(g.items.map(\.hit.location)).sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if g.needsAdmin { Text("admin").font(.caption2).foregroundStyle(.orange) }
                            SafetyBadge(safety: g.safety, help: g.confidence == .high ? "Nenhum app ou ferramenta instalada usa este identificador." : "Nome genérico ou de um fornecedor que ainda tem outro app instalado. Confira antes.")
                            Text(Fmt.bytes(g.total)).monospacedDigit().fontWeight(.semibold).frame(width: 80, alignment: .trailing)
                            Button { if open { expanded.remove(g.key) } else { expanded.insert(g.key) } } label: {
                                Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0))
                            }.buttonStyle(.borderless)
                        }
                        if open {
                            ForEach(g.items, id: \.hit.path) { it in
                                HStack {
                                    Text(it.hit.location).font(.caption).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
                                    Text(Paths.pretty(it.hit.path)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(Fmt.bytes(it.size)).font(.caption).monospacedDigit()
                                    Button { FileOps.reveal(it.hit.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                                }
                                .padding(.leading, 28)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .overlay { if store.scanning { ProgressView("Comparando com apps instalados...").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
            }
            Divider()
            HStack {
                Text("\(visible.count) grupos · \(Fmt.bytes(visible.reduce(0) { $0 + $1.total }))").foregroundStyle(.secondary)
                if let m = store.message { Text(m).font(.callout) }
                Spacer()
                Text("Selecionado: \(Fmt.bytes(store.selectedBytes))").monospacedDigit()
                Button("Mover para a Lixeira") { confirm = true }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.selected.isEmpty || store.scanning)
            }
            .padding(12)
        }
        .navigationTitle("Restos de apps")
        .toolbar { Button { Task { await store.scan() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.scanning) }
        .confirmationDialog("Mover \(store.selected.count) grupo(s) para a Lixeira?", isPresented: $confirm) {
            Button("Mover para a Lixeira", role: .destructive) { Task { await store.remove() } }
        } message: { Text("Tudo vai para a Lixeira, então dá para desfazer. Itens de /Library pedem senha.") }
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
        HSplitView {
            Table(rows, selection: $selection, sortOrder: $sort) {
                TableColumn("App", value: \.name) { a in
                    HStack { Image(nsImage: SystemInfo.icon(a.path)).resizable().frame(width: 18, height: 18); Text(a.name) }
                }
                .width(min: 150, ideal: 200)
                TableColumn("Usado", value: \.lastUsedSort) { a in Text(Fmt.ago(a.lastUsed)).foregroundStyle(a.lastUsed.map { Date().timeIntervalSince($0) > 90 * 86_400 } ?? true ? .orange : .secondary) }.width(120)
                TableColumn("Versão", value: \.version) { a in Text(a.version).foregroundStyle(.secondary) }.width(80)
                TableColumn("Tamanho", value: \.size) { a in Text(Fmt.bytes(a.size)).monospacedDigit() }.width(80)
            }
            .frame(minWidth: 480)
            .overlay { if store.loading && store.apps.isEmpty { ProgressView("Medindo apps...") } }

            detail.frame(minWidth: 300, idealWidth: 360)
        }
        .navigationTitle("Aplicativos")
        .searchable(text: $search, prompt: "Buscar app")
        .toolbar { Button { Task { await store.load() } } label: { Image(systemName: "arrow.clockwise") } }
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: SystemInfo.icon(a.path)).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(a.name).font(.title3.weight(.semibold))
                        Text(a.bundleId).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Grid(alignment: .leading, verticalSpacing: 4) {
                    GridRow { Text("App").foregroundStyle(.secondary); Text(Fmt.bytes(a.size)) }
                    GridRow { Text("Arquivos do app").foregroundStyle(.secondary); Text(rel.map { Fmt.bytes($0.reduce(0) { $0 + $1.size }) } ?? "...") }
                    GridRow { Text("Último uso").foregroundStyle(.secondary); Text(Fmt.ago(a.lastUsed)) }
                    GridRow { Text("Local").foregroundStyle(.secondary); Text(Paths.pretty(a.path)).lineLimit(1).truncationMode(.middle) }
                }
                .font(.callout)
                if a.isApple { Label("App da Apple. Remover pode exigir reinstalar pela App Store.", systemImage: "applelogo").font(.caption).foregroundStyle(.orange) }
                Divider()
                Text("Arquivos relacionados").font(.headline)
                if let rel {
                    if rel.isEmpty { Text("Nada encontrado fora do bundle.").foregroundStyle(.secondary).font(.callout) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(rel, id: \.hit.path) { r in
                                HStack {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(r.hit.location).font(.caption).foregroundStyle(.secondary)
                                        Text(Paths.pretty(r.hit.path)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(Fmt.bytes(r.size)).font(.caption).monospacedDigit()
                                    Button { FileOps.reveal(r.hit.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                } else { ProgressView().controlSize(.small) }
                Spacer()
                if let m = store.message { Text(m).font(.callout) }
                HStack {
                    Button("Mostrar no Finder") { FileOps.reveal(a.path) }
                    Spacer()
                    Button("Desinstalar") { confirm = a }.buttonStyle(.borderedProminent).tint(.red).disabled(rel == nil)
                }
            }
            .padding(16)
        } else {
            ContentUnavailableView("Escolha um app", systemImage: "app.dashed", description: Text("Veja o tamanho real (app + caches + containers) e desinstale levando tudo junto."))
        }
    }
}

extension InstalledApp {
    var lastUsedSort: Date { lastUsed ?? .distantPast }
}
