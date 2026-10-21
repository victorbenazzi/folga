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
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.light)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1180, height: 760)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // The app is a tool you open, use and close. No background agent, no menu bar icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for w in NSApp.windows { w.backgroundColor = .white }
    }
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
        HStack(spacing: 0) {
            Sidebar(screen: $screen)
                .frame(width: 228)
            Rectangle().fill(Theme.line).frame(width: 1)
            NavigationStack {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
            }
        }
        .background(Theme.bg)
        .toolbarBackground(Theme.bg, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
    }

    @ViewBuilder
    private var detail: some View {
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

struct Sidebar: View {
    @Binding var screen: Screen

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "wind")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x0E9F8E)))
                Text("Folga").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    group("RAM", [.overview, .memory, .startup])
                    group("Armazenamento", [.cleanup, .projects, .large, .explorer, .leftovers, .apps])
                }
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
            DiskFooter()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .background(Theme.bg)
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [Screen]) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 10)
            .padding(.top, 18)
            .padding(.bottom, 6)
        ForEach(items) { s in SidebarItem(screen: s, selected: screen == s) { screen = s } }
    }
}

struct SidebarItem: View {
    let screen: Screen
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: screen.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.accent : Theme.text2)
                Text(screen.rawValue)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Theme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accentSoft : hovering ? Theme.hover : Theme.bg))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct DiskFooter: View {
    @State private var disk = SystemInfo.disk()

    var body: some View {
        let used = Double(disk.total - disk.free)
        let frac = used / Double(max(disk.total, 1))
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Disco").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Text("\(Int(frac * 100))%").font(.system(size: 12)).foregroundStyle(Theme.text2).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.barFree)
                    Capsule().fill(frac > 0.9 ? Theme.red : Theme.accent).frame(width: g.size.width * frac)
                }
            }
            .frame(height: 6)
            Text("\(Fmt.bytes(disk.free)) livres de \(Fmt.bytes(disk.total))").font(.system(size: 11.5)).foregroundStyle(Theme.text2)
            if disk.important > disk.free + 1_000_000_000 {
                Text("+ \(Fmt.bytes(disk.important - disk.free)) liberáveis pelo macOS").font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.subtle))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in disk = SystemInfo.disk() }
        .onTapGesture { disk = SystemInfo.disk() }
    }
}
