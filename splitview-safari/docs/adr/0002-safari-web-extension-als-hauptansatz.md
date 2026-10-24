# 0002 Safari Web Extension als Hauptansatz, WKWebView-App als Ausweichlösung

Status: vorgeschlagen
Datum: 2026-10-24

## Kontext

Ziel ist, zwei Webseiten nebeneinander im selben Safari-Tab zu zeigen, auf Mac und iPad, nach dem Vorbild eines bestehenden VS-Code-Plugins. Zwei Wege kommen in Frage:

- (A) Safari Web Extension: ein Content Script blendet die zweite Seite als iframe in die aktuelle Seite ein. Der Split lebt in Safari, mit Safaris Tabs, Lesezeichen und Logins.
- (B) Eigene App mit zwei `WKWebView`: volle Kontrolle über beide Seiten, aber außerhalb von Safari und mit eigenem Cookie-Speicher.

Weg A hängt an zwei Hypothesen aus `CLAUDE.md`:

- H1: `declarativeNetRequest` entfernt bei `sub_frame`-Antworten die Header `X-Frame-Options` und `Content-Security-Policy`, damit Seiten mit Einbett-Sperre im iframe laden.
- H2: Ein Content Script im iframe (`all_frames: true`) ruft bei einem Nutzer-Tipp `document.requestStorageAccess()` auf, damit die eingebettete Seite ihre Login-Cookies sieht.

Rahmenbedingungen aus der Recherche (Abrufdatum 2026-10-24, Quellen unter Belege):

- Safari unterstützt `declarativeNetRequest` seit Safari 15, `modifyHeaders` seit Safari 16.4. `modifyHeaders` verlangt die Berechtigung `declarativeNetRequestWithHostAccess`, passende `host_permissions` und die Zustimmung des Nutzers für die betroffene Website. Das deckt sich mit `CLAUDE.md`.
- Abweichung zu `CLAUDE.md`: Nach den MDN-Kompatibilitätsdaten unterstützt Safari bei `modifyHeaders` nur `requestHeaders`, nicht `responseHeaders`. Im aktuellen WebKit-Quellcode wendet die Aktion ebenfalls nur Anfrage-Header an. `X-Frame-Options` und `Content-Security-Policy` sind Antwort-Header. H1 ist damit voraussichtlich nicht umsetzbar; Details und Vorschlag in ADR-0004.
- Abweichung zu `CLAUDE.md`: Die Rule-Bedingung `tabIds` (tab-gebundene Session-Regeln) unterstützt Safari nicht; `initiatorDomains` erst ab Safari 26. Die engste in Safari verfügbare Eingrenzung ist eine Session-Regel nur für `sub_frame` und nur für die vom Nutzer eingegebene Domain (`requestDomains`, seit Safari 16.4), die beim Schließen des Splits wieder entfernt wird.
- Storage Access API: in Safari seit 11.1, Zugriff gilt pro Seite (per-page). WebKit verlangt einen Nutzer-Tipp und bisher eine frühere Nutzung der eingebetteten Seite als Hauptseite innerhalb von 30 Tagen; ein erteilter Zugriff zählt selbst als solche Nutzung. Das deckt sich mit `CLAUDE.md`.
- Content Scripts mit `all_frames` seit Safari 14; sie laufen erst, wenn der Nutzer der Erweiterung Zugriff auf die Website gegeben hat.
- Die Basis-URL `safari-web-extension://<GUID>` wechselt bei jedem Safari-Start (Schutz vor Fingerprinting). Eine eigene Erweiterungsseite als Träger des Splits scheidet deshalb aus; der Split läuft in der normalen Webseite.
- Seit Safari 18.4 lässt sich ein Erweiterungsordner auf dem Mac ohne Xcode-Projekt vorübergehend installieren (Einstellungen, Entwickler, „Temporäre Erweiterung hinzufügen“). Für das iPad bleibt das Xcode-Projekt nötig.

## Entscheidung

Vorgeschlagen: Weg A (Safari Web Extension) ist der Hauptansatz. Er bleibt an Bedingungen geknüpft:

1. H1 und H2 gelten als unbewiesen, bis ein Test auf echtem Gerät sie in `docs/testing.md` bestätigt oder widerlegt.
2. Der Spike (Branch `spike/h1-h2`) testet beide Hypothesen, H1 ausdrücklich auch dann, wenn er nach aktueller Quellenlage scheitern dürfte (ADR-0004), weil der Test wenige Zeilen kostet und das Ergebnis die Richtung festlegt.
3. Nach dem Test folgt ein Ergebnis-ADR. Scheitert H1 ohne erweiterungsseitigen Ausweg, oder scheitert H2, dann entscheidet dieses ADR über den Wechsel zu Weg B oder einen Hybrid (Erweiterung für einbettbare Seiten, App für gesperrte).

## Betrachtete Alternativen

