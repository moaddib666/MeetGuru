import Foundation
import os

public enum Log {
    private static let logger = Logger(subsystem: "com.meetingguru.app", category: "app")
    private static let state = OSAllocatedUnfairLock(initialState: (debug: false, echo: false))

    /// `echo` mirrors log lines to stderr, like the Python app's console logging.
    public static func configure(debug: Bool, echo: Bool) {
        state.withLock { $0 = (debug, echo) }
    }

    public static var isDebug: Bool { state.withLock { $0.debug } }

    public static func debug(_ message: @autoclosure () -> String) {
        guard isDebug else { return }
        emit("DEBUG", message(), type: .debug)
    }

    public static func info(_ message: @autoclosure () -> String) { emit("INFO", message(), type: .info) }

    public static func error(_ message: @autoclosure () -> String) { emit("ERROR", message(), type: .error) }

    private static func emit(_ level: String, _ message: String, type: OSLogType) {
        logger.log(level: type, "\(message, privacy: .public)")
        if state.withLock({ $0.echo }) {
            let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
            FileHandle.standardError.write(Data("\(stamp) - \(level) - \(message)\n".utf8))
        }
    }
}
