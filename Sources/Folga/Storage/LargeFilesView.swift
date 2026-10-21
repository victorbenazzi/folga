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
            HStack {
                Picker("Maior que", selection: $s.minMB) {
                    Text("50 MB").tag(50); Text("100 MB").tag(100); Text("250 MB").tag(250); Text("500 MB").tag(500); Text("1 GB").tag(1000); Text("5 GB").tag(5000)
                }
                .frame(width: 180)
                Picker("Tipo", selection: $kind) {
                    Text("Todos").tag("Todos")
                    ForEach(Array(Set(store.files.map(\.kind))).sorted(), id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 240)
                Toggle("Ocultar ~/Library", isOn: $hideLibrary).toggleStyle(.checkbox)
                Spacer()
                Button(store.scanning ? "Procurando..." : "Procurar em ~") { Task { await store.scan() } }.disabled(store.scanning)
            }
            .padding(12)
            Divider()
            if store.files.isEmpty && !store.scanning {
                ContentUnavailableView("Arquivos grandes", systemImage: "doc.badge.ellipsis",
                                       description: Text("Varre toda a sua pasta de usuário, inclusive ~/Library e pastas ocultas, atrás de arquivos pesados: vídeos, VMs, modelos, dumps, instaladores."))
            } else {
                Table(visible, selection: $s.selected) {
                    TableColumn("Nome") { f in
                        HStack {
                            Image(nsImage: SystemInfo.icon(f.path)).resizable().frame(width: 16, height: 16)
                            Text(f.name).lineLimit(1)
                        }
                        .contextMenu {
                            Button("Mostrar no Finder") { FileOps.reveal(f.path) }
                            Button("Abrir") { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) }
                        }
                    }
                    .width(min: 160, ideal: 240)
                    TableColumn("Pasta") { f in Text(Paths.pretty((f.path as NSString).deletingLastPathComponent)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(f.path) }
                    TableColumn("Tipo") { f in Text(f.kind).foregroundStyle(.secondary) }.width(140)
                    TableColumn("Modificado") { f in Text(Fmt.ago(f.mtime)).foregroundStyle(.secondary) }.width(110)
                    TableColumn("") { f in SafetyBadge(safety: f.safety) }.width(95)
                    TableColumn("Tamanho") { f in Text(Fmt.bytes(f.size)).monospacedDigit().fontWeight(.semibold) }.width(80)
                }
                .overlay { if store.scanning { ProgressView("\(store.scanned.formatted()) arquivos lidos...").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
            }
            Divider()
            HStack {
                Text("\(visible.count) arquivos · \(Fmt.bytes(visible.reduce(0) { $0 + $1.size }))").foregroundStyle(.secondary)
                if let m = store.message { Text(m).font(.callout) }
                Spacer()
                Button("Mostrar no Finder") { store.selected.forEach(FileOps.reveal) }.disabled(store.selected.isEmpty)
                Button("Mover para a Lixeira") { confirm = true }.buttonStyle(.borderedProminent).disabled(store.selected.isEmpty)
            }
            .padding(12)
        }
        .navigationTitle("Arquivos grandes")
        .confirmationDialog("Mover \(store.selected.count) arquivo(s) para a Lixeira?", isPresented: $confirm) {
            Button("Mover para a Lixeira", role: .destructive) { Task { await store.trashSelected() } }
        }
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
            HStack {
                Button { Task { await store.back() } } label: { Image(systemName: "chevron.left") }.disabled(store.stack.count < 2)
                Text(Paths.pretty(store.current)).font(.headline.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
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
                .frame(width: 100)
                Button { Task { await store.load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(12)
            Divider()
            let maxSize = Double(store.entries.first?.size ?? 1)
            List(store.entries) { e in
                HStack(spacing: 10) {
                    Image(nsImage: SystemInfo.icon(e.path)).resizable().frame(width: 18, height: 18)
                    Text(e.name).lineLimit(1)
                    Spacer()
                    GeometryReader { g in
                        Capsule().fill(Color.accentColor.opacity(0.6)).frame(width: max(2, g.size.width * Double(e.size) / max(maxSize, 1)))
                    }
                    .frame(width: 160, height: 6)
                    Text(Fmt.bytes(e.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if e.isDir && !e.name.hasSuffix(".app") { Task { await store.open(e.path) } } }
                .contextMenu {
                    if e.isDir { Button("Abrir aqui") { Task { await store.open(e.path) } } }
                    Button("Mostrar no Finder") { FileOps.reveal(e.path) }
                    Button("Mover para a Lixeira", role: .destructive) { confirmTrash = e }
                }
            }
            .overlay { if store.loading { ProgressView("Medindo...") } }
            Divider()
            Text("Clique duas vezes para entrar numa pasta. Botão direito para Finder ou Lixeira. \(Fmt.bytes(store.entries.reduce(0) { $0 + $1.size })) nesta pasta.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .navigationTitle("Explorar disco")
        .task { if store.entries.isEmpty { await store.load() } }
        .confirmationDialog("Mover \(confirmTrash?.name ?? "") para a Lixeira?", isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } })) {
            Button("Mover para a Lixeira", role: .destructive) { if let e = confirmTrash { Task { await store.trash(e) } } }
        } message: { Text(confirmTrash.map { "\(Paths.pretty($0.path)) · \(Fmt.bytes($0.size))" } ?? "") }
    }
}
