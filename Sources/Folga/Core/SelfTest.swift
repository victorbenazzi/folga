import Foundation

/// `Folga --selftest` prints what each scanner finds, without UI and without deleting anything.
enum SelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest") else { return }
        let only = CommandLine.arguments.drop { $0 != "--selftest" }.dropFirst().first
        func on(_ s: String) -> Bool { only == nil || only == s }
        let t0 = Date()
        func lap(_ s: String) { print(String(format: "  [%.2fs] %@", Date().timeIntervalSince(t0), s)) }

        if on("mem") {
            let m = MemorySnapshot.read()
            print("== Memória: usado \(Fmt.mem(m.used)) / \(Fmt.mem(m.total)) app \(Fmt.mem(m.app)) wired \(Fmt.mem(m.wired)) comp \(Fmt.mem(m.compressed)) cache \(Fmt.mem(m.cached)) livre \(Fmt.mem(m.free)) swap \(Fmt.mem(m.swapUsed)) pressão \(m.pressureLabel)")
            let groups = Classifier.group(ProcessReader.all()).sorted { $0.memory > $1.memory }
            lap("processos")
            for c in ProcCategory.allCases {
                let g = groups.filter { $0.category == c }
                print("-- \(c.rawValue): \(Fmt.mem(g.reduce(0) { $0 + $1.memory })) em \(g.count) grupos")
                for x in g.prefix(6) { print("   \(x.name) [\(x.processes.count)] \(Fmt.mem(x.memory)) \(x.safety.label)") }
            }
        }
        if on("startup") {
            let s = StartupScanner.scan()
            lap("startup")
            print("== Itens de início: \(s.count)")
            for i in s { print("   [\(i.kind.rawValue)] \(i.name) \(i.disabled ? "OFF" : "on") \(i.running ? "rodando" : "") \(i.isOrphan ? "ORFAO" : "") \(i.safety.label)") }
        }
        if on("clean") {
            let r = CleanupScanner.scan { _ in }
            lap("limpeza")
            print("== Limpeza: \(Fmt.bytes(r.reduce(0) { $0 + $1.total }))")
            for x in r.sorted(by: { $0.total > $1.total }) {
                print("   \(x.target.group.rawValue) | \(x.target.title): \(Fmt.bytes(x.total)) (\(x.items.count))\(x.probe.map { " probe: " + $0.replacingOccurrences(of: "\n", with: " / ").prefix(80) } ?? "")")
            }
        }
        if on("projects") {
            let p = ProjectScanner.scan(extraRoots: []) { _ in }
            lap("projetos")
            print("== Projetos: \(p.count), \(Fmt.bytes(p.reduce(0) { $0 + $1.total }))")
            for x in p.prefix(15) { print("   \(x.name) \(Fmt.bytes(x.total)) \(x.artifacts.map(\.kind)) parado \(x.idleDays)d") }
        }
        if on("leftovers") {
            let apps = Inventory.apps()
            lap("inventário: \(apps.count) apps")
            let hits = Leftovers.scan(known: Known.build(apps))
            lap("restos")
            let sizes = DiskSize.many(hits.map(\.path))
            print("== Restos: \(hits.count) itens, \(Fmt.bytes(sizes.values.reduce(0, +)))")
            for h in hits.sorted(by: { (sizes[$0.path] ?? 0) > (sizes[$1.path] ?? 0) }).prefix(60) {
                print("   \(h.confidence == .high ? "ALTA " : "baixa") \(h.location): \(Paths.pretty(h.path)) \(Fmt.bytes(sizes[h.path] ?? 0))")
            }
        }
        if on("large") {
            var n = 0
            let f = LargeFileScanner.scan(root: Paths.home, minBytes: 500_000_000) { n = $0 }
            lap("grandes (\(n)+ arquivos)")
            for x in f.prefix(20) { print("   \(Fmt.bytes(x.size)) \(x.kind) \(Paths.pretty(x.path))") }
        }
        exit(0)
    }
}
