# SplitView für Safari

Safari Web Extension für macOS und iPadOS, die zwei Webseiten nebeneinander im selben Safari-Tab zeigt. Ein Content Script blendet die zweite Seite als iframe rechts neben die aktuelle Seite ein; ein verschiebbarer Teiler regelt die Breite. Vorbild ist ein bestehendes Split-Screen-Plugin für VS Code; Ziel ist ein Werkzeug für den täglichen Gebrauch, das ohne fremde Dienste auskommt und keine Daten das Gerät verlassen lässt.

Stand: Phase 0, Grundgerüst und Machbarkeitstest. Es gibt noch keinen lauffähigen Code. Zwei Hypothesen sind offen und entscheiden über den Ansatz: H1 (Einbett-Sperren per `declarativeNetRequest` umgehen) und H2 (im iframe eingeloggt bleiben per Storage Access API). Phase, nächste Schritte und offene Fragen stehen in `docs/STATUS.md`; Entscheidungen in `docs/adr/`; Arbeitsregeln in `CLAUDE.md`.
