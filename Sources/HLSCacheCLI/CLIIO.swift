import Foundation

protocol CLIIO {
    func writeLine(_ text: String)
    func readLine() -> String?
}

struct StandardIO: CLIIO {
    func writeLine(_ text: String) {
        Swift.print(text)
    }

    func readLine() -> String? {
        Swift.readLine()
    }
}
