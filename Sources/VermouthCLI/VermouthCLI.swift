import Foundation
import VermouthCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@main
enum VermouthCLI {
    static let version = "0.1.0"

    static func main() async {
        let exitCode = await run(arguments: Array(CommandLine.arguments.dropFirst()))
        fflush(nil)
        exit(exitCode)
    }

    static func run(arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            CLIOutput.printRootHelp()
            return 0
        }

        let rest = Array(arguments.dropFirst())

        switch command {
        case "--version", "-v", "version":
            CLIOutput.writeStdout("vermouth \(version)")
            return 0

        case "--help", "-h", "help":
            CLIOutput.printRootHelp()
            return 0

        case "recipes":
            return CLICommands.runBuiltInRecipesSmoke()

        default:
            break
        }

        let context = CLIContext.live()

        do {
            switch command {
            case "preflight":
                return try await CLICommands.runPreflight(args: rest, context: context)
            case "engine":
                return try await CLICommands.runEngine(args: rest, context: context)
            case "bottle":
                return try await CLICommands.runBottle(args: rest, context: context)
            case "graphics":
                return try await CLICommands.runGraphics(args: rest, context: context)
            case "run":
                return try await CLICommands.runExecutable(args: rest, context: context)
            case "scan":
                return try CLICommands.runScan(args: rest, context: context)
            case "diagnose":
                return try CLICommands.runDiagnose(args: rest, context: context)
            case "snapshot":
                return try CLICommands.runSnapshot(args: rest, context: context)
            case "recipe":
                return try await CLICommands.runRecipe(args: rest, context: context)
            default:
                throw CLIError.unknownCommand(command)
            }
        } catch let error as CLIError {
            CLIOutput.writeStderr("error: \(error.description)")
            return error.exitCode
        } catch let error as VermouthError {
            CLIOutput.writeStderr("error: \(error.errorDescription ?? String(describing: error))")
            return 1
        } catch {
            CLIOutput.writeStderr("error: \(error.localizedDescription)")
            return 1
        }
    }
}

// MARK: - Live Service Container

struct CLIContext: Sendable {
    let paths: VermouthPaths
    let commandRunner: LiveCommandRunner
    let systemProber: LiveSystemProber
    let httpFetcher: LiveHTTPFetcher
    let engineManager: EngineManager
    let bottleStore: BottleStore
    let graphicsManager: GraphicsStackManager
    let wineRunner: WineRunner
    let scanner: ExecutableScanner
    let diagnoser: CrashDiagnoser
    let snapshotManager: SnapshotManager
    let recipeEngine: RecipeEngine

    static func live() -> CLIContext {
        let paths = VermouthPaths()
        let commandRunner = LiveCommandRunner()
        let systemProber = LiveSystemProber(commandRunner: commandRunner)
        let httpFetcher = LiveHTTPFetcher()
        let engineManager = EngineManager(
            paths: paths,
            commandRunner: commandRunner,
            systemProber: systemProber
        )
        let bottleStore = BottleStore(paths: paths)
        let graphicsManager = GraphicsStackManager(
            paths: paths,
            commandRunner: commandRunner,
            httpFetcher: httpFetcher,
            bottleStore: bottleStore
        )
        let wineRunner = WineRunner(
            paths: paths,
            commandRunner: commandRunner,
            systemProber: systemProber
        )
        let scanner = ExecutableScanner()
        let diagnoser = CrashDiagnoser()
        let snapshotManager = SnapshotManager(paths: paths, commandRunner: commandRunner)
        let recipeEngine = RecipeEngine(paths: paths)

        return CLIContext(
            paths: paths,
            commandRunner: commandRunner,
            systemProber: systemProber,
            httpFetcher: httpFetcher,
            engineManager: engineManager,
            bottleStore: bottleStore,
            graphicsManager: graphicsManager,
            wineRunner: wineRunner,
            scanner: scanner,
            diagnoser: diagnoser,
            snapshotManager: snapshotManager,
            recipeEngine: recipeEngine
        )
    }

