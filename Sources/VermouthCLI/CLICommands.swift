import Foundation
import VermouthCore

enum CLICommands: Sendable {
    // MARK: - 1. Preflight

    static func runPreflight(args: [String], context: CLIContext) async throws -> Int32 {
        let parsed = try ParsedArguments.parse(args, allowedFlags: ["json"])
        if parsed.isHelp {
            CLIOutput.writeStdout("Usage: vermouth preflight [--json]")
            return 0
        }

        let report = await context.engineManager.runPreflight()
        if parsed.isJSON {
            try CLIOutput.printJSON(report)
            return 0
        }

        CLIOutput.writeStdout("Vermouth Preflight Report")
        CLIOutput.writeStdout("  OS:            \(report.osVersion.displayString)")
        CLIOutput.writeStdout("  Architecture:  \(report.architecture.rawValue)")
        CLIOutput.writeStdout("  Rosetta 2:     \(report.rosetta2Ready ? "ready" : "not detected")")
        CLIOutput.writeStdout("  Homebrew:      \(report.homebrewPath ?? "not found")")
        CLIOutput.writeStdout("  Winetricks:    \(report.winetricksPath ?? "not found")")
        CLIOutput.writeStdout("  Wine Engines:  \(report.discoveredEngines.count)")
        CLIOutput.writeStdout("")

        for item in report.items {
            let badge: String
            switch item.status {
            case .pass: badge = "PASS"
            case .warning: badge = "WARN"
            case .fail: badge = "FAIL"
            }
            CLIOutput.writeStdout("[\(badge)] \(item.title)")
            CLIOutput.writeStdout("  \(item.detail)")
            if let remediation = item.remediationCommand {
                CLIOutput.writeStdout("  Command: \(remediation)")
            }
        }

        CLIOutput.writeStdout("")
        CLIOutput.writeStdout("Ready to launch: \(report.isReadyToLaunch ? "yes" : "no")")
        return 0
    }

    // MARK: - 2. Engine Commands

    static func runEngine(args: [String], context: CLIContext) async throws -> Int32 {
        guard let subcommand = args.first else {
            printEngineHelp()
            return 0
        }
        let rest = Array(args.dropFirst())

        switch subcommand {
        case "--help", "-h", "help":
            printEngineHelp()
            return 0

        case "list":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["json"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth engine list [--json]")
                return 0
            }
            let engines = try await context.engineManager.listEngines()
            let defaultEngine = try await context.engineManager.defaultEngine()
            if parsed.isJSON {
                try CLIOutput.printJSON(engines)
                return 0
            }
            if engines.isEmpty {
                CLIOutput.writeStdout("No Wine engines found. Install Wine via Homebrew or register one with 'vermouth engine add <name> <root-path>'.")
                return 0
            }
            for engine in engines {
                let marker = engine.id == defaultEngine?.id ? "*" : " "
                var caps: [String] = []
                if engine.capabilities.supports32Bit { caps.append("32-bit") }
                if engine.capabilities.supports64Bit { caps.append("64-bit") }
                if engine.capabilities.isNewWoW64 { caps.append("WoW64") }
                if engine.capabilities.supportsMSync { caps.append("MSync") }
                if engine.capabilities.supportsWineDLLPathPrepend { caps.append("DLLPathPrepend") }
                let quarantineTag = engine.isQuarantined ? " [QUARANTINED]" : ""
                CLIOutput.writeStdout("\(marker) \(engine.id) | \(engine.name) (\(engine.version)) [\(engine.source.rawValue)]\(quarantineTag)")
                CLIOutput.writeStdout("    Root: \(engine.rootPath)")
                CLIOutput.writeStdout("    Capabilities: \(caps.isEmpty ? "none" : caps.joined(separator: ", "))")
            }
            return 0

        case "add":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["json"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth engine add <name> <root-path> [--json]")
                return 0
            }
            guard parsed.positionals.count >= 2 else {
                throw CLIError.missingArgument("vermouth engine add <name> <root-path>")
            }
            let engine = try await context.engineManager.registerCustomEngine(
                name: parsed.positionals[0],
                rootPath: parsed.positionals[1]
            )
            if parsed.isJSON {
                try CLIOutput.printJSON(engine)
            } else {
                CLIOutput.writeStdout("Registered engine '\(engine.name)' (id: \(engine.id), version: \(engine.version))")
            }
            return 0

        case "remove":
            let parsed = try ParsedArguments.parse(rest)
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth engine remove <engine-id>")
                return 0
            }
            guard let engineID = parsed.positionals.first else {
                throw CLIError.missingArgument("vermouth engine remove <engine-id>")
            }
            try await context.engineManager.unregisterCustomEngine(id: engineID)
            CLIOutput.writeStdout("Removed custom engine '\(engineID)'.")
            return 0

        case "default":
            let parsed = try ParsedArguments.parse(rest)
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth engine default <engine-id>")
                return 0
            }
            guard let engineID = parsed.positionals.first else {
                throw CLIError.missingArgument("vermouth engine default <engine-id>")
            }
            try await context.engineManager.setDefaultEngine(id: engineID)
            CLIOutput.writeStdout("Default engine set to '\(engineID)'.")
            return 0

