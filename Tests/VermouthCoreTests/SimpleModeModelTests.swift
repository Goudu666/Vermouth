import Foundation
import XCTest

@testable import VermouthCore

/// 普通模式（「点开就能玩」）背后的 Core 逻辑：环境准备规划、拖入文件识别、运行结果判断。
final class EnvironmentSetupPlannerTests: XCTestCase {
    private func engine(quarantined: Bool = false, id: String = "app-wine-stable") -> WineEngine {
        WineEngine(
            id: id,
            name: "Wine Stable",
            rootPath: "/Applications/Wine Stable.app/Contents/Resources/wine",
            wineBinaryPath: "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine",
            wineserverPath: "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wineserver",
            version: "wine-11.0",
            source: .custom,
            capabilities: EngineCapabilities(
                supports32Bit: true,
                supports64Bit: true,
                isNewWoW64: true,
                supportsMSync: true,
                supportsWineDLLPathPrepend: true
            ),
            isQuarantined: quarantined
        )
    }

    private func report(
        rosetta: Bool = true,
        homebrew: String? = "/opt/homebrew/bin/brew",
        winetricks: String? = "/opt/homebrew/bin/winetricks",
        engines: [WineEngine]
    ) -> PreflightReport {
        PreflightReport(
            checkedAt: Date(timeIntervalSince1970: 1_700_000_000),
            architecture: .arm64,
            osVersion: OSVersionInfo(major: 15, minor: 1, patch: 0, displayString: "macOS 15.1"),
            rosetta2Ready: rosetta,
            homebrewPath: homebrew,
            winetricksPath: winetricks,
            discoveredEngines: engines,
            items: [],
            isReadyToLaunch: rosetta && !engines.isEmpty
        )
    }

    func testFreshMacNeedsEverythingInDependencyOrder() throws {
        let fresh = report(rosetta: false, homebrew: nil, winetricks: nil, engines: [])
        let steps = EnvironmentSetupPlanner.steps(for: fresh)
        XCTAssertEqual(steps.map(\.kind), [.rosetta, .homebrew, .wineEngine, .winetricks])
        XCTAssertEqual(steps.filter(\.isRequired).map(\.kind), [.rosetta, .homebrew, .wineEngine])
        XCTAssertFalse(EnvironmentSetupPlanner.isReady(fresh))

        let script = try XCTUnwrap(EnvironmentSetupPlanner.terminalScript(for: steps))
        let rosetta = try XCTUnwrap(script.range(of: "softwareupdate --install-rosetta"))
        let brew = try XCTUnwrap(script.range(of: "Homebrew/install/HEAD/install.sh"))
        let wine = try XCTUnwrap(script.range(of: "brew install --cask gcenx/wine/wine-stable"))
        let tricks = try XCTUnwrap(script.range(of: "brew install winetricks"))
        XCTAssertTrue(rosetta.lowerBound < brew.lowerBound)
        XCTAssertTrue(brew.lowerBound < wine.lowerBound)
        XCTAssertTrue(wine.lowerBound < tricks.lowerBound)
        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.contains("set -e"))
        XCTAssertTrue(script.contains("[1/4]") && script.contains("[4/4]"))
        // 刚装好的 Homebrew 不在 PATH 上，必须先载入 shellenv
        let shellenv = try XCTUnwrap(script.range(of: "brew shellenv"))
        XCTAssertTrue(shellenv.lowerBound < wine.lowerBound)
    }

    func testScriptNeverUsesRemovedHomebrewFlags() throws {
        let script = try XCTUnwrap(
            EnvironmentSetupPlanner.terminalScript(
                for: EnvironmentSetupPlanner.steps(for: report(homebrew: nil, winetricks: nil, engines: []))
            )
        )
        // L-019
        XCTAssertFalse(script.contains("--no-quarantine"))
        XCTAssertTrue(script.contains("xattr -dr com.apple.quarantine \"/Applications/Wine Stable.app\""))
    }

    func testReadyMacHasNoSteps() {
        let ready = report(engines: [engine()])
        XCTAssertTrue(EnvironmentSetupPlanner.steps(for: ready).isEmpty)
        XCTAssertTrue(EnvironmentSetupPlanner.isReady(ready))
        XCTAssertNil(EnvironmentSetupPlanner.terminalScript(for: []))
    }

    func testMissingWinetricksIsOptional() {
        let ready = report(winetricks: nil, engines: [engine()])
        let steps = EnvironmentSetupPlanner.steps(for: ready)
        XCTAssertEqual(steps.map(\.kind), [.winetricks])
        XCTAssertFalse(steps[0].isRequired)
        XCTAssertTrue(EnvironmentSetupPlanner.isReady(ready))
    }

    func testQuarantinedOnlyEngineIsFixedInAppNotTerminal() {
        let blocked = report(engines: [engine(quarantined: true)])
        let steps = EnvironmentSetupPlanner.steps(for: blocked)
        XCTAssertEqual(steps.map(\.kind), [.unquarantineEngine])
        XCTAssertTrue(steps[0].isRequired)
        XCTAssertFalse(steps[0].runsInTerminal)
        XCTAssertEqual(steps[0].engineID, "app-wine-stable")
        XCTAssertFalse(EnvironmentSetupPlanner.isReady(blocked))
        XCTAssertNil(EnvironmentSetupPlanner.terminalScript(for: steps))
    }

    func testQuarantinedSecondaryEngineIsOptional() {
        let mixed = report(engines: [engine(), engine(quarantined: true, id: "app-crossover")])
        let steps = EnvironmentSetupPlanner.steps(for: mixed)
        XCTAssertEqual(steps.count, 1)
        XCTAssertFalse(steps[0].isRequired)
        XCTAssertTrue(EnvironmentSetupPlanner.isReady(mixed))
    }

    func testHomebrewPresentSkipsHomebrewStep() {
        let steps = EnvironmentSetupPlanner.steps(for: report(engines: []))
        XCTAssertEqual(steps.map(\.kind), [.wineEngine])
    }
}

