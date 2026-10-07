# AI Dev Hub — Architecture Blueprint

## 1. What the two gateway repos actually are

I read both READMEs before designing the router layer. Two findings change the design:

| | FreeLLMAPI | OmniRoute |
|---|---|---|
| What it is | Self-hosted Node server (Docker / desktop / experimental Termux) | Self-hosted Node/Next.js gateway (npm / Docker / desktop) |
| Endpoint | `http://host:3001/v1` + unified `freellmapi-…` bearer | `http://host:20128/v1`, model `auto` works zero-config |
| Routing | Fallback chain, per-key RPM/RPD/TPM/TPD tracking, `auto`, `auto:<profile>` | 19 strategies, `auto`, `auto/coding`, `auto/fast`, `auto/cheap`, circuit breakers, key cooldowns |
| "Always up to date" | Signed Ed25519 catalog from freellmapi.co. **Free installs get the monthly snapshot (30 days behind); same-day is the paid tier** | Catalog ships with releases; optional signed "Radar" overlay for supporters |
| Debug header | `X-Routed-Via: platform/model` | `X-OmniRoute-Decision` |

**Consequence:** neither project publishes a documented, app-consumable "router definitions API". Both are servers you run, not feeds you subscribe to. So "fetch router definitions from upstream" cannot mean calling their internal catalog directly (I didn't verify the catalog format, and it's signature-pinned to their own server).

**Design that works instead — three layers:**

1. **Gateway Mode (real OmniRoute / FreeLLMAPI):** the user points the *Custom* provider at their own instance (`http://<pc-or-vps>:20128/v1`, model `auto`). The gateway does the sophisticated routing. The app just needs `GET /v1/models` to stay current (live sync, zero app updates).
2. **Direct Mode:** the app's own lightweight `RouterService` (included) does priority fallback + cooldowns across the providers the user has keys for.
3. **Remote registry:** `assets/providers.json` is bundled, and refreshed at launch from a URL you control (raw file in your own GitHub repo, ETag-cached, optional Ed25519 signature). This is how new base URLs / model IDs reach users without an app update.

## 2. Tech stack recommendation: **Flutter (Android-first)**

| Requirement | Flutter | React Native/Expo | Kotlin + Compose |
|---|---|---|---|
| SAF file access | Packages (`saf_util`, `saf_stream`) or small MethodChannel | Weak/patchy libs | Native, best |
| Local HTTP server | `shelf` (pure Dart) | Needs native module | Ktor/NanoHTTPD |
| Background server | `flutter_foreground_task` | Native work needed | Native foreground service |
| Blur/glass, haptics, animation | `BackdropFilter`, `HapticFeedback`, 120fps Skia/Impeller — excellent for Apple-style UI | OK | Good, blur is API 31+ |
| Secure storage | `flutter_secure_storage` (EncryptedSharedPreferences / Keychain) | OK | Native |
| Streaming SSE + GitHub REST | `dio` | OK | OkHttp |
| iOS later | Same codebase | Same | Rewrite |

**Pick Flutter.** One codebase, the glass/Cupertino aesthetic is the easiest to get right, and `shelf` makes the proxy trivial. Choose Kotlin only if SAF becomes your main product surface; Flutter's SAF packages cover read/write/list/delete but not every edge case.

Platform realities to design around:
- **Proxy server is Android-only in practice.** iOS suspends background sockets within seconds.
- **Android needs a foreground service + notification** to keep the proxy alive.
- **Installing the downloaded APK** needs `REQUEST_INSTALL_PACKAGES` and a `FileProvider`; the user must grant "install unknown apps" once.

## 3. Project structure