        default:
            throw CLIError.unknownSubcommand(command: "engine", subcommand: subcommand)
        }
    }

    private static func printEngineHelp() {
        CLIOutput.writeStdout(
            """
            USAGE:
              vermouth engine list [--json]
              vermouth engine add <name> <root-path> [--json]
              vermouth engine remove <engine-id>
              vermouth engine default <engine-id>
            """
        )
    }

    // MARK: - 3. Bottle Commands

    static func runBottle(args: [String], context: CLIContext) async throws -> Int32 {
        guard let subcommand = args.first else {
            printBottleHelp()
            return 0
        }
        let rest = Array(args.dropFirst())

        switch subcommand {
        case "--help", "-h", "help":
            printBottleHelp()
            return 0

        case "list":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["json"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth bottle list [--json]")
                return 0
            }
            let bottles = try context.bottleStore.listBottles()
            if parsed.isJSON {
                try CLIOutput.printJSON(bottles)
                return 0
            }
            if bottles.isEmpty {
                CLIOutput.writeStdout("No bottles found. Create one with 'vermouth bottle create <name>'.")
                return 0
            }
            for bottle in bottles {
                let prefixKind = bottle.isExternalPrefix ? "external" : "managed"
                CLIOutput.writeStdout(
                    "- \(bottle.name) (\(bottle.id.uuidString)) [win=\(bottle.config.windowsVersion.rawValue), graphics=\(bottle.config.graphicsBackend.rawValue), sync=\(bottle.config.syncMode.rawValue), \(prefixKind)]"
                )
                CLIOutput.writeStdout("    Prefix: \(bottle.prefixPath)")
            }
            return 0

        case "create":
            let parsed = try ParsedArguments.parse(
                rest,
                allowedFlags: ["json"],
                valueOptions: ["win", "graphics", "sync", "engine"]
            )
            if parsed.isHelp {
                CLIOutput.writeStdout(
                    "Usage: vermouth bottle create <name> [--win winxp|win7|win10|win11] [--graphics wined3d|dxvk|dxmt] [--sync msync|esync|none] [--engine <id>] [--json]"
                )
                return 0
            }
            guard let name = parsed.positionals.first else {
                throw CLIError.missingArgument("vermouth bottle create <name>")
            }

            let windowsVersion: WindowsVersion
            if let rawWin = parsed.option("win") {
                guard let parsedWin = WindowsVersion(rawValue: rawWin.lowercased()) else {
                    throw CLIError.invalidArgument(
                        "invalid --win '\(rawWin)' (expected: winxp, win7, win10, win11)"
                    )
                }
                windowsVersion = parsedWin
            } else {
                windowsVersion = .win10
            }

            let graphicsBackend: GraphicsBackend
            if let rawGraphics = parsed.option("graphics") {
                guard let parsedGraphics = GraphicsBackend(rawValue: rawGraphics.lowercased()) else {
                    throw CLIError.invalidArgument(
                        "invalid --graphics '\(rawGraphics)' (expected: wined3d, dxvk, dxmt)"
                    )
                }
                graphicsBackend = parsedGraphics
            } else {
                graphicsBackend = .wined3d
            }

            let syncMode: SyncMode
            if let rawSync = parsed.option("sync") {
                guard let parsedSync = SyncMode(rawValue: rawSync.lowercased()) else {
                    throw CLIError.invalidArgument(
                        "invalid --sync '\(rawSync)' (expected: msync, esync, none)"
                    )
                }
                syncMode = parsedSync
            } else {
                syncMode = .msync
            }

            let engineID = parsed.option("engine")
            let initialConfig = BottleConfig(
                engineID: engineID,
                windowsVersion: windowsVersion,
                syncMode: syncMode,
                graphicsBackend: graphicsBackend
            )
            let bottle = try context.bottleStore.createBottle(
                name: name,
                engineID: engineID,
                initialConfig: initialConfig
            )
            if parsed.isJSON {
                try CLIOutput.printJSON(bottle)
            } else {
                CLIOutput.writeStdout("Created bottle '\(bottle.name)' (\(bottle.id.uuidString))")
                CLIOutput.writeStdout("  Prefix:   \(bottle.prefixPath)")
                CLIOutput.writeStdout("  Config:   win=\(bottle.config.windowsVersion.rawValue), graphics=\(bottle.config.graphicsBackend.rawValue), sync=\(bottle.config.syncMode.rawValue)")
            }
            return 0

        case "inspect":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["json"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth bottle inspect <name-or-id> [--json]")
                return 0
            }
            guard let target = parsed.positionals.first else {
                throw CLIError.missingArgument("vermouth bottle inspect <name-or-id>")
            }
            let bottle = try context.bottleStore.findBottle(nameOrID: target)
            if parsed.isJSON {
                try CLIOutput.printJSON(bottle)
                return 0
            }

            let deployment = try? context.graphicsManager.deploymentState(for: bottle)
            CLIOutput.writeStdout("Bottle: \(bottle.name)")
            CLIOutput.writeStdout("  ID:                 \(bottle.id.uuidString)")
            CLIOutput.writeStdout("  Prefix:             \(bottle.prefixPath) (\(bottle.isExternalPrefix ? "external" : "managed"))")
            CLIOutput.writeStdout("  Engine ID:          \(bottle.config.engineID ?? "(default)")")
            CLIOutput.writeStdout("  Windows Version:    \(bottle.config.windowsVersion.rawValue)")
            CLIOutput.writeStdout("  Sync Mode:          \(bottle.config.syncMode.rawValue)")
            CLIOutput.writeStdout("  Graphics Backend:   \(bottle.config.graphicsBackend.rawValue) (package: \(bottle.config.graphicsLayerVersionID ?? "none"))")
            if let deployment {
                CLIOutput.writeStdout("  Deployed Strategy:  \(deployment.strategy.rawValue) (deployed files: \(deployment.deployedFiles.count), backups: \(deployment.backedUpFiles.count))")
            }
            CLIOutput.writeStdout("  Display:            retina=\(bottle.config.display.retinaMode), dpi=\(bottle.config.display.dpi), metalHUD=\(bottle.config.display.metalHUD), virtualDesktop=\(bottle.config.display.virtualDesktop.enabled ? "\(bottle.config.display.virtualDesktop.width)x\(bottle.config.display.virtualDesktop.height)" : "off")")
            CLIOutput.writeStdout("  Chinese Locale:     \(bottle.config.locale.chineseLocalizationEnabled ? "enabled (\(bottle.config.locale.lcAll), font=\(bottle.config.locale.fallbackFontName))" : "disabled")")
            CLIOutput.writeStdout("  WINEDEBUG:          \(bottle.config.wineDebugChannels)")
            if let recipeID = bottle.appliedRecipeID {
                CLIOutput.writeStdout("  Applied Recipe:     \(recipeID)")
            }
            let formattedOverrides = DllOverrideFormatter.format(bottle.config.dllOverrides)
            if !formattedOverrides.isEmpty {
                CLIOutput.writeStdout("  DLL Overrides:      \(formattedOverrides)")
            }
            if !bottle.config.environmentVariables.isEmpty {
                let envSummary = bottle.config.environmentVariables
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ", ")
                CLIOutput.writeStdout("  Environment Vars:   \(envSummary)")
            }
            CLIOutput.writeStdout("  Pinned/Saved Apps:  \(bottle.apps.count)")
            return 0

        case "rename":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["json"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth bottle rename <name-or-id> <new-name> [--json]")
                return 0
            }
            guard parsed.positionals.count >= 2 else {
                throw CLIError.missingArgument("vermouth bottle rename <name-or-id> <new-name>")
            }
            let existing = try context.bottleStore.findBottle(nameOrID: parsed.positionals[0])
            let updated = try context.bottleStore.renameBottle(id: existing.id, newName: parsed.positionals[1])
            if parsed.isJSON {
                try CLIOutput.printJSON(updated)
            } else {
                CLIOutput.writeStdout("Renamed bottle '\(existing.name)' -> '\(updated.name)' (\(updated.id.uuidString)).")
            }
            return 0

        case "clone":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["json"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth bottle clone <source> <new-name> [--json]")
                return 0
            }
            guard parsed.positionals.count >= 2 else {
                throw CLIError.missingArgument("vermouth bottle clone <source> <new-name>")
            }
            let source = try context.bottleStore.findBottle(nameOrID: parsed.positionals[0])
            let cloned = try context.bottleStore.cloneBottle(id: source.id, newName: parsed.positionals[1])
            if parsed.isJSON {
                try CLIOutput.printJSON(cloned)
            } else {
                CLIOutput.writeStdout("Cloned bottle '\(source.name)' -> '\(cloned.name)' (\(cloned.id.uuidString))")
                CLIOutput.writeStdout("  Prefix: \(cloned.prefixPath)")
            }
            return 0

        case "import":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["copy", "json"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth bottle import <name> <prefix-path> [--copy] [--json]")
                return 0
            }
            guard parsed.positionals.count >= 2 else {
                throw CLIError.missingArgument("vermouth bottle import <name> <prefix-path> [--copy]")
            }
            let copyFiles = parsed.hasFlag("copy")
            let imported = try context.bottleStore.importExistingPrefix(
                name: parsed.positionals[0],
                sourcePrefixPath: parsed.positionals[1],
                copyFiles: copyFiles
            )
            if parsed.isJSON {
                try CLIOutput.printJSON(imported)
            } else {
                let modeLabel = imported.isExternalPrefix
                    ? "reference (external prefix protected from deletion)"
                    : "copied (managed prefix)"
                CLIOutput.writeStdout("Imported bottle '\(imported.name)' (\(imported.id.uuidString)) [\(modeLabel)]")
                CLIOutput.writeStdout("  Prefix: \(imported.prefixPath)")
            }
            return 0

        case "delete":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["keep-prefix"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth bottle delete <name-or-id> [--keep-prefix]")
                return 0
            }
            guard let target = parsed.positionals.first else {
                throw CLIError.missingArgument("vermouth bottle delete <name-or-id> [--keep-prefix]")
            }
            let bottle = try context.bottleStore.findBottle(nameOrID: target)
            let removePrefixFiles = !parsed.hasFlag("keep-prefix")
            try context.bottleStore.deleteBottle(id: bottle.id, removePrefixFiles: removePrefixFiles)

            if bottle.isExternalPrefix {
                CLIOutput.writeStdout("Deleted bottle '\(bottle.name)' metadata (external WINEPREFIX preserved at \(bottle.prefixPath)).")
            } else if !removePrefixFiles {
                CLIOutput.writeStdout("Deleted bottle '\(bottle.name)' metadata (managed WINEPREFIX preserved at \(bottle.prefixPath)).")
            } else {
                CLIOutput.writeStdout("Deleted bottle '\(bottle.name)' (\(bottle.id.uuidString)) and its managed WINEPREFIX.")
            }
            return 0

        case "chinese-fix":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["json"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth bottle chinese-fix <name-or-id> [--json]")
                return 0
            }
            guard let target = parsed.positionals.first else {
                throw CLIError.missingArgument("vermouth bottle chinese-fix <name-or-id>")
            }
            var bottle = try context.bottleStore.findBottle(nameOrID: target)
            bottle.config.locale.chineseLocalizationEnabled = true
            if bottle.config.locale.lcAll.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bottle.config.locale.lcAll = "zh_CN.UTF-8"
            }
            let detectedFont = RegistryPatcher.detectAvailableCJKFont()
            if bottle.config.locale.fallbackFontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bottle.config.locale.fallbackFontName = detectedFont
            }
            bottle.updatedAt = VermouthJSON.currentTimestamp()
            try context.bottleStore.saveBottle(bottle)

            var registrySynced = false
            do {
                let engine = try await context.resolveEngine(for: bottle)
                try await context.wineRunner.applyBottleRegistrySettings(bottle: bottle, engine: engine)
                registrySynced = true
            } catch VermouthError.noEngineAvailable {
                registrySynced = false
            }

            if parsed.isJSON {
                try CLIOutput.printJSON(
                    ChineseFixJSONOutput(
                        bottle: bottle,
                        registrySynced: registrySynced,
                        fallbackFont: bottle.config.locale.fallbackFontName
                    )
                )
            } else if registrySynced {
                CLIOutput.writeStdout(
                    "Enabled Chinese localization (LC_ALL=\(bottle.config.locale.lcAll), font=\(bottle.config.locale.fallbackFontName)) and synced registry for '\(bottle.name)'."
                )
            } else {
                CLIOutput.writeStdout(
                    "Enabled Chinese localization in bottle.json (LC_ALL=\(bottle.config.locale.lcAll), font=\(bottle.config.locale.fallbackFontName)) for '\(bottle.name)'."
                )
                CLIOutput.writeStderr(
                    "warning: no Wine engine available; registry font mapping will be applied once an engine is configured."
                )
            }
            return 0

        case "terminal-script":
            let parsed = try ParsedArguments.parse(rest)
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth bottle terminal-script <name-or-id>")
                return 0
            }
            guard let target = parsed.positionals.first else {
                throw CLIError.missingArgument("vermouth bottle terminal-script <name-or-id>")
            }
            let bottle = try context.bottleStore.findBottle(nameOrID: target)
            let engine = try await context.resolveEngine(for: bottle)
            let graphicsPackage = try context.resolveActiveGraphicsPackage(for: bottle)
            let script = try context.wineRunner.buildInteractiveTerminalScript(
                bottle: bottle,
                engine: engine,
                graphicsPackage: graphicsPackage
            )
            CLIOutput.writeStdoutRaw(script)
            return 0

        case "kill":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["force"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth bottle kill <name-or-id> [--force]")
                return 0
            }
            guard let target = parsed.positionals.first else {
                throw CLIError.missingArgument("vermouth bottle kill <name-or-id> [--force]")
            }
            let bottle = try context.bottleStore.findBottle(nameOrID: target)
            let engine = try await context.resolveEngine(for: bottle)
            let force = parsed.hasFlag("force")
            try await context.wineRunner.killWineServer(for: bottle, engine: engine, force: force)
            CLIOutput.writeStdout("Terminated wineserver for bottle '\(bottle.name)'\(force ? " (forced)" : "").")
            return 0

        default:
            throw CLIError.unknownSubcommand(command: "bottle", subcommand: subcommand)
        }
    }

    private static func printBottleHelp() {
        CLIOutput.writeStdout(
            """
            USAGE:
              vermouth bottle list [--json]
              vermouth bottle create <name> [--win winxp|win7|win10|win11] [--graphics wined3d|dxvk|dxmt] [--sync msync|esync|none] [--engine <id>] [--json]
              vermouth bottle inspect <name-or-id> [--json]
              vermouth bottle rename <name-or-id> <new-name> [--json]
              vermouth bottle clone <source> <new-name> [--json]
              vermouth bottle import <name> <prefix-path> [--copy] [--json]
              vermouth bottle delete <name-or-id> [--keep-prefix]
              vermouth bottle chinese-fix <name-or-id> [--json]
              vermouth bottle terminal-script <name-or-id>
              vermouth bottle kill <name-or-id> [--force]
            """
        )
    }

    // MARK: - 4. Graphics Commands

    static func runGraphics(args: [String], context: CLIContext) async throws -> Int32 {
        guard let subcommand = args.first else {
            printGraphicsHelp()
            return 0
        }
        let rest = Array(args.dropFirst())

        switch subcommand {
        case "--help", "-h", "help":
            printGraphicsHelp()
            return 0

        case "list":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["json"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth graphics list [--json]")
                return 0
            }
            let packages = try context.graphicsManager.listInstalledPackages()
            if parsed.isJSON {
                try CLIOutput.printJSON(packages)
                return 0
            }
            if packages.isEmpty {
                CLIOutput.writeStdout("No external graphics packages installed. Use 'vermouth graphics releases <dxmt|dxvk>' or 'vermouth graphics import'.")
                return 0
            }
            for pkg in packages {
                CLIOutput.writeStdout("- \(pkg.id) [backend=\(pkg.backend.rawValue), format=\(pkg.format.rawValue), version=\(pkg.version)]")
                CLIOutput.writeStdout("    DLLs: \(pkg.containedDLLs.joined(separator: ", "))")
                CLIOutput.writeStdout("    Path: \(pkg.installPath)")
            }
            return 0

        case "releases":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["json"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth graphics releases <dxmt|dxvk> [--json]")
                return 0
            }
            guard let rawBackend = parsed.positionals.first else {
                throw CLIError.missingArgument("vermouth graphics releases <dxmt|dxvk>")
            }
            let backend = try parseExternalGraphicsBackend(rawBackend)
            let releases = try await context.graphicsManager.fetchAvailableReleases(for: backend)
            if parsed.isJSON {
                try CLIOutput.printJSON(releases)
                return 0
            }
            if releases.isEmpty {
                CLIOutput.writeStdout("No downloadable releases found for \(backend.rawValue).")
                return 0
            }
            for release in releases {
                let sizeText = release.sizeBytes.map { CLIOutput.formatByteCount(UInt64(max(0, $0))) } ?? "unknown size"
                CLIOutput.writeStdout("- \(release.tagName) | \(release.assetName) [\(release.format.rawValue), \(sizeText)]")
                CLIOutput.writeStdout("    URL: \(release.downloadURL.absoluteString)")
            }
            return 0

        case "install":
            let parsed = try ParsedArguments.parse(
                rest,
                allowedFlags: ["json"],
                valueOptions: ["tag"]
            )
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth graphics install <dxmt|dxvk> [--tag <tag>] [--json]")
                return 0
            }
            guard let rawBackend = parsed.positionals.first else {
                throw CLIError.missingArgument("vermouth graphics install <dxmt|dxvk> [--tag <tag>]")
            }
            let backend = try parseExternalGraphicsBackend(rawBackend)
            let releases = try await context.graphicsManager.fetchAvailableReleases(for: backend)
            guard !releases.isEmpty else {
                throw CLIError.general("no downloadable releases found for \(backend.rawValue)")
            }

            let selected: RemoteGraphicsRelease
            if let requestedTag = parsed.option("tag") {
                let matching = releases.filter {
                    $0.tagName.caseInsensitiveCompare(requestedTag) == .orderedSame
                }
                guard let chosen = matching.first(where: { backend == .dxmt ? $0.format == .wineBuiltin : true })
                    ?? matching.first
                else {
                    throw CLIError.invalidArgument("no \(backend.rawValue) release matching tag '\(requestedTag)'")
                }
                selected = chosen
            } else {
                selected = releases.first(where: { backend == .dxmt ? $0.format == .wineBuiltin : true })
                    ?? releases[0]
            }

            if !parsed.isJSON {
                CLIOutput.writeStderr("Downloading \(selected.assetName) (\(selected.tagName))...")
            }
            let package = try await context.graphicsManager.installPackage(from: selected, progress: nil)
            if parsed.isJSON {
                try CLIOutput.printJSON(package)
            } else {
                CLIOutput.writeStdout("Installed graphics package '\(package.id)' [\(package.format.rawValue)]")
                CLIOutput.writeStdout("  DLLs: \(package.containedDLLs.joined(separator: ", "))")
                CLIOutput.writeStdout("  Path: \(package.installPath)")
            }
            return 0

        case "import":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["json"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth graphics import <dxmt|dxvk> <version> <archive-path> [--json]")
                return 0
            }
            guard parsed.positionals.count >= 3 else {
                throw CLIError.missingArgument("vermouth graphics import <dxmt|dxvk> <version> <archive-path>")
            }
            let backend = try parseExternalGraphicsBackend(parsed.positionals[0])
            let version = parsed.positionals[1]
            let archivePath = parsed.positionals[2]
            let package = try await context.graphicsManager.importLocalArchive(
                at: archivePath,
                backend: backend,
                version: version
            )
            if parsed.isJSON {
                try CLIOutput.printJSON(package)
            } else {
                CLIOutput.writeStdout("Imported graphics package '\(package.id)' [\(package.format.rawValue)]")
                CLIOutput.writeStdout("  DLLs:   \(package.containedDLLs.joined(separator: ", "))")
                if let sha = package.sha256 {
                    CLIOutput.writeStdout("  SHA256: \(sha)")
                }
                CLIOutput.writeStdout("  Path:   \(package.installPath)")
            }
            return 0

        case "remove":
            let parsed = try ParsedArguments.parse(rest)
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth graphics remove <package-id>")
                return 0
            }
            guard let packageID = parsed.positionals.first else {
                throw CLIError.missingArgument("vermouth graphics remove <package-id>")
            }
            let activeBottles = try context.bottleStore.listBottles()
            try context.graphicsManager.removePackage(id: packageID, activeBottles: activeBottles)
            CLIOutput.writeStdout("Removed graphics package '\(packageID)'.")
            return 0

        case "set":
            let parsed = try ParsedArguments.parse(
                rest,
                allowedFlags: ["json"],
                valueOptions: ["package"]
            )
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth graphics set <bottle> <wined3d|dxvk|dxmt> [--package <id>] [--json]")
                return 0
            }
            guard parsed.positionals.count >= 2 else {
                throw CLIError.missingArgument("vermouth graphics set <bottle> <wined3d|dxvk|dxmt> [--package <id>]")
            }
            let bottle = try context.bottleStore.findBottle(nameOrID: parsed.positionals[0])
            guard let backend = GraphicsBackend(rawValue: parsed.positionals[1].lowercased()) else {
                throw CLIError.invalidArgument(
                    "invalid backend '\(parsed.positionals[1])' (expected: wined3d, dxvk, dxmt)"
                )
            }
            let engine = try await context.resolveEngine(for: bottle)
            let result = try await context.graphicsManager.applyBackend(
                backend,
                packageID: parsed.option("package"),
                to: bottle,
                engine: engine
            )

            if parsed.isJSON {
                try CLIOutput.printJSON(
                    GraphicsApplyJSONOutput(
                        bottle: result.bottle,
                        record: result.record,
                        warnings: result.warnings
                    )
                )
            } else {
                CLIOutput.writeStdout(
                    "Applied graphics backend '\(result.record.backend.rawValue)' to '\(result.bottle.name)' (strategy: \(result.record.strategy.rawValue), package: \(result.record.packageID ?? "builtin"))."
                )
                if !result.record.deployedFiles.isEmpty {
                    CLIOutput.writeStdout(
                        "  Deployed files: \(result.record.deployedFiles.count), backups created: \(result.record.backedUpFiles.count)"
                    )
                }
                if !result.warnings.isEmpty {
                    CLIOutput.printFindings(result.warnings, toStderr: true)
                }
            }
            return 0

        default:
            throw CLIError.unknownSubcommand(command: "graphics", subcommand: subcommand)
        }
    }

    private static func parseExternalGraphicsBackend(_ raw: String) throws -> GraphicsBackend {
        guard let backend = GraphicsBackend(rawValue: raw.lowercased()),
              backend != .wined3d
        else {
            throw CLIError.invalidArgument("invalid graphics backend '\(raw)' (expected: dxmt or dxvk)")
        }
        return backend
    }

    private static func printGraphicsHelp() {
        CLIOutput.writeStdout(
            """
            USAGE:
              vermouth graphics list [--json]
              vermouth graphics releases <dxmt|dxvk> [--json]
              vermouth graphics install <dxmt|dxvk> [--tag <tag>] [--json]
              vermouth graphics import <dxmt|dxvk> <version> <archive-path> [--json]
              vermouth graphics remove <package-id>
              vermouth graphics set <bottle> <wined3d|dxvk|dxmt> [--package <id>] [--json]
            """
        )
    }

    // MARK: - 5. Run Command

    static func runExecutable(args: [String], context: CLIContext) async throws -> Int32 {
        let parsed = try ParsedArguments.parse(
            args,
            allowedFlags: ["dry-run", "json"],
            valueOptions: ["debug"]
        )
        if parsed.isHelp {
            CLIOutput.writeStdout(
                "Usage: vermouth run <bottle> <exe-or-msi-path> [--dry-run] [--debug <channels>] [--json] [-- <args...>]"
            )
            return 0
        }
        guard parsed.positionals.count >= 2 else {
            throw CLIError.missingArgument(
                "vermouth run <bottle> <exe-or-msi-path> [--dry-run] [--debug <channels>] [-- <args...>]"
            )
        }

        let bottleIdentifier = parsed.positionals[0]
        let targetPath = parsed.positionals[1]
        let trailingPositionals = Array(parsed.positionals.dropFirst(2))
        let extraArgs = trailingPositionals + parsed.passthrough

        let bottle = try context.bottleStore.findBottle(nameOrID: bottleIdentifier)
        let engine = try await context.resolveEngine(for: bottle)
        let graphicsPackage = try context.resolveActiveGraphicsPackage(for: bottle)

        let target: LaunchTarget = targetPath.lowercased().hasSuffix(".msi")
            ? .installer(path: targetPath)
            : .executable(path: targetPath, workingDirectory: nil)

        let plan = try await context.wineRunner.buildLaunchPlan(
            bottle: bottle,
            engine: engine,
            target: target,
            graphicsPackage: graphicsPackage,
            extraArgs: extraArgs,
            debugChannelsOverride: parsed.option("debug")
        )

        if parsed.hasFlag("dry-run") {
            if parsed.isJSON {
                try CLIOutput.printJSON(plan)
            } else {
                if !plan.warnings.isEmpty {
                    CLIOutput.printFindings(plan.warnings, toStderr: true)
                    CLIOutput.writeStderr("")
                }
                CLIOutput.writeStdout("Working Directory: \(plan.workingDirectory)")
                CLIOutput.writeStdout("Log File:          \(plan.logFilePath)")
                CLIOutput.writeStdout("Command:")
                CLIOutput.writeStdout(plan.shellCommandPreview)
            }
            return 0
        }

        if !plan.warnings.isEmpty {
            CLIOutput.printFindings(plan.warnings, toStderr: true)
        }

        try await context.wineRunner.ensurePrefixInitialized(bottle: bottle, engine: engine)
        let session = context.wineRunner.launch(plan)

        let maxBufferedLines = 20_000
        var collectedLogs: [String] = []
        var exitCode: Int32 = 0

        for try await logLine in session.stream {
            switch logLine.stream {
            case .stdout:
                CLIOutput.writeStdout(logLine.text)
                appendCapped(logLine.text, to: &collectedLogs, limit: maxBufferedLines)
            case .stderr:
                CLIOutput.writeStderr(logLine.text)
                appendCapped(logLine.text, to: &collectedLogs, limit: maxBufferedLines)
            case .system:
                if let code = logLine.exitCode {
                    exitCode = code
                }
            }
        }

        if exitCode != 0 {
            let findings = context.diagnoser.diagnose(
                logs: collectedLogs,
                preflightWarnings: plan.warnings
            )
            CLIOutput.writeStderr("")
            CLIOutput.writeStderr("Process exited with code \(exitCode). Log saved to: \(session.logFilePath)")
            if !findings.isEmpty {
                CLIOutput.writeStderr("Crash Diagnostics:")
                CLIOutput.printFindings(findings, toStderr: true)
            }
        }

        return exitCode
    }

    private static func appendCapped(_ line: String, to buffer: inout [String], limit: Int) {
        if buffer.count >= limit {
            buffer.removeFirst(buffer.count - limit + 1)
        }
        buffer.append(line)
    }

    // MARK: - 6. Scan & Diagnose

    static func runScan(args: [String], context: CLIContext) throws -> Int32 {
        let parsed = try ParsedArguments.parse(args, allowedFlags: ["json"])
        if parsed.isHelp {
            CLIOutput.writeStdout("Usage: vermouth scan <bottle> [--json]")
            return 0
        }
        guard let target = parsed.positionals.first else {
            throw CLIError.missingArgument("vermouth scan <bottle> [--json]")
        }
        let bottle = try context.bottleStore.findBottle(nameOrID: target)
        let executables = try context.scanner.scan(prefixPath: bottle.prefixPath)
        if parsed.isJSON {
            try CLIOutput.printJSON(executables)
            return 0
        }
        if executables.isEmpty {
            CLIOutput.writeStdout("No executables discovered in bottle '\(bottle.name)'.")
            return 0
        }
        for exe in executables {
            let argsSuffix = exe.arguments.isEmpty ? "" : " (args: \(exe.arguments.joined(separator: " ")))"
            CLIOutput.writeStdout("- \(exe.name) [\(exe.architecture.rawValue), \(exe.source.rawValue)]\(argsSuffix)")
            CLIOutput.writeStdout("    \(exe.executablePath)")
        }
        return 0
    }

    static func runDiagnose(args: [String], context: CLIContext) throws -> Int32 {
        let parsed = try ParsedArguments.parse(args, allowedFlags: ["json"])
        if parsed.isHelp {
            CLIOutput.writeStdout("Usage: vermouth diagnose <log-file-path> [--json]")
            return 0
        }
        guard let rawPath = parsed.positionals.first else {
            throw CLIError.missingArgument("vermouth diagnose <log-file-path> [--json]")
        }
        let expandedPath = CLIOutput.expandTilde(rawPath)
        let fileURL = URL(fileURLWithPath: expandedPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CLIError.fileNotFound(fileURL.path)
        }

        let data = try Data(contentsOf: fileURL)
        // Lossy UTF-8 decoding handles GBK/Shift-JIS Wine log lines safely (L-009)
        let content = String(decoding: data, as: UTF8.self)
        let lines = content.split(whereSeparator: \.isNewline).map(String.init)
        let findings = context.diagnoser.diagnose(logs: lines, preflightWarnings: [])

        if parsed.isJSON {
            try CLIOutput.printJSON(findings)
            return 0
        }
        if findings.isEmpty {
            CLIOutput.writeStdout("No known crash patterns detected in \(fileURL.lastPathComponent).")
            return 0
        }
        CLIOutput.printFindings(findings, toStderr: false)
        return 0
    }

    // MARK: - 7. Snapshot Commands

    static func runSnapshot(args: [String], context: CLIContext) throws -> Int32 {
        guard let subcommand = args.first else {
            printSnapshotHelp()
            return 0
        }
        let rest = Array(args.dropFirst())

        switch subcommand {
        case "--help", "-h", "help":
            printSnapshotHelp()
            return 0

        case "create":
            let parsed = try ParsedArguments.parse(
                rest,
                allowedFlags: ["json"],
                valueOptions: ["label", "note"]
            )
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth snapshot create <bottle> <path> [--label <name>] [--note <text>] [--json]")
                return 0
            }
            guard parsed.positionals.count >= 2 else {
                throw CLIError.missingArgument("vermouth snapshot create <bottle> <path> [--label <name>] [--note <text>]")
            }
            let bottle = try context.bottleStore.findBottle(nameOrID: parsed.positionals[0])
            let targetPath = parsed.positionals[1]
            let defaultLabel = URL(fileURLWithPath: targetPath).lastPathComponent
            let label = parsed.option("label") ?? (defaultLabel.isEmpty ? "snapshot" : defaultLabel)
            let target = SnapshotTarget(label: label, path: targetPath)
            let record = try context.snapshotManager.createSnapshot(
                bottleID: bottle.id,
                target: target,
                note: parsed.option("note")
            )
            if parsed.isJSON {
                try CLIOutput.printJSON(record)
            } else {
                CLIOutput.writeStdout("Created snapshot \(record.id.uuidString) for '\(bottle.name)'")
                CLIOutput.writeStdout("  Label:   \(record.label)")
                CLIOutput.writeStdout("  Source:  \(record.sourcePath)")
                CLIOutput.writeStdout("  Files:   \(record.fileCount) (\(CLIOutput.formatByteCount(record.totalBytes)))")
                CLIOutput.writeStdout("  SHA-256: \(record.sha256)")
            }
            return 0

        case "list":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["json"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth snapshot list <bottle> [--json]")
                return 0
            }
            guard let bottleArg = parsed.positionals.first else {
                throw CLIError.missingArgument("vermouth snapshot list <bottle> [--json]")
            }
            let bottle = try context.bottleStore.findBottle(nameOrID: bottleArg)
            let records = try context.snapshotManager.listSnapshots(bottleID: bottle.id, targetID: nil)
            if parsed.isJSON {
                try CLIOutput.printJSON(records)
                return 0
            }
            if records.isEmpty {
                CLIOutput.writeStdout("No snapshots found for bottle '\(bottle.name)'.")
                return 0
            }
            for record in records {
                let noteSuffix = record.note.map { " — \($0)" } ?? ""
                CLIOutput.writeStdout(
                    "- \(record.id.uuidString) | \(record.label) [\(record.fileCount) files, \(CLIOutput.formatByteCount(record.totalBytes))]\(noteSuffix)"
                )
                CLIOutput.writeStdout("    Source: \(record.sourcePath)")
                CLIOutput.writeStdout("    SHA256: \(record.sha256)")
            }
            return 0

        case "rollback":
            let parsed = try ParsedArguments.parse(
                rest,
                allowedFlags: ["json"],
                valueOptions: ["to"]
            )
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth snapshot rollback <bottle> <snapshot-id> [--to <override-path>] [--json]")
                return 0
            }
            guard parsed.positionals.count >= 2 else {
                throw CLIError.missingArgument("vermouth snapshot rollback <bottle> <snapshot-id> [--to <override-path>]")
            }
            let bottle = try context.bottleStore.findBottle(nameOrID: parsed.positionals[0])
            let snapshotID = try resolveSnapshotID(
                rawID: parsed.positionals[1],
                bottleID: bottle.id,
                context: context
            )
            let safetyBackup = try context.snapshotManager.rollback(
                bottleID: bottle.id,
                snapshotID: snapshotID,
                destinationOverride: parsed.option("to")
            )
            if parsed.isJSON {
                try CLIOutput.printJSON(safetyBackup)
            } else {
                CLIOutput.writeStdout("Rolled back snapshot \(snapshotID.uuidString) for '\(bottle.name)'.")
                CLIOutput.writeStdout("  Auto safety backup created: \(safetyBackup.id.uuidString) (\(safetyBackup.label))")
            }
            return 0

        case "delete":
            let parsed = try ParsedArguments.parse(rest)
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth snapshot delete <bottle> <snapshot-id>")
                return 0
            }
            guard parsed.positionals.count >= 2 else {
                throw CLIError.missingArgument("vermouth snapshot delete <bottle> <snapshot-id>")
            }
            let bottle = try context.bottleStore.findBottle(nameOrID: parsed.positionals[0])
            let snapshotID = try resolveSnapshotID(
                rawID: parsed.positionals[1],
                bottleID: bottle.id,
                context: context
            )
            try context.snapshotManager.deleteSnapshot(bottleID: bottle.id, snapshotID: snapshotID)
            CLIOutput.writeStdout("Deleted snapshot \(snapshotID.uuidString).")
            return 0

        default:
            throw CLIError.unknownSubcommand(command: "snapshot", subcommand: subcommand)
        }
    }

    private static func resolveSnapshotID(
        rawID: String,
        bottleID: UUID,
        context: CLIContext
    ) throws -> UUID {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = UUID(uuidString: trimmed) {
            return exact
        }
        let lowerPrefix = trimmed.lowercased()
        let records = try context.snapshotManager.listSnapshots(bottleID: bottleID, targetID: nil)
        let matches = records.filter { $0.id.uuidString.lowercased().hasPrefix(lowerPrefix) }
        if matches.count == 1 {
            return matches[0].id
        }
        if matches.count > 1 {
            throw CLIError.invalidArgument("ambiguous snapshot ID prefix '\(rawID)' (matched \(matches.count) snapshots)")
        }
        throw CLIError.invalidArgument("invalid or unknown snapshot ID '\(rawID)'")
    }

    private static func printSnapshotHelp() {
        CLIOutput.writeStdout(
            """
            USAGE:
              vermouth snapshot create <bottle> <path> [--label <name>] [--note <text>] [--json]
              vermouth snapshot list <bottle> [--json]
              vermouth snapshot rollback <bottle> <snapshot-id> [--to <override-path>] [--json]
              vermouth snapshot delete <bottle> <snapshot-id>
            """
        )
    }

    // MARK: - 8. Recipes (Built-in CI Smoke Alias & Full Recipe Commands)

    /// Preserves exact output format expected by `.github/workflows/ci.yml` bundled resource smoke check (L-013).
    static func runBuiltInRecipesSmoke() -> Int32 {
        guard let directory = VermouthResourceLocator.builtInRecipesDirectory() else {
            CLIOutput.writeStderr("error: could not locate built-in recipes directory.")
            return 1
        }

        let files = VermouthResourceLocator.builtInRecipeFiles()
        guard !files.isEmpty else {
            CLIOutput.writeStderr("error: no built-in .recipe.json files found in \(directory.path).")
            return 1
        }

        CLIOutput.writeStdout("Built-in recipes directory: \(directory.path)")
        CLIOutput.writeStdout("Discovered \(files.count) built-in recipe(s):")

        for fileURL in files {
            do {
                let recipe = try VermouthJSON.read(Recipe.self, from: fileURL)
                guard recipe.schemaVersion <= Recipe.currentSchemaVersion else {
                    CLIOutput.writeStderr(
                        "error: unsupported recipe schemaVersion \(recipe.schemaVersion) in \(fileURL.lastPathComponent)"
                    )
                    return 1
                }
                CLIOutput.writeStdout(
                    "  - \(recipe.id) | \(recipe.name) [arch=\(recipe.targetArchitecture.rawValue), backend=\(recipe.recommendedBackend.rawValue), sync=\(recipe.recommendedSyncMode.rawValue)] (\(fileURL.lastPathComponent))"
                )
            } catch {
                CLIOutput.writeStderr("error: failed to decode recipe \(fileURL.path): \(error.localizedDescription)")
                return 1
            }
        }

        return 0
    }

    static func runRecipe(args: [String], context: CLIContext) async throws -> Int32 {
        guard let subcommand = args.first else {
            printRecipeHelp()
            return 0
        }
        let rest = Array(args.dropFirst())

        switch subcommand {
        case "--help", "-h", "help":
            printRecipeHelp()
            return 0

        case "list":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["json"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth recipe list [--json]")
                return 0
            }
            let recipes = try context.recipeEngine.listRecipes()
            if parsed.isJSON {
                try CLIOutput.printJSON(recipes)
                return 0
            }
            if recipes.isEmpty {
                CLIOutput.writeStdout("No recipes available.")
                return 0
            }
            for recipe in recipes {
                CLIOutput.writeStdout(
                    "- \(recipe.id) | \(recipe.name) [arch=\(recipe.targetArchitecture.rawValue), win=\(recipe.recommendedWindowsVersion.rawValue), backend=\(recipe.recommendedBackend.rawValue), sync=\(recipe.recommendedSyncMode.rawValue)]"
                )
                CLIOutput.writeStdout("    \(recipe.summary)")
            }
            return 0

        case "apply":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["json"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth recipe apply <bottle> <recipe-id-or-path> [--json]")
                return 0
            }
            guard parsed.positionals.count >= 2 else {
                throw CLIError.missingArgument("vermouth recipe apply <bottle> <recipe-id-or-path>")
            }
            let bottle = try context.bottleStore.findBottle(nameOrID: parsed.positionals[0])
            let recipe = try context.recipeEngine.loadRecipe(from: parsed.positionals[1])
            let engine = try? await context.resolveEngine(for: bottle)

            let plan = context.recipeEngine.planApplication(of: recipe, to: bottle, engine: engine)
            try context.bottleStore.saveBottle(plan.updatedBottle)

            if parsed.isJSON {
                try CLIOutput.printJSON(
                    RecipeApplyJSONOutput(
                        recipe: recipe,
                        bottle: plan.updatedBottle,
                        requiresGraphicsBackendChange: plan.requiresGraphicsBackendChange,
                        requiresRegistrySync: plan.requiresRegistrySync,
                        requiresWineServerRestart: plan.requiresWineServerRestart,
                        warnings: plan.warnings
                    )
                )
            } else {
                CLIOutput.writeStdout("Applied recipe '\(recipe.id)' (\(recipe.name)) to bottle '\(plan.updatedBottle.name)'.")
                CLIOutput.writeStdout(
                    "  Updated config: win=\(plan.updatedBottle.config.windowsVersion.rawValue), backend=\(plan.updatedBottle.config.graphicsBackend.rawValue), sync=\(plan.updatedBottle.config.syncMode.rawValue), chinese=\(plan.updatedBottle.config.locale.chineseLocalizationEnabled)"
                )
                if plan.requiresGraphicsBackendChange {
                    CLIOutput.writeStdout(
                        "  Next step: deploy graphics backend with 'vermouth graphics set \(ShellQuoting.posixEscape(plan.updatedBottle.name)) \(recipe.recommendedBackend.rawValue)'."
                    )
                }
                if plan.requiresRegistrySync {
                    CLIOutput.writeStdout("  Note: registry settings (Windows version / CJK fonts) will take effect after syncing registry.")
                }
                if plan.requiresWineServerRestart {
                    CLIOutput.writeStdout("  Note: restart bottle wineserver ('vermouth bottle kill ...') before next launch if running.")
                }
                if !plan.warnings.isEmpty {
                    CLIOutput.printFindings(plan.warnings, toStderr: true)
                }
            }
            return 0

        case "import":
            let parsed = try ParsedArguments.parse(rest, allowedFlags: ["json"])
            if parsed.isHelp {
                CLIOutput.writeStdout("Usage: vermouth recipe import <file-path> [--json]")
                return 0
            }
            guard let filePath = parsed.positionals.first else {
                throw CLIError.missingArgument("vermouth recipe import <file-path>")
            }
            let imported = try context.recipeEngine.importRecipeFile(at: filePath)
            if parsed.isJSON {
                try CLIOutput.printJSON(imported)
            } else {
                CLIOutput.writeStdout("Imported recipe '\(imported.id)' (\(imported.name)).")
            }
            return 0

        case "export":
            let parsed = try ParsedArguments.parse(
                rest,
                allowedFlags: ["json"],
                valueOptions: ["id", "name", "summary"]
            )
            if parsed.isHelp {
                CLIOutput.writeStdout(
                    "Usage: vermouth recipe export <bottle> <output-path> --id <id> --name <name> [--summary <text>] [--json]"
                )
                return 0
            }
            guard parsed.positionals.count >= 2 else {
                throw CLIError.missingArgument(
                    "vermouth recipe export <bottle> <output-path> --id <id> --name <name> [--summary <text>]"
                )
            }
            guard let id = parsed.option("id"), !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError.missingArgument("--id <id> is required")
            }
            guard let name = parsed.option("name"), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError.missingArgument("--name <name> is required")
            }

            let bottle = try context.bottleStore.findBottle(nameOrID: parsed.positionals[0])
            let outputPath = CLIOutput.expandTilde(parsed.positionals[1])
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            let summary = parsed.option("summary") ?? "Exported from Vermouth bottle '\(bottle.name)'"

            let recipe = context.recipeEngine.exportSanitizedRecipe(
                from: bottle,
                id: id,
                name: name,
                summary: summary
            )
            try VermouthJSON.writeAtomically(recipe, to: outputURL)

            if parsed.isJSON {
                try CLIOutput.printJSON(recipe)
            } else {
                CLIOutput.writeStdout("Exported sanitized recipe '\(recipe.id)' to \(outputURL.path).")
            }
            return 0

        default:
            throw CLIError.unknownSubcommand(command: "recipe", subcommand: subcommand)
        }
    }

    private static func printRecipeHelp() {
        CLIOutput.writeStdout(
            """
            USAGE:
              vermouth recipes
              vermouth recipe list [--json]
              vermouth recipe apply <bottle> <recipe-id-or-path> [--json]
              vermouth recipe import <file-path> [--json]
              vermouth recipe export <bottle> <output-path> --id <id> --name <name> [--summary <text>] [--json]
            """
        )
    }
}

// MARK: - CLI JSON Wrapper DTOs

private struct ChineseFixJSONOutput: Encodable, Sendable {
    let bottle: Bottle
    let registrySynced: Bool
    let fallbackFont: String
}

private struct GraphicsApplyJSONOutput: Encodable, Sendable {
    let bottle: Bottle
    let record: GraphicsDeploymentRecord
    let warnings: [DiagnosticFinding]
}

private struct RecipeApplyJSONOutput: Encodable, Sendable {
    let recipe: Recipe
    let bottle: Bottle
    let requiresGraphicsBackendChange: Bool
    let requiresRegistrySync: Bool
    let requiresWineServerRestart: Bool
    let warnings: [DiagnosticFinding]
}