    func resolveEngine(for bottle: Bottle) async throws -> WineEngine {
        let engines = try await engineManager.listEngines()

        if let configuredID = bottle.config.engineID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredID.isEmpty
        {
            if let matched = engines.first(where: { $0.id == configuredID }) {
                return matched
            }
            throw VermouthError.engineNotFound(id: configuredID)
        }

        if let defaultEngine = try await engineManager.defaultEngine() {
            return defaultEngine
        }

        if let first = engines.first {
            return first
        }

        throw VermouthError.noEngineAvailable
    }

    func resolveActiveGraphicsPackage(for bottle: Bottle) throws -> GraphicsLayerPackage? {
        guard bottle.config.graphicsBackend != .wined3d else {
            return nil
        }

        let installed = try graphicsManager.listInstalledPackages()
        if let versionID = bottle.config.graphicsLayerVersionID,
           let exact = installed.first(where: { $0.id == versionID })
        {
            return exact
        }

        return installed
            .filter { $0.backend == bottle.config.graphicsBackend }
            .sorted { lhs, rhs in
                if lhs.installedAt != rhs.installedAt {
                    return lhs.installedAt > rhs.installedAt
                }
                return lhs.id > rhs.id
            }
            .first
    }
}

// MARK: - CLI Error & Argument Parsing

enum CLIError: Error, Sendable {
    case unknownCommand(String)
    case unknownSubcommand(command: String, subcommand: String)
    case unknownOption(String)
    case missingArgument(String)
    case missingOptionValue(String)
    case invalidArgument(String)
    case fileNotFound(String)
    case general(String)

    var exitCode: Int32 {
        switch self {
        case .unknownCommand, .unknownSubcommand, .unknownOption,
             .missingArgument, .missingOptionValue, .invalidArgument:
            return 2
        case .fileNotFound, .general:
            return 1
        }
    }

    var description: String {
        switch self {
        case let .unknownCommand(command):
            return "unknown command '\(command)'. Run 'vermouth --help' for usage."
        case let .unknownSubcommand(command, subcommand):
            return "unknown subcommand '\(subcommand)' for 'vermouth \(command)'. Run 'vermouth \(command) --help' for usage."
        case let .unknownOption(option):
            return "unknown option '\(option)'"
        case let .missingArgument(usage):
            return "missing required argument. Usage: \(usage)"
        case let .missingOptionValue(option):
            return "option '\(option)' requires a value"
        case let .invalidArgument(message):
            return message
        case let .fileNotFound(path):
            return "file not found: \(path)"
        case let .general(message):
            return message
        }
    }
}

struct ParsedArguments: Sendable {
    let positionals: [String]
    let flags: Set<String>
    let options: [String: String]
    let passthrough: [String]

    var isJSON: Bool { flags.contains("json") }
    var isHelp: Bool { flags.contains("help") || flags.contains("h") }

    func hasFlag(_ name: String) -> Bool {
        flags.contains(name)
    }

    func option(_ name: String) -> String? {
        options[name]
    }

