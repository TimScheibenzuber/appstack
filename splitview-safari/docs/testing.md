# Testmatrix und Testprotokoll

Verhalten in Safari gilt erst als bestätigt, wenn ein Eintrag hier es mit Gerät, OS-Version, Safari-Version, Spike-Commit und Datum belegt (`CLAUDE.md`, Arbeitsweise 3). Diese Datei enthält die Matrix für den Spike `spike/h1-h2` und das Protokoll der Durchläufe.

Stand 2026-10-24: Der Spike ist noch nicht gebaut (wartet auf Freigabe von ADR-0003 und Entscheidung zu ADR-0004). Die Installationsschritte gelten, sobald der Branch existiert.

## Testgeräte

| Kürzel | Gerät | OS-Version | Safari-Version | Eingetragen am |
|---|---|---|---|---|
| Mac | *(ausfüllen, z. B. MacBook Pro M3)* | macOS … | Safari … | |
| iPad | *(ausfüllen, z. B. iPad Pro M4)* | iPadOS … | Safari … | |

Safari-Version am Mac: Safari, Über Safari. Am iPad entspricht sie der iPadOS-Version (Einstellungen, Allgemein, Info).

## Installation des Spikes

### Mac, Weg 1: ohne Xcode (Safari 18.4 oder neuer)

1. Branch holen: `git fetch origin spike/h1-h2 && git switch spike/h1-h2`.
2. Safari, Einstellungen, Erweitert: „Funktionen für Webentwickler anzeigen“ aktivieren.
3. Safari, Einstellungen, Entwickler: „Unsignierte Erweiterungen erlauben“ setzen (das Häkchen fällt bei jedem Safari-Neustart zurück).
4. Dort „Temporäre Erweiterung hinzufügen…“ und den Ordner `splitview-safari/extension` wählen. Safari wechselt zum Tab Erweiterungen und zeigt die Erweiterung unter „Temporär“.
5. Erweiterung einschalten. Safari entfernt temporäre Erweiterungen nach 24 Stunden oder beim Beenden; danach Schritt 3 und 4 wiederholen.

Quelle: Apple, „Running your Safari web extension“ (abgerufen 2026-10-24). Dieser Weg reicht für die Matrix am Mac und spart den Xcode-Build.

### Mac, Weg 2: über das Xcode-Projekt

1. `xcode/SplitView.xcodeproj` öffnen (entsteht mit dem Spike über den Packager; Befehl in ADR-0003).
2. Schema „SplitView (macOS)“ wählen, Produkt, Ausführen. Die Träger-App startet und meldet die Erweiterung bei Safari an.
3. Safari, Einstellungen, Entwickler: „Unsignierte Erweiterungen erlauben“ setzen, falls kein Entwicklerzertifikat eingerichtet ist.
4. Safari, Einstellungen, Erweiterungen: SplitView einschalten.

### iPad

Voraussetzung: Mac mit Xcode, iPad per Kabel verbunden, Apple-ID in Xcode (Einstellungen, Accounts) eingetragen. ungeprüft: Apples Dokumentation sagt, für Tests auf dem Gerät sei die Mitgliedschaft im Apple Developer Program nötig; mit einer kostenlosen Apple-ID (Personal Team) laufen Apps nach verbreiteter Erfahrung sieben Tage. Ob das auch für die Erweiterung gilt, zeigt der erste Lauf; bitte als erstes Ergebnis notieren.

1. In Xcode das Schema „SplitView (iOS)“ wählen, als Ziel das iPad.
2. Signing & Capabilities: Team auf das Personal Team setzen; Bundle-ID muss weltweit eindeutig sein (Wert steht in `xcode/Local.xcconfig`, nicht im Repo).
3. Produkt, Ausführen. Beim ersten Mal auf dem iPad: Einstellungen, Allgemein, VPN und Geräteverwaltung, dem Entwickler vertrauen.
4. Am iPad: Einstellungen, Apps, Safari, Erweiterungen, SplitView einschalten; alternativ in Safari über das Menü „Mehr“ (Symbol links in der Adressleiste), Erweiterungen verwalten.
5. Beim ersten Aufruf einer Website der Erweiterung Zugriff geben („Für einen Tag erlauben“ oder „Immer erlauben“). Ohne diese Freigabe laufen weder Content Scripts noch Header-Regeln (Apple, „Blocking content with your Safari web extension“, abgerufen 2026-10-24).

### Lokale Testseiten erreichbar machen

Die Seiten in `docs/test-pages/` müssen über HTTP kommen, damit sie sich wie echte Seiten verhalten. Auf dem Mac im Projektordner:

```
cd splitview-safari/docs/test-pages && python3 -m http.server 8000
```

