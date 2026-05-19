# Matador

A native macOS app for inspecting and operating BullMQ queues — like a local Bull Board / Durabull, but built from the ground up as a real macOS app: multi-window, native menus, keyboard-friendly, instant startup.

Matador talks **directly to Redis** using Apple's `Network` framework — no Node.js, no Electron, no embedded webview. The whole binary is a small Swift Package executable.

## Features

- **Multiple Redis profiles** — save connections (host, port, ACL user, TLS, db, custom BullMQ prefix). Passwords stored in the macOS Keychain.
- **Queue list with live counts** — auto-polled every 5s. See waiting / active / failed at a glance for every queue.
- **Per-state job browsing** — tabs for Waiting, Active, Completed, Failed, Delayed, Prioritized, Paused, Waiting-Children. Paginated, searchable.
- **Job detail** — pretty-printed `data`, `opts`, `returnvalue`; stack trace; logs; created/started/finished timestamps; attempts; priority; parent.
- **Actions** — retry failed, promote delayed, remove, pause/resume queue, clean (bulk remove from a state), drain (waiting + delayed + prioritized + paused).
- **TLS / `rediss://`** — first-class.
- **Auto-update** — checks `latest.json` on launch, banner + sheet for new versions.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jai-bhardwaj/matador/main/release/install.sh | bash
```

Or download the `.dmg` manually from the [latest GitHub release](https://github.com/jai-bhardwaj/matador/releases/latest).

Matador ships **ad-hoc signed**, not notarized — the installer strips the quarantine bit so Gatekeeper won't prompt. If you build from source you'll need to do the same.

## Requirements

- macOS **14 (Sonoma) or later**
- A reachable Redis (≥ 5.0) running BullMQ-managed queues

## Building from source

```bash
git clone https://github.com/jai-bhardwaj/matador.git
cd matador
swift build -c release
```

Binary lands at `.build/<arch>-apple-macosx/release/Matador`. To produce a `.app` bundle and DMG, use:

```bash
./release/publish.sh <version>
```

(See [`release/publish.sh`](release/publish.sh) for what it does — bumps version, builds, ad-hoc signs, makes the DMG, publishes the GitHub release, updates `latest.json`.)

## Architecture

```
Sources/Matador/
├── MatadorApp.swift          # @main entry, scene config
├── AppConstants.swift        # version, update URL
├── Models/
│   ├── RESP.swift            # RESP2 encoder + streaming parser
│   ├── RedisClient.swift     # async actor over NWConnection, pipelining
│   ├── BullMQ.swift          # queue/job models + BullMQService
│   ├── Profile.swift         # connection profile struct
│   ├── ProfileStore.swift    # JSON persistence to Application Support
│   ├── Keychain.swift        # password storage
│   └── UpdateChecker.swift   # latest.json poll
├── ViewModels/
│   └── AppState.swift        # @Observable root state
└── Views/                    # SwiftUI views — sidebar, list, detail, sheets, status
```

Zero external Swift package dependencies — pure Foundation + SwiftUI + Network + Security.

## Notes on BullMQ semantics

Mutating actions (retry, promote, remove, clean, drain) are implemented as direct Redis commands rather than BullMQ's own Lua scripts. They're correct for standard inspection workflows but are **not** transactionally identical to the BullMQ client. For high-throughput queues with active workers, prefer the BullMQ API for mutations and use Matador for inspection.

## License

MIT
