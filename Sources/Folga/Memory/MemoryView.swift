import AppKit
import SwiftUI

@MainActor
@Observable
final class MemoryStore {
    var snapshot = MemorySnapshot()
    var groups: [ProcGroup] = []
    var loading = false
    var lastError: String?
    var autoRefresh = true

    private var lastCpu: [pid_t: UInt64] = [:]
    private var lastTime = Date()
    private var timer: Timer?

    func start() {
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoRefresh else { return }
                await self.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        if loading { return }
        loading = true
        let prev = lastCpu
        let prevTime = lastTime
        let (snap, procs, now) = await Task.detached(priority: .userInitiated) { () -> (MemorySnapshot, [ProcInfo], Date) in
            (MemorySnapshot.read(), ProcessReader.all(), Date())
        }.value
        let dt = max(now.timeIntervalSince(prevTime), 0.25) * 1_000_000_000
        var withCpu = procs
        var next: [pid_t: UInt64] = [:]
        for i in withCpu.indices {
            let p = withCpu[i]
            next[p.pid] = p.cpuNs
            if let old = prev[p.pid], p.cpuNs >= old { withCpu[i].cpu = Double(p.cpuNs - old) / dt * 100 }
        }
        lastCpu = next
        lastTime = now
        snapshot = snap
        groups = Classifier.group(withCpu)
        loading = false
    }

    func stop(_ g: ProcGroup, mode: Killer.Mode) async {
        let err = await Task.detached { Killer.stop(g, mode: mode) }.value
        lastError = err
        try? await Task.sleep(for: .milliseconds(600))
        await refresh()
    }

    func kill(_ p: ProcInfo, mode: Killer.Mode) async {
        let err = await Task.detached { Killer.signal([p.pid], mode: mode) }.value
        lastError = err
        try? await Task.sleep(for: .milliseconds(400))
        await refresh()
    }

    func purge() async {
        let r = await Task.detached { Shell.admin("/usr/sbin/purge") }.value
        lastError = r.ok ? nil : "purge cancelado ou falhou."
        await refresh()
    }

    func total(_ c: ProcCategory) -> Int64 { groups.filter { $0.category == c }.reduce(0) { $0 + $1.memory } }
}

struct MemoryBar: View {
    let s: MemorySnapshot

