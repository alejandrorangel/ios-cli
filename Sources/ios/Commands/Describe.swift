import ArgumentParser
import IOSCore

struct Describe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show schemes, and with a scheme, the apps it builds and where they end up.",
        discussion: "Results are cached until project files change (xcodebuild takes 10–40 s to answer). Use --refresh to bypass the cache."
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var project: ProjectOptions
    @OptionGroup var destination: DestinationOptions

    @Flag(help: "Ignore cached results.")
    var refresh = false

    func run() throws {
        let container = try project.container()
        let (listing, listingCached) = try Describer.listing(container, refresh: refresh)

        // Products need a scheme; use the given one, or the only one if there's just one.
        let scheme: String? = project.scheme != nil || listing.schemes.count == 1
            ? try Describer.resolveScheme(project.scheme, in: listing) : nil
        var products: [AppProduct]?
        var productsCached = true
        if let scheme {
            (products, productsCached) = try Describer.appProducts(
                container, scheme: scheme, configuration: project.configuration,
                destination: try destination.destination(), derivedDataPath: project.derivedDataPath, refresh: refresh
            )
        }

        let description = ProjectDescription(
            container: container.path, containerType: container.kind, name: listing.name,
            schemes: listing.schemes, targets: listing.targets, configurations: listing.configurations,
            scheme: scheme, products: products, fromCache: listingCached && productsCached
        )
        try Output.emit(description, json: global.json) {
            var lines = ["\(listing.name) (\(container.kind)): \(container.path)", "Schemes: \(listing.schemes.joined(separator: ", "))"]
            if let targets = listing.targets { lines.append("Targets: \(targets.joined(separator: ", "))") }
            if let scheme, let products {
                lines.append("")
                lines.append(products.isEmpty ? "Scheme \(scheme) builds no apps." : "Apps built by \(scheme):")
                for p in products {
                    lines.append("  \(p.target)  \(p.bundleIdentifier)  \(p.configuration)/\(p.sdk)  iOS \(p.deploymentTarget ?? "?")+")
                    lines.append("    \(p.path)")
                }
            } else {
                lines.append("Pass --scheme to see the apps a scheme builds.")
            }
            if description.fromCache { lines.append("(cached; --refresh to re-read)") }
            return lines.joined(separator: "\n")
        }
    }
}
