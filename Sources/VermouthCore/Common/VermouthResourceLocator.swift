import Foundation

/// Locates read-only bundled resources (such as built-in `.recipe.json` files) across
/// packaged macOS `.app` bundles, standalone CLI executables, `swift test`, and source trees.
///
/// Always probes `Bundle.main.resourceURL` and executable-relative paths before touching
/// SwiftPM's `Bundle.module` so non-Xcode `.app` bundles never trigger `Bundle.module`'s `fatalError`.
/// When executing inside a `.app` bundle, source-tree `#filePath` fallback is strictly disabled
/// so missing or misplaced bundle resources fail loudly.
public enum VermouthResourceLocator: Sendable {
    private static let resourceBundleNames = [
        "Vermouth_VermouthCore.bundle",
        "Vermouth_VermouthCore.resources",
    ]
    private static let recipeFileSuffix = ".recipe.json"

    private final class BundleAnchor: Sendable {}

    /// Returns the directory containing built-in `.recipe.json` files, or `nil` if unavailable.
    public static func builtInRecipesDirectory() -> URL? {
        // 1. Check Bundle.main.resourceURL and executable-relative paths first so packaged
        //    `.app` bundles and bundled companion CLI binaries never hit Bundle.module's fatalError.
        for candidate in primaryBundleCandidates() {
            if !recipeFiles(in: candidate).isEmpty {
                return candidate
            }
        }

        // Inside a packaged `.app` bundle, strictly disable Bundle.module and `#filePath`
        // fallbacks so broken packaging cannot be silently masked by a local source tree.
        if isRunningInsideAppBundle() {
            return nil
        }

        // 2. Check SwiftPM / test bundle paths when not executing inside a `.app` bundle.
        for candidate in secondaryBundleCandidates() {
            if !recipeFiles(in: candidate).isEmpty {
                return candidate
            }
        }

        // 3. Fallback to the source-tree relative directory via `#filePath` (non-.app dev/test only).
        let sourceFallback = sourceTreeRecipesDirectory()
        if !recipeFiles(in: sourceFallback).isEmpty {
            return sourceFallback
        }
        if directoryExists(at: sourceFallback) {
            return sourceFallback
        }

        return nil
    }

    /// Returns all built-in `.recipe.json` files sorted lexicographically by filename.
    public static func builtInRecipeFiles() -> [URL] {
        guard let directory = builtInRecipesDirectory() else {
            return []
        }
        return recipeFiles(in: directory)
    }

    // MARK: - Candidate Resolution

