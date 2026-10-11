# Blitz – schneller Claude-Client für iPhone & iPad

SwiftUI-App (iOS/iPadOS 17+), die direkt mit der Claude Messages API streamt.
Kein eigener Server, keine Drittanbieter-Abhängigkeiten.

## Starten

1. `ios/Blitz/Blitz.xcodeproj` in Xcode 16 oder neuer öffnen.
2. Target **Blitz** → *Signing & Capabilities* → eigenes Team wählen.
3. Auf iPhone/iPad oder Simulator starten, API-Key aus der
   [Claude Console](https://console.anthropic.com/settings/keys) einfügen. Der Key wird vor dem
   Speichern ohne Token-Kosten geprüft (`GET /v1/models`).

Neue Dateien hinzugefügt? Projekt neu erzeugen: `brew install xcodegen && xcodegen generate`
(Quelle der Wahrheit ist `project.yml`).

## Was die App schnell macht

| Hebel | Wirkung |
|---|---|
| Eine langlebige HTTP/2-Verbindung, Vorwärmen beim App-Start und beim ersten Tastendruck | Senden ohne DNS/TCP/TLS-Handshake |
| Streaming ab dem ersten Byte, SSE-Parser auf Rohbytes, Delegate-Chunks statt Byte-Iteration | Erstes Token so früh wie möglich |
| Automatisches Prompt-Caching, deterministisch serialisierte Requests, Verlauf strikt append-only | Folgefragen lesen den Verlauf aus dem Cache (schneller, günstiger) |
| Fast Mode (`speed: "fast"`, Opus 5.5) | bis ~2,5× schnellere Ausgabe |
| Aufwand standardmäßig `low` | kurze Denkphase → schnelle erste Antwort |
| UI-Updates gebündelt auf ~30 fps, nur die streamende Zeile wird neu gezeichnet | flüssig auch bei langen Antworten |

## Was die App stabil macht

- Wiederholung mit Backoff + Jitter bei 429/5xx/529, Netzfehlern und abgebrochenen Streams; `retry-after` wird beachtet.
- Bricht ein Stream mitten in der Antwort ab, wird die Anfrage einmal automatisch neu gestartet.
- Offline: wartet auf das Netz (NWPathMonitor), statt sofort zu scheitern.
- Lehnt die API ein optionales Feature ab (z. B. Fast Mode nicht freigeschaltet), wird es automatisch abgeschaltet und die Nachricht trotzdem gesendet.
- Sicherheits-Ablehnungen laufen serverseitig über das empfohlene Fallback-Modell (`fallbacks: "default"`).
- Signatur-Konflikte bei Thinking-Blöcken werden durch einmaliges Neusenden ohne Thinking behoben.
- Antworten laufen im Hintergrund weiter (Background Task), Chats bleiben beim Wechsel aktiv.
- Atomare Speicherung; beschädigte Dateien werden beiseitegelegt statt die App abstürzen zu lassen.

## Sicherheit

- API-Key nur im Schlüsselbund (`WhenUnlockedThisDeviceOnly`, kein iCloud-Sync, kein Backup).
- Nur HTTPS zu `api.anthropic.com` (ATS, TLS ≥ 1.2), Redirects werden nie verfolgt (Key kann nicht an fremde Hosts gehen).
- Ephemere URLSession: kein Cache, keine Cookies, nichts auf der Platte.
- Chats mit Data Protection verschlüsselt gespeichert; App-Umschalter zeigt keine Inhalte.
- Logs enthalten nie den Key oder Chat-Inhalte (nur Request-IDs und Fehlertypen).

**Bewusst nicht umgesetzt:** Certificate Pinning. Es würde bei jeder Zertifikatsrotation von Anthropic
die App lahmlegen; ATS + Systemvertrauen ist hier das stabilere Sicherheitsniveau.

## Kosten-Hinweis

Fast Mode kostet auf Opus 5.5 das Doppelte ($8 / $40 statt $4 / $20 pro Mio. Tokens) und ist
standardmäßig **an**. In den Einstellungen oder im Modell-Menü abschaltbar.

## Architektur

```
ClaudeKit/          plattformunabhängiges Swift-Paket (auch unter Linux getestet)
  Streaming/        SSEParser (inkrementell, bytegenau), MessageAccumulator
  Networking/       URLSessionTransport (HTTP/2, ephemer, keine Redirects)
  Client/           ClaudeClient (Retries, Feature-Aushandlung, Vorwärmen), Fehler, Request-Encoder
  Conversation/     Konversationsmodell + append-only API-Verlauf
App/                SwiftUI-App (Keychain, Speicher, Netzwerkmonitor, Views)
AppTests/           ViewModel- und Speicher-Tests (Simulator)
```

## Tests

```bash
cd ClaudeKit
swift test                      # Unit-Tests
scripts/integration-test.sh     # + echte HTTP-Tests gegen lokalen Mock-Server
```

CI (`.github/workflows/ios-blitz.yml`): ClaudeKit unter Linux und macOS, App-Build + Tests im
iOS-Simulator, Release-Build für Geräte.