final class ProgramFileClassifierTests: XCTestCase {
    func testInstallersAreRecognised() {
        XCTAssertEqual(ProgramFileClassifier.classify(fileName: "game.msi"), .installer)
        XCTAssertEqual(ProgramFileClassifier.classify(fileName: "SteamSetup.exe"), .installer)
        XCTAssertEqual(ProgramFileClassifier.classify(fileName: "GTA_SA-Installer.EXE"), .installer)
        XCTAssertEqual(ProgramFileClassifier.classify(fileName: "微信安装包.exe"), .installer)
        XCTAssertEqual(ProgramFileClassifier.classify(fileName: "vc_redist.x64.exe"), .installer)
    }

    func testPortableProgramsAreApplications() {
        XCTAssertEqual(ProgramFileClassifier.classify(fileName: "gta_sa.exe"), .application)
        XCTAssertEqual(ProgramFileClassifier.classify(fileName: "Notepad++.exe"), .application)
    }

    func testUnsupportedFilesAreRejected() {
        XCTAssertNil(ProgramFileClassifier.classify(fileName: "readme.txt"))
        XCTAssertNil(ProgramFileClassifier.classify(fileName: "Game.app"))
        XCTAssertNil(ProgramFileClassifier.classify(fileName: "exe"))
    }

    func testHelperExecutablesAreSkipped() {
        XCTAssertTrue(ProgramFileClassifier.isHelperExecutable(fileName: "unins000.exe"))
        XCTAssertTrue(ProgramFileClassifier.isHelperExecutable(fileName: "UnityCrashHandler64.exe"))
        XCTAssertFalse(ProgramFileClassifier.isHelperExecutable(fileName: "gta_sa.exe"))
    }

    func testDisplayNameDropsInstallerNoise() {
        XCTAssertEqual(ProgramFileClassifier.suggestedDisplayName(forFileName: "GTA_San_Andreas-Setup_v1.0.exe"), "GTA San Andreas")
        XCTAssertEqual(ProgramFileClassifier.suggestedDisplayName(forFileName: "SteamSetup.exe"), "SteamSetup")
        XCTAssertEqual(ProgramFileClassifier.suggestedDisplayName(forFileName: "setup.exe"), "setup")
        XCTAssertEqual(ProgramFileClassifier.suggestedDisplayName(forFileName: "Witcher3_x64.exe"), "Witcher3")
    }

    func testDisplayNamePrefersMeaningfulFolder() {
        XCTAssertEqual(
            ProgramFileClassifier.suggestedDisplayName(forFileAt: "/Users/a/Games/GTA San Andreas/gta_sa.exe"),
            "GTA San Andreas"
        )
        XCTAssertEqual(
            ProgramFileClassifier.suggestedDisplayName(forFileAt: "/Users/a/Games/Hades/Binaries/Win64/Hades.exe"),
            "Hades"
        )
        XCTAssertEqual(
            ProgramFileClassifier.suggestedDisplayName(forFileAt: "/Users/a/Downloads/putty.exe"),
            "putty"
        )
        // 安装程序不用文件夹名（通常就在 Downloads 里，文件名更有信息量）
        XCTAssertEqual(
            ProgramFileClassifier.suggestedDisplayName(forFileAt: "/Users/a/Stuff/Office_Setup.exe"),
            "Office"
        )
    }
}

