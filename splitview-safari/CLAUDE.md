# CLAUDE.md – SplitView für Safari

## Projekt

Safari Web Extension für macOS und iPadOS: zwei Webseiten nebeneinander im selben Safari-Tab.
Die zweite Seite läuft in einem iframe, den ein Content Script in die aktuelle Seite einblendet.
Ziel ist ein Werkzeug, das Tim täglich nutzt: zuverlässig, wartbar, nachvollziehbar dokumentiert.

Aktuelle Phase steht in `docs/STATUS.md`. Lies sie zu Beginn jeder Sitzung.

## Technischer Ansatz und offene Hypothesen

| Baustein | Technik | Status |
|---|---|---|
| Split anzeigen | Content Script blendet iframe in die aktuelle Seite ein | gesetzt |
| Einbett-Sperre umgehen | `declarativeNetRequest` entfernt `X-Frame-Options` und `Content-Security-Policy` bei `sub_frame` | Hypothese H1 |
| Eingeloggt bleiben | Content Script im iframe (`all_frames: true`) ruft bei Nutzer-Tipp `document.requestStorageAccess()` auf | Hypothese H2 |
| Notlösung | Tracking-Schutz in Safari abschalten (Nutzer-Einstellung, nicht Teil des Codes) | dokumentiert |
| Alternative | Eigene App mit zwei `WKWebView` | nur falls H2 scheitert, per ADR |

Bekannte Eigenheiten von Safari, die du beim Entwerfen beachtest:
- `modifyHeaders` wirkt nur, wenn der Nutzer der Erweiterung Zugriff auf die Domain gegeben hat.
- Storage Access braucht einen echten Tipp oder Klick, gilt pro Seitenladen und setzt einen früheren Besuch der Seite als Haupttab voraus.
- Erweiterungsseiten (`safari-web-extension://<GUID>`) bekommen bei jedem Safari-Start eine neue Adresse. Der Split läuft deshalb in der normalen Webseite, nicht auf einer eigenen Erweiterungsseite.

Behandle H1 und H2 als unbewiesen, bis ein dokumentierter Test auf echtem Gerät sie bestätigt.
Prüfe Aussagen zu Safari-APIs gegen Apple- oder WebKit-Dokumentation und vermerke die Quelle mit Datum im ADR.

## Repository-Struktur

```
extension/            Web Extension (manifest.json, src/, rules/, assets/)
  src/content/        Content Scripts (Split-UI, Storage-Access-Auslöser)
  src/background/     Hintergrundskript, Regelverwaltung
  rules/              declarativeNetRequest-Regeln
xcode/                Xcode-Projekt (macOS- und iOS-Target), aus extension/ erzeugt
docs/
  STATUS.md           Phase, nächster Schritt, offene Fragen
  architecture.md     Aufbau und Datenfluss, aktuell gehalten
  adr/                Entscheidungsprotokoll (Architecture Decision Records)
  testing.md          Testmatrix und Testprotokoll auf echten Geräten
CHANGELOG.md
```

Code, Bezeichner und Code-Kommentare auf Englisch. Dokumentation unter `docs/` auf Deutsch.

## Entscheidungshistorie (strikt)

Jede Entscheidung, die sich später nur mit Aufwand ändern lässt, bekommt ein ADR in `docs/adr/NNNN-kurztitel.md`, bevor sie umgesetzt wird.
Das gilt für: Wahl von Technik, Bibliothek oder API; neue Berechtigungen im Manifest; Sicherheits- oder Datenschutz-Abwägungen; Hinzufügen oder Streichen von Funktionen; Ergebnisse von Spikes; Abweichungen von diesem Dokument.

Format:

```markdown
# NNNN Titel
Status: vorgeschlagen | angenommen | abgelehnt | ersetzt durch NNNN
Datum: JJJJ-MM-TT
## Kontext
## Entscheidung
## Betrachtete Alternativen   (je ein Satz, warum nicht)
## Konsequenzen               (positiv und negativ)
## Belege                     (Links mit Datum, Testprotokoll-Verweise)
```

Regeln:
- Angenommene ADRs werden nicht mehr inhaltlich bearbeitet. Eine Änderung ist ein neues ADR, das das alte ersetzt; im alten nur den Status anpassen.
- `docs/adr/README.md` führt alle ADRs als Liste mit Nummer, Titel, Status.
- Du legst ADRs mit Status `vorgeschlagen` an. Auf `angenommen` setzt nur Tim, außer er hat es in der Aufgabe ausdrücklich freigegeben.
- Commits, die eine Entscheidung umsetzen, nennen das ADR in der Nachricht (`Refs: ADR-0003`).

## Git

- Conventional Commits auf Englisch: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`.
- Kleine Commits, je ein Gedanke. `main` baut immer.
- Arbeit auf Branches `feat/…`, `fix/…`, `spike/…`. Spikes werden nicht nach `main` gemergt; ihr Ergebnis geht als ADR und Testprotokoll nach `main`.
- Keine Signierdaten, Team-IDs oder persönlichen Pfade im Repo; lokale Werte in `xcode/Local.xcconfig` (in `.gitignore`).
- Versionen als Git-Tags nach SemVer, Einträge in `CHANGELOG.md` (Keep a Changelog).

## Sicherheit und Datenschutz

- Header-Regeln nur so weit wie nötig: ausschließlich `sub_frame`, möglichst nur für Frames, die vom Split ausgehen (`initiatorDomains` oder tab-gebundene Session-Regeln). Weiter gefasste Regeln brauchen ein ADR.
- Kleinstmögliche Berechtigungen im Manifest. Jede neue Berechtigung braucht ein ADR.
- Kein nachgeladener Code, keine Telemetrie, keine Daten verlassen das Gerät.

## Arbeitsweise

1. Lies `docs/STATUS.md` und die angenommenen ADRs.
2. Plane in wenigen Sätzen, dann setze in kleinen Schritten um.
3. Prüfe jeden Schritt: Build, Lint, Tests. Verhalten in Safari gilt erst als bestätigt, wenn ein Eintrag in `docs/testing.md` es mit Gerät, OS-Version, Safari-Version und Datum belegt. Was du nicht auf einem Gerät testen kannst, markierst du als ungetestet und gibst Tim die Testschritte.
4. Aktualisiere `docs/STATUS.md`, `docs/architecture.md` und `CHANGELOG.md`, wenn sich etwas Entsprechendes ändert.
5. Committe.

Frag Tim vorher bei: neuen Abhängigkeiten, neuen Manifest-Berechtigungen, Löschen von Dateien, Umschreiben der Git-Historie, Wechsel des technischen Ansatzes.

## Befehle

Trage hier ein, sobald sie existieren, und halte sie aktuell:

- Build Extension: `…`
- Lint / Format: `…`
- Tests: `…`
- Xcode-Projekt erzeugen oder aktualisieren: `xcrun safari-web-extension-converter extension/ …`

## Definition of Done

Build und Lint grün, Tests grün, betroffene Doku aktualisiert, ADR vorhanden falls nötig, Testprotokoll-Eintrag für Safari-Verhalten, Commit mit passender Nachricht.
