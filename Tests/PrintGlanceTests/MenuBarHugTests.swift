import XCTest
@testable import PrintGlance

final class MenuBarHugTests: XCTestCase {
    func testShrinkKeepsTheTopAndTrailingEdge() {
        let current = CGRect(x: 958, y: 692, width: 248, height: 255)
        let next = MenuBarHug.frame(current: current, fitting: CGSize(width: 248, height: 197))
        XCTAssertEqual(next, CGRect(x: 958, y: 750, width: 248, height: 197))
    }

    func testWidenKeepsTheTrailingEdge() {
        let current = CGRect(x: 900, y: 700, width: 248, height: 197)
        let next = MenuBarHug.frame(current: current, fitting: CGSize(width: 280, height: 420))
        XCTAssertEqual(next?.maxX, current.maxX)
        XCTAssertEqual(next?.maxY, current.maxY)
        XCTAssertEqual(next?.size, CGSize(width: 280, height: 420))
    }

    func testUnsetMinDoesNotMoveThePanel() {
        let current = CGRect(x: 10, y: 20, width: 248, height: 255)
        XCTAssertNil(MenuBarHug.frame(current: current, fitting: .zero))
    }

    func testAlreadyFittingDoesNotMoveThePanel() {
        let current = CGRect(x: 10, y: 20, width: 248, height: 197)
        XCTAssertNil(MenuBarHug.frame(current: current, fitting: CGSize(width: 248.4, height: 197.4)))
    }
}
