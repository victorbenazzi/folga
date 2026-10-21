import SwiftUI

struct OverviewView: View {
    let go: (Screen) -> Void
    @Environment(MemoryStore.self) private var memory
    @Environment(CleanupStore.self) private var cleanup

    var body: some View {
        let s = memory.snapshot
        let disk = SystemInfo.disk()
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !SystemInfo.hasFullDiskAccess { FDABanner().clipShape(RoundedRectangle(cornerRadius: Theme.radius)) }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) { memoryCard(s); diskCard(disk) }
                    VStack(spacing: 20) { memoryCard(s); diskCard(disk) }
                }

                Card {
                    cardTitle("O que mais pesa agora", "flame")
                    let top = memory.groups.sorted { $0.memory > $1.memory }.prefix(8)
                    if top.isEmpty { ProgressView().controlSize(.small) }
                    VStack(spacing: 0) {
                        ForEach(Array(top.enumerated()), id: \.element.id) { i, g in
                            HStack(spacing: 12) {
                                Image(systemName: g.category.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(g.category.fg)
                                    .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7).fill(g.category.soft))
                                Text(g.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                                Tag(text: g.category.rawValue, fg: g.category.fg, bg: g.category.soft)
                                Spacer(minLength: 12)
                                SafetyBadge(safety: g.safety, help: g.reason)
                                Text(Fmt.mem(g.memory)).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 80, alignment: .trailing)
                            }
                            .frame(height: 46)
                            if i < top.count - 1 { Hairline() }
                        }
                    }
                    FlowLayout(spacing: 16, lineSpacing: 6) {
                        ForEach(ProcCategory.allCases) { c in
                            HStack(spacing: 5) {
                                Circle().fill(c.fg).frame(width: 6, height: 6)
                                Text(c.rawValue).foregroundStyle(Theme.text2)
                                Text(Fmt.mem(memory.total(c))).foregroundStyle(Theme.text).monospacedDigit()
                            }
                            .font(.system(size: 12))
                        }
                    }
                    .padding(.top, 4)
                }

                Card {
                    cardTitle("Atalhos", "bolt")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        shortcut("Itens de início", "power", .startup)
                        shortcut("Projetos", "folder.badge.gearshape", .projects)
                        shortcut("Arquivos grandes", "doc.badge.ellipsis", .large)
                        shortcut("Restos de apps", "puzzlepiece.extension", .leftovers)
                        shortcut("Desinstalar apps", "square.grid.3x3", .apps)
                        shortcut("Explorar disco", "chart.pie", .explorer)
                    }
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .background(Theme.bg)
        .navigationTitle("Visão geral")
        .toolbar { Button { Task { await memory.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Atualizar") }
        .task {
            await memory.refresh()
            try? await Task.sleep(for: .milliseconds(700))
            await memory.refresh()
        }
    }

    private func memoryCard(_ s: MemorySnapshot) -> some View {
        Card {
            HStack {
                cardTitle("Memória", "memorychip")
                Spacer()
                PressureLabel(s: s)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.mem(s.used)).font(.system(size: 30, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                Text("de \(Fmt.mem(s.total))").font(.system(size: 14)).foregroundStyle(Theme.text2)
            }
            MemoryBar(s: s)
            HStack {
                Text("Swap \(Fmt.mem(s.swapUsed))").font(.system(size: 12.5)).foregroundStyle(s.swapUsed > 2 << 30 ? Theme.amber : Theme.text2)
                Spacer()
                Button("Ver processos") { go(.memory) }.buttonStyle(.app)
            }
            .padding(.top, 4)
        }
    }

    private func diskCard(_ disk: SystemInfo.Disk) -> some View {
        let frac = Double(disk.total - disk.free) / Double(max(disk.total, 1))
        return Card {
            cardTitle("Disco", "internaldrive")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.bytes(disk.free)).font(.system(size: 30, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                Text("livres de \(Fmt.bytes(disk.total))").font(.system(size: 14)).foregroundStyle(Theme.text2)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.barFree)
                    Capsule().fill(frac > 0.9 ? Theme.red : Theme.accent).frame(width: g.size.width * frac)
                }
            }
            .frame(height: 10)
            Text(cleanup.scannedOnce ? "\(Fmt.bytes(cleanup.results.reduce(0) { $0 + $1.total })) encontrados para limpar" : "Ainda não analisado")
                .font(.system(size: 12.5)).foregroundStyle(Theme.text2)
            HStack {
                Spacer()
                Button(cleanup.scannedOnce ? "Ver limpeza" : "Analisar limpeza") {
                    go(.cleanup)
                    if !cleanup.scannedOnce { Task { await cleanup.scan() } }
                }
                .buttonStyle(.app)
            }
            .padding(.top, 4)
        }
    }

    private func cardTitle(_ t: String, _ symbol: String) -> some View {
        Label(t, systemImage: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
    }

    private func shortcut(_ t: String, _ s: String, _ screen: Screen) -> some View {
        ShortcutTile(title: t, symbol: s) { go(screen) }
    }
}

struct ShortcutTile: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 20)
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Theme.hover : Theme.subtle))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
