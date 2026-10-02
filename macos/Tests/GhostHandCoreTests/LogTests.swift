import Foundation
import XCTest
@testable import GhostHandCore

/// File-backed logging: the first write must create the file and later writes must
/// append, never replace, so earlier log lines are preserved.
final class LogTests: XCTestCase {
    /// Returns a unique temporary file path for a single log test.
    private func temporaryPath() -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ghosthand-log-\(UUID().uuidString).txt")
    }

    /// Verifies that the first log write creates the log file when it does not yet exist.
    func testFileLogging_createsTheFileWhenMissing() {
        let log = GhostLog()
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        log.filePath = path
        log.warning("created")

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    /// Verifies that later log writes append to the file and preserve earlier lines.
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

    /// Verifies that writes racing with a reconfiguration neither crash nor lose the log:
    /// configuration reads and writes share the logger's lock with the write path.
    func testFileLogging_concurrentConfigurationAndWrites_areSafe() {
        let log = GhostLog()
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        log.filePath = path
        log.minimumLevel = .trace

        DispatchQueue.concurrentPerform(iterations: 400) { index in
            if index.isMultiple(of: 4) {
                log.minimumLevel = index.isMultiple(of: 8) ? .error : .trace
            } else {
                log.warning("line \(index)")
            }
        }

        log.minimumLevel = .trace
        log.warning("final line")
        let contents = try? String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents?.contains("final line") ?? false, contents ?? "")
    }
}
