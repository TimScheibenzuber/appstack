import Foundation
import NaturalLanguage
import Accelerate
import FoundationModels

struct Vector: Sendable {
    var lang: NLLanguage
    var values: [Float]   // unit length, so a dot product is the cosine similarity
}

/// Owns the NLEmbedding models (not documented as thread-safe) and computes sentence vectors off the main thread.
actor Embedder {
    private var models: [NLLanguage: NLEmbedding?] = [:]

    func embed(_ text: String) -> Vector? {
        let sample = String(text.prefix(1500))
        guard sample.contains(where: \.isLetter) else { return nil }
        let lang = NLLanguageRecognizer.dominantLanguage(for: sample) ?? .english
        for candidate in [lang, .english] {
            guard let model = model(candidate), let raw = model.vector(for: sample) else { continue }
            let v = raw.map(Float.init)
            let norm = sqrt(vDSP.sumOfSquares(v))
            return norm > 0 ? Vector(lang: candidate, values: vDSP.divide(v, norm)) : nil
        }
        return nil
    }

    private func model(_ lang: NLLanguage) -> NLEmbedding? {
        if let cached = models[lang] { return cached }
        let model = NLEmbedding.sentenceEmbedding(for: lang)
        models[lang] = model
        return model
    }
}

/// On-device semantic index: related items, semantic search and sorting suggestions.
@MainActor @Observable
final class Brain {
    private(set) var vectors: [UUID: Vector] = [:]
    @ObservationIgnored private var indexed: [UUID: Date] = [:]
    @ObservationIgnored private let embedder = Embedder()
    @ObservationIgnored private var task: Task<Void, Never>?

    func reset() {
        task?.cancel()
        vectors = [:]
        indexed = [:]
    }

    /// Embeds new or changed items in the background and publishes the results in one batch.
    func refresh(_ items: [Item]) {
        let live = items.filter { !$0.trashed }
        let liveIDs = Set(live.map(\.id))
        if vectors.keys.contains(where: { !liveIDs.contains($0) }) {
            vectors = vectors.filter { liveIDs.contains($0.key) }
        }
        let stale = live.filter { indexed[$0.id] != $0.updated }.map { ($0.id, $0.updated, $0.text) }
        guard !stale.isEmpty else { return }
        task?.cancel()
        task = Task { [embedder] in
            var fresh: [(UUID, Date, Vector?)] = []
            for (id, date, text) in stale {
                if Task.isCancelled { return }
                fresh.append((id, date, await embedder.embed(text)))
            }
            var next = vectors
            for (id, date, vector) in fresh {
                indexed[id] = date
                next[id] = vector
            }
            vectors = next
        }
    }

    func nearest(_ query: Vector, limit: Int, minScore: Float) -> [(id: UUID, score: Float)] {
        var hits: [(id: UUID, score: Float)] = []
        for (id, v) in vectors where v.lang == query.lang {
            let score = vDSP.dot(query.values, v.values)
            if score >= minScore { hits.append((id, score)) }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    func similar(to id: UUID, limit: Int = 6, minScore: Float = 0.45) -> [(id: UUID, score: Float)] {
        guard let v = vectors[id] else { return [] }
        return Array(nearest(v, limit: limit + 1, minScore: minScore).filter { $0.id != id }.prefix(limit))
    }

    func search(_ text: String) async -> [(id: UUID, score: Float)] {
        guard let v = await embedder.embed(text) else { return [] }
        return nearest(v, limit: 12, minScore: 0.3)
    }

    /// Lets the most similar already-sorted items vote on where this one belongs.
    func suggestion(for item: Item, in items: [UUID: Item]) -> (space: UUID, project: UUID?)? {
        let votes = similar(to: item.id, limit: 8, minScore: 0.4).compactMap { hit in
            items[hit.id].flatMap { $0.space == nil ? nil : ($0, hit.score) }
        }
        var spaces: [UUID: Float] = [:]
        for (neighbour, score) in votes { spaces[neighbour.space!, default: 0] += score }
        let total = spaces.values.reduce(0, +)
        guard let best = spaces.max(by: { $0.value < $1.value }), best.value >= 0.5, best.value / total >= 0.6 else { return nil }
        var projects: [UUID: Float] = [:]
        for (neighbour, score) in votes where neighbour.space == best.key {
            if let p = neighbour.project { projects[p, default: 0] += score }
        }
        let project = projects.max(by: { $0.value < $1.value }).flatMap { $0.value / best.value >= 0.6 ? $0.key : nil }
        return (best.key, project)
    }
}

@Generable
struct Triage {
    @Guide(description: "A specific title of at most eight words, in the language of the text")
    var title: String
    @Guide(description: "One sentence with the key point, in the language of the text")
    var summary: String
    @Guide(description: "Two to four short lowercase topic tags")
    var tags: [String]
}

/// Apple Intelligence (on-device Foundation Models) with a NaturalLanguage fallback. Nothing leaves the device.
enum AI {
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static func triage(_ text: String) async throws -> Triage {
        let session = LanguageModelSession(instructions: """
            You file notes, files and chats into a personal knowledge base. Be precise and neutral. Never invent facts.
            """)
        return try await session.respond(to: "Text:\n" + String(text.prefix(3000)), generating: Triage.self).content
    }

    static func answer(_ question: String, context: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
            Answer the user's open question briefly, using the notes provided when they help. \
            Say clearly when the notes are not enough. Answer in the language of the question.
            """)
        let prompt = "Question:\n\(question.prefix(1500))\n\nNotes:\n\(context.prefix(2500))"
        return try await session.respond(to: prompt).content
    }

    /// Fallback tags: the most frequent nouns and names.
    static func keywords(_ text: String, limit: Int = 4) -> [String] {
        let sample = String(text.prefix(6000))
        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass])
        tagger.string = sample
        var counts: [String: Int] = [:]
        let wanted: Set<NLTag> = [.noun, .personalName, .placeName, .organizationName]
        tagger.enumerateTags(in: sample.startIndex..<sample.endIndex, unit: .word, scheme: .nameTypeOrLexicalClass,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let tag, wanted.contains(tag) {
                let word = sample[range].lowercased()
                if word.count > 3 { counts[word, default: 0] += 1 }
            }
            return true
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(\.key)
    }
}
