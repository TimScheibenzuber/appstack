# Architektur

Stand: 2026-10-24, geplanter Aufbau für den Spike. Wird mit dem Code aktualisiert.

## Bausteine

| Baustein | Ort | Aufgabe |
|---|---|---|
| Content Script, Haupt-Frame | `extension/src/content/split.js` | Tastenkürzel oder Toolbar-Button empfangen, URL abfragen, iframe und Teiler in die Seite einblenden, Protokoll-Overlay zeigen, Hintergrundskript über Öffnen und Schließen informieren. |
| Content Script, iframe | `extension/src/content/storage-access.js` (gleiche Datei mit `all_frames: true`, Verzweigung nach `window.top !== window.self`) | Beim ersten Tipp `document.hasStorageAccess()` und `document.requestStorageAccess()` aufrufen, Ergebnis per `runtime.sendMessage` melden. |
| Hintergrundskript | `extension/src/background/background.js` | Session-Regel für die eingegebene Domain anlegen (`declarativeNetRequest.updateSessionRules`), beim Schließen entfernen; Nachrichten zwischen Frames weiterreichen; Tastenkürzel (`commands`) an den aktiven Tab senden. |
| Regeln | `extension/rules/` | Vorlage der `modifyHeaders`-Regel (nur `sub_frame`, nur `requestDomains` der Zieldomain). Keine statische Regel mit weitem Geltungsbereich. |
| Träger-App | `xcode/` | Vom Packager erzeugt, macOS- und iOS-Target, ohne eigene Logik. |

## Datenfluss beim Öffnen eines Splits

1. Nutzer drückt das Tastenkürzel oder den Button. Hintergrundskript sendet `open-split` an das Content Script des aktiven Tabs.
2. Content Script fragt die URL ab, normalisiert sie (nur `http`/`https`), sendet `split-opened` mit der Domain an das Hintergrundskript.
3. Hintergrundskript legt eine Session-Regel für diese Domain an und bestätigt. Erst dann setzt das Content Script `iframe.src`.
4. Im iframe läuft dasselbe Content Script als Frame-Instanz. Beim ersten Tipp ruft es `requestStorageAccess()` auf und meldet `storage-access-result` (gewährt, abgelehnt, Fehlertext) an das Hintergrundskript, das es an den Haupt-Frame weiterreicht.
5. Beim Schließen sendet das Content Script `split-closed`; das Hintergrundskript entfernt die Regel.

## Geplante Berechtigungen (brauchen ADR-0005 vor dem Manifest)

| Berechtigung | Zweck | Warum nicht enger |
|---|---|---|
| `declarativeNetRequest`, `declarativeNetRequestWithHostAccess` | Session-Regel für Header (H1) | `modifyHeaders` verlangt in Safari beide zusammen mit Host-Zugriff. |
| `host_permissions: ["<all_urls>"]` | Content Script auf beliebiger linker Seite, Header-Regel für beliebige rechte Seite | Safari fragt den Nutzer trotzdem je Website; die Erweiterung erhält Zugriff nur, wo er ihn erteilt. |
| `commands` (Manifest-Key) | Tastenkürzel | keine Alternative. |

Nicht geplant: `tabs`, `storage`, `webRequest`, Netzwerkzugriff aus der Erweiterung heraus.

## Bekannte Grenzen

- Antwort-Header lassen sich in Safari per `declarativeNetRequest` voraussichtlich nicht ändern (ADR-0004). Seiten mit `X-Frame-Options` oder `frame-ancestors` laden dann nicht im iframe.
- Seiten mit Skript-Sperre (`top.location = self.location`) brechen aus dem Frame aus; dagegen gibt es keinen sauberen Schutz.
- Storage Access gilt pro Seite und verlangt einen echten Tipp; ohne früheren Besuch der rechten Seite als Hauptseite kann Safari ablehnen.
