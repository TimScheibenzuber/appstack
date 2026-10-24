# 0003 Werkzeuge: Sprache, Build, Lint, Tests

Status: vorgeschlagen
Datum: 2026-10-24

## Kontext

Das Projekt wird von einer Person gewartet. Jede Abhängigkeit ist eine Pflegeaufgabe (Updates, Sicherheitsmeldungen, Brüche bei Major-Versionen). Eine Safari Web Extension braucht von sich aus keinen Build: Safari lädt `manifest.json`, JavaScript, JSON-Regeln und Assets direkt. Der Safari-Packager (`xcrun safari-web-extension-packager`) verweist standardmäßig aus dem Xcode-Projekt auf den Ordner `extension/`, sodass Änderungen dort ohne Zwischenschritt in den nächsten Xcode-Build fließen. Ein Build-Schritt würde diesen Vorteil aufgeben und einen zweiten Ordner (`dist/`) einführen, der vergessen werden kann.

Zugleich sollen Tippfehler im Manifest, ungültige Regeln und unbeabsichtigte neue Berechtigungen früh auffallen, und reine Logik (URL-Prüfung, Regelbau) soll ohne Safari testbar sein.

## Entscheidung

Vorgeschlagen:

| Bereich | Wahl | Abhängigkeiten |
|---|---|---|
| Sprache | JavaScript (Syntax, die Safari 16.4 und neuer ohne Umwandlung ausführt), JSON für Manifest und Regeln. Kein TypeScript, kein Transpiler. | keine |
| Build | Keiner. `extension/` ist das Auslieferungsformat. Das Xcode-Projekt in `xcode/` wird vom Packager erzeugt und verweist auf `extension/` (ohne `--copy-resources`). | Xcode auf dem Mac |
| Lint und Format | Biome als einzige Entwicklungsabhängigkeit, Version gepinnt (wird beim Installieren in `package.json` eingetragen und hier nachgetragen). Konfiguration in `biome.json`, Standardregeln plus `noUnusedVariables`. | 1 npm-Paket (ein Binärpaket je Plattform, keine Abhängigkeitskette) |
| Prüfskript | `scripts/check-extension.mjs` (Node, ohne Pakete): parst `manifest.json` und alle Regeldateien, prüft Pflichtfelder, und vergleicht `permissions` und `host_permissions` mit einer Liste erlaubter Einträge, die je Eintrag das zugehörige ADR nennt. Eine Berechtigung ohne ADR lässt die Prüfung fehlschlagen. | keine |
| Tests | Eingebauter Test-Runner von Node (`node --test`) für reine Logik in `tests/`. Testbare Logik liegt in `extension/src/shared/` als Skripte ohne Browser-Zugriff, die sich in Node laden lassen. Verhalten in Safari wird manuell nach `docs/testing.md` geprüft; es gibt keinen automatisierten Safari-Test, weil kein Werkzeug echte Safari-Erweiterungen mit Nutzerfreigaben treibt. | keine |
| Laufzeit für Werkzeuge | Node in der aktuellen LTS-Version; die genutzte Hauptversion wird beim Einrichten unter `engines` in `package.json` festgehalten. | Node auf dem Mac |

Befehle nach Einrichtung (werden in `CLAUDE.md` unter „Befehle“ eingetragen):

```
npm run lint       # biome lint extension/ scripts/ tests/
npm run format     # biome format --write extension/ scripts/ tests/
npm run check      # node scripts/check-extension.mjs
npm test           # node --test tests/
xcrun safari-web-extension-packager extension/ --project-location xcode/ --app-name SplitView --bundle-identifier <Bundle-ID>
```

Die ersten drei Befehle laufen auf jedem Rechner mit Node, der Packager nur auf dem Mac mit Xcode.

Was gegen den Vorschlag spricht: Biome ist jünger als ESLint und Prettier, und sein Regelsatz deckt weniger Spezialfälle ab. Die Alternative ESLint plus Prettier gewinnt, wenn Tim diese Werkzeuge ohnehin in anderen Projekten konfiguriert hat und dieselben Regeln will; der Wechsel kostet etwa eine Stunde, weil keine Regel in den Code eingebaut ist.

## Betrachtete Alternativen

- TypeScript mit Bundler (esbuild, Vite oder webpack): bessere Typprüfung, aber Build-Schritt, `dist/`-Ordner, Source Maps im Bundle und drei bis dreißig Pakete mehr; für eine Erweiterung mit wenigen hundert Zeilen nicht gerechtfertigt.
- ESLint plus Prettier: Branchenstandard, aber zwei Werkzeuge mit vielen transitiven Paketen und zwei Konfigurationen; siehe oben, wann sie gewinnen.
- Gar kein Lint, nur `node --check`: null Pakete, findet aber keine ungenutzten Variablen, keine Tippfehler in Bezeichnern und erzwingt kein einheitliches Format.
- Testlauf mit Playwright gegen WebKit: Playwrights WebKit ist nicht Safari und lädt keine Safari-Erweiterungen; würde falsche Sicherheit geben.
- `web-ext` (Mozilla) zum Packen und Prüfen: prüft Firefox-Regeln, nicht Safari-Regeln; Safari-Pakete baut Xcode.

## Konsequenzen

Positiv: eine Entwicklungsabhängigkeit, keine Laufzeitabhängigkeit; kein Build, Änderungen in `extension/` sind sofort testbar (Mac: temporäre Erweiterung; iPad: Xcode-Build); Berechtigungen bleiben per Prüfskript an ADRs gebunden; Tests laufen in unter einer Sekunde ohne Browser.

Negativ: keine Typprüfung, dafür JSDoc-Kommentare an öffentlichen Funktionen; Code muss Safari-kompatibel geschrieben sein, ohne dass ein Compiler das prüft; Safari-Verhalten bleibt Handarbeit nach Testmatrix.

## Belege

- Apple, „Packaging a web extension for Safari“: Packager verweist standardmäßig auf die Originaldateien („the project references the original extension files“), `--copy-resources` kopiert stattdessen; Optionen `--macos-only`, `--ios-only`, `--rebuild-project`; das Werkzeug hieß früher `safari-web-extension-converter`. https://developer.apple.com/documentation/safariservices/packaging-a-web-extension-for-safari (abgerufen 2026-10-24)
- Apple, „Running your Safari web extension“: temporäre Installation eines Ordners in macOS Safari ohne Xcode-Projekt. https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension (abgerufen 2026-10-24)
- Biome, Projektseite und Dokumentation: https://biomejs.dev/ (ungeprüft: Seite in dieser Sitzung nicht geladen; Beschreibung als Linter und Formatter in einem Paket ist stabiles Allgemeinwissen, Versionsnummer wird beim Installieren ermittelt)
- Node.js, Test-Runner `node --test`, stabil seit Node 20: https://nodejs.org/api/test.html (ungeprüft: Seite in dieser Sitzung nicht geladen)