    private static func isRunningInsideAppBundle() -> Bool {
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            return true
        }
        if let resolvedExec = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let parentMacOS = resolvedExec.deletingLastPathComponent()
            let parentContents = parentMacOS.deletingLastPathComponent()
            let parentApp = parentContents.deletingLastPathComponent()
            if parentMacOS.lastPathComponent == "MacOS",
               parentContents.lastPathComponent == "Contents",
               parentApp.pathExtension.lowercased() == "app"
            {
                return true
            }
        }
        return false
    }

    private static func primaryBundleCandidates() -> [URL] {
        var candidates: [URL] = []

        if let mainResourceURL = Bundle.main.resourceURL {
            candidates.append(contentsOf: expandResourceBundles(in: mainResourceURL))
            candidates.append(mainResourceURL.appendingPathComponent("Recipes"))
            candidates.append(mainResourceURL.appendingPathComponent("Resources"))
        }

        if let executableURL = Bundle.main.executableURL {
            let executableDirs = deduplicate([
                executableURL.resolvingSymlinksInPath().deletingLastPathComponent(),
                executableURL.deletingLastPathComponent(),
            ])

            for executableDir in executableDirs {
                candidates.append(contentsOf: expandResourceBundles(in: executableDir))
                candidates.append(executableDir.appendingPathComponent("Recipes"))

                let siblingResources = executableDir
                    .deletingLastPathComponent()
                    .appendingPathComponent("Resources")
                candidates.append(contentsOf: expandResourceBundles(in: siblingResources))
                candidates.append(siblingResources.appendingPathComponent("Recipes"))
            }
        }

        return deduplicate(candidates)
    }

    private static func secondaryBundleCandidates() -> [URL] {
        var candidates: [URL] = []

        let anchorBundle = Bundle(for: BundleAnchor.self)
        if let anchorResourceURL = anchorBundle.resourceURL {
            candidates.append(contentsOf: expandResourceBundles(in: anchorResourceURL))
        }
        candidates.append(contentsOf: expandResourceBundles(in: anchorBundle.bundleURL))
        candidates.append(
            contentsOf: expandResourceBundles(
                in: anchorBundle.bundleURL.deletingLastPathComponent()
            )
        )

        candidates.append(contentsOf: expandResourceBundles(in: Bundle.main.bundleURL))

        #if SWIFT_PACKAGE
        if canSafelyAccessModuleBundle(anchorBundle: anchorBundle) {
            let moduleBundle = Bundle.module
            if let moduleResourceURL = moduleBundle.resourceURL {
                candidates.append(moduleResourceURL.appendingPathComponent("Resources"))
                candidates.append(moduleResourceURL.appendingPathComponent("Recipes"))
                candidates.append(moduleResourceURL)
            }
            candidates.append(moduleBundle.bundleURL.appendingPathComponent("Resources"))
            candidates.append(moduleBundle.bundleURL)
        }
        #endif

        return deduplicate(candidates)
    }

    /// Mirrors SwiftPM's generated `Bundle.module` search paths to verify that accessing
    /// `Bundle.module` will succeed without triggering a runtime `fatalError`.
    private static func canSafelyAccessModuleBundle(anchorBundle: Bundle) -> Bool {
        var searchRoots: [URL] = []

        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let override = env["PACKAGE_RESOURCE_BUNDLE_PATH"] ?? env["PACKAGE_RESOURCE_BUNDLE_URL"],
           !override.isEmpty
        {
            searchRoots.append(URL(fileURLWithPath: override))
        }
        #endif

        if let mainResourceURL = Bundle.main.resourceURL {
            searchRoots.append(mainResourceURL)
        }
        if let anchorResourceURL = anchorBundle.resourceURL {
            searchRoots.append(anchorResourceURL)
        }
        searchRoots.append(Bundle.main.bundleURL)

        for root in searchRoots {
            for bundleName in resourceBundleNames {
                let bundleURL = root.appendingPathComponent(bundleName)
                if Bundle(url: bundleURL) != nil {
                    return true
                }
            }
        }

        return false
    }

    private static func expandResourceBundles(in containerURL: URL) -> [URL] {
        var candidates: [URL] = []
        for bundleName in resourceBundleNames {
            candidates.append(
                contentsOf: expandResourceBundle(at: containerURL.appendingPathComponent(bundleName))
            )
        }
        return candidates
    }

    private static func expandResourceBundle(at bundleURL: URL) -> [URL] {
        var candidates: [URL] = [
            bundleURL.appendingPathComponent("Resources"),
            bundleURL.appendingPathComponent("Contents/Resources/Resources"),
        ]

        if let loadedBundle = Bundle(url: bundleURL), let resourceURL = loadedBundle.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("Resources"))
            candidates.append(resourceURL)
        }

        candidates.append(bundleURL.appendingPathComponent("Contents/Resources"))
        candidates.append(bundleURL)

        return candidates
    }

    private static func sourceTreeRecipesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Common/
            .deletingLastPathComponent() // VermouthCore/
            .appendingPathComponent("Recipes", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
    }

    private static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func recipeFiles(in directory: URL) -> [URL] {
        guard directoryExists(at: directory) else {
            return []
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries
            .filter { url in
                guard url.lastPathComponent.lowercased().hasSuffix(recipeFileSuffix) else {
                    return false
                }
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            }
            .sorted { lhs, rhs in
                lhs.lastPathComponent < rhs.lastPathComponent
            }
    }

    private static func deduplicate(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        result.reserveCapacity(urls.count)
        for url in urls {
            let normalized = url.standardizedFileURL.path
            if seen.insert(normalized).inserted {
                result.append(url)
            }
        }
        return result
    }
}
