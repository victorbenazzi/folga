import Foundation

enum CleanGroup: String, CaseIterable, Identifiable {
    case system = "Lixo do sistema"
    case dev = "Dev"
    case ai = "IA e modelos"
    case browsers = "Navegadores"
    case apps = "Caches de apps"
    case downloads = "Downloads e instaladores"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .system: "trash.fill"
        case .dev: "hammer.fill"
        case .ai: "sparkles"
        case .browsers: "globe"
        case .apps: "square.stack.3d.up.fill"
        case .downloads: "arrow.down.circle.fill"
        }
    }
}

struct CleanTarget: Identifiable {
    enum Action {
        /// Delete what the patterns match (each match removed entirely).
        case delete
        /// Move matches to the Trash (user data, reversible).
        case trash
        /// Run a shell command instead of deleting files (sizes still come from `patterns`).
        case command(String)
        /// Command that needs root.
        case adminCommand(String)
        /// Delete as root.
        case adminDelete
        /// Only informative; nothing to do automatically.
        case info
    }

    let id: String
    let group: CleanGroup
    let title: String
    let detail: String
    let patterns: [String]
    var safety: Safety = .safe
    var action: Action = .delete
    /// Only matches older than this many days.
    var olderThanDays: Int? = nil
    /// Generic targets lose any path claimed by a specific target.
    var generic = false
    /// Only show when this tool exists.
    var requiresTool: String? = nil
    /// Paths to never touch even if matched.
    var exclude: [String] = []

    var isCommand: Bool {
        switch action { case .command, .adminCommand: true; default: false }
    }
}

enum Catalog {
    static let chromiumBases = [
        "~/Library/Application Support/Google/Chrome", "~/Library/Application Support/Google/Chrome Beta",
        "~/Library/Application Support/Google/Chrome Canary", "~/Library/Application Support/BraveSoftware/Brave-Browser",
        "~/Library/Application Support/Microsoft Edge", "~/Library/Application Support/Vivaldi",
        "~/Library/Application Support/Arc/User Data", "~/Library/Application Support/com.operasoftware.Opera",
        "~/Library/Application Support/Chromium", "~/Library/Application Support/Dia/User Data",
        "~/Library/Application Support/Comet", "~/Library/Application Support/Thorium"
    ]

    static let chromiumCacheDirs = ["Cache", "Code Cache", "GPUCache", "Service Worker/CacheStorage", "Service Worker/ScriptCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache"]

    static let editorBases = [
        "~/Library/Application Support/Code", "~/Library/Application Support/Code - Insiders", "~/Library/Application Support/Cursor",
        "~/Library/Application Support/Windsurf", "~/Library/Application Support/VSCodium", "~/Library/Application Support/Antigravity",
        "~/Library/Application Support/Kiro", "~/Library/Application Support/Trae"
    ]

    static let electronCacheDirs = ["Cache", "Code Cache", "GPUCache", "CachedData", "Service Worker/CacheStorage", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "ShaderCache", "GrShaderCache", "Crashpad/completed"]

