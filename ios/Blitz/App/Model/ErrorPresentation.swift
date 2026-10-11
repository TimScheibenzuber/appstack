import ClaudeKit
import Foundation

/// Turns failures into short, actionable German messages. Never includes the API key.
struct ErrorPresentation {
    let message: String
    let isMissingKey: Bool
    let isConnectivityLoss: Bool
    let logDescription: String

    init(_ error: any Error) {
        guard let error = error as? ClaudeError else {
            message = error.localizedDescription
            isMissingKey = false
            isConnectivityLoss = false
            logDescription = String(describing: error)
            return
        }
        logDescription = "\(error) request-id=\(error.requestID ?? "-")"
        isConnectivityLoss = error.isConnectivityLoss
        isMissingKey = error == .missingAPIKey || {
            if case .http(let info) = error { return info.status == 401 }
            return false
        }()
        message = Self.text(for: error)
    }

    private static func text(for error: ClaudeError) -> String {
        switch error {
        case .missingAPIKey:
            return "Kein API-Key hinterlegt. Füge ihn in den Einstellungen hinzu."
        case .http(let info):
            let suffix = info.requestID.map { " (Request-ID \($0))" } ?? ""
            switch info.status ?? 0 {
            case 400: return "Anfrage abgelehnt: \(info.message)\(suffix)"
            case 401: return "Der API-Key ist ungültig oder wurde widerrufen."
            case 402: return "Abrechnungsproblem beim API-Konto: \(info.message)"
            case 403: return "Keine Berechtigung: \(info.message)"
            case 404: return "Modell oder Endpunkt nicht verfügbar: \(info.message)"
            case 413: return "Die Unterhaltung ist zu groß für eine Anfrage. Starte einen neuen Chat."
            case 429: return "Rate-Limit erreicht. Bitte kurz warten und erneut versuchen.\(suffix)"
            case 529: return "Die API ist gerade überlastet. Bitte gleich erneut versuchen.\(suffix)"
            case 500...: return "Serverfehler (\(info.status ?? 0)). Bitte erneut versuchen.\(suffix)"
            default: return "Fehler \(info.status ?? 0): \(info.message)\(suffix)"
            }
        case .stream(let info):
            if info.type == "overloaded_error" {
                return "Die API ist gerade überlastet. Bitte gleich erneut versuchen."
            }
            return "Die Antwort wurde vom Server abgebrochen: \(info.message)"
        case .network(let code, _):
            switch code {
            case -1009, -1020, -1018: return "Keine Internetverbindung."
            case -1001: return "Zeitüberschreitung – die Verbindung ist zu langsam oder unterbrochen."
            case -1005: return "Die Verbindung wurde unterbrochen."
            case -1200, -1201, -1202, -1203, -1204, -1205, -1206:
                return "Sichere Verbindung fehlgeschlagen (TLS). Prüfe das Netzwerk (z. B. WLAN-Anmeldeseite)."
            default: return "Netzwerkfehler (\(code))."
            }
        case .truncatedStream:
            return "Die Verbindung wurde vor dem Ende der Antwort getrennt."
        case .malformedResponse:
            return "Unerwartete Antwort vom Server. Prüfe das Netzwerk (z. B. WLAN-Anmeldeseite)."
        }
    }
}
