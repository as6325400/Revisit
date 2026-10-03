import Foundation
import Testing
@testable import Revisit

struct SimplifierTests {
    @Test func straightLineCollapsesToEndpoints() {
        let line = TestRoutes.straightLine(seconds: 100).map(\.coordinate)
        let simplified = Simplifier.simplify(line, tolerance: 1)
        #expect(simplified == [line.first!, line.last!])
    }

    @Test func keepsCorners() {
        let origin = TestRoutes.origin
        let east = (0...50).map { Geo.offset(origin, north: 0, east: Double($0) * 10) }
        let north = (1...50).map { Geo.offset(east.last!, north: Double($0) * 10, east: 0) }
        let simplified = Simplifier.simplify(east + north, tolerance: 1)
        #expect(simplified.count == 3)
        #expect(simplified[1] == east.last!)
    }

    @Test func respectsMaxPoints() {
        let zigzag = (0..<500).map { i in
            Geo.offset(TestRoutes.origin, north: i.isMultiple(of: 2) ? 0 : 30, east: Double(i) * 10)
        }
        #expect(Simplifier.simplify(zigzag, maxPoints: 120).count <= 120)
    }

    @Test func shortInputIsUnchanged() {
        let two = [TestRoutes.origin, Geo.offset(TestRoutes.origin, north: 10, east: 0)]
        #expect(Simplifier.simplify(two, tolerance: 100) == two)
        #expect(Simplifier.simplify([], tolerance: 1).isEmpty)
    }
}
