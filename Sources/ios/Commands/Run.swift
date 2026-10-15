import ArgumentParser
import IOSCore

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build, install and launch an app on a simulator or device.",
        discussion: "Boots the simulator if needed and restarts the app if it's already running."
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var project: ProjectOptions
    @OptionGroup var target: TargetOptions
    @OptionGroup var signing: SigningOptions

    @Flag(help: "Install and launch the last build without building.")
    var noBuild = false

    struct Result: Encodable {
        let build: BuildResult?
        let app: AppProduct
        let launch: LaunchResult
    }

    func run() throws {
        let container = try project.container()
        let resolved = try TargetResolver.resolve(target.device)
        let destination = Destination.target(resolved)
        let (listing, _) = try Describer.listing(container)
        let scheme = try Describer.resolveScheme(project.scheme, in: listing)

        var build: BuildResult?
        if !noBuild {
            let result = try Builder.build(BuildRequest(
                container: container, scheme: scheme, configuration: project.configuration,
                destination: destination, derivedDataPath: project.derivedDataPath, team: signing.team
            ))
            guard result.succeeded else {
                try Output.emit(result, json: global.json) { result.textSummary }
                throw ExitCode.failure
            }
            build = result
        }

        let (products, _) = try Describer.appProducts(
            container, scheme: scheme, configuration: project.configuration,
            destination: destination, derivedDataPath: project.derivedDataPath
        )
        let app = try Describer.primaryApp(products, scheme: scheme)
        try Launcher.prepare(resolved)
        try Launcher.install(app.path, on: resolved)
        let launch = try Launcher.launch(app.bundleIdentifier, on: resolved)

        try Output.emit(Result(build: build, app: app, launch: launch), json: global.json) {
            var lines: [String] = []
            if let build { lines.append(build.textSummary) }
            lines.append("Launched \(app.bundleIdentifier) on \(resolved.label)" + (launch.pid.map { " (pid \($0))" } ?? ""))
            return lines.joined(separator: "\n")
        }
    }
}
