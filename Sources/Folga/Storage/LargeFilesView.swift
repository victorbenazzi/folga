import AppKit
import SwiftUI

struct BigFile: Identifiable, Hashable {
    let path: String
    let size: Int64
    let mtime: Date
    let atime: Date
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }

    var kind: String {
        switch ext {
        case "mp4", "mov", "mkv", "avi", "m4v", "webm", "prores": "Vídeo"
        case "dmg", "iso", "img", "sparseimage", "sparsebundle", "raw", "qcow2", "vmdk", "vdi", "utm", "pvm", "hdd": "Imagem de disco / VM"
        case "zip", "gz", "tgz", "xz", "7z", "rar", "tar", "bz2", "zst", "xip": "Compactado"
        case "pkg", "mpkg", "ipsw", "ipa", "apk", "aab": "Instalador"
        case "gguf", "safetensors", "bin", "pt", "pth", "onnx", "ckpt", "mlmodel", "mlpackage", "h5", "npz", "tflite": "Modelo de IA / dados"
        case "log", "txt", "jsonl", "out": "Log / texto"
        case "sqlite", "db", "sqlite3", "realm", "dump", "sql", "bak": "Banco de dados"
        case "psd", "ai", "sketch", "fig", "blend", "aep", "prproj", "fcpxml": "Projeto criativo"
        case "jpg", "jpeg", "png", "heic", "tif", "tiff", "cr2", "nef", "arw", "dng": "Imagem"
        case "wav", "aiff", "flac", "mp3", "m4a": "Áudio"
        default: "Outro"
        }
    }

    var safety: Safety {
        if path.contains("/Library/Containers/com.docker.docker/") || path.contains("/.orbstack/") { return .danger }
        if ["Instalador", "Log / texto"].contains(kind) || (kind == "Imagem de disco / VM" && ext == "dmg") || path.hasPrefix(Paths.home + "/.Trash/") { return .safe }
        if path.contains("/Library/") { return .caution }
        return .caution
    }
}

enum LargeFileScanner {
    static func scan(root: String, minBytes: Int64, progress: @escaping (Int) -> Void) -> [BigFile] {
        var out: [BigFile] = []
        var count = 0
        let skip: Set<String> = ["CloudStorage", "Mobile Documents", ".Spotlight-V100", ".fseventsd", "node_modules"]
        DiskSize.walk(root) { e in
            let info = Int32(e.pointee.fts_info)
            if info == FTS_D {
                if e.pointee.fts_level > 0, skip.contains(DiskSize.name(e)) { return .skip }
                return .go
            }
            guard info == FTS_F, let st = e.pointee.fts_statp else { return .go }
            count += 1
            if count % 20_000 == 0 { progress(count) }
            let bytes = Int64(st.pointee.st_blocks) * 512
            if bytes >= minBytes {
                out.append(BigFile(path: DiskSize.path(e), size: bytes,
                                   mtime: Date(timeIntervalSince1970: TimeInterval(st.pointee.st_mtimespec.tv_sec)),
                                   atime: Date(timeIntervalSince1970: TimeInterval(st.pointee.st_atimespec.tv_sec))))
            }
            return .go
        }
        return out.sorted { $0.size > $1.size }
    }
}

@MainActor
@Observable
final class LargeFilesStore {
    var files: [BigFile] = []
    var scanning = false
    var scanned = 0
    var minMB = 250
    var selected: Set<String> = []
    var message: String?

    func scan() async {
        scanning = true
        scanned = 0
        let min = Int64(minMB) * 1_000_000
        files = await Task.detached(priority: .userInitiated) {
            LargeFileScanner.scan(root: Paths.home, minBytes: min) { n in Task { @MainActor in self.scanned = n } }
        }.value
        selected = []
        scanning = false
    }

    func trashSelected() async {
        let paths = Array(selected)
        let failed = await Task.detached { paths.filter { !FileOps.trash($0) } }.value
        message = failed.isEmpty ? "\(paths.count) arquivo(s) na Lixeira. Esvazie a Lixeira para liberar o espaço." : "\(failed.count) não puderam ir para a Lixeira."
        files.removeAll { selected.contains($0.path) && !failed.contains($0.path) }
        selected = []
    }
}

struct LargeFilesView: View {
    @Environment(LargeFilesStore.self) private var store
    @State private var kind = "Todos"
    @State private var hideLibrary = false
    @State private var confirm = false

    var visible: [BigFile] {
        store.files.filter { (kind == "Todos" || $0.kind == kind) && (!hideLibrary || !$0.path.hasPrefix(Paths.home + "/Library/")) }
    }

