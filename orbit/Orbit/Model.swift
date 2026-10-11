import SwiftUI

enum Kind: String, Codable, CaseIterable, Identifiable {
    case note, question, chat, file, mindmap
    var id: Self { self }

    var label: String {
        switch self {
        case .note: "Note"
        case .question: "Question"
        case .chat: "Chat"
        case .file: "File"
        case .mindmap: "Mindmap"
        }
    }

    var icon: String {
        switch self {
        case .note: "text.alignleft"
        case .question: "questionmark.bubble"
        case .chat: "bubble.left.and.text.bubble.right"
        case .file: "doc"
        case .mindmap: "point.3.filled.connected.trianglepath.dotted"
        }
    }

    var tint: Color {
        switch self {
        case .note: .blue
        case .question: .orange
        case .chat: .teal
        case .file: .indigo
        case .mindmap: .pink
        }
    }
}

enum Status: String, Codable, CaseIterable, Identifiable {
    case none, open, active, done
    var id: Self { self }

    var label: String {
        switch self {
        case .none: "No Status"
        case .open: "Open"
        case .active: "In Progress"
        case .done: "Done"
        }
    }

    var icon: String {
        switch self {
        case .none: "circle.dashed"
        case .open: "circle"
        case .active: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        }
    }
}

struct FileRef: Codable, Hashable {
    var name: String
    var type: String        // UTType identifier
    var size: Int
    var text: String?       // extracted text, used for search and AI
    var hasThumb = false    // encrypted JPEG preview in blobs/<id>.thumb
}

struct MindNode: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var parent: UUID?
}

struct Item: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: Kind = .note
    var title = ""
    var body = ""
    var summary = ""
    var tags: [String] = []
    var space: UUID?
    var project: UUID?
    var status: Status = .none
    var pinned = false
    var trashed = false
    var links: [UUID] = []
    var file: FileRef?
    var nodes: [MindNode] = []
    var created = Date()
    var updated = Date()

    var display: String {
        if !title.isEmpty { return title }
        if let file { return file.name }
        let line = body.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? "Untitled" : String(line.prefix(80))
    }

    var snippet: String {
        let s = summary.isEmpty ? body : summary
        return String(s.prefix(240)).replacingOccurrences(of: "\n", with: " ")
    }

    /// Text that represents the item for search and embeddings.
    var text: String {
        [title, summary, tags.joined(separator: " "), body, file?.text ?? "", nodes.map(\.text).joined(separator: ", ")]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func matches(_ query: String) -> Bool {
        let haystack = text
        return query.split(separator: " ").allSatisfy { haystack.localizedStandardContains($0) }
    }
}

struct Space: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var icon: String
    var tone: Int           // slot in Palette
}

struct Project: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var space: UUID
    var archived = false
}

struct Meta: Codable, Equatable {
    var spaces: [Space] = [
        Space(name: "Work", icon: "briefcase.fill", tone: 0),
        Space(name: "Personal", icon: "leaf.fill", tone: 2),
    ]
    var projects: [Project] = []
}

enum Scope: Hashable {
    case overview, inbox, all, questions, pinned, trash
    case space(UUID), project(UUID)
}

enum Mode: String, CaseIterable, Identifiable {
    case list, board, graph
    var id: Self { self }
    var icon: String {
        switch self {
        case .list: "list.bullet"
        case .board: "rectangle.split.3x1"
        case .graph: "circle.hexagongrid"
        }
    }
}
