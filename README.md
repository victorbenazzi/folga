# Folga

App nativo para macOS (SwiftUI, sem dependências) que mostra o que está pesando na RAM e no disco e limpa sob demanda. Você abre, resolve e fecha: não fica rodando em segundo plano, não tem ícone na barra de menus e encerra ao fechar a janela.

## Instalar

```bash
./scripts/build.sh
cp -R dist/Folga.app /Applications/
```

Depois, em **Ajustes do Sistema > Privacidade e Segurança > Acesso Total ao Disco**, adicione o Folga. Sem isso, Lixeira, Safari, Mail e alguns containers ficam invisíveis.

O script assina com o primeiro certificado de código encontrado no Keychain (assim o Acesso Total ao Disco sobrevive a rebuilds). Para assinatura ad-hoc: `SIGN_IDENTITY="-" ./scripts/build.sh`.

## Telas

| Tela | O que faz |
|---|---|
| Visão geral | RAM (apps, wired, comprimida, cache, swap, pressão), disco livre e o que mais pesa agora. |
| Memória | Processos agrupados por app (helpers do Chrome, Electron e WebKit somados no app dono) e separados em Dev, IA, Navegadores, Apps e Sistema. Cada grupo tem selo Seguro / Cuidado / Não mexa com o motivo. **Encerrar** (SIGTERM ou quit do app) e **Matar** (SIGKILL), por app ou por processo; processos root pedem senha. `purge` opcional. Atualiza a cada 3 s só enquanto a tela está aberta. |
| Itens de início | LaunchAgents do usuário e globais, LaunchDaemons e itens de login/tarefas em segundo plano (BTM). Mostra se está rodando, se é KeepAlive e se é **órfão** (programa não existe mais). Desativar (launchctl disable + bootout, reversível) ou remover (plist para a Lixeira). |
| Limpeza | 87 alvos: caches e logs do usuário e do sistema, temporários, crash reports, core dumps, snapshots do Time Machine, Xcode (DerivedData, Archives, DeviceSupport, simuladores, runtimes), npm, pnpm, Yarn, Bun, Deno, versões de Node/Python/Rust, pip/uv/poetry/conda, cargo, Go, Gradle, Maven, Android, CocoaPods, SwiftPM, Homebrew, Docker, VS Code/Cursor/Windsurf, JetBrains, Playwright, Ollama, LM Studio, Hugging Face, VM do Claude Desktop, Claude Code/Codex, navegadores, apps Electron e Downloads. |
| Projetos | Varre suas pastas de código atrás de `node_modules`, `.next`, `.turbo`, `dist`, `build`, `target`, `.build`, `Pods`, `.venv`, `.gradle` e outros, com a data da última mexida no projeto. Filtro "parados há 30/90 dias". |
| Arquivos grandes | Varre toda a pasta de usuário (inclusive `~/Library` e ocultos) e classifica por tipo: VM/imagem de disco, vídeo, modelo de IA, compactado, instalador, banco. |
| Explorar disco | Navegação por pastas ordenadas por tamanho, estilo DaisyDisk. |
| Restos de apps | Compara `~/Library` e `/Library` com todos os apps, ferramentas do Homebrew e CLIs instalados para achar pastas, preferências, containers e launchd de apps que você já removeu. |
| Aplicativos | Tamanho, último uso e desinstalação levando caches, preferências e containers do app. |

## Regras de segurança

- Nada é apagado sem confirmação. Itens **Seguro** vêm pré-selecionados; **Cuidado** e itens genéricos acima de 2 GB não.
- Caches, builds e node_modules são apagados de vez (são recriáveis). Arquivos seus, restos de apps e apps desinstalados vão para a **Lixeira**.
- Comandos oficiais quando existem: `brew cleanup`, `docker system prune`, `xcrun simctl delete unavailable`, `go clean`, `tmutil thinlocalsnapshots`, `log erase`.
- Tudo que precisa de root usa o diálogo de senha do próprio macOS.

## Diagnóstico sem interface

```bash
dist/Folga.app/Contents/MacOS/Folga --selftest          # tudo
dist/Folga.app/Contents/MacOS/Folga --selftest clean    # mem | startup | clean | projects | leftovers | large
```

Só lista o que encontraria. Não apaga nada.