    var body: some View {
        let parts: [(String, Int64, Color)] = [
            ("Apps", s.app, .blue), ("Fixa (wired)", s.wired, .orange), ("Comprimida", s.compressed, .purple),
            ("Cache de arquivos", s.cached, .teal.opacity(0.55)), ("Livre", s.free, .gray.opacity(0.25))
        ]
        let total = max(Double(s.total), 1)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { p in
                        Rectangle().fill(p.2).frame(width: max(0, geo.size.width * Double(p.1) / total))
                    }
                }
            }
            .frame(height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 14) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 4) {
                        Circle().fill(p.2).frame(width: 8, height: 8)
                        Text("\(p.0) \(Fmt.mem(p.1))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct MemoryView: View {
    @Environment(MemoryStore.self) private var store
    @State private var filter: ProcCategory? = nil
    @State private var search = ""
    @State private var sortByCpu = false
    @State private var expanded: Set<String> = []
    @State private var confirm: (ProcGroup, Killer.Mode)?
    @State private var showSystem = true

    var visible: [ProcGroup] {
        store.groups
            .filter { filter == nil || $0.category == filter }
            .filter { showSystem || filter == .system || $0.category != .system }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.processes.contains { $0.name.localizedCaseInsensitiveContains(search) || String($0.pid) == search } }
            .sorted { sortByCpu ? $0.cpu > $1.cpu : $0.memory > $1.memory }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(visible) { g in row(g) }
            }
            .listStyle(.inset)
        }
        .navigationTitle("Memória")
        .searchable(text: $search, prompt: "Buscar processo ou PID")
        .toolbar {
            ToolbarItemGroup {
                Toggle("Ao vivo", isOn: Bindable(store).autoRefresh).toggleStyle(.switch).help("Atualiza a cada 3 s enquanto esta tela estiver aberta")
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Atualizar")
            }
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        .alert(item: Binding(get: { confirm.map { ConfirmBox(group: $0.0, mode: $0.1) } }, set: { if $0 == nil { confirm = nil } })) { box in
            Alert(title: Text(box.mode == .force ? "Matar \(box.group.name)?" : "Encerrar \(box.group.name)?"),
                  message: Text("\(box.group.reason)\n\n\(box.group.processes.count) processo(s), \(Fmt.mem(box.group.memory)).\(box.group.needsAdmin ? "\nAlguns rodam como root: o macOS vai pedir sua senha." : "")"),
                  primaryButton: .destructive(Text(box.mode == .force ? "Matar" : "Encerrar")) { Task { await store.stop(box.group, mode: box.mode) } },
                  secondaryButton: .cancel())
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Fmt.mem(store.snapshot.used)) de \(Fmt.mem(store.snapshot.total)) em uso").font(.title2.weight(.semibold))
                Spacer()
                Label("Pressão: \(store.snapshot.pressureLabel)", systemImage: "gauge.with.needle")
                    .foregroundStyle(store.snapshot.pressure >= 4 ? .red : store.snapshot.pressure >= 2 ? .orange : .green)
                Text("Swap \(Fmt.mem(store.snapshot.swapUsed))").foregroundStyle(store.snapshot.swapUsed > 2 << 30 ? .orange : .secondary)
                Button("Liberar cache (purge)") { Task { await store.purge() } }
                    .help("Roda /usr/sbin/purge como admin: descarta cache de disco da RAM. Efeito temporário; o que ajuda de verdade é fechar o que está pesado.")
            }
            MemoryBar(s: store.snapshot)
            HStack(spacing: 6) {
                chip(nil, "Tudo", store.groups.reduce(0) { $0 + $1.memory })
                ForEach(ProcCategory.allCases) { c in chip(c, c.rawValue, store.total(c)) }
                Spacer()
                Toggle("Mostrar sistema", isOn: $showSystem).toggleStyle(.checkbox)
                Picker("", selection: $sortByCpu) { Text("Por memória").tag(false); Text("Por CPU").tag(true) }
                    .pickerStyle(.segmented).frame(width: 190)
            }
            if let e = store.lastError {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
        }
        .padding(16)
    }

    private func chip(_ c: ProcCategory?, _ title: String, _ bytes: Int64) -> some View {
        Button { filter = c } label: {
            HStack(spacing: 5) {
                if let c { Image(systemName: c.symbol) }
                Text(title)
                Text(Fmt.mem(bytes)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(filter == c ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func row(_ g: ProcGroup) -> some View {
        let isOpen = expanded.contains(g.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { if isOpen { expanded.remove(g.id) } else { expanded.insert(g.id) } } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 12)
                }
                .buttonStyle(.plain)
                .opacity(g.processes.count > 1 ? 1 : 0.25)
                Group {
                    if let b = g.bundlePath { Image(nsImage: SystemInfo.icon(b)).resizable() }
                    else { Image(systemName: g.category.symbol).foregroundStyle(.secondary) }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(g.name).fontWeight(.medium)
                        Text(g.category.rawValue).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(g.processes.count > 1 ? "\(g.processes.count) processos" : "PID \(g.mainPid)\(g.processes.first?.isMine == false ? " · root" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                SafetyBadge(safety: g.safety, help: g.reason)
                Text(Fmt.pct(g.cpu)).monospacedDigit().foregroundStyle(g.cpu > 50 ? .orange : .secondary).frame(width: 60, alignment: .trailing)
                Text(Fmt.mem(g.memory)).monospacedDigit().fontWeight(.semibold).frame(width: 80, alignment: .trailing)
                Button("Encerrar") { confirmOrRun(g, .quit) }.disabled(g.safety == .danger && g.processes.contains { $0.pid <= 1 })
                Button("Matar") { confirmOrRun(g, .force) }.tint(.red).buttonStyle(.borderedProminent)
                    .disabled(g.processes.contains { $0.pid <= 1 || $0.pid == getpid() })
            }
            .contentShape(Rectangle())
            .contextMenu {
                if let p = g.processes.first?.path, !p.isEmpty { Button("Mostrar no Finder") { FileOps.reveal(g.bundlePath ?? p) } }
                Button("Copiar PIDs") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(g.processes.map { String($0.pid) }.joined(separator: " "), forType: .string)
                }
            }
            if isOpen {
                ForEach(g.processes) { p in
                    HStack(spacing: 8) {
                        Text("\(p.pid)").monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        Text(p.name).lineLimit(1).truncationMode(.middle)
                        if !p.isMine { Text("root").font(.caption2).foregroundStyle(.orange) }
                        Spacer()
                        Text(Fmt.pct(p.cpu)).monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                        Text(Fmt.mem(p.memory)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        Button { Task { await store.kill(p, mode: .force) } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).help("Matar só este processo (SIGKILL)")
                            .disabled(p.pid <= 1 || p.pid == getpid())
                    }
                    .font(.callout)
                    .padding(.leading, 56)
                    .padding(.vertical, 2)
                    .help(p.path)
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 3)
    }

    private func confirmOrRun(_ g: ProcGroup, _ mode: Killer.Mode) {
        if g.safety == .safe && !g.needsAdmin && mode == .quit {
            Task { await store.stop(g, mode: mode) }
        } else {
            confirm = (g, mode)
        }
    }
}

private struct ConfirmBox: Identifiable {
    let group: ProcGroup
    let mode: Killer.Mode
    var id: String { group.id + (mode == .force ? "!" : "") }
}
