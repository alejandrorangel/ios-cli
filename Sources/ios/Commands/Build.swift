import ArgumentParser
import IOSCore

struct Build: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build a scheme and summarize errors and warnings.",
        discussion: "The full xcodebuild log is written to a file; its path is in the output. Exits non-zero when the build fails, after printing the summary."
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var project: ProjectOptions
    @OptionGroup var destination: DestinationOptions

    func run() throws {
        let container = try project.container()
        let (listing, _) = try Describer.listing(container)
        let scheme = try Describer.resolveScheme(project.scheme, in: listing)

        let result = try Builder.build(BuildRequest(
            container: container, scheme: scheme, configuration: project.configuration,
            destination: try destination.destination(), derivedDataPath: project.derivedDataPath
        ))
        try Output.emit(result, json: global.json) { result.textSummary }
        if !result.succeeded { throw ExitCode.failure }
    }
}
