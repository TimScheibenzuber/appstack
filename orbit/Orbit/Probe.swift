// Temporary API probe: verifies SDK assumptions on CI before the real code lands.
import SwiftUI
import Charts
import CryptoKit
import CommonCrypto
import FoundationModels
import NaturalLanguage
import QuickLookThumbnailing
import LocalAuthentication
import PDFKit
import Accelerate

@Generable
struct ProbeTriage {
    @Guide(description: "A short title")
    var title: String
    @Guide(description: "Topic tags")
    var tags: [String]
}

func probeAI() async throws -> String {
    guard SystemLanguageModel.default.isAvailable else { return "" }
    let session = LanguageModelSession(instructions: "Be brief.")
    let r = try await session.respond(to: "Hello", generating: ProbeTriage.self)
    return r.content.title
}

func probeKDF(_ pass: String, salt: Data) -> SymmetricKey {
    var out = [UInt8](repeating: 0, count: 32)
    let pw = Array(pass.utf8)
    salt.withUnsafeBytes { s in
        pw.withUnsafeBufferPointer { p in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 1000, &out, out.count)
        }
    }
    return SymmetricKey(data: out)
}

func probeEmbed() -> Float {
    let e = NLEmbedding.sentenceEmbedding(for: .german)
    let v = (e?.vector(for: "Hallo Welt") ?? []).map(Float.init)
    return vDSP.dot(v, v)
}

struct Probe: View {
    @State private var url: URL?
    @Namespace private var ns
    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack {
                Text("Orbit").padding().glassEffect(.regular.tint(.purple).interactive(), in: .capsule)
                    .glassEffectID("a", in: ns)
                Image(systemName: "sparkles").symbolEffect(.bounce, value: url)
                Button("Glass") {}.buttonStyle(.glass)
                Button("Prominent") {}.buttonStyle(.glassProminent)
            }
        }
        .frame(minWidth: 300, minHeight: 200)
        .background(MeshGradient(width: 2, height: 2, points: [[0, 0], [1, 0], [0, 1], [1, 1]], colors: [.indigo, .purple, .blue, .cyan]))
        .quickLookPreview($url)
        .onKeyPress(.downArrow) { .handled }
        .overlay {
            Chart([1, 2, 3], id: \.self) { BarMark(x: .value("x", $0), y: .value("y", $0)) }
        }
        .task { _ = try? await probeAI(); _ = probeEmbed(); _ = probeKDF("x", salt: Data([1])) }
    }
}