final class LaunchOutcomeTests: XCTestCase {
    private func finding(_ id: String, _ severity: DiagnosticSeverity) -> DiagnosticFinding {
        DiagnosticFinding(
            id: id,
            category: .missingDLL,
            severity: severity,
            title: id,
            explanation: "",
            suggestion: ""
        )
    }

    func testCleanExitIsQuiet() {
        let outcome = LaunchOutcomeEvaluator.evaluate(exitCode: 0, wasStopped: false, newFindings: [finding("i", .info)])
        XCTAssertEqual(outcome, .finished)
        XCTAssertFalse(outcome.shouldNotifyUser)
    }

    func testUserStopIsQuietEvenWithNonZeroExit() {
        let outcome = LaunchOutcomeEvaluator.evaluate(exitCode: 137, wasStopped: true, newFindings: [finding("e", .error)])
        XCTAssertEqual(outcome, .stopped)
        XCTAssertFalse(outcome.shouldNotifyUser)
    }

    func testCleanExitWithWarningsNeedsAttention() {
        let outcome = LaunchOutcomeEvaluator.evaluate(
            exitCode: 0,
            wasStopped: false,
            newFindings: [finding("w", .warning), finding("i", .info)]
        )
        XCTAssertEqual(outcome, .needsAttention(findingCount: 1))
        XCTAssertTrue(outcome.shouldNotifyUser)
    }

    func testNonZeroOrMissingExitIsCrash() {
        XCTAssertEqual(
            LaunchOutcomeEvaluator.evaluate(exitCode: 1, wasStopped: false, newFindings: [finding("e", .error)]),
            .crashed(exitCode: 1, findingCount: 1)
        )
        XCTAssertEqual(
            LaunchOutcomeEvaluator.evaluate(exitCode: nil, wasStopped: false, newFindings: []),
            .crashed(exitCode: nil, findingCount: 0)
        )
    }

    func testHeadlinesAreFriendly() {
        XCTAssertEqual(LaunchOutcome.crashed(exitCode: 1, findingCount: 0).headline(programName: "GTA"), "「GTA」意外退出了")
        XCTAssertEqual(
            LaunchOutcome.crashed(exitCode: 1, findingCount: 2).headline(programName: "GTA"),
            "「GTA」没能正常运行，找到了 2 个可能的原因"
        )
    }
}

final class InstalledProgramAdopterTests: XCTestCase {
    private func exec(_ path: String, _ source: DiscoveredExecutable.DiscoverySource, name: String? = nil) -> DiscoveredExecutable {
        DiscoveredExecutable(
            name: name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            executablePath: path,
            source: source
        )
    }

    func testShortcutsWinOverLooseExecutables() {
        let before = [exec("/p/drive_c/windows/notepad.exe", .programFilesScan)]
        let after = before + [
            exec("/p/drive_c/Program Files/Game/Game.exe", .startMenuShortcut, name: "My Game"),
            exec("/p/drive_c/Program Files/Game/Tool.exe", .programFilesScan),
            exec("/p/drive_c/Program Files/Game/unins000.exe", .programFilesScan),
        ]
        XCTAssertEqual(InstalledProgramAdopter.programsToAdopt(before: before, after: after).map(\.name), ["My Game"])
    }

    func testFewLooseExecutablesAreAdoptedAndHelpersSkipped() {
        let after = [
            exec("/p/drive_c/Program Files/App/App.exe", .programFilesScan),
            exec("/p/drive_c/Program Files/App/Uninstall.exe", .programFilesScan),
        ]
        XCTAssertEqual(InstalledProgramAdopter.programsToAdopt(before: [], after: after).map(\.name), ["App"])
    }

    func testTooManyLooseExecutablesAreLeftForTheUser() {
        let after = (1...5).map { exec("/p/drive_c/Program Files/Suite/tool\($0).exe", .programFilesScan) }
        XCTAssertTrue(InstalledProgramAdopter.programsToAdopt(before: [], after: after).isEmpty)
    }

    func testNothingNewMeansNothingAdopted() {
        let same = [exec("/p/drive_c/Program Files/Game/Game.exe", .desktopShortcut)]
        XCTAssertTrue(InstalledProgramAdopter.programsToAdopt(before: same, after: same).isEmpty)
    }

    func testDuplicateShortcutsCollapse() {
        let after = [
            exec("/p/drive_c/Program Files/Game/Game.exe", .startMenuShortcut, name: "Game"),
            exec("/P/drive_c/Program Files/Game/GAME.exe", .desktopShortcut, name: "Game"),
        ]
        XCTAssertEqual(InstalledProgramAdopter.programsToAdopt(before: [], after: after).count, 1)
    }
}
