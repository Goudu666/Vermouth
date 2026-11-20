import Foundation
import VermouthCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private enum VermouthCLIBootstrap {
    static let version = "0.1.0"

    static func writeStderr(_ message: String) {
        if let data = (message + "\n").data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }

    static func printHelp() {
        print(
            """
            vermouth \(version) — Native macOS Windows compatibility launcher CLI (Round 1 bootstrap)

            USAGE:
              vermouth <command>

            COMMANDS:
              recipes         List built-in compatibility recipes bundled with VermouthCore
              --version, -v   Print version information
              --help, -h      Show this help message
            """
        )
    }

    static func runRecipesCommand() -> Int32 {
        guard let directory = VermouthResourceLocator.builtInRecipesDirectory() else {
            writeStderr("error: could not locate built-in recipes directory.")
            return 1
        }

        let files = VermouthResourceLocator.builtInRecipeFiles()
        guard !files.isEmpty else {
            writeStderr("error: no built-in .recipe.json files found in \(directory.path).")
            return 1
        }

        print("Built-in recipes directory: \(directory.path)")
        print("Discovered \(files.count) built-in recipe(s):")

        for fileURL in files {
            do {
                let data = try Data(contentsOf: fileURL)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    writeStderr("error: invalid JSON object in \(fileURL.lastPathComponent)")
                    return 1
                }
                let id = object["id"] as? String ?? fileURL.deletingPathExtension().lastPathComponent
                let name = object["name"] as? String ?? fileURL.lastPathComponent
                let backend = object["recommendedBackend"] as? String ?? "unknown"
                let arch = object["targetArchitecture"] as? String ?? "unknown"
                print("  - \(id) | \(name) [arch=\(arch), backend=\(backend)] (\(fileURL.lastPathComponent))")
            } catch {
                writeStderr("error: failed to read recipe \(fileURL.path): \(error.localizedDescription)")
                return 1
            }
        }

        return 0
    }

    static func run(arguments: [String]) -> Int32 {
        let args = Array(arguments.dropFirst())
        guard let first = args.first else {
            printHelp()
            return 0
        }

        switch first {
        case "--version", "-v", "version":
            print("vermouth \(version)")
            return 0
        case "--help", "-h", "help":
            printHelp()
            return 0
        case "recipes":
            return runRecipesCommand()
        default:
            writeStderr("error: unknown command '\(first)'")
            writeStderr("Run 'vermouth --help' for usage.")
            return 2
        }
    }
}

exit(VermouthCLIBootstrap.run(arguments: CommandLine.arguments))
