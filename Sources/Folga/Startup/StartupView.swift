import AppKit
import SwiftUI

struct StartupItem: Identifiable {
    enum Kind: String, CaseIterable {
        case userAgent = "Agente do usuário"
        case globalAgent = "Agente global"
        case daemon = "Daemon (root)"
        case loginItem = "Item de login"
        case background = "Tarefa em segundo plano"
    }

    let id: String
    var label: String
    var name: String
    var kind: Kind
    var plist: String?
    var program: String?
    var programExists = true
    var runAtLoad = false
    var keepAlive = false
    var disabled = false
    var running = false
    var developer: String?
    var parentApp: String?
    var lastUse: String?
    var safety: Safety = .safe
    var note = ""

    var isOrphan: Bool { program != nil && !programExists }
    var canToggle: Bool { plist != nil }
    var needsAdmin: Bool { kind == .daemon || (plist.map { !$0.hasPrefix(Paths.home) } ?? false) }
}

enum StartupScanner {
    /// sfltool talks to backgroundtaskmanagementd, which sometimes hangs. Then we fall back to launchd only.
    nonisolated(unsafe) static var btmAvailable = true

    static func scan(includeBTM: Bool = true) -> [StartupItem] {
        let uid = getuid()
        let disabledUser = disabledSet(Shell.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"]).out)
        let disabledSystem = disabledSet(Shell.run("/bin/launchctl", ["print-disabled", "system"]).out)
        let runningUser = runningLabels(Shell.run("/bin/launchctl", ["list"]).out)
        let systemDump = Shell.run("/bin/launchctl", ["print", "system"]).out

        var items: [StartupItem] = []
        let dirs: [(String, StartupItem.Kind)] = [
            (Paths.home + "/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .globalAgent),
            ("/Library/LaunchDaemons", .daemon)
        ]
        for (dir, kind) in dirs {
            for path in Paths.children(dir) where path.hasSuffix(".plist") {
                guard let d = NSDictionary(contentsOfFile: path) as? [String: Any] else {
                    // Some vendors ship root-only (0700) plists. List them anyway.
                    let label = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                    var item = StartupItem(id: path, label: label, name: label, kind: kind, plist: path)
                    item.note = "Plist protegido: só o root consegue ler."
                    item.disabled = kind == .daemon ? disabledSystem.contains(label) : disabledUser.contains(label)
                    item.running = kind == .daemon ? systemDump.contains(label) : runningUser[label] != nil
                    items.append(item)
                    continue
                }
                let label = d["Label"] as? String ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                let args = d["ProgramArguments"] as? [String]
                let program = (d["Program"] as? String) ?? args?.first
                var item = StartupItem(id: path, label: label, name: label, kind: kind, plist: path, program: program)
                if let program, program.hasPrefix("/") { item.programExists = Paths.exists(program) }
                if let args, args.count > 1, program?.hasSuffix("sh") == true || program?.hasSuffix("env") == true {
                    item.note = args.dropFirst().joined(separator: " ")
                }
                item.runAtLoad = d["RunAtLoad"] as? Bool ?? false
                item.keepAlive = (d["KeepAlive"] as? Bool) ?? (d["KeepAlive"] is [String: Any])
                item.disabled = (d["Disabled"] as? Bool ?? false) || (kind == .daemon ? disabledSystem.contains(label) : disabledUser.contains(label))
                item.running = kind == .daemon ? systemDump.contains("\t\(label)\n") || systemDump.contains(" \(label)\n") : runningUser[label] != nil
                items.append(item)
            }
        }
        if includeBTM { mergeBTM(into: &items) }
        for i in items.indices { classify(&items[i]) }
        return items.sorted { ($0.isOrphan ? 0 : 1, $0.kind.rawValue, $0.name.lowercased()) < ($1.isOrphan ? 0 : 1, $1.kind.rawValue, $1.name.lowercased()) }
    }

    private static func disabledSet(_ out: String) -> Set<String> {
        var s = Set<String>()
        for line in out.split(separator: "\n") where line.contains("=> disabled") || line.contains("=> true") {
            if let a = line.firstIndex(of: "\""), let b = line[line.index(after: a)...].firstIndex(of: "\"") {
                s.insert(String(line[line.index(after: a)..<b]))
            }
        }
        return s
    }

    private static func runningLabels(_ out: String) -> [String: String] {
        var m: [String: String] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t")
            if cols.count == 3, cols[0] != "-" { m[String(cols[2])] = String(cols[0]) }
        }
        return m
    }

    /// Background Task Management (what System Settings > Login Items shows).
    private static func mergeBTM(into items: inout [StartupItem]) {
        let r = Shell.run("/usr/bin/sfltool", ["dumpbtm"], timeout: 8)
        btmAvailable = r.ok && !r.out.isEmpty
        let out = r.out
        guard let start = out.range(of: "Records for UID \(getuid()) ") else { return }
        let mine = out[start.upperBound...]
        let section = mine.range(of: "Records for UID").map { mine[..<$0.lowerBound] } ?? mine
        let systemSection = out.range(of: "Records for UID 0 ").map { s -> Substring in
            let rest = out[s.upperBound...]
            return rest.range(of: "Records for UID").map { rest[..<$0.lowerBound] } ?? rest
        } ?? ""

        var appNames: [String: String] = [:]
        var records: [[String: String]] = []
        for chunk in (String(section) + "\n" + String(systemSection)).components(separatedBy: "\n #") {
            var r: [String: String] = [:]
            for line in chunk.split(separator: "\n") {
                guard let c = line.firstIndex(of: ":") else { continue }
                let k = line[..<c].trimmingCharacters(in: .whitespaces)
                let v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
                if r[k] == nil { r[k] = v }
            }
            guard let type = r["Type"] else { continue }
            if type.hasPrefix("app"), let id = r["Identifier"], let n = r["Name"] { appNames[id] = n }
            records.append(r)
        }

        for r in records {
            guard let type = r["Type"] else { continue }
            let enabled = r["Disposition"]?.contains("[enabled") ?? false
            let url = r["URL"] ?? ""
            let parent = r["Parent Identifier"].flatMap { appNames[$0] }
            if type.hasPrefix("legacy") {
                // Match the plist we already found.
                let plistPath = url.replacingOccurrences(of: "file://", with: "").replacingOccurrences(of: "/Users/\(getuid())/", with: Paths.home + "/")
                if let i = items.firstIndex(where: { $0.plist == plistPath || $0.label == plistPath.split(separator: "/").last.map { String($0).replacingOccurrences(of: ".plist", with: "") } }) {
                    items[i].developer = r["Developer Name"].flatMap { $0 == "(null)" ? nil : $0 }
                    items[i].parentApp = parent
                    items[i].lastUse = r["Last Use"]
                    if !enabled { items[i].disabled = true }
                }
            } else if type.hasPrefix("login item") || type.hasPrefix("background tasks") || type.hasPrefix("agent") || type.hasPrefix("daemon") {
                let name = r["Name"].flatMap { $0 == "(null)" ? nil : $0 } ?? r["Identifier"] ?? "?"
                var item = StartupItem(id: "btm:" + (r["UUID"] ?? name), label: r["Bundle Identifier"] ?? r["Identifier"] ?? name, name: name,
                                       kind: type.hasPrefix("login item") ? .loginItem : .background)
                item.disabled = !enabled
                item.developer = r["Developer Name"].flatMap { $0 == "(null)" ? nil : $0 }
                item.parentApp = parent
                item.lastUse = r["Last Use"]
                if url.hasPrefix("/") || url.hasPrefix("file://") {
                    let p = url.replacingOccurrences(of: "file://", with: "").removingPercentEncoding ?? url
                    item.program = p
                    item.programExists = Paths.exists(p)
                }
                item.running = r["Bundle Identifier"].map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? false
                items.append(item)
            }
        }
    }

    private static func classify(_ i: inout StartupItem) {
        let l = (i.label + " " + i.name + " " + (i.program ?? "")).lowercased()
        if i.isOrphan {
            i.safety = .safe
            i.note = "Órfão: o programa não existe mais (app desinstalado). Pode remover."
        } else if l.hasPrefix("com.apple.") {
            i.safety = .danger
            i.note = "Componente da Apple."
        } else if ["sprinto", "crowdstrike", "falcon", "jamf", "kandji", "mosyle", "sentinel", "intune", "addigy", "drata", "vanta"].contains(where: l.contains) {
            i.safety = .danger
            i.note = "Agente de segurança/compliance (provavelmente exigido pela empresa)."
        } else if ["vpn", "1password", "littlesnitch", "lulu", "tailscale", "wireguard", "malwarebytes", "cloudflare", "bitwarden"].contains(where: l.contains) {
            i.safety = .caution
            i.note = "Segurança, VPN ou senhas. Desativar faz o app parar de funcionar direito."
        } else if l.contains("docker") || l.contains("orbstack") || l.contains("colima") {
            i.safety = .caution
            i.note = "Necessário para containers. Desative se não usa Docker no dia a dia; o app reinstala quando abrir."
        } else if ["update", "keystone", "updater", "autoupdate", "sparkle"].contains(where: l.contains) {
            i.safety = .safe
            i.note = "Só um atualizador automático. Desativar não quebra o app; ele só para de se atualizar sozinho."
        } else if i.kind == .daemon {
            i.safety = .caution
            i.note = "Roda como root no boot. Desative só se souber de qual app é."
        } else if i.program?.hasPrefix(Paths.home) == true || ["/usr/bin/ssh", "/bin/sh", "/bin/bash", "/bin/zsh"].contains(i.program ?? "") {
            i.safety = .safe
            i.note = i.note.isEmpty ? "Criado por você ou por uma ferramenta de dev." : i.note
        } else {
            i.safety = .safe
            if i.note.isEmpty { i.note = i.keepAlive ? "Fica sempre rodando (KeepAlive)." : i.runAtLoad ? "Abre junto com o login." : "Roda sob demanda." }
        }
    }

    // MARK: actions

    static func setEnabled(_ item: StartupItem, _ on: Bool) -> String? {
        guard let plist = item.plist else { return "Este item é gerenciado pelo próprio app. Use Ajustes do Sistema > Itens de Início." }
        let uid = getuid()
        if item.kind == .daemon {
            let cmd = on
                ? "/bin/launchctl enable system/\(item.label); /bin/launchctl bootstrap system \(Shell.q(plist)) 2>/dev/null; true"
                : "/bin/launchctl bootout system/\(item.label) 2>/dev/null; /bin/launchctl disable system/\(item.label)"
            return Shell.admin(cmd).ok ? nil : "Cancelado ou sem permissão."
        }
        if on {
            Shell.run("/bin/launchctl", ["enable", "gui/\(uid)/\(item.label)"])
            Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist])
        } else {
            Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(item.label)"])
            let r = Shell.run("/bin/launchctl", ["disable", "gui/\(uid)/\(item.label)"])
            if !r.ok { return r.err }
        }
        return nil
    }

    static func remove(_ item: StartupItem) -> String? {
        guard let plist = item.plist else { return "Item gerenciado pelo app: remova desinstalando o app ou em Ajustes do Sistema." }
        let uid = getuid()
        if item.needsAdmin {
            let domain = item.kind == .daemon ? "system" : "gui/\(uid)"
            let trash = Paths.home + "/.Trash/" + (plist as NSString).lastPathComponent
            let cmd = "/bin/launchctl bootout \(domain)/\(item.label) 2>/dev/null; /bin/mv -f \(Shell.q(plist)) \(Shell.q(trash))"
            return Shell.admin(cmd).ok ? nil : "Cancelado ou sem permissão."
        }
        Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(item.label)"])
        return FileOps.trash(plist) ? nil : "Não consegui mover para a Lixeira."
    }
}

