# Orbit

A native, encrypted second brain for Mac, iPhone and iPad. Orbit keeps your
important generated files, notes, open questions and AI chats in one vault,
sorts them with on-device intelligence and shows how everything connects.

Swift + SwiftUI, no dependencies, ~3,700 lines. MacBook first.

## Features

| Area | What you get |
|---|---|
| **Capture** | Notes, questions, chats, mindmaps, files. ⌘N, menu bar quick capture, drag & drop anywhere. |
| **Chats** | Import Claude and ChatGPT data exports (`conversations.json`), or paste any transcript (`User:` / `Claude:` / `### You`). Rendered as a conversation. |
| **Files** | Stored encrypted, with thumbnails, Quick Look and full-text search of PDFs and text files. |
| **Organize** | Spaces → projects → items, pins, statuses, tags, links and backlinks, trash. |
| **Intelligence** (on-device) | Sentence embeddings for related items and semantic search; Inbox auto-sort by neighbour vote; Apple Intelligence titles, summaries, tags, answer suggestions and mindmap expansion. |
| **Visualize** | Overview dashboard, Kanban board by status, live force-directed knowledge graph, mindmap editor. |
| **Navigate** | ⌘K command palette for search (text + meaning) and every action. Focus mode for long work. |
| **Security** | AES-256-GCM per file, passphrase-derived key, Touch ID / Face ID, App Sandbox, auto-lock, no network access. |

## Requirements

- macOS 26 or iOS/iPadOS 26 (built and tested on CI with Xcode 26.6)
- Apple Silicon Mac
- Apple Intelligence enabled for titles, summaries, answers and mindmap ideas.
  Without it, Orbit falls back to keyword tags; embeddings, related items,
  semantic search and auto-sort still work.

## Run it

1. Open `orbit/Orbit.xcodeproj` in Xcode.
2. Choose the **Orbit** scheme and **My Mac**, press ⌘R. The Mac build signs
   locally and needs no developer account.
3. For iPhone or iPad: select the Orbit target → *Signing & Capabilities* →
   pick your team.

First launch asks you to create a vault:

- **On this device** – stays inside the app container.
- **In folder (iCloud Drive)** – pick e.g. *iCloud Drive*; Orbit creates
  `Orbit Vault` there. On iPhone/iPad choose **Open Existing Vault** and select
  that folder to sync. Any sync tool works: the vault is just files.

## Keyboard

| Keys | Action |
|---|---|
| ⌘K | Command palette (search + commands) |
| ⌘N / ⇧⌘N / ⌥⌘N | New note / question / mindmap |
| ⇧⌘I | Import files or chat exports |
| ⌘1 / ⌘2 / ⌘3 | List / Board / Graph |
| ⌘L | Lock vault |
| Double-click | Open item in focus mode, Esc to go back |
| Mindmap: Tab / Return / Delete / Space | Child / sibling / delete / rename |

## Security model

```
vault.json          plaintext: format, PBKDF2 salt + rounds, master key sealed with the passphrase key
meta.orbit          spaces and projects        ┐
items/<uuid>.orbit  one JSON record per item   ├ AES-256-GCM with a random 256-bit master key
blobs/<uuid>[.thumb] file contents, thumbnails ┘
```

- The passphrase is stretched with PBKDF2-HMAC-SHA256 (600,000 rounds) and only
  unwraps the master key, so changing it doesn't re-encrypt the vault.
- Touch ID stores the master key in the device keychain
  (`WhenUnlockedThisDeviceOnly`), released after a successful
  `LocalAuthentication` check. Turn it off in Settings to require the passphrase.
- Everything decrypted lives in memory only. Quick Look/Share copies go to a
  private temp folder that is wiped on lock. Locks on sleep, screen lock,
  background (iOS) and ⌘L.
- The app is sandboxed with access only to the folder you pick and declares no
  network entitlement; all AI runs on device.

Limits you should know:

- File names are random UUIDs, but the number of items, their sizes and
  modification times are visible to anyone with folder access.
- There is no passphrase recovery.
- Files are encrypted in memory as a whole; very large files (> 1 GB) need
  that much RAM during import.
- Two devices editing the same item offline: the last save wins.

## Architecture

| File | Role |
|---|---|
| `Model.swift` | `Item`, `Space`, `Project`, `MindNode`, scopes |
| `Vault.swift` | Encrypted folder format, key derivation, keychain, bookmarks |
| `Store.swift` | `@Observable` app state, debounced off-main saves, folder watcher sync, import, AI actions |
| `Intelligence.swift` | `NLEmbedding` index (vDSP cosine), auto-sort vote, Foundation Models prompts |
| `Importer.swift` | Files (text/PDF extraction, thumbnails), Claude/ChatGPT exports, transcript parser |
| `GraphView.swift` | d3-style force simulation on `Canvas`; pauses when settled |
| `MindmapView.swift` | Balanced tree layout with animated curved branches, keyboard editing |
| `*View.swift` | Lock, sidebar, list/board, editor, palette, overview |

Performance choices: one encrypted file per item (parallel load, small sync
diffs), all crypto and disk work off the main thread, embeddings computed in a
background actor, the graph's per-frame state kept outside SwiftUI observation,
and lazy thumbnail decryption with an in-memory cache.

## Tests

`OrbitTests` covers encryption round trips, wrong keys, passphrase change, blob
export, Claude/ChatGPT import, transcript parsing and the mindmap layout.
CI (`.github/workflows/orbit.yml`) runs them on macOS and builds for iOS.