    var body: some View {
        @Bindable var s = store
        VStack(spacing: 0) {
            if store.files.isEmpty && !store.scanning {
                EmptyState(symbol: "doc.badge.ellipsis", title: "Arquivos grandes",
                           text: "Varre toda a sua pasta de usuário, inclusive ~/Library e pastas ocultas, atrás de arquivos pesados: vídeos, VMs, modelos, dumps, instaladores.") {
                    Picker("Maior que", selection: $s.minMB) { sizeOptions }.fixedSize()
                    Button("Procurar") { Task { await store.scan() } }.buttonStyle(.primary)
                }
            } else {
                PageHeader(title: "Arquivos pesados na sua pasta de usuário", subtitle: "Ordenados por espaço real ocupado. Selecione e mande para a Lixeira.") {
                    Picker("Maior que", selection: $s.minMB) { sizeOptions }.font(.system(size: 12.5)).fixedSize()
                    Picker("Tipo", selection: $kind) {
                        Text("Todos").tag("Todos")
                        ForEach(Array(Set(store.files.map(\.kind))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .font(.system(size: 12.5)).fixedSize()
                    Toggle("Ocultar ~/Library", isOn: $hideLibrary).toggleStyle(.checkbox).font(.system(size: 12.5)).fixedSize()
                    Button(store.scanning ? "Procurando..." : "Procurar de novo") { Task { await store.scan() } }.buttonStyle(.app).disabled(store.scanning)
                }
                Hairline()
                Table(visible, selection: $s.selected) {
                    TableColumn("Nome") { f in
                        HStack(spacing: 8) {
                            Image(nsImage: SystemInfo.icon(f.path)).resizable().frame(width: 18, height: 18)
                            Text(f.name).foregroundStyle(Theme.text).lineLimit(1)
                        }
                        .contextMenu {
                            Button("Mostrar no Finder") { FileOps.reveal(f.path) }
                            Button("Abrir") { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) }
                        }
                    }
                    .width(min: 160, ideal: 240)
                    TableColumn("Pasta") { f in
                        Text(Paths.pretty((f.path as NSString).deletingLastPathComponent)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle).help(f.path)
                    }
                    TableColumn("Tipo") { f in Text(f.kind).foregroundStyle(Theme.text2) }.width(min: 90, ideal: 140)
                    TableColumn("Modificado") { f in Text(Fmt.ago(f.mtime)).foregroundStyle(Theme.text2) }.width(min: 80, ideal: 110)
                    TableColumn("") { f in SafetyBadge(safety: f.safety) }.width(90)
                    TableColumn("Tamanho") { f in Text(Fmt.bytes(f.size)).monospacedDigit().fontWeight(.semibold) }.width(80)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
                .background(Theme.bg)
                .overlay { if store.scanning { BusyPill(text: "\(store.scanned.formatted()) arquivos lidos...") } }
                ActionBar {
                    Text("\(visible.count) arquivos · \(Fmt.bytes(visible.reduce(0) { $0 + $1.size }))").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                    if let m = store.message { Text(m).font(.system(size: 12.5)).foregroundStyle(Theme.text) }
                    Spacer()
                    Button("Mostrar no Finder") { store.selected.forEach(FileOps.reveal) }.buttonStyle(.app).disabled(store.selected.isEmpty)
                    Button("Mover para a Lixeira") { confirm = true }.buttonStyle(.primary).disabled(store.selected.isEmpty)
                }
            }
        }
        .background(Theme.bg)
        .navigationTitle("Arquivos grandes")
        .toolbar { Button { Task { await store.scan() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.scanning).help("Procurar de novo") }
        .confirmationDialog("Mover \(store.selected.count) arquivo(s) para a Lixeira?", isPresented: $confirm) {
            Button("Mover para a Lixeira", role: .destructive) { Task { await store.trashSelected() } }
        }
    }

    @ViewBuilder private var sizeOptions: some View {
        Text("50 MB").tag(50); Text("100 MB").tag(100); Text("250 MB").tag(250); Text("500 MB").tag(500); Text("1 GB").tag(1000); Text("5 GB").tag(5000)
    }
}

// MARK: - Disk explorer

struct DirEntry: Identifiable {
    let path: String
    let size: Int64
    let isDir: Bool
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

@MainActor
@Observable
final class ExplorerStore {
    var stack: [String] = [Paths.home]
    var entries: [DirEntry] = []
    var loading = false
    private var cache: [String: [DirEntry]] = [:]

    var current: String { stack.last ?? Paths.home }

    func open(_ p: String) async { stack.append(p); await load() }
    func back() async { if stack.count > 1 { stack.removeLast(); await load() } }
    func jump(_ p: String) async { stack = [p]; await load() }

    func load(force: Bool = false) async {
        let dir = current
        if !force, let c = cache[dir] { entries = c; return }
        loading = true
        entries = []
        let res = await Task.detached(priority: .userInitiated) { () -> [DirEntry] in
            let kids = Paths.children(dir)
            let sizes = DiskSize.many(kids)
            return kids.map { DirEntry(path: $0, size: sizes[$0] ?? 0, isDir: Paths.isDir($0)) }.sorted { $0.size > $1.size }
        }.value
        cache[dir] = res
        if current == dir { entries = res }
        loading = false
    }

    func trash(_ e: DirEntry) async {
        if FileOps.trash(e.path) { cache = [:]; await load(force: true) }
    }
}

struct ExplorerView: View {
    @Environment(ExplorerStore.self) private var store
    @State private var confirmTrash: DirEntry?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconButton(symbol: "chevron.left", help: "Voltar") { Task { await store.back() } }.disabled(store.stack.count < 2)
                Text(Paths.pretty(store.current)).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 12)
                Text(Fmt.bytes(store.entries.reduce(0) { $0 + $1.size })).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text2)
                Menu("Ir para") {
                    Button("Pasta de usuário") { Task { await store.jump(Paths.home) } }
                    Button("~/Library") { Task { await store.jump(Paths.home + "/Library") } }
                    Button("Application Support") { Task { await store.jump(Paths.home + "/Library/Application Support") } }
                    Button("Containers") { Task { await store.jump(Paths.home + "/Library/Containers") } }
                    Button("Developer") { Task { await store.jump(Paths.home + "/Library/Developer") } }
                    Button("/Applications") { Task { await store.jump("/Applications") } }
                    Button("/Library") { Task { await store.jump("/Library") } }
                    Button("/opt/homebrew") { Task { await store.jump("/opt/homebrew") } }
                    Button("/private/var") { Task { await store.jump("/private/var") } }
                }
                .menuStyle(.button).fixedSize()
            }
            .padding(.horizontal, Theme.pagePadding)
            .frame(height: 58)
            Hairline()
            let maxSize = Double(store.entries.first?.size ?? 1)
            List(store.entries) { e in
                HStack(spacing: 12) {
                    Image(nsImage: SystemInfo.icon(e.path)).resizable().frame(width: 22, height: 22)
                    Text(e.name).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 16)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.barFree)
                            Capsule().fill(Theme.accent).frame(width: max(3, g.size.width * Double(e.size) / max(maxSize, 1)))
                        }
                    }
                    .frame(width: 180, height: 6)
                    Text(Fmt.bytes(e.size)).font(.system(size: 12.5, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 80, alignment: .trailing)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text3)
                        .opacity(e.isDir && !e.name.hasSuffix(".app") ? 1 : 0)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if e.isDir && !e.name.hasSuffix(".app") { Task { await store.open(e.path) } } }
                .contextMenu {
                    if e.isDir { Button("Abrir aqui") { Task { await store.open(e.path) } } }
                    Button("Mostrar no Finder") { FileOps.reveal(e.path) }
                    Button("Mover para a Lixeira", role: .destructive) { confirmTrash = e }
                }
                .cleanRow()
            }
            .cleanList()
            .environment(\.defaultMinListRowHeight, 44)
            .overlay { if store.loading { BusyPill(text: "Medindo...") } }
            Hairline()
            Text("Clique duas vezes para entrar numa pasta. Botão direito para Finder ou Lixeira.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.text3).frame(maxWidth: .infinity).frame(height: 36)
        }
        .background(Theme.bg)
        .navigationTitle("Explorar disco")
        .toolbar { Button { Task { await store.load(force: true) } } label: { Image(systemName: "arrow.clockwise") }.help("Medir de novo") }
        .task { if store.entries.isEmpty { await store.load() } }
        .confirmationDialog("Mover \(confirmTrash?.name ?? "") para a Lixeira?", isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } })) {
            Button("Mover para a Lixeira", role: .destructive) { if let e = confirmTrash { Task { await store.trash(e) } } }
        } message: { Text(confirmTrash.map { "\(Paths.pretty($0.path)) · \(Fmt.bytes($0.size))" } ?? "") }
    }
}
