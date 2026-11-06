import Foundation
import CoreGraphics

@main struct FeatureTourCheck {
    static func main() {
        // Catches a stuck final step, overflow on corrupt saved indices, and broken replay/back.
        precondition(LedgerTourStep.step(at: 0) != nil, "Replay must start at the first step")
        var visited: [LedgerTourTarget] = []
        var index: Int? = 0
        while let current = index {
            guard let step = LedgerTourStep.step(at: current) else { preconditionFailure("Missing step") }
            precondition(!visited.contains(step.target), "Next must make progress")
            visited.append(step.target)
            index = LedgerTourStep.next(after: current)
        }
        precondition(Set(visited) == Set(LedgerTourTarget.allCases))
        precondition(LedgerTourStep.previous(before: 0) == nil)
        precondition(LedgerTourStep.previous(before: 1) == 0)
        for invalid in [Int.min, -1, LedgerTourStep.all.count, Int.max] {
            precondition(LedgerTourStep.step(at: invalid) == nil)
            precondition(LedgerTourStep.next(after: invalid) == nil)
            precondition(LedgerTourStep.previous(before: invalid) == nil)
        }
        precondition(LedgerTourStep.step(at: nil) == nil)

        let solo = LedgerTourStep.stepsAvailable(memberCount: 1)
        precondition(!solo.contains { $0.target == .settlement })
        precondition(solo.map(\.target) == LedgerTourStep.all.filter { $0.target != .settlement }.map(\.target))
        precondition(LedgerTourStep.stepsAvailable(memberCount: 2).map(\.target) == LedgerTourStep.all.map(\.target))
        let personal = LedgerTourStep.stepsAvailable(memberCount: 2, scope: "personal")
        precondition(personal.map(\.target) == solo.map(\.target), "개인 안내에 보이지 않는 공용 정산 단계를 넣으면 안 됨")
        precondition(LedgerTourStep.step(at: 4, in: solo)?.target == .settings)
        precondition(LedgerTourStep.next(after: 4, in: solo) == 5)
        precondition(LedgerTourStep.next(after: 5, in: solo) == nil)
        precondition(LedgerTourStep.previous(before: 5, in: solo) == 4)
        precondition(LedgerTourStep.step(at: 6, in: solo) == nil)
        precondition(LedgerTourStep.step(at: 0, in: []) == nil)
        precondition(LedgerTourStep.next(after: 0, in: []) == nil)
        precondition(LedgerTourStep.previous(before: 0, in: []) == nil)

        let viewport = CGRect(x: 0, y: 0, width: 402, height: 874)
        let safe = CGRect(x: 24, y: 86, width: 354, height: 730)
        let target = CGRect(x: 24, y: 250, width: 354, height: 52)
        let placement = LedgerTourPlacement(viewport: viewport, safeBounds: safe, target: target, cardHeight: 280)
        guard let hole = placement.hole else { preconditionFailure("Visible target needs a spotlight") }
        precondition(hole.contains(target.insetBy(dx: -12, dy: -12)), "Spotlight must leave 12pt breathing room around its target")
        precondition(safe.contains(placement.card))
        precondition(placement.card.minY >= hole.maxY + 40 || placement.card.maxY <= hole.minY - 40,
                     "Description and target need a 40pt gap for a separate direction marker")
        for edgeTarget in [CGRect(x: 4, y: 100, width: 394, height: 44), CGRect(x: 24, y: 770, width: 354, height: 50)] {
            let edge = LedgerTourPlacement(viewport: viewport, safeBounds: safe, target: edgeTarget, cardHeight: 450)
            precondition(safe.contains(edge.card))
            if let hole = edge.hole { precondition(viewport.contains(hole) && hole.contains(edgeTarget)); precondition(!hole.intersects(edge.card)) }
        }
        for missing in [nil, CGRect(x: 0, y: -10, width: 100, height: 50), viewport] as [CGRect?] {
            let fallback = LedgerTourPlacement(viewport: viewport, safeBounds: safe, target: missing, cardHeight: 1000)
            precondition(fallback.hole == nil && safe.contains(fallback.card))
        }
        print("PASS: tour navigation, spotlight padding, card gap, edge targets and constrained fallback")
    }
}
