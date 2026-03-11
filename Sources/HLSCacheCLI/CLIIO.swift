import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

protocol CLIIO {
    func writeLine(_ text: String)
    func writeErrorLine(_ text: String)
    func readLine() -> String?
}

extension CLIIO {
    func writeErrorLine(_ text: String) {
        writeLine(text)
    }
}

struct StandardIO: CLIIO {
    func writeLine(_ text: String) {
        Swift.print(text)
    }

    func writeErrorLine(_ text: String) {
        fputs(text + "\n", stderr)
    }

    func readLine() -> String? {
        Swift.readLine()
    }
}