```
ai_dev_hub/
├── pubspec.yaml
├── assets/providers.json            # bundled registry (fallback)
├── .github/workflows/android-build.yml   # copy into repos you want to build remotely
└── lib/
    ├── main.dart                    ✅ wiring, tabs, sessions, build download
    ├── core/
    │   ├── models.dart              # Endpoint, ChatRequest, errors, stats
    │   ├── theme.dart               # light/dark/system, glass tokens
    │   └── haptics.dart
    ├── services/
    │   ├── openai_compatible_client.dart   ✅ included
    │   ├── router_service.dart             ✅ included (fallback + registry sync)
    │   ├── github_service.dart             ✅ included
    │   ├── build_poller.dart               ✅ included
    │   ├── local_file_service.dart         ✅ included (SAF)
    │   ├── proxy_server.dart               ✅ included
    │   └── secure_store.dart        # keys + PAT
    ├── features/
    │   ├── chat/        # markdown+highlight, artifacts, build cards
    │   ├── providers/   # keys, test connection, latency/tokens
    │   ├── proxy/       # toggle, token, LAN IP
    │   └── settings/
    └── state/           # Riverpod providers
```

UI packages: `flutter_riverpod`, `flutter_markdown` + `flutter_highlight` (or `markdown_widget`), `url_launcher`, `open_filex` (APK install), `path_provider`, `archive` (unzip).

## 4. Chat-side agent contract

Don't parse free text for file edits. Give the model tools (OpenAI `tools` / function calling) and execute them in the app with a **confirmation sheet for every write, delete, commit, push, and build**:

`read_file`, `write_file`, `delete_file`, `list_dir`, `github_tree`, `github_read`, `github_commit(files[], message)`, `trigger_build(repo, workflow, ref)`.

Models on free tiers often have weak tool calling, so also support a fallback: the model emits fenced blocks with `path=` metadata (` ```dart path=lib/a.dart `) which the UI turns into an "Apply / Commit" card.

**Implemented (`lib/services/agent/`)** — `AgentRunner` streams a reply, accumulates `tool_calls` deltas, runs the tools, feeds results back, and loops (max 10 rounds). Tools act on the selected GitHub repo/branch through the API: `list_files`, `read_file`, `write_file`, `replace_in_file`, `delete_file`, `list_changes`, `discard_changes`, `commit_changes`, `trigger_build`. Deviations from the contract above:
- `write_file` / `replace_in_file` / `delete_file` only **stage** changes in memory (nothing leaves the device), so the confirmation sheet is at `commit_changes` (lists every file with a short preview) and `trigger_build`. Staged changes are lost if the app is killed.
- No local-folder (SAF) tools and no fenced-block `path=` fallback yet.
- Enabled by a Settings switch. A provider that rejects `tools` returns 400, which the router treats as a bad key/model and cools down for 5 minutes, so enable tools only with providers that support them.

## 5. Remote build flow

1. App generates a `correlation_id`, dispatches the workflow with it as an input.
2. Workflow sets `run-name: build ${{ inputs.correlation_id }}`, so the app can find its run (dispatch itself returns 204 with **no run ID**).
3. `BuildPoller` polls the run list → run → artifacts and emits states; the chat shows a progress card, then a download card.
4. Artifacts download as a **ZIP** (the APK is inside). The poller handles the redirect without leaking your token to blob storage, and the app unzips it.
5. Caveats: release APKs must be signed (store keystore in Actions secrets, or sideload a debug-signed build); artifacts expire (default 90 days); private-repo Actions minutes count against the user's quota.

## 6. Security notes (important)

- **GitHub PAT:** use a fine-grained token scoped to specific repos: Contents R/W, Actions R/W, Metadata R. Never log it. Store in secure storage only.
- **LAN proxy:** it spends the user's provider keys for anyone holding the bearer token. Generate a random 32-byte token by default, bind to loopback unless LAN is enabled, show a warning when enabling LAN, and never expose it to the internet. Traffic is cleartext HTTP on the LAN.
- **Mid-stream fallback is impossible without duplicating output.** The router only fails over *before the first token*. After that it surfaces the error (UI offers "Retry on next provider").
- **Free tiers:** FreeLLMAPI explicitly frames itself as personal experimentation; each provider's ToS still applies to traffic you route.

## 7. Status of the code

Written against current APIs from memory and **not compiled or run** (no Flutter toolchain in my sandbox). Expect small fixes, especially the SAF package calls — check `saf_util` / `saf_stream` signatures against the pub.dev version you install. The `LocalFileService` interface is deliberately thin so you can swap in a MethodChannel if needed.
