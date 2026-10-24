# STATUS

Stand: 2026-10-24

## Phase

Phase 0: Grundgerüst und Machbarkeitstest. Kein lauffähiger Code, keine installierten Abhängigkeiten.

## Erledigt

- Repository-Struktur aus `CLAUDE.md`, README, CHANGELOG, `.gitignore`.
- ADR-0001 (ADR-Prozess), ADR-0002 (Web Extension als Hauptansatz, WKWebView-App als Ausweich), ADR-0003 (Werkzeuge), ADR-0004 (Abweichung bei H1), alle `vorgeschlagen`.
- `docs/testing.md` mit Testmatrix, Installationsschritten und zwei lokalen Testseiten.
- Recherche zu Safari-APIs mit Quellen und Abrufdatum in ADR-0002 und ADR-0004.

## Blockiert, wartet auf Tim

1. Freigabe von ADR-0003 (Werkzeuge). Erst danach wird Biome installiert und der Spike gebaut.
2. Entscheidung zu ADR-0004: Spike wie vorgeschlagen bauen (H1 trotz Quellenlage testen, H2 getrennt davon), oder Richtung schon jetzt ändern.

## Nächster Schritt (nach Freigabe)

Branch `spike/h1-h2`:

- `extension/manifest.json` (Manifest V3) mit Content Script (`all_frames: true`), Hintergrundskript, Befehl für das Tastenkürzel und Toolbar-Button. Berechtigungen und `host_permissions` bekommen vorher ADR-0005.
- Content Script im Haupt-Frame: Eingabefeld für die URL, iframe rechts, verschiebbarer Teiler, Protokoll-Overlay.
- Hintergrundskript: beim Öffnen des Splits Session-Regel (`updateSessionRules`) nur für `sub_frame` und nur für die eingegebene Domain, die `X-Frame-Options` und `Content-Security-Policy` entfernt; beim Schließen wieder entfernen.
- Content Script im iframe: beim ersten Tipp `document.hasStorageAccess()` und `document.requestStorageAccess()`, Ergebnis an das Overlay im Haupt-Frame melden.
- Xcode-Projekt: `xcrun safari-web-extension-packager` läuft nur auf dem Mac. Claude legt Befehl und `Local.xcconfig`-Vorlage bereit; Tim führt den Packager aus und committet `xcode/`. Danach bindet Claude die xcconfig-Dateien ein.

Danach: Tim füllt die Matrix in `docs/testing.md` auf Mac und iPad aus; aus den Ergebnissen entsteht das Ergebnis-ADR zu H1 und H2 auf `main`.

## Annahmen (bitte widersprechen, falls falsch)

- Annahme: Das Projekt lebt als Unterordner `splitview-safari/` im Monorepo `appstack`, nicht als eigenes Repository; `CLAUDE.md` liegt im Unterordner.
- Annahme: Bundle-ID nach dem Muster `de.<nachname>.splitview`; der konkrete Wert und die Team-ID stehen nur in `xcode/Local.xcconfig`.
- Annahme: Zielversionen sind macOS 26 und iPadOS 26 mit Safari 26; Mindestversion der Erweiterung Safari 16.4 (`modifyHeaders`). `initiatorDomains` (ab Safari 26) wird nicht genutzt, damit die Erweiterung auch auf Safari 16.4 bis 18 läuft.

## Offene Fragen an Tim

1. Freigabe ADR-0003 und Entscheidung ADR-0004 (siehe oben).
2. Testgeräte mit OS- und Safari-Version für `docs/testing.md`, und Pfad zum VS-Code-Plugin, falls dessen Verhalten (Tastenkürzel, Teiler) als Vorbild übernommen werden soll. Beide Platzhalter aus der Aufgabe sind noch leer.
3. Kandidat für Zeile T6 der Matrix: eine Login-Seite ohne Einbett-Sperre, damit H2 unabhängig von H1 prüfbar ist.

## Umgebungshinweis

Claude arbeitet in einer Linux-Umgebung ohne Xcode und ohne Safari. Alles, was Safari oder Xcode braucht (Packager, Builds, Gerätetests), führt Tim auf dem Mac aus; Claude liefert Befehle und wertet Protokolle aus.
