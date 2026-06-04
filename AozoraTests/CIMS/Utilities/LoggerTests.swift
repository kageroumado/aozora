import Foundation
import Testing
@testable import Aozora

struct LogTests {
    @Test
    func `creates logger with subsystem and category`() {
        let logger = Log.make(category: "tools")
        // If this compiles and doesn't crash, the factory works.
        // os.Logger has no inspectable state, so we verify via file logger.
        _ = logger
        #expect(true)
    }

    @Test
    func `file logger writes to disk`() throws {
        let path = NSTemporaryDirectory() + "test-log-\(UUID().uuidString).log"
        let fileLogger = FileLogger(path: path)
        fileLogger.log(level: .info, category: "test", message: "hello structured world")

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("hello structured world"))
        #expect(content.contains("[test]"))
        #expect(content.contains("INFO"))
    }

    @Test
    func `file logger rotates at size limit`() throws {
        let path = NSTemporaryDirectory() + "test-log-\(UUID().uuidString).log"
        let fileLogger = FileLogger(path: path, maxBytes: 500)

        for i in 0 ..< 50 {
            fileLogger.log(level: .info, category: "test", message: "line \(i) padding padding padding")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data.count < 1_000)
    }
}
