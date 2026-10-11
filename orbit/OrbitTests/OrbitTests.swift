import Foundation
import CryptoKit
import Testing
@testable import Orbit

struct OrbitTests {
    @Test func kdfIsDeterministic() {
        let a = probeKDF("pw", salt: Data([1, 2, 3]))
        let b = probeKDF("pw", salt: Data([1, 2, 3]))
        #expect(a == b)
    }
}
