import SwiftUI

struct OverviewView: View {
    let go: (Screen) -> Void
    @Environment(MemoryStore.self) private var memory
    @Environment(CleanupStore.self) private var cleanup
    @Environment(StartupStore.self) private var startup

    var body: some View {
        let s = memory.snapshot
        let disk = SystemInfo.disk()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !SystemInfo.hasFullDiskAccess { FDABanner().clipShape(RoundedRectangle(cornerRadius: 8)) }
                HStack(alignment: .top, spacing: 16) {
                    card("Memória", "memorychip") {
                        Text("\(Fmt.mem(s.used)) / \(Fmt.mem(s.total))").font(.system(size: 28, weight: .semibold)).monospacedDigit()
                        MemoryBar(s: s)
                        HStack {
                            Label("Pressão \(s.pressureLabel)", systemImage: "gauge.with.needle")
                                .foregroundStyle(s.pressure >= 4 ? .red : s.pressure >= 2 ? .orange : .green)
                            Spacer()
                            Text("Swap \(Fmt.mem(s.swapUsed))").foregroundStyle(s.swapUsed > 2 << 30 ? .orange : .secondary)
                        }
                        .font(.callout)
                        Button("Ver processos") { go(.memory) }
                    }
                    card("Disco", "internaldrive") {
                        Text("\(Fmt.bytes(disk.free)) livres").font(.system(size: 28, weight: .semibold)).monospacedDigit()
                        ProgressView(value: Double(disk.total - disk.free), total: Double(max(disk.total, 1)))
                        Text("de \(Fmt.bytes(disk.total))").font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button(cleanup.scannedOnce ? "Limpeza: \(Fmt.bytes(cleanup.results.reduce(0) { $0 + $1.total })) encontrados" : "Analisar limpeza") {
                                go(.cleanup)
                                if !cleanup.scannedOnce { Task { await cleanup.scan() } }
                            }
                            Button("Projetos") { go(.projects) }
                        }
                    }
                }

                card("O que mais pesa agora", "flame") {
                    let top = memory.groups.sorted { $0.memory > $1.memory }.prefix(8)
                    if top.isEmpty { ProgressView().controlSize(.small) }
                    ForEach(Array(top)) { g in
                        HStack {
                            Image(systemName: g.category.symbol).foregroundStyle(.secondary).frame(width: 18)
                            Text(g.name)
                            Text(g.category.rawValue).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            SafetyBadge(safety: g.safety, help: g.reason)
                            Text(Fmt.mem(g.memory)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                    }
                    HStack(spacing: 14) {
                        ForEach(ProcCategory.allCases) { c in
                            Label("\(c.rawValue) \(Fmt.mem(memory.total(c)))", systemImage: c.symbol).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }

                card("Atalhos", "bolt") {
                    HStack(spacing: 10) {
                        shortcut("Itens de início", "power", .startup)
                        shortcut("Arquivos grandes", "doc.badge.ellipsis", .large)
                        shortcut("Restos de apps", "puzzlepiece.extension", .leftovers)
                        shortcut("Desinstalar apps", "square.grid.3x3", .apps)
                        shortcut("Explorar disco", "chart.pie", .explorer)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Visão geral")
        .task {
            await memory.refresh()
            try? await Task.sleep(for: .milliseconds(700))
            await memory.refresh()
        }
    }

    private func card<C: View>(_ title: String, _ symbol: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func shortcut(_ t: String, _ s: String, _ screen: Screen) -> some View {
        Button { go(screen) } label: {
            VStack(spacing: 6) { Image(systemName: s).font(.title2); Text(t).font(.caption) }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
    }
}