Mac: `http://localhost:8000/plain.html`. iPad im selben WLAN: `http://<Name-des-Mac>.local:8000/plain.html` (Name unter Systemeinstellungen, Allgemein, Teilen, „Lokaler Hostname“).

### Einbett-Sperre einer Seite vorab prüfen

```
curl -sI -A "Mozilla/5.0 (Macintosh) Safari/605.1.15" https://github.com | grep -i -E "x-frame-options|content-security-policy"
```

`X-Frame-Options: deny|sameorigin` oder `frame-ancestors` in der CSP bedeuten Header-Sperre. Keine Treffer bedeutet: höchstens Skript-Sperre. Ergebnis in Spalte „Sperre (geprüft am)“ eintragen.

## Testmatrix

So wird getestet: linke Seite ist eine beliebige Seite, auf der die Erweiterung Zugriff hat (z. B. `plain.html`); rechte Seite ist die Zeile der Matrix. Nach dem Öffnen des Splits ein Tipp in den rechten Bereich; das Protokoll-Overlay des Spikes zeigt das Ergebnis von `requestStorageAccess()`. Web-Inspector-Konsole am Mac (Entwickler, Seite anzeigen) oder am iPad über den Mac (Entwickler, iPad-Name) mitlesen.

| Nr. | Rechte Seite | Sperre (geprüft am) | Prüft | Erwartet nach Quellenlage (ADR-0004) | Ergebnis Mac | Ergebnis iPad | Notizen (Konsolenmeldung, Storage-Access-Ergebnis) |
|---|---|---|---|---|---|---|---|
| T1 | `https://github.com` | Header, ungeprüft: `X-Frame-Options: deny`, `frame-ancestors 'none'` | H1 | Frame bleibt leer; Konsole meldet Refused to display in a frame; Session-Regel ändert nichts. Falls die Seite lädt, ist H1 bestätigt und ADR-0004 widerlegt. | | | |
| T2 | `https://mail.google.com` | Header, ungeprüft: `X-Frame-Options: SAMEORIGIN` | H1, dann H2 | Wie T1: Frame lädt nicht, H2 nicht prüfbar. Falls der Frame lädt: nach Tipp Storage-Access-Dialog, nach Zustimmung eingeloggt. | | | |
| T3 | `http://<host>:8000/framebuster.html` | Skript (`top.location = self.location`) | Grenze des Ansatzes | Rechte Seite übernimmt den ganzen Tab (Frame bricht aus). Kein Header-Trick hilft; nur Dokumentation der Grenze. | | | |
| T4 | `http://<host>:8000/plain.html` | keine | Kontrolle, Split-UI | Lädt im Frame, Text „Loaded inside a frame“, Teiler verschiebbar, Tastenkürzel und Button funktionieren. | | | |
| T5 | `https://example.com` | keine (ungeprüft) | Kontrolle, echte Seite | Lädt im Frame. | | | |
| T6 | Login-Seite ohne Header-Sperre: *(Kandidat offen, mit curl prüfen; Vorschlag: eine Seite, auf der du eingeloggt bist und die keine Sperre sendet)* | prüfen | H2 isoliert | Erster Tipp: `requestStorageAccess()` zeigt Safari-Dialog oder wird ohne Dialog gewährt; danach ist die Seite im Frame eingeloggt. Ablehnung oder Fehler („not allowed“, fehlende Nutzeraktion) wird im Overlay protokolliert. Voraussetzung: Seite wurde vorher als Hauptseite besucht. | | | |

Ergebnis-Kürzel für die Spalten Mac und iPad: `ok` (wie erwartet), `anders` (Abweichung, Notiz nötig), `offen`. Jede Zeile braucht beide Geräte, bevor ein Ergebnis-ADR daraus entsteht.

## Was je Durchlauf festgehalten wird

- Gerät, OS-Version, Safari-Version, Datum, Commit des Spikes (`git rev-parse --short HEAD`).
- Ob die Erweiterung Zugriff auf linke und rechte Domain hatte (Safari zeigt das im Erweiterungs-Symbol).
- Konsolenmeldungen beim Laden des Frames, wörtlich.
- Overlay-Protokoll des Spikes: Ergebnis von `document.hasStorageAccess()` vor dem Tipp, Ergebnis von `requestStorageAccess()` nach dem Tipp (gewährt, abgelehnt, Fehlertext).
- Ob Safari in Einstellungen, Erweiterungen, SplitView einen Regelfehler anzeigt.

## Testprotokoll

| Datum | Gerät | OS | Safari | Spike-Commit | Zeile | Ergebnis | Notizen |
|---|---|---|---|---|---|---|---|
| | | | | | | | |
