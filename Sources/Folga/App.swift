import AppKit
import SwiftUI

@main
struct FolgaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var memory = MemoryStore()
    @State private var startup = StartupStore()
    @State private var cleanup = CleanupStore()
    @State private var projects = ProjectsStore()
    @State private var large = LargeFilesStore()
    @State private var explorer = ExplorerStore()
    @State private var leftovers = LeftoversStore()
    @State private var apps = AppsStore()

    init() { SelfTest.runIfRequested() }

    var body: some Scene {
        Window("Folga", id: "main") {
            RootView()
                .environment(memory)
                .environment(startup)
                .environment(cleanup)
                .environment(projects)
                .environment(large)
                .environment(explorer)
                .environment(leftovers)
                .environment(apps)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // The app is a tool you open, use and close. No background agent, no menu bar icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Screen: String, CaseIterable, Identifiable {
    case overview = "Visão geral"
    case memory = "Memória"
    case startup = "Itens de início"
    case cleanup = "Limpeza"
    case projects = "Projetos"
    case large = "Arquivos grandes"
    case explorer = "Explorar disco"
    case leftovers = "Restos de apps"
    case apps = "Aplicativos"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .memory: "memorychip"
        case .startup: "power"
        case .cleanup: "sparkles"
        case .projects: "folder.badge.gearshape"
        case .large: "doc.badge.ellipsis"
        case .explorer: "chart.pie"
        case .leftovers: "puzzlepiece.extension"
        case .apps: "square.grid.3x3"
        }
    }
}

struct RootView: View {
    @State private var screen: Screen = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $screen) {
                Section("RAM") {
                    item(.overview); item(.memory); item(.startup)
                }
                Section("Armazenamento") {
                    item(.cleanup); item(.projects); item(.large); item(.explorer); item(.leftovers); item(.apps)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200)
            .safeAreaInset(edge: .bottom) { DiskFooter() }
        } detail: {
            switch screen {
            case .overview: OverviewView(go: { screen = $0 })
            case .memory: MemoryView()
            case .startup: StartupView()
            case .cleanup: CleanupView()
            case .projects: ProjectsView()
            case .large: LargeFilesView()
            case .explorer: ExplorerView()
            case .leftovers: LeftoversView()
            case .apps: AppsView()
            }
        }
    }

    private func item(_ s: Screen) -> some View {
        Label(s.rawValue, systemImage: s.symbol).tag(s)
    }
}

struct DiskFooter: View {
    @State private var disk = SystemInfo.disk()

    var body: some View {
        let used = disk.total - disk.free
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(used), total: Double(max(disk.total, 1)))
                .tint(Double(disk.free) / Double(max(disk.total, 1)) < 0.1 ? .red : .accentColor)
            Text("\(Fmt.bytes(disk.free)) livres de \(Fmt.bytes(disk.total))").font(.caption).foregroundStyle(.secondary)
            if disk.important > disk.free + 1_000_000_000 {
                Text("+ \(Fmt.bytes(disk.important - disk.free)) liberáveis pelo macOS").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in disk = SystemInfo.disk() }
        .onTapGesture { disk = SystemInfo.disk() }
    }
}
