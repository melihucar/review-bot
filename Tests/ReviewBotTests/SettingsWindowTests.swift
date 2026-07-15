import AppKit
import XCTest
@testable import ReviewBot

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testOpenSettingsCreatesAVisibleReusableWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewBotSettingsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(paths: StoragePaths(root: root))

        model.openSettings()

        let firstWindow = try XCTUnwrap(
            NSApplication.shared.windows.first(where: {
                $0.title == "Review Bot Settings" && $0.isVisible
            })
        )

        model.openSettings()

        let matchingWindows = NSApplication.shared.windows.filter {
            $0.title == "Review Bot Settings" && $0.isVisible
        }
        XCTAssertEqual(matchingWindows.count, 1)
        XCTAssertTrue(matchingWindows.first === firstWindow)
        firstWindow.close()
    }
}