    /// Parses CLI arguments supporting `--flag`, `--option value`, `--option=value`, and `--` pass-through.
    /// Explicitly declared `valueOptions` consume the following token even if it starts with `-` (e.g. `--debug -all,+loaddll`).
    static func parse(
        _ args: [String],
        allowedFlags: Set<String> = [],
        valueOptions: Set<String> = []
    ) throws -> ParsedArguments {
        var positionals: [String] = []
        var flags: Set<String> = []
        var options: [String: String] = [:]
        var passthrough: [String] = []

        var allAllowedFlags = allowedFlags
        allAllowedFlags.insert("help")
        allAllowedFlags.insert("h")

        var index = 0
        while index < args.count {
            let token = args[index]

            if token == "--" {
                passthrough = Array(args[(index + 1)...])
                break
            }

            if token == "-h" {
                flags.insert("help")
                index += 1
                continue
            }

            if token.hasPrefix("--") && token.count > 2 {
                let rawBody = String(token.dropFirst(2))
                if let equalsIndex = rawBody.firstIndex(of: "=") {
                    let name = String(rawBody[..<equalsIndex])
                    let value = String(rawBody[rawBody.index(after: equalsIndex)...])
                    guard valueOptions.contains(name) else {
                        throw CLIError.unknownOption("--\(name)")
                    }
                    options[name] = value
                    index += 1
                    continue
                }

                if valueOptions.contains(rawBody) {
                    guard index + 1 < args.count else {
                        throw CLIError.missingOptionValue("--\(rawBody)")
                    }
                    options[rawBody] = args[index + 1]
                    index += 2
                    continue
                }

                if allAllowedFlags.contains(rawBody) {
                    flags.insert(rawBody)
                    index += 1
                    continue
                }

                throw CLIError.unknownOption(token)
            }

            if token.hasPrefix("-") && token.count > 1 {
                let shortName = String(token.dropFirst(1))
                if allAllowedFlags.contains(shortName) {
                    flags.insert(shortName)
                    index += 1
                    continue
                }
                throw CLIError.unknownOption(token)
            }

            positionals.append(token)
            index += 1
        }

        return ParsedArguments(
            positionals: positionals,
            flags: flags,
            options: options,
            passthrough: passthrough
        )
    }
}

// MARK: - Output Helpers

