# 0004 Abweichung: Safari ändert mit `declarativeNetRequest` keine Antwort-Header (H1 gefährdet)

Status: vorgeschlagen
Datum: 2026-10-24

## Kontext

`CLAUDE.md` setzt für H1 voraus, dass eine `declarativeNetRequest`-Regel mit `modifyHeaders` bei `sub_frame`-Antworten die Header `X-Frame-Options` und `Content-Security-Policy` entfernt. Beide sind Antwort-Header (`responseHeaders`). Die Recherche vom 2026-10-24 ergibt:

1. Apples Dokumentation nennt `modifyHeaders` ab Safari 16.4 und spricht von „add, remove, or append headers“, ohne Anfrage- und Antwort-Header zu unterscheiden.
2. Die MDN-Kompatibilitätsdaten führen für Safari `RuleAction.requestHeaders` ab 16.4, `RuleAction.responseHeaders` dagegen als nicht unterstützt (Desktop und iOS).
3. Im WebKit-Quellcode (Zweig `main`) parst `ModifyHeadersAction` zwar `response-headers`, aber `applyToRequest` wendet nur `requestHeaders` an; eine Stelle, die Antwort-Header verändert, findet sich in `ContentExtensionsBackend.cpp`, `NetworkResourceLoader.cpp` und `NetworkLoadChecker.cpp` nicht.
4. Ein Apple-Mitarbeiter antwortete im Juni 2024 auf eine Frage zu einer `responseHeaders`-Regel nur mit dem Hinweis auf die Website-Freigabe, ohne zu sagen, dass Antwort-Header nicht unterstützt sind. Eine Bestätigung, dass es funktioniert, gibt es in dem Thread nicht.

Vermutung: Safari übersetzt `declarativeNetRequest`-Regeln in WebKit-Content-Rule-Lists (dasselbe Modell wie Content-Blocker), und dieses Modell greift nur vor dem Senden der Anfrage ein. Das würde erklären, warum Antwort-Header außen vor bleiben.

Folge für das Projekt: Seiten, die Einbettung per `X-Frame-Options` oder `Content-Security-Policy: frame-ancestors` verbieten (darunter github.com und mail.google.com), lassen sich in Safari voraussichtlich nicht per Erweiterung in einen iframe laden. Safari bietet auch keinen anderen Erweiterungsweg: blockierendes `webRequest` (`webRequestBlocking`, `BlockingResponse`) unterstützt Safari nicht. Damit wäre H2 auf diesen Seiten gar nicht erst prüfbar, weil der Frame nicht lädt.

## Entscheidung

Vorgeschlagen, bis Tim entscheidet:

1. H1 gilt ab sofort als „voraussichtlich widerlegt“, nicht mehr als offen. `CLAUDE.md` wird erst nach dem Gerätetest angepasst (eigenes ADR mit dem Ergebnis).
2. Der Spike testet H1 trotzdem, mit genau der in `CLAUDE.md` beschriebenen Regel (nur `sub_frame`, nur die Zieldomain, Session-Regel). Aufwand: eine Regeldatei und ein Protokolleintrag. Der Test misst dabei zusätzlich, welche Fehlermeldung die Web-Inspector-Konsole zeigt und ob Safari in Einstellungen, Erweiterungen einen Regelfehler meldet.
3. Der Spike trennt H2 von H1: Die Testmatrix enthält eine Login-Seite ohne Einbett-Sperre, damit `requestStorageAccess()` auch dann geprüft wird, wenn H1 scheitert.
4. Das Ergebnis-ADR wählt danach zwischen: (a) Erweiterung mit eingeschränktem Umfang, der Split funktioniert nur für Seiten ohne Einbett-Sperre, gesperrte Seiten bekommen eine klare Meldung mit Ausweich-Aktion; (b) Wechsel zur WKWebView-App (ADR-0002, Ausweichlösung); (c) Hybrid: Erweiterung für einbettbare Seiten, App-Split für den Rest. Keine der drei Optionen wird hier vorweggenommen.

## Betrachtete Alternativen

- H1 stillschweigend streichen und direkt umbauen: verstößt gegen `CLAUDE.md` (Abweichungen brauchen ein ADR und Tims Entscheidung) und verschenkt den günstigen Gerätetest, der die Quellenlage bestätigen oder widerlegen würde.
- Antwort-Header über einen eigenen Proxy oder einen Hintergrund-`fetch` umgehen: Daten würden das Gerät verlassen oder die Herkunft der Seite würde gebrochen; verstößt gegen die Sicherheitsregeln in `CLAUDE.md`.
- Auf eine künftige Safari-Version warten: kein bekannter Zeitplan; MDN verweist für verwandte `responseHeaders`-Bedingungen auf einen offenen WebKit-Bug (275158).

## Konsequenzen

Positiv: Die Richtungsentscheidung fällt auf Grundlage eines dokumentierten Tests statt einer Vermutung; der Spike liefert zusätzlich die Zahl der Zielseiten, die ohne Header-Änderung einbettbar sind.

Negativ: Der Spike enthält voraussichtlich einen scheiternden Testfall; die Zeitplanung für Phase 1 verschiebt sich, bis das Ergebnis-ADR steht; falls (b) oder (c) gewinnt, entsteht eine App mit eigener Cookie-Verwaltung.

## Belege

- Apple, „Blocking content with your Safari web extension“: „Safari requires user permission to add, remove, or append headers.“ https://developer.apple.com/documentation/safariservices/blocking-content-with-your-safari-web-extension (abgerufen 2026-10-24)
- MDN browser-compat-data, `webextensions/api/declarativeNetRequest.json`, Knoten `RuleAction.responseHeaders`: Safari `version_added: false`; `RuleCondition.responseHeaders` mit `impl_url` https://webkit.org/b/275158. https://github.com/mdn/browser-compat-data/blob/main/webextensions/api/declarativeNetRequest.json (abgerufen 2026-10-24)
- WebKit-Quellcode, `Source/WebCore/contentextensions/ContentExtensionActions.cpp` (Zeilen 96 bis 108 parsen `request-headers` und `response-headers`, Zeilen 163 bis 167 wenden nur `requestHeaders` an) und `Source/WebCore/contentextensions/ContentExtensionsBackend.cpp` (Zeilen 486 bis 490 rufen nur `applyToRequest`). https://github.com/WebKit/WebKit/tree/main/Source/WebCore/contentextensions (abgerufen 2026-10-24; Zeilennummern Stand dieses Tages)
- Apple Developer Forums, Thread 757846 (Juni 2024): Nutzerfrage zu `responseHeaders` `remove` `Content-Disposition`, Antwort eines Apple-Mitarbeiters verweist nur auf die Website-Freigabe. https://developer.apple.com/forums/thread/757846 (abgerufen 2026-10-24)
- Apple, „Assessing your Safari web extension's browser compatibility“: `webRequestBlocking` nicht unterstützt, `BlockingResponse` nicht unterstützt, `webRequest` nicht in iOS. https://developer.apple.com/documentation/safariservices/assessing-your-safari-web-extension-s-browser-compatibility (abgerufen 2026-10-24)
- Einbett-Sperren von github.com (`X-Frame-Options: deny`, `frame-ancestors 'none'`) und mail.google.com (`X-Frame-Options: SAMEORIGIN`): ungeprüft aus dieser Umgebung (Hosts nicht erreichbar); Prüfbefehl steht in `docs/testing.md`.
