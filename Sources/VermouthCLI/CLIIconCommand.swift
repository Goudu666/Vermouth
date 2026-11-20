import Foundation
import VermouthCore

extension CLICommands {
    /// `vermouth icon <exe> [--output <file.ico>] [--json]`：从 Windows 程序中提取图标（Clean-Room PE 资源解析）。
    static func runIcon(args: [String]) throws -> Int32 {
        let usage = "vermouth icon <exe-or-dll> [--output <file.ico>] [--json]"
        let parsed = try ParsedArguments.parse(args, allowedFlags: ["json"], valueOptions: ["output"])
        if parsed.isHelp {
            CLIOutput.writeStdout("Usage: \(usage)")
            return 0
        }
        guard let rawPath = parsed.positionals.first else {
            throw CLIError.missingArgument(usage)
        }
        let path = URL(fileURLWithPath: CLIOutput.expandTilde(rawPath)).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIError.fileNotFound(path)
        }

        guard let iconSet = try PEIconExtractor.extractIcon(fileAtPath: path) else {
            if parsed.isJSON {
                try CLIOutput.printJSON(IconReport(source: path, output: nil, images: []))
            } else {
                CLIOutput.writeStdout("No icon resources found in \(URL(fileURLWithPath: path).lastPathComponent).")
            }
            return 2
        }

        var outputPath: String?
        if let rawOutput = parsed.option("output") {
            let outputURL = URL(fileURLWithPath: CLIOutput.expandTilde(rawOutput)).standardizedFileURL
            try iconSet.icoData.write(to: outputURL, options: .atomic)
            outputPath = outputURL.path
        }

        if parsed.isJSON {
            try CLIOutput.printJSON(IconReport(source: path, output: outputPath, images: iconSet.images))
            return 0
        }
        CLIOutput.writeStdout("Icon group \(iconSet.groupID.map(String.init) ?? "<named>") in \(URL(fileURLWithPath: path).lastPathComponent):")
        for image in iconSet.images {
            CLIOutput.writeStdout("  - \(image.width)x\(image.height) @ \(image.bitCount)bpp \(image.isPNG ? "PNG" : "DIB") (\(image.byteCount) bytes)")
        }
        if let outputPath {
            CLIOutput.writeStdout("Wrote \(iconSet.icoData.count) bytes to \(outputPath)")
        }
        return 0
    }

    private struct IconReport: Encodable {
        let source: String
        let output: String?
        let images: [PEIconImage]
    }
}