    static var all: [CleanTarget] {
        var t: [CleanTarget] = []

        // MARK: Sistema
        t += [
            CleanTarget(id: "user-logs", group: .system, title: "Logs de apps", detail: "~/Library/Logs. Apps recriam quando precisam.",
                        patterns: ["~/Library/Logs/*"], generic: true),
            CleanTarget(id: "crash", group: .system, title: "Relatórios de falha", detail: "Crash reports e diagnósticos antigos.",
                        patterns: ["~/Library/Logs/DiagnosticReports/*", "/Library/Logs/DiagnosticReports/*"]),
            CleanTarget(id: "sys-logs", group: .system, title: "Logs do sistema", detail: "/Library/Logs e /var/log. Pede senha de admin.",
                        patterns: ["/Library/Logs/*", "/private/var/log/*.gz", "/private/var/log/*.bz2", "/private/var/log/asl/*.asl"],
                        safety: .safe, action: .adminDelete, generic: true, exclude: ["/Library/Logs/DiagnosticReports"]),
            CleanTarget(id: "unified-logs", group: .system, title: "Logs unificados do macOS", detail: "Roda `log erase --all`. Apaga o histórico do Console.app.",
                        patterns: ["/private/var/db/diagnostics/Persist", "/private/var/db/diagnostics/Special", "/private/var/db/uuidtext"],
                        safety: .caution, action: .adminCommand("/usr/bin/log erase --all")),
            CleanTarget(id: "user-caches", group: .system, title: "Caches de apps (outros)", detail: "~/Library/Caches. Tudo aqui é recriável; o app fica um pouco mais lento na primeira abertura.",
                        patterns: ["~/Library/Caches/*"], generic: true, exclude: ["~/Library/Caches/com.apple.HomeKit", "~/Library/Caches/CloudKit", "~/Library/Caches/com.apple.Safari"]),
            CleanTarget(id: "tmp", group: .system, title: "Arquivos temporários antigos", detail: "Pasta temporária do usuário e /tmp, só itens com mais de 3 dias.",
                        patterns: [NSTemporaryDirectory() + "*", "/private/tmp/*"], safety: .caution, olderThanDays: 3),
            CleanTarget(id: "saved-state", group: .system, title: "Estado salvo de janelas", detail: "Saved Application State. Só perde as janelas reabertas automaticamente.",
                        patterns: ["~/Library/Saved Application State/*"]),
            CleanTarget(id: "cores", group: .system, title: "Core dumps", detail: "/cores: despejos de memória de crashes. Costumam ser enormes.",
                        patterns: ["/cores/*"], action: .adminDelete),
            CleanTarget(id: "trash", group: .system, title: "Lixeira", detail: "Esvazia a Lixeira pelo Finder. Precisa de Acesso Total ao Disco para medir.",
                        patterns: ["~/.Trash/*"], safety: .caution, action: .command("osascript -e 'tell application \"Finder\" to empty trash'")),
            CleanTarget(id: "tm-snapshots", group: .system, title: "Snapshots locais do Time Machine", detail: "Snapshots APFS que aparecem como \"Dados do Sistema\". Pede senha.",
                        patterns: [], safety: .caution, action: .adminCommand("/usr/bin/tmutil thinlocalsnapshots / 999999999999 4")),
            CleanTarget(id: "macos-installers", group: .system, title: "Instaladores do macOS", detail: "Apps \"Instalar macOS\" esquecidos em /Applications.",
                        patterns: ["/Applications/Install macOS*.app", "/Applications/Instalar macOS*.app"], action: .trash),
            CleanTarget(id: "ios-updates", group: .system, title: "Atualizações de iPhone/iPad baixadas", detail: "Arquivos .ipsw antigos.",
                        patterns: ["~/Library/iTunes/iPhone Software Updates/*", "~/Library/iTunes/iPad Software Updates/*", "~/Library/Group Containers/*.com.apple.configurator/Library/Caches/*"]),
            CleanTarget(id: "ios-backups", group: .system, title: "Backups de iPhone/iPad", detail: "Backups locais (Finder). Só apague se tiver backup no iCloud.",
                        patterns: ["~/Library/Application Support/MobileSync/Backup/*"], safety: .caution, action: .trash),
            CleanTarget(id: "mail-downloads", group: .system, title: "Anexos baixados do Mail", detail: "Cópias de anexos que você abriu. Continuam no servidor.",
                        patterns: ["~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/*"]),
            CleanTarget(id: "qt", group: .system, title: "Miniaturas do Quick Look", detail: "Cache de miniaturas. Roda `qlmanage -r cache`.",
                        patterns: [], action: .command("qlmanage -r cache"))
        ]

        // MARK: Dev, Xcode e Apple
        t += [
            CleanTarget(id: "derived", group: .dev, title: "Xcode DerivedData", detail: "Builds intermediários e índices. Recriados no próximo build.",
                        patterns: ["~/Library/Developer/Xcode/DerivedData/*"]),
            CleanTarget(id: "archives", group: .dev, title: "Xcode Archives", detail: "Builds arquivados. Você perde os dSYMs para simbolizar crashes de versões publicadas.",
                        patterns: ["~/Library/Developer/Xcode/Archives/*"], safety: .caution, action: .trash),
            CleanTarget(id: "device-support", group: .dev, title: "Device Support (iOS, watchOS, tvOS, visionOS)", detail: "Símbolos de cada versão de iOS que você já conectou. Recriado ao conectar o device.",
                        patterns: ["~/Library/Developer/Xcode/iOS DeviceSupport/*", "~/Library/Developer/Xcode/watchOS DeviceSupport/*", "~/Library/Developer/Xcode/tvOS DeviceSupport/*", "~/Library/Developer/Xcode/visionOS DeviceSupport/*", "~/Library/Developer/Xcode/macOS DeviceSupport/*"]),
            CleanTarget(id: "xc-previews", group: .dev, title: "SwiftUI Previews", detail: "Simuladores e builds das previews.",
                        patterns: ["~/Library/Developer/Xcode/UserData/Previews/*", "~/Library/Developer/Xcode/UserData/IB Support/*"]),
            CleanTarget(id: "xc-caches", group: .dev, title: "Caches do Xcode", detail: "Cache do Xcode, docs e downloads.",
                        patterns: ["~/Library/Caches/com.apple.dt.Xcode", "~/Library/Caches/com.apple.dt.Xcode.sourcecontrol.Git", "~/Library/Developer/DVTDownloads/*", "~/Library/Developer/Xcode/Products/*"]),
            CleanTarget(id: "sim-unavailable", group: .dev, title: "Simuladores indisponíveis", detail: "Roda `xcrun simctl delete unavailable` (simuladores de runtimes que você já removeu).",
                        patterns: [], action: .command("xcrun simctl delete unavailable"), requiresTool: "xcrun"),
            CleanTarget(id: "sim-data", group: .dev, title: "Dados de todos os simuladores", detail: "Roda `xcrun simctl erase all`: apps instalados e dados dos simuladores voltam ao zero.",
                        patterns: ["~/Library/Developer/CoreSimulator/Devices"], safety: .caution, action: .command("xcrun simctl shutdown all; xcrun simctl erase all"), requiresTool: "xcrun"),
            CleanTarget(id: "sim-caches", group: .dev, title: "Caches do CoreSimulator", detail: "Caches de dyld e logs dos simuladores.",
                        patterns: ["~/Library/Developer/CoreSimulator/Caches/*", "~/Library/Logs/CoreSimulator/*"]),
            CleanTarget(id: "sim-runtimes", group: .dev, title: "Runtimes de simulador sem uso há 30 dias", detail: "Roda `xcrun simctl runtime delete --notUsedSinceDays 30`. Cada runtime tem 5 a 10 GB.",
                        patterns: ["/Library/Developer/CoreSimulator/Images/*.dmg", "/Library/Developer/CoreSimulator/Volumes/*"], safety: .caution,
                        action: .command("xcrun simctl runtime delete --notUsedSinceDays 30"), requiresTool: "xcrun"),
            CleanTarget(id: "spm", group: .dev, title: "Swift Package Manager", detail: "Cache de pacotes SwiftPM.",
                        patterns: ["~/Library/Caches/org.swift.swiftpm", "~/Library/org.swift.swiftpm/cache"]),
            CleanTarget(id: "cocoapods", group: .dev, title: "CocoaPods", detail: "Cache de pods. As specs (~/.cocoapods/repos) ficam.",
                        patterns: ["~/Library/Caches/CocoaPods"]),
            CleanTarget(id: "cocoapods-repos", group: .dev, title: "CocoaPods specs repo", detail: "Clone do repositório de specs. Baixado de novo no próximo `pod install`.",
                        patterns: ["~/.cocoapods/repos/*"], safety: .caution),
            CleanTarget(id: "carthage", group: .dev, title: "Carthage", detail: "Cache do Carthage.", patterns: ["~/Library/Caches/org.carthage.CarthageKit"]),
        ]

        // MARK: Dev, JS
        t += [
            CleanTarget(id: "npm", group: .dev, title: "npm", detail: "Cache do npm, npx e logs. `npm install` baixa de novo quando precisar.",
                        patterns: ["~/.npm/_cacache", "~/.npm/_npx", "~/.npm/_logs", "~/.npm/_prebuilds"]),
            CleanTarget(id: "pnpm", group: .dev, title: "pnpm store", detail: "Store global do pnpm. Projetos continuam funcionando; o próximo install baixa de novo.",
                        patterns: ["~/Library/pnpm/store", "~/.pnpm-store", "~/.local/share/pnpm/store", "~/Library/Caches/pnpm"], safety: .caution),
            CleanTarget(id: "yarn", group: .dev, title: "Yarn", detail: "Cache do Yarn classic e Berry.",
                        patterns: ["~/Library/Caches/Yarn", "~/.yarn/berry/cache", "~/.cache/yarn"]),
            CleanTarget(id: "bun", group: .dev, title: "Bun", detail: "Cache de instalação do Bun.", patterns: ["~/.bun/install/cache"]),
            CleanTarget(id: "deno", group: .dev, title: "Deno", detail: "Cache de módulos do Deno.", patterns: ["~/Library/Caches/deno", "~/.cache/deno"]),
            CleanTarget(id: "node-gyp", group: .dev, title: "node-gyp e headers", detail: "Headers do Node para módulos nativos.",
                        patterns: ["~/Library/Caches/node-gyp", "~/.node-gyp", "~/.cache/node-gyp"]),
            CleanTarget(id: "node-versions", group: .dev, title: "Versões instaladas do Node", detail: "fnm, nvm, volta, asdf. Apague só as versões que não usa (abra os detalhes).",
                        patterns: ["~/.local/share/fnm/node-versions/*", "~/Library/Application Support/fnm/node-versions/*", "~/.fnm/node-versions/*", "~/.nvm/versions/node/*", "~/.volta/tools/image/node/*", "~/.asdf/installs/nodejs/*"],
                        safety: .caution),
            CleanTarget(id: "fnm-multishell", group: .dev, title: "fnm multishells antigos", detail: "Links temporários que o fnm cria a cada terminal aberto.",
                        patterns: ["~/.local/state/fnm_multishells/*", "~/Library/Caches/fnm_multishells/*"], olderThanDays: 2),
            CleanTarget(id: "js-tools", group: .dev, title: "Turbo, Next/SWC, Electron, esbuild", detail: "Caches de ferramentas de build JS.",
                        patterns: ["~/Library/Caches/turbo", "~/.turbo", "~/Library/Caches/next-swc", "~/Library/Caches/electron", "~/Library/Caches/electron-builder", "~/.cache/esbuild", "~/Library/Caches/esbuild", "~/.vercel/cache", "~/Library/Caches/typescript", "~/.cache/typescript"]),
            CleanTarget(id: "browsers-test", group: .dev, title: "Playwright, Puppeteer, Cypress, Selenium", detail: "Navegadores baixados para testes. `npx playwright install` baixa de novo.",
                        patterns: ["~/Library/Caches/ms-playwright", "~/.cache/ms-playwright", "~/.cache/puppeteer", "~/Library/Caches/Cypress", "~/.cache/selenium", "~/.cache/ms-playwright-go"]),
            CleanTarget(id: "prisma", group: .dev, title: "Prisma engines", detail: "Binários do Prisma baixados.", patterns: ["~/.cache/prisma"]),
        ]

        // MARK: Dev, outras linguagens
        t += [
            CleanTarget(id: "pip", group: .dev, title: "Python: pip, uv, poetry, pipenv", detail: "Caches de pacotes Python.",
                        patterns: ["~/Library/Caches/pip", "~/.cache/pip", "~/.cache/uv", "~/Library/Caches/uv", "~/Library/Caches/pypoetry", "~/Library/Caches/pipenv", "~/.cache/pre-commit"]),
            CleanTarget(id: "conda", group: .dev, title: "Conda pkgs", detail: "Pacotes baixados pelo conda (`conda clean -a`).",
                        patterns: ["~/miniconda3/pkgs/*", "~/anaconda3/pkgs/*", "~/miniforge3/pkgs/*", "~/mambaforge/pkgs/*", "/opt/homebrew/Caskroom/miniconda/base/pkgs/*", "~/.conda/pkgs/*"]),
            CleanTarget(id: "pyenv", group: .dev, title: "Versões do Python (pyenv, uv)", detail: "Interpretadores instalados. Apague só os que não usa.",
                        patterns: ["~/.pyenv/versions/*", "~/.local/share/uv/python/*"], safety: .caution),
            CleanTarget(id: "cargo", group: .dev, title: "Rust: cargo registry e git", detail: "Fontes e pacotes baixados pelo cargo.",
                        patterns: ["~/.cargo/registry/cache", "~/.cargo/registry/src", "~/.cargo/git/checkouts", "~/.cargo/git/db"]),
            CleanTarget(id: "rustup", group: .dev, title: "Rust toolchains", detail: "Toolchains do rustup. Remova as antigas (nightlies velhas).",
                        patterns: ["~/.rustup/toolchains/*"], safety: .caution),
            CleanTarget(id: "go-build", group: .dev, title: "Go build cache", detail: "Roda `go clean -cache`.",
                        patterns: ["~/Library/Caches/go-build"], action: .command("go clean -cache"), requiresTool: "go"),
            CleanTarget(id: "go-mod", group: .dev, title: "Go module cache", detail: "Roda `go clean -modcache`. Módulos são baixados de novo no próximo build.",
                        patterns: ["~/go/pkg/mod"], safety: .caution, action: .command("go clean -modcache"), requiresTool: "go"),
            CleanTarget(id: "gradle", group: .dev, title: "Gradle caches e daemons", detail: "Caches do Gradle. Build seguinte fica mais lento.",
                        patterns: ["~/.gradle/caches", "~/.gradle/daemon", "~/.gradle/native", "~/.gradle/.tmp"]),
            CleanTarget(id: "gradle-dists", group: .dev, title: "Gradle wrappers baixados", detail: "Distribuições do Gradle de cada versão usada.",
                        patterns: ["~/.gradle/wrapper/dists/*"], safety: .caution),
            CleanTarget(id: "maven", group: .dev, title: "Maven repository", detail: "~/.m2/repository. Baixado de novo no próximo build.",
                        patterns: ["~/.m2/repository"], safety: .caution),
            CleanTarget(id: "android-avd", group: .dev, title: "Emuladores Android (AVDs)", detail: "Cada emulador tem vários GB.",
                        patterns: ["~/.android/avd/*.avd"], safety: .caution, action: .trash),
            CleanTarget(id: "android-sys", group: .dev, title: "Android system images", detail: "Imagens de sistema do SDK. Remova versões que não usa.",
                        patterns: ["~/Library/Android/sdk/system-images/*"], safety: .caution),
            CleanTarget(id: "android-cache", group: .dev, title: "Android caches", detail: "Cache do SDK e build cache.", patterns: ["~/.android/cache", "~/.android/build-cache"]),
            CleanTarget(id: "ruby", group: .dev, title: "Ruby / Bundler", detail: "Cache do bundler e gems.", patterns: ["~/.bundle/cache", "~/Library/Caches/rubygems", "~/.gem/specs"]),
            CleanTarget(id: "composer", group: .dev, title: "PHP Composer", detail: "Cache do Composer.", patterns: ["~/Library/Caches/composer", "~/.composer/cache", "~/.cache/composer"]),
            CleanTarget(id: "dart", group: .dev, title: "Flutter / Dart pub cache", detail: "Pacotes do pub. `flutter pub get` baixa de novo.",
                        patterns: ["~/.pub-cache/hosted", "~/.pub-cache/git"], safety: .caution),
            CleanTarget(id: "ccache", group: .dev, title: "ccache / sccache / Bazel", detail: "Caches de compilação C/C++/Rust.",
                        patterns: ["~/Library/Caches/ccache", "~/.ccache", "~/Library/Caches/Mozilla.sccache", "~/.cache/sccache", "~/.cache/bazel"]),
            CleanTarget(id: "terraform", group: .dev, title: "Terraform plugin cache", detail: "Providers baixados.", patterns: ["~/.terraform.d/plugin-cache/*"]),
            CleanTarget(id: "jetbrains", group: .dev, title: "JetBrains caches e índices", detail: "Índices são reconstruídos ao abrir o projeto.",
                        patterns: ["~/Library/Caches/JetBrains/*", "~/Library/Caches/Google/AndroidStudio*"]),
            CleanTarget(id: "editors", group: .dev, title: "VS Code, Cursor, Windsurf: caches", detail: "Caches do Electron, VSIX baixados, logs. Feche o editor antes.",
                        patterns: editorBases.flatMap { b in electronCacheDirs.map { "\(b)/\($0)" } + ["\(b)/CachedExtensionVSIXs", "\(b)/logs/*", "\(b)/CachedProfilesData"] }),
            CleanTarget(id: "editors-ws", group: .dev, title: "VS Code, Cursor: workspaceStorage", detail: "Estado local por projeto (abas, histórico de chat da IA em alguns editores). Itens com mais de 30 dias.",
                        patterns: editorBases.map { "\($0)/User/workspaceStorage/*" }, safety: .caution, olderThanDays: 30),
            CleanTarget(id: "brew", group: .dev, title: "Homebrew", detail: "Roda `brew cleanup --prune=all -s`: downloads e versões antigas das fórmulas.",
                        patterns: ["~/Library/Caches/Homebrew"], action: .command("brew cleanup --prune=all -s; rm -rf \"$(brew --cache)\""), requiresTool: "brew"),
            CleanTarget(id: "docker-build", group: .dev, title: "Docker: cache de build", detail: "Roda `docker builder prune -af`. Docker precisa estar aberto.",
                        patterns: [], action: .command("docker builder prune -af"), requiresTool: "docker"),
            CleanTarget(id: "docker-prune", group: .dev, title: "Docker: imagens, containers parados e redes", detail: "Roda `docker system prune -af`. Volumes ficam (seus bancos não são apagados).",
                        patterns: [], safety: .caution, action: .command("docker system prune -af"), requiresTool: "docker"),
            CleanTarget(id: "docker-stale-update", group: .dev, title: "Docker: atualização abandonada", detail: "Cópia do Docker.app de um update que não terminou.",
                        patterns: ["~/Library/Application Support/com.docker.install/in_progress"], safety: .caution),
            CleanTarget(id: "docker-disk", group: .dev, title: "Disco virtual do Docker (Docker.raw)", detail: "Tamanho real ocupado pelo disco da VM. Diminui depois dos prunes acima.",
                        patterns: ["~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", "~/.orbstack/data", "~/.colima/_lima/*/diffdisk"], safety: .danger, action: .info),
        ]

        // MARK: IA
        t += [
            CleanTarget(id: "ollama", group: .ai, title: "Modelos do Ollama", detail: "Seus modelos locais. Apague e baixe de novo com `ollama pull`.",
                        patterns: ["~/.ollama/models"], safety: .caution),
            CleanTarget(id: "lmstudio", group: .ai, title: "Modelos do LM Studio", detail: "Um item por modelo baixado.",
                        patterns: ["~/.lmstudio/models/*/*", "~/.cache/lm-studio/models/*/*"], safety: .caution),
            CleanTarget(id: "hf", group: .ai, title: "Hugging Face cache", detail: "Modelos e datasets do hub (transformers, MLX, diffusers). Baixados de novo quando usados.",
                        patterns: ["~/.cache/huggingface/hub/*", "~/.cache/huggingface/datasets/*", "~/.cache/huggingface/xet"], safety: .caution),
            CleanTarget(id: "ml-caches", group: .ai, title: "PyTorch, Whisper, CLIP, outros", detail: "Pesos baixados por libs de ML.",
                        patterns: ["~/.cache/torch", "~/.cache/whisper", "~/.cache/clip", "~/.cache/chroma", "~/.cache/sentence_transformers", "~/.cache/mlx", "~/.diffusionbee/downloads"], safety: .caution),
            CleanTarget(id: "chrome-ai", group: .ai, title: "Modelo de IA do Chrome (Gemini Nano)", detail: "Modelo on-device do Chrome. Volta a baixar se a função continuar ativa em chrome://flags.",
                        patterns: ["~/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", "~/Library/Application Support/Google/Chrome/OnDeviceHeadSuggestModel"], safety: .caution),
            CleanTarget(id: "claude-code", group: .ai, title: "Claude Code: caches", detail: "Snapshots de shell, debug, logs e todos antigos.",
                        patterns: ["~/.claude/shell-snapshots/*", "~/.claude/debug/*", "~/.claude/statsig/*", "~/.claude/todos/*", "~/.claude/telemetry/*"], olderThanDays: 7),
            CleanTarget(id: "claude-projects", group: .ai, title: "Claude Code: histórico de conversas", detail: "Transcripts em ~/.claude/projects com mais de 30 dias. Perde o `--resume` dessas sessões.",
                        patterns: ["~/.claude/projects/*/*.jsonl", "~/.claude/file-history/*"], safety: .caution, olderThanDays: 30),
            CleanTarget(id: "claude-vm", group: .ai, title: "Claude Desktop: máquina virtual", detail: "Imagem da VM que o app do Claude usa para rodar código. Feche o Claude antes; ele baixa de novo quando precisar.",
                        patterns: ["~/Library/Application Support/Claude/vm_bundles/*"], safety: .caution),
            CleanTarget(id: "updaters", group: .ai, title: "Atualizações baixadas de apps (ShipIt, Squirrel)", detail: "Pacotes de update já instalados por apps Electron (Claude, VS Code, Slack...).",
                        patterns: ["~/Library/Caches/*.ShipIt", "~/Library/Caches/*-updater", "~/Library/Caches/@*updater*", "~/Library/Application Support/Caches/*-updater"]),
            CleanTarget(id: "codex", group: .ai, title: "Codex / Gemini CLI / Aider", detail: "Sessões e logs antigos das CLIs de IA (mais de 30 dias).",
                        patterns: ["~/.codex/sessions/*", "~/.codex/log/*", "~/.gemini/tmp/*", "~/.aider/caches/*"], safety: .caution, olderThanDays: 30),
        ]

        // MARK: Navegadores
        t += [
            CleanTarget(id: "chromium", group: .browsers, title: "Chrome, Brave, Edge, Arc, Vivaldi, Opera", detail: "Cache de páginas, código e GPU de cada perfil. Logins e histórico ficam.",
                        patterns: ["~/Library/Caches/Google/*", "~/Library/Caches/BraveSoftware/*", "~/Library/Caches/Microsoft Edge*", "~/Library/Caches/Arc", "~/Library/Caches/company.thebrowser.Browser", "~/Library/Caches/Vivaldi", "~/Library/Caches/com.operasoftware.Opera", "~/Library/Caches/Chromium"]
                            + chromiumBases.flatMap { b in chromiumCacheDirs.map { "\(b)/*/\($0)" } + ["\(b)/GrShaderCache", "\(b)/ShaderCache", "\(b)/GraphiteDawnCache", "\(b)/component_crx_cache", "\(b)/Crashpad/completed"] }),
            CleanTarget(id: "google-updater", group: .browsers, title: "Google Updater: pacotes baixados", detail: "Instaladores de componentes do Chrome já aplicados.",
                        patterns: ["~/Library/Application Support/Google/GoogleUpdater/crx_cache/*", "~/Library/Application Support/Google/GoogleUpdater/updater.log*"]),
            CleanTarget(id: "firefox", group: .browsers, title: "Firefox / Zen", detail: "Cache de páginas dos perfis.",
                        patterns: ["~/Library/Caches/Firefox/Profiles/*", "~/Library/Caches/zen/Profiles/*", "~/Library/Caches/Mozilla/updates"]),
            CleanTarget(id: "safari", group: .browsers, title: "Safari", detail: "Cache do Safari e WebKit. Precisa de Acesso Total ao Disco.",
                        patterns: ["~/Library/Caches/com.apple.Safari", "~/Library/Containers/com.apple.Safari/Data/Library/Caches/*", "~/Library/Caches/com.apple.WebKit.*"]),
        ]

        // MARK: Apps
        t += [
            CleanTarget(id: "electron", group: .apps, title: "Apps Electron (Slack, Discord, Claude, Notion, Figma...)", detail: "Cache, GPUCache e Service Worker de cada app. Feche o app antes para liberar tudo.",
                        patterns: electronCacheDirs.map { "~/Library/Application Support/*/\($0)" } + ["~/Library/Application Support/*/Partitions/*/Cache", "~/Library/Application Support/*/Partitions/*/Code Cache", "~/Library/Application Support/*/Partitions/*/Service Worker/CacheStorage"],
                        generic: true),
            CleanTarget(id: "containers", group: .apps, title: "Caches de apps da App Store (sandbox)", detail: "Library/Caches dentro de cada container.",
                        patterns: ["~/Library/Containers/*/Data/Library/Caches/*"], generic: true, exclude: ["com.apple.mail", "com.apple.Safari"]),
            CleanTarget(id: "spotify", group: .apps, title: "Spotify, Music e players", detail: "Músicas em cache para streaming.",
                        patterns: ["~/Library/Application Support/Spotify/PersistentCache", "~/Library/Caches/com.spotify.client"]),
            CleanTarget(id: "adobe", group: .apps, title: "Adobe Media Cache", detail: "Cache de mídia do Premiere, After Effects.",
                        patterns: ["~/Library/Application Support/Adobe/Common/Media Cache Files", "~/Library/Application Support/Adobe/Common/Media Cache", "~/Library/Caches/Adobe"]),
            CleanTarget(id: "messengers", group: .apps, title: "Telegram, WhatsApp: mídia em cache", detail: "Arquivos de mídia baixados. Ficam disponíveis na nuvem do app.",
                        patterns: ["~/Library/Group Containers/*.ru.keepcoder.Telegram/stable/account-*/postbox/media", "~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media"], safety: .caution),
        ]

        // MARK: Downloads
        t += [
            CleanTarget(id: "dl-installers", group: .downloads, title: "Instaladores em Downloads", detail: ".dmg, .pkg, .xip, .iso já usados. Vão para a Lixeira.",
                        patterns: ["~/Downloads/*.dmg", "~/Downloads/*.pkg", "~/Downloads/*.mpkg", "~/Downloads/*.xip", "~/Downloads/*.iso", "~/Downloads/*.ipsw"], action: .trash),
            CleanTarget(id: "dl-archives", group: .downloads, title: "Arquivos compactados em Downloads", detail: ".zip, .tar.gz, .7z, .rar com mais de 14 dias. Confira antes.",
                        patterns: ["~/Downloads/*.zip", "~/Downloads/*.tar.gz", "~/Downloads/*.tgz", "~/Downloads/*.7z", "~/Downloads/*.rar"], safety: .caution, action: .trash, olderThanDays: 14),
            CleanTarget(id: "dl-old", group: .downloads, title: "Downloads parados há mais de 90 dias", detail: "Tudo em ~/Downloads sem mexer há 3 meses. Vai para a Lixeira.",
                        patterns: ["~/Downloads/*"], safety: .caution, action: .trash, olderThanDays: 90, generic: true),
        ]
        return t
    }
}

extension Catalog {
    /// Commands whose output describes what a command-type target would free.
    static let probes: [String: String] = [
        "tm-snapshots": "tmutil listlocalsnapshots / 2>/dev/null | grep -c com.apple | sed 's/$/ snapshot(s) local(is)/'",
        "sim-unavailable": "xcrun simctl list devices unavailable 2>/dev/null | grep -c '(unavailable' | sed 's/$/ simulador(es) indisponível(is)/'",
        "sim-runtimes": "xcrun simctl runtime list 2>/dev/null | grep -E '^iOS|^watchOS|^tvOS|^visionOS|^xrOS' | head -12",
        "docker-build": "docker system df 2>/dev/null | awk 'NR==1 || /Build Cache/' || echo 'Docker não está rodando'",
        "docker-prune": "docker system df 2>/dev/null || echo 'Docker não está rodando: abra o Docker para medir'",
        "brew": "brew cleanup -n --prune=all 2>/dev/null | tail -1",
        "ollama": "ollama list 2>/dev/null | head -15",
    ]
}
