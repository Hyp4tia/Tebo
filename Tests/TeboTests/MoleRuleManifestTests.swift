import Foundation
import Testing
@testable import Tebo

@Suite("Mole rule disposition manifest")
struct MoleRuleManifestTests {
    private struct Manifest: Decodable {
        let originalRuleCount: Int
        let runtimeRuleCount: Int
        let rules: [Rule]
    }

    private struct Rule: Decodable {
        let ruleID: String
        let eligibility: String
        let needsAdmin: Bool
        let reportOnly: Bool
        let disposition: String
        let policyReason: String
        let tests: [String]
    }

    @Test("Every original rule has exactly one disposition matching the real runtime policy")
    func completeRuntimeInventory() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = repo.appendingPathComponent("docs/MOLE-RULE-DISPOSITIONS.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file))
        let targets = MoleTables.allTargets
        #expect(manifest.originalRuleCount == 469)
        #expect(manifest.runtimeRuleCount == targets.count)
        try #require(manifest.rules.count == targets.count)
        try #require(Set(manifest.rules.map(\.ruleID)).count == manifest.rules.count)
        let records = Dictionary(uniqueKeysWithValues: manifest.rules.map { ($0.ruleID, $0) })
        #expect(Set(records.keys) == Set(targets.map(\.ruleID)))
        for target in targets {
            let record = try #require(records[target.ruleID])
            #expect(record.eligibility == target.eligibility.rawValue)
            #expect(record.needsAdmin == target.needsAdmin)
            #expect(record.reportOnly == target.reportOnly)
            #expect(!record.policyReason.isEmpty && !record.tests.isEmpty)
            if record.disposition == "supported-rebuildable-cache" {
                #expect(target.eligibility == .rebuildableCache && target.risk == .safe)
                #expect(!target.needsAdmin && !target.reportOnly)
            } else if record.disposition == "supported-manual-review" {
                #expect(target.eligibility == .manualReview)
            } else {
                #expect(target.eligibility == .unsupported || target.needsAdmin || target.reportOnly)
            }
        }
    }
}
