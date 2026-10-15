import ArgumentParser
import Foundation
import IOSCore

struct ProjectOptions: ParsableArguments {
    @Option(help: "Path to an .xcworkspace. Defaults to the one in the current directory.")
    var workspace: String?

    @Option(help: "Path to an .xcodeproj. Used when there's no workspace.")
    var project: String?

    @Option(help: "Scheme to use. Required when the project has more than one.")
    var scheme: String?

    @Option(help: "Build configuration, e.g. Debug or Release. Defaults to the scheme's.")
    var configuration: String?

    @Option(help: "Custom DerivedData location. Defaults to Xcode's, so builds share Xcode's cache.")
    var derivedDataPath: String?

    func container() throws -> Container {
        try ProjectLocator.locate(workspace: workspace, project: project,
                                  directory: FileManager.default.currentDirectoryPath)
    }
}

enum PlatformChoice: String, ExpressibleByArgument, CaseIterable {
    case simulator, device

    var genericDestination: Destination {
        self == .simulator ? .genericSimulator : .genericDevice
    }
}

struct DestinationOptions: ParsableArguments {
    @Option(name: .long, help: "Simulator or device UDID or name to build for.")
    var device: String?

    @Option(help: "Generic platform to build for when --device isn't given.")
    var platform: PlatformChoice = .simulator

    func destination() throws -> Destination {
        if let device { return .target(try TargetResolver.resolve(device)) }
        return platform.genericDestination
    }
}

extension BuildResult {
    var textSummary: String {
        let mark = succeeded ? "✓ Build succeeded" : "✗ Build failed"
        var lines = ["\(mark) in \(duration)s (\(errors.count) errors, \(warningCount) warnings)"]
        lines += errors.prefix(15).map { "  \($0.summary)" }
        if errors.count > 15 { lines.append("  … \(errors.count - 15) more errors") }
        lines.append("Log: \(log)")
        return lines.joined(separator: "\n")
    }
}