- Sofort Weg B (App mit zwei `WKWebView`): umgeht H1 und H2 vollständig, weil beide Seiten als Hauptseiten laden; aber eigene Logins (WKWebView teilt keine Cookies mit Safari), kein Zugriff auf Safari-Tabs, eine zweite App zu pflegen. Bleibt Ausweichlösung.
- Safaris eingebaute Fensterteilung (iPadOS Split View mit zwei Safari-Fenstern, Fenster-Kacheln auf macOS): kostet keinen Code und ist der stärkste Einwand gegen das Projekt; sie koppelt die beiden Seiten aber nicht (kein „Link rechts öffnen“, kein Teiler im Tab, keine gespeicherten Paare). Als Baseline für den Vergleich notiert, nicht als Lösung.
- Safari App Extension (altes Format): nur macOS, kein iPad.
- Erweiterungsseite mit zwei iframes: Basis-URL wechselt pro Start, dieselben Einbett-Sperren, zusätzlich Verlust der Tab-Identität. Verworfen.
- Zweite Seite per `fetch` im Hintergrund laden und als `srcdoc` einblenden: bricht Herkunft, Cookies und relative Links; Sicherheitsrisiko. Verworfen.

## Konsequenzen

Positiv: ein Codebestand für Mac und iPad; der Split lebt in Safari mit dessen Logins und Passwörtern, falls H2 hält; die native App ist nur ein dünner Träger; kleine Berechtigungen, keine Daten verlassen das Gerät.

Negativ: hängt an zwei unbewiesenen Hypothesen, H1 voraussichtlich widerlegt (ADR-0004); Nutzer muss der Erweiterung je Website Zugriff geben; iframes haben Grenzen (Popups, Downloads, Seiten, die Einbettung per Skript erkennen); Safari-Updates können das Verhalten ändern, deshalb Testprotokoll mit Versionen.

## Belege

- Apple, „Blocking content with your Safari web extension“: Safari unterstützt `modifyHeaders` ab 16.4, verlangt `declarativeNetRequestWithHostAccess`, `host_permissions` und Nutzerzustimmung; Liste der unterstützten `RuleCondition`-Felder ohne `initiatorDomains`/`tabIds`. https://developer.apple.com/documentation/safariservices/blocking-content-with-your-safari-web-extension (abgerufen 2026-10-24)
- Apple, Safari 16.4 Release Notes: „Added support for the `modifyHeaders` action type of `declarativeNetRequest`“, „Added support for `requestDomains`“. https://developer.apple.com/documentation/safari-release-notes/safari-16_4-release-notes (abgerufen 2026-10-24)
- MDN browser-compat-data, `webextensions/api/declarativeNetRequest.json`: `RuleAction.requestHeaders` Safari 16.4, `RuleAction.responseHeaders` Safari nicht unterstützt, `RuleCondition.tabIds` nicht unterstützt, `RuleCondition.initiatorDomains` ab Safari 26, `updateSessionRules` ab 15.4. https://github.com/mdn/browser-compat-data/blob/main/webextensions/api/declarativeNetRequest.json (abgerufen 2026-10-24)
- WebKit-Quellcode, `Source/WebCore/contentextensions/ContentExtensionActions.cpp`: `ModifyHeadersAction::applyToRequest` iteriert nur `requestHeaders`; `responseHeaders` wird geparst, aber nirgends angewendet. https://github.com/WebKit/WebKit/blob/main/Source/WebCore/contentextensions/ContentExtensionActions.cpp (abgerufen 2026-10-24)
- Apple Developer Forums, Thread 757846 (Juni 2024), Antwort eines Apple-Mitarbeiters: „For this to work in Safari, you have to grant the extension permission to access the page that you are trying to change the headers on.“ https://developer.apple.com/forums/thread/757846 (abgerufen 2026-10-24)
- Apple Developer Forums, Thread 729383 (Mai 2023): Safari unterstützt `initiatorDomains` nicht; ohne Antwort von Apple. https://developer.apple.com/forums/thread/729383 (abgerufen 2026-10-24)
- MDN browser-compat-data, `api/Document.json`: `requestStorageAccess` Safari 11.1, Hinweis „Client-side storage access is granted per-page“. https://github.com/mdn/browser-compat-data/blob/main/api/Document.json (abgerufen 2026-10-24)
- WebKit-Blog, „Updates to the Storage Access API“ (2021): per-page Storage Access ab iOS 14.5/macOS 11.3; Nutzerinteraktion als Hauptseite innerhalb von 30 Tagen nötig, erteilter Zugriff zählt als Interaktion. https://webkit.org/blog/11545/updates-to-the-storage-access-api/ (ungeprüft: Seite aus dieser Umgebung nicht abrufbar, Aussagen stammen aus Suchauszügen vom 2026-10-24)
- MDN browser-compat-data, `webextensions/manifest/content_scripts.json`: `all_frames` ab Safari 14; Content Scripts laufen erst nach Nutzerfreigabe für die Website. (abgerufen 2026-10-24)
- Apple Developer Forums, Thread 129519 und 652933 (Apple-Mitarbeiter): Basis-URL der Erweiterung wechselt pro Start gegen Fingerprinting. https://developer.apple.com/forums/thread/129519 (abgerufen 2026-10-24, Inhalt über Suchauszug)
- Apple, „Running your Safari web extension“: temporäre Installation eines Ordners in macOS Safari ohne Xcode; iOS braucht die Träger-App aus Xcode. https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension (abgerufen 2026-10-24)
- Apple, Safari 18.4 Release Notes: „Added support for temporarily installing web extensions from disk without requiring an Xcode project.“ https://developer.apple.com/documentation/safari-release-notes/safari-18_4-release-notes (abgerufen 2026-10-24)
