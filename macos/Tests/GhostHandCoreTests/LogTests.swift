import Foundation
import XCTest
@testable import GhostHandCore

/// File-backed logging: the first write must create the file and later writes must
/// append, never replace, so earlier log lines are preserved.
final class LogTests: XCTestCase {
    private func temporaryPath() -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ghosthand-log-\(UUID().uuidString).txt")
    }

    func testFileLogging_createsTheFileWhenMissing() {
        let log = GhostLog()
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        log.filePath = path
        log.warning("created")

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testFileLogging_appendsRatherThanReplacing() throws {
        let log = GhostLog()
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        log.filePath = path
        log.info("first line")
        log.info("second line")

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents.contains("first line"), contents)
        XCTAssertTrue(contents.contains("second line"), contents)
    }
}
