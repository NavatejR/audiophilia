# AGENTS.md

Native macOS audio player (SwiftUI + AppKit, Swift 5). Single Xcode project, no SPM dependencies.

## Build & verify

- Open in Xcode: `open Audiophilia.xcodeproj` -> scheme **Audiophilia**, run target **My Mac** (⌘R).
- CLI (no shared scheme — use `-target`, not `-scheme`):
  ```bash
  xcodebuild -project Audiophilia.xcodeproj -target Audiophilia -configuration Debug build
  ```
- Artefacts land in `build/Build/Products/<Configuration>/Audiophilia.app` (gitignored).
- Deployment target macOS 14.0+. There are **no tests** — the build is the verification.

## Concurrency (critical)

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set in the project. **Every type
  you write is `@MainActor` by default.**
- Library scanning/import runs in `Task.detached` and calls `MetadataExtractor`,
  `FLACParser`, `Track`/`Playlist` etc. Those are explicitly `nonisolated` — **keep `nonisolated`
  on them, and on anything new called from detached scan tasks.** Do NOT raise `SWIFT_VERSION`
  to 6 or enable strict concurrency; the codebase depends on Swift 5 mode.
- UI state mutating `@Published` on `LibraryManager`/`AudioEngine`/`PlayerState` must hop via
  `await MainActor.run { … }`, as the scan tasks already do.

## Architecture

- **Singletons** `LibraryManager.shared`, `AudioEngine.shared`, `PlayerState.shared`,
  `ThemeManager.shared` are injected as `@StateObject` + `.environmentObject` in
  `AudiophiliaApp` (`AudiophiliaApp.swift`). New app settings go in `ThemeManager` as
  `@AppStorage` (persisted); session-only UI state goes in `PlayerState`.
- **Views live mostly in one large file:** `Audiophobia/ContentView.swift` (sidebar, canvas,
  playbar, fullscreen player, all cards/rows). Settings is split out at `Views/SettingsView.swift`.
  Follow that convention — new views go in `ContentView.swift` unless they're meant for Settings.
- **Frameless window:** `AudiophiliaAppDelegate.configureTitlebar` removes `.titled` and paints
  the opaque theme gradient. Never re-add a titlebar or opaque chrome in views; the SwiftUI root
  draws the theme wash full-bleed.

## Data & persistence

- Library/playlists/folders: JSON in `~/Library/Application Support/Audiophilia/`.
- Embedded artwork: extracted once per track (offline, via `MetadataExtractor`), written as
  JPEG to `~/Library/Caches/AudiophiliaArtwork/<trackID>.jpg`, `artworkPath` stored on the track.
  **Do not change these paths.** `LibraryManager.artwork(for:)` reads + downscales with NSCache.
- The app is **not sandboxed** (`ENABLE_APP_SANDBOX = NO`).

## Audio

- Playback = `AVAudioEngine` (`Audiophobia/Audio/AudioEngine.swift`): bit-perfect HAL output,
  auto sample-rate switching (engine must be stopped when switching), 10-band `AVAudioUnitEQ`
  with ISO bands [31…16000]. Don't change sample-rate switching flow.

## Conventions

- No comments of the explanatory kind unless a module needs them; this codebase uses heavy
  `// MARK:` docs and explains _why_ in block comments — match that density for new code.
- macOS 14+ SwiftUI only (no UIKit), `@Environment(\.colorScheme)` is available for appearance.