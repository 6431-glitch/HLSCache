import Foundation

struct CLIApp {
    private let context: CLIAppContext
    private let io: any CLIIO

    init(context: CLIAppContext, io: any CLIIO = StandardIO()) {
        self.context = context
        self.io = io
    }

    func runInteractive() {
        io.writeLine("HLSCacheCLI")
        io.writeLine("Base directory: \(context.baseDirectory.path)")
        io.writeLine("Settings path: \(context.settingsFileURL.path)")
        io.writeLine("Proxy base URL: \(context.serverBaseURL.absoluteString)")
        io.writeLine("")

        var shouldExit = false
        while !shouldExit {
            renderMainMenu()

            guard let selection = normalizedInput() else {
                io.writeLine("Input stream closed. Exiting.")
                break
            }

            switch selection.lowercased() {
            case "1":
                runSubflow(
                    title: "Asset Management",
                    options: [
                        "1) Register alias and URL (coming soon)",
                        "2) List aliases (coming soon)"
                    ]
                )
            case "2":
                runSubflow(
                    title: "Proxy Server",
                    options: [
                        "1) Show proxy status (coming soon)",
                        "2) Restart proxy server (coming soon)"
                    ]
                )
            case "3":
                runSubflow(
                    title: "Settings",
                    options: [
                        "1) Show settings file path",
                        "2) Edit default User-Agent (coming soon)"
                    ]
                )
            case "4":
                runSubflow(
                    title: "Cache Operations",
                    options: [
                        "1) Show cache summary (coming soon)",
                        "2) Clear cache by alias (coming soon)"
                    ]
                )
            case "0", "q", "quit", "exit":
                shouldExit = true
            default:
                io.writeLine("Invalid selection '\(selection)'. Please choose 0-4.")
            }
        }

        io.writeLine("Goodbye.")
    }

    private func renderMainMenu() {
        io.writeLine("Main Menu")
        io.writeLine("1) Asset management")
        io.writeLine("2) Proxy server")
        io.writeLine("3) Settings")
        io.writeLine("4) Cache operations")
        io.writeLine("0) Exit")
        io.writeLine("Choose an option:")
    }

    private func runSubflow(title: String, options: [String]) {
        var shouldReturn = false
        while !shouldReturn {
            io.writeLine("")
            io.writeLine("[\(title)]")
            for option in options {
                io.writeLine(option)
            }
            io.writeLine("0) Back")
            io.writeLine("Choose an option:")

            guard let selection = normalizedInput() else {
                io.writeLine("Input stream closed. Returning to main menu.")
                return
            }

            switch selection.lowercased() {
            case "0", "b", "back":
                shouldReturn = true
            case "1":
                if title == "Settings" {
                    io.writeLine("Settings file: \(context.settingsFileURL.path)")
                } else {
                    io.writeLine("Option 1 in \(title) is not implemented yet.")
                }
            case "2":
                io.writeLine("Option 2 in \(title) is not implemented yet.")
            default:
                io.writeLine("Invalid selection '\(selection)'. Enter 0 to go back.")
            }
        }
    }

    private func normalizedInput() -> String? {
        io.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