@MainActor
@Observable
final class StartupStore {
    var items: [StartupItem] = []
    var loading = false
    var message: String?

    var btmMissing = false

    func load() async {
        loading = true
        items = await Task.detached { StartupScanner.scan(includeBTM: false) }.value
        items = await Task.detached { StartupScanner.scan(includeBTM: true) }.value
        btmMissing = !StartupScanner.btmAvailable
        loading = false
    }

    func toggle(_ i: StartupItem) async {
        message = await Task.detached { StartupScanner.setEnabled(i, i.disabled) }.value
        await load()
    }

    func remove(_ i: StartupItem) async {
        message = await Task.detached { StartupScanner.remove(i) }.value
        await load()
    }
}

struct StartupView: View {
    @Environment(StartupStore.self) private var store
    @State private var confirmRemove: StartupItem?
    @State private var showDisabled = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("O que liga sozinho quando você faz login").font(.headline)
                    Text("Agentes launchd, daemons, itens de login e tarefas em segundo plano. Desativar é reversível; remover manda o plist para a Lixeira.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Mostrar desativados", isOn: $showDisabled).toggleStyle(.checkbox)
                Button("Abrir Itens de Início") { SystemInfo.openLoginItemsSettings() }
            }
            .padding(16)
            if store.btmMissing {
                Label("O serviço de Itens de Início do macOS não respondeu (sfltool). Mostrando só launchd; itens de login de apps estão em Ajustes.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).padding(.horizontal, 16).padding(.bottom, 8)
            }
            if store.loading && !store.items.isEmpty { ProgressView("Consultando itens de login do macOS...").controlSize(.small).padding(.bottom, 8) }
            if let m = store.message { Label(m, systemImage: "info.circle").foregroundStyle(.orange).padding(.horizontal, 16).padding(.bottom, 8) }
            Divider()
            List {
                ForEach(StartupItem.Kind.allCases, id: \.self) { kind in
                    let rows = store.items.filter { $0.kind == kind && (showDisabled || !$0.disabled) }
                    if !rows.isEmpty {
                        Section("\(kind.rawValue)s (\(rows.count))") {
                            ForEach(rows) { row($0) }
                        }
                    }
                }
            }
            .overlay { if store.loading && store.items.isEmpty { ProgressView("Lendo launchd e BTM...") } }
        }
        .navigationTitle("Itens de início")
        .toolbar { Button { Task { await store.load() } } label: { Image(systemName: "arrow.clockwise") } }
        .task { if store.items.isEmpty { await store.load() } }
        .confirmationDialog("Remover \(confirmRemove?.name ?? "")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Desligar e mover para a Lixeira", role: .destructive) { if let i = confirmRemove { Task { await store.remove(i) } } }
        } message: {
            Text(confirmRemove?.plist ?? "")
        }
    }

    private func row(_ i: StartupItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(i.running ? Color.green : i.disabled ? Color.gray.opacity(0.4) : Color.yellow.opacity(0.7))
                .frame(width: 9, height: 9).padding(.top, 5)
                .help(i.running ? "Rodando agora" : i.disabled ? "Desativado" : "Ativado, não está rodando agora")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(i.name).fontWeight(.medium).strikethrough(i.disabled)
                    if i.isOrphan { Text("ÓRFÃO").font(.caption2.bold()).foregroundStyle(.white).padding(.horizontal, 5).background(.red, in: Capsule()) }
                    if i.keepAlive { Text("sempre ligado").font(.caption2).foregroundStyle(.orange) }
                    if let d = i.developer ?? i.parentApp { Text(d).font(.caption).foregroundStyle(.secondary) }
                }
                if i.name != i.label { Text(i.label).font(.caption).foregroundStyle(.secondary) }
                if let p = i.program { Text(Paths.pretty(p)).font(.caption.monospaced()).foregroundStyle(i.programExists ? Color.secondary : Color.red).lineLimit(1).truncationMode(.middle) }
                Text(i.note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SafetyBadge(safety: i.safety, help: i.note)
            if i.canToggle {
                Button(i.disabled ? "Ativar" : "Desativar") { Task { await store.toggle(i) } }
                Button("Remover") { confirmRemove = i }.tint(.red)
            } else {
                Button("Ajustes...") { SystemInfo.openLoginItemsSettings() }.help("Itens registrados pelo app só podem ser ligados/desligados em Ajustes do Sistema")
            }
            if let p = i.plist ?? i.program { Button { FileOps.reveal(p) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Mostrar no Finder") }
        }
        .padding(.vertical, 3)
    }
}
