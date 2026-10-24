# 0001 Entscheidungen als ADR festhalten

Status: vorgeschlagen
Datum: 2026-10-24

## Kontext

Das Projekt wird von einer Person gewartet und baut auf Safari-Verhalten auf, das sich mit jeder Safari-Version ändern kann. Ohne schriftliche Begründung lässt sich später nicht mehr nachvollziehen, warum ein Weg gewählt wurde, welche Alternativen verworfen wurden und auf welchen Belegen die Wahl beruhte. `CLAUDE.md` verlangt deshalb ein Architecture Decision Record (ADR) für jede Entscheidung, die sich später nur mit Aufwand ändern lässt.

## Entscheidung

Jede solche Entscheidung bekommt vor der Umsetzung eine Datei `docs/adr/NNNN-kurztitel.md` im Format aus `CLAUDE.md` (Status, Datum, Kontext, Entscheidung, Betrachtete Alternativen, Konsequenzen, Belege). Pflicht ist ein ADR für: Wahl von Technik, Bibliothek oder API; neue Berechtigungen im Manifest; Sicherheits- oder Datenschutz-Abwägungen; Hinzufügen oder Streichen von Funktionen; Ergebnisse von Spikes; Abweichungen von `CLAUDE.md`.

Regeln:
- Nummern sind vierstellig und fortlaufend; `docs/adr/README.md` führt alle ADRs mit Nummer, Titel und Status.
- Neue ADRs entstehen mit Status `vorgeschlagen`. Auf `angenommen` setzt nur Tim.
- Angenommene ADRs werden inhaltlich nicht mehr geändert. Eine Änderung ist ein neues ADR; im alten wird nur der Status auf `ersetzt durch NNNN` gesetzt.
- Belege nennen die Quelle mit Abrufdatum. Aussagen zu Safari-Verhalten gelten erst als bestätigt, wenn ein Eintrag in `docs/testing.md` sie mit Gerät, OS-Version, Safari-Version und Datum belegt.
- Commits, die ein ADR umsetzen, nennen es in der Nachricht (`Refs: ADR-NNNN`).

## Betrachtete Alternativen

- Entscheidungen nur in Commit-Nachrichten: nicht auffindbar, keine Alternativen und Belege, verstreut über die Historie.
- Ein einzelnes Dokument `DECISIONS.md`: wird lang und unübersichtlich, Änderungen überschreiben die Begründung statt sie zu ergänzen.
- Issues in GitHub: liegen außerhalb des Repositorys und sind ohne Netz nicht verfügbar; Format nicht einheitlich.

## Konsequenzen

Positiv: Jede Weiche ist mit Begründung und Quelle auffindbar; eine spätere Umstellung (etwa auf eine WKWebView-App) kann auf dokumentierten Testergebnissen aufbauen; Claude und Tim arbeiten gegen denselben Stand.

Negativ: Jede größere Änderung kostet ein paar Minuten Schreibarbeit; bei schnellen Spikes besteht die Versuchung, das ADR nachzuholen statt vorzuziehen.

## Belege

- `CLAUDE.md`, Abschnitt „Entscheidungshistorie (strikt)“, Stand 2026-10-24.
- Michael Nygard, „Documenting Architecture Decisions“ (2011), Ursprung des ADR-Formats: https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions (abgerufen 2026-10-24; Inhalt in dieser Umgebung nicht direkt geladen, allgemein bekanntes Referenzdokument).