enum CLIOutput: Sendable {
    static func writeStdout(_ message: String) {
        if let data = (message + "\n").data(using: .utf8) {
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
    }

    static func writeStdoutRaw(_ message: String) {
        if let data = message.data(using: .utf8) {
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
    }

    static func writeStderr(_ message: String) {
        if let data = (message + "\n").data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let data = try VermouthJSON.encode(value)
        if let text = String(data: data, encoding: .utf8) {
            writeStdout(text)
        }
    }

    static func printFindings(_ findings: [DiagnosticFinding], toStderr: Bool = false) {
        let emit: (String) -> Void = { line in
            if toStderr {
                writeStderr(line)
            } else {
                writeStdout(line)
            }
        }
        for finding in findings {
            let sev = finding.severity.rawValue.uppercased()
            emit("[\(sev)] (\(finding.category.rawValue)) \(finding.title)")
            emit("  Why: \(finding.explanation)")
            emit("  Fix: \(finding.suggestion)")
            if let missingDLL = finding.missingDLLName {
                let runtimeSuffix = finding.recommendedRuntime.map { " (runtime: \($0))" } ?? ""
                emit("  Missing DLL: \(missingDLL)\(runtimeSuffix)")
            }
            if let matched = finding.matchedLine {
                emit("  Log: \(matched)")
            }
            if let quickFix = finding.quickFix {
                emit("  QuickFix: \(describeQuickFix(quickFix))")
            }
        }
    }

    static func describeQuickFix(_ fix: DiagnosticQuickFix) -> String {
        switch fix {
        case let .removeQuarantine(path, recursive):
            let flag = recursive ? "-dr" : "-d"
            return "xattr \(flag) com.apple.quarantine \(ShellQuoting.posixEscape(path))"
        case let .switchGraphicsBackend(backend):
            return "vermouth graphics set <bottle> \(backend.rawValue)"
        case .killWineServer:
            return "vermouth bottle kill <bottle>"
        case .select32BitCapableEngine:
            return "Switch bottle to a 32-bit/WoW64 capable Wine engine (e.g. Wine Stable 11+)"
        case let .removeConflictingDllOverrides(dlls):
            return "Remove conflicting DLL overrides: \(dlls.joined(separator: ", "))"
        case .enableChineseLocalization:
            return "vermouth bottle chinese-fix <bottle>"
        case let .copyCommand(label, command):
            return "\(label): \(command)"
        }
    }

    static func formatByteCount(_ bytes: UInt64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        }
        let kb = Double(bytes) / 1024.0
        if kb < 1024.0 {
            return String(format: "%.1f KiB", kb)
        }
        let mb = kb / 1024.0
        if mb < 1024.0 {
            return String(format: "%.1f MiB", mb)
        }
        let gb = mb / 1024.0
        return String(format: "%.2f GiB", gb)
    }

    static func expandTilde(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser
        if trimmed == "~" {
            return home.path
        }
        if trimmed.hasPrefix("~/") {
            return home.appendingPathComponent(String(trimmed.dropFirst(2))).path
        }
        return trimmed
    }

    static func printRootHelp() {
        writeStdout(
            """
            vermouth \(VermouthCLI.version) — Native macOS Windows compatibility launcher CLI

            USAGE:
              vermouth <command> [subcommand] [options]

            ENVIRONMENT & ENGINES:
              preflight [--json]                                  Run host environment preflight checks
              engine list [--json]                                List discovered & custom Wine engines
              engine add <name> <root-path> [--json]              Register a custom local Wine engine
              engine remove <engine-id>                           Unregister a custom Wine engine
              engine default <engine-id>                          Set default Wine engine

            BOTTLES:
              bottle list [--json]                                List all bottles
              bottle create <name> [--win winxp|win7|win10|win11]
                                   [--graphics wined3d|dxvk|dxmt]
                                   [--sync msync|esync|none]
                                   [--engine <id>] [--json]       Create a new bottle
              bottle inspect <name-or-id> [--json]                Inspect bottle configuration
              bottle rename <name-or-id> <new-name> [--json]      Rename a bottle
              bottle clone <source> <new-name> [--json]           Clone a bottle (APFS COW)
              bottle import <name> <prefix-path> [--copy] [--json] Import an existing WINEPREFIX
              bottle delete <name-or-id> [--keep-prefix]          Delete a bottle (protects external prefix)
              bottle chinese-fix <name-or-id>                     Enable CJK locale & font mapping
              bottle terminal-script <name-or-id>                 Print POSIX shell setup script
              bottle kill <name-or-id> [--force]                  Terminate bottle wineserver

            GRAPHICS STACK:
              graphics list [--json]                              List installed DXMT/DXVK packages
              graphics releases <dxmt|dxvk> [--json]              Fetch official GitHub releases
              graphics install <dxmt|dxvk> [--tag <tag>] [--json] Download & install a release
              graphics import <dxmt|dxvk> <version> <archive>     Import local .tar.gz/.tar.xz archive
              graphics remove <package-id>                        Remove an unused graphics package
              graphics set <bottle> <wined3d|dxvk|dxmt>
                           [--package <id>] [--json]              Switch bottle graphics backend

            EXECUTION, DISCOVERY & DIAGNOSTICS:
              run <bottle> <exe-or-msi> [--dry-run] [--debug <ch>]
                  [--json] [-- <args...>]                         Run a Windows .exe or .msi in bottle
              scan <bottle> [--json]                              Scan shortcuts & Program Files .exe
              diagnose <log-file-path> [--json]                   Diagnose a Wine log file

            SNAPSHOTS & RECIPES:
              snapshot create <bottle> <path> [--label <name>]
                              [--note <text>] [--json]            Create SHA-256 snapshot archive
              snapshot list <bottle> [--json]                     List snapshots for bottle
              snapshot rollback <bottle> <snapshot-id>
                                [--to <override-path>] [--json]   Verify & atomically rollback snapshot
              snapshot delete <bottle> <snapshot-id>              Delete a snapshot
              recipes                                             Inspect bundled built-in recipes
              recipe list [--json]                                List built-in & imported recipes
              recipe apply <bottle> <recipe-id-or-path> [--json]  Apply recipe to bottle
              recipe import <file-path> [--json]                  Import a .recipe.json file
              recipe export <bottle> <output-path>
                            --id <id> --name <name>
                            [--summary <text>] [--json]           Export sanitized .recipe.json

            OPTIONS:
              --version, -v                                       Print version information
              --help, -h                                          Show help message
            """
        )
    }
}
