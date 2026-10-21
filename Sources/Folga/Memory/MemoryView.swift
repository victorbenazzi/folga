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
            ("Apps", s.app, Theme.barApp), ("Fixa (wired)", s.wired, Theme.barWired), ("Comprimida", s.compressed, Theme.barCompressed),
            ("Cache de arquivos", s.cached, Theme.barCache), ("Livre", s.free, Theme.barFree)
        ]
        // Sum of the parts, not physical RAM, so the bar always fills its width.
        let total = max(Double(parts.reduce(0) { $0 + $1.1 }), 1)
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { p in
                        Rectangle().fill(p.2).frame(width: max(0, (geo.size.width - 8) * Double(p.1) / total))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            FlowLayout(spacing: 18, lineSpacing: 6) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(p.2).frame(width: 8, height: 8)
                        Text(p.0).foregroundStyle(Theme.text2)
                        Text(Fmt.mem(p.1)).foregroundStyle(Theme.text).monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .fixedSize()
                }
            }
        }
    }
}

struct PressureLabel: View {
    let s: MemorySnapshot

    var body: some View {
        let sev: Safety = s.pressure >= 4 ? .danger : s.pressure >= 2 ? .caution : .safe
        HStack(spacing: 6) {
            Circle().fill(sev.fg).frame(width: 7, height: 7)
            Text("Pressão \(s.pressureLabel.lowercased())")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(sev.fg)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(sev.soft))
        .fixedSize()
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
            Hairline()
            List {
                ForEach(visible) { g in row(g).cleanRow() }
            }
            .cleanList()
        }
        .background(Theme.bg)
        .navigationTitle("Memória")
        .searchable(text: $search, placement: .toolbar, prompt: "Buscar processo ou PID")
        .toolbar {
            ToolbarItemGroup {
                Toggle("Ao vivo", isOn: Bindable(store).autoRefresh).toggleStyle(.switch).controlSize(.small)
                    .help("Atualiza a cada 3 s enquanto esta tela estiver aberta")
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
        let snap = store.snapshot
        return VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    usage(snap)
                    Spacer(minLength: 16)
                    stats(snap)
                }
                VStack(alignment: .leading, spacing: 12) {
                    usage(snap)
                    HStack(spacing: 12) { stats(snap) }
                }
            }
            MemoryBar(s: snap)
            HStack(alignment: .top, spacing: 16) {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    Chip(title: "Tudo", value: Fmt.mem(store.groups.reduce(0) { $0 + $1.memory }), selected: filter == nil) { filter = nil }
                    ForEach(ProcCategory.allCases) { c in
                        Chip(title: c.rawValue, value: Fmt.mem(store.total(c)), symbol: c.symbol, selected: filter == c) { filter = c }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 14) {
                    Toggle("Sistema", isOn: $showSystem).toggleStyle(.checkbox).font(.system(size: 12.5)).fixedSize()
                    Picker("", selection: $sortByCpu) { Text("Memória").tag(false); Text("CPU").tag(true) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                }
                .padding(.top, 2)
            }
            if let e = store.lastError {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(Theme.amber)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private func usage(_ s: MemorySnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Fmt.mem(s.used)).font(.system(size: 26, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
            Text("de \(Fmt.mem(s.total)) em uso").font(.system(size: 14)).foregroundStyle(Theme.text2)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func stats(_ s: MemorySnapshot) -> some View {
        PressureLabel(s: s)
        Text("Swap \(Fmt.mem(s.swapUsed))")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(s.swapUsed > 2 << 30 ? Theme.amber : Theme.text2)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(s.swapUsed > 2 << 30 ? Theme.amberSoft : Theme.subtle))
            .fixedSize()
        Button("Liberar cache") { Task { await store.purge() } }
            .buttonStyle(.app)
            .help("Roda /usr/sbin/purge como admin: descarta cache de disco da RAM. Efeito temporário; o que ajuda de verdade é fechar o que está pesado.")
    }

    @ViewBuilder
    private func row(_ g: ProcGroup) -> some View {
        let isOpen = expanded.contains(g.id)
        let canExpand = g.processes.count > 1
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.text3)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12)
                    .opacity(canExpand ? 1 : 0)
                Group {
                    if let b = g.bundlePath { Image(nsImage: SystemInfo.icon(b)).resizable() }
                    else {
                        Image(systemName: g.category.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(g.category.fg)
                            .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7).fill(g.category.soft))
                    }
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(g.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        Tag(text: g.category.rawValue, fg: g.category.fg, bg: g.category.soft)
                    }
                    Text(canExpand ? "\(g.processes.count) processos" : "PID \(g.mainPid)\(g.processes.first?.isMine == false ? " · root" : "")")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                }
                .layoutPriority(1)
                Spacer(minLength: 12)
                SafetyBadge(safety: g.safety, help: g.reason)
                Text(Fmt.pct(g.cpu)).font(.system(size: 12.5)).monospacedDigit()
                    .foregroundStyle(g.cpu > 50 ? Theme.amber : Theme.text2).frame(width: 54, alignment: .trailing)
                Text(Fmt.mem(g.memory)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.text).frame(width: 78, alignment: .trailing)
                HStack(spacing: 6) {
                    Button("Encerrar") { confirmOrRun(g, .quit) }.buttonStyle(.app)
                        .disabled(g.processes.contains { $0.pid <= 1 })
                    Button("Matar") { confirmOrRun(g, .force) }.buttonStyle(.dangerSoft)
                        .disabled(g.processes.contains { $0.pid <= 1 || $0.pid == getpid() })
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if canExpand { if isOpen { expanded.remove(g.id) } else { expanded.insert(g.id) } } }
            .contextMenu {
                if let p = g.processes.first?.path, !p.isEmpty { Button("Mostrar no Finder") { FileOps.reveal(g.bundlePath ?? p) } }
                Button("Copiar PIDs") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(g.processes.map { String($0.pid) }.joined(separator: " "), forType: .string)
                }
            }
            if isOpen {
                VStack(spacing: 0) {
                    ForEach(g.processes) { p in
                        HStack(spacing: 10) {
                            Text("\(p.pid)").monospacedDigit().foregroundStyle(Theme.text3).frame(width: 56, alignment: .leading)
                            Text(p.name).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                            if !p.isMine { Tag(text: "root", fg: Theme.amber, bg: Theme.amberSoft) }
                            Spacer(minLength: 12)
                            Text(Fmt.pct(p.cpu)).monospacedDigit().foregroundStyle(Theme.text2).frame(width: 54, alignment: .trailing)
                            Text(Fmt.mem(p.memory)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 78, alignment: .trailing)
                            IconButton(symbol: "xmark", help: "Matar só este processo (SIGKILL)", tint: Theme.red) { Task { await store.kill(p, mode: .force) } }
                                .disabled(p.pid <= 1 || p.pid == getpid())
                        }
                        .font(.system(size: 12))
                        .frame(height: 30)
                        .help(p.path)
                    }
                }
                .padding(.leading, 64)
                .padding(.trailing, 4)
                .padding(.top, 10)
            }
        }
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
