import Foundation

public struct SchemeListing: Codable, Equatable, Sendable {
    public let name: String
    public let schemes: [String]
    /// Only reported for projects, not workspaces.
    public let targets: [String]?
    public let configurations: [String]?
}

/// An app built by a scheme, with where xcodebuild puts it.
public struct AppProduct: Codable, Equatable, Sendable {
    public let target: String
    public let bundleIdentifier: String
    public let productName: String
    public let path: String
    public let configuration: String
    public let sdk: String
    public let deploymentTarget: String?
}

public struct ProjectDescription: Codable, Sendable {
    public let container: String
    public let containerType: String
    public let name: String
    public let schemes: [String]
    public let targets: [String]?
    public let configurations: [String]?
    /// Set when a scheme was given (or the project has only one).
    public let scheme: String?
    public let products: [AppProduct]?
    public let fromCache: Bool

    public init(container: String, containerType: String, name: String, schemes: [String], targets: [String]?,
                configurations: [String]?, scheme: String?, products: [AppProduct]?, fromCache: Bool) {
        self.container = container
        self.containerType = containerType
        self.name = name
        self.schemes = schemes
        self.targets = targets
        self.configurations = configurations
        self.scheme = scheme
        self.products = products
        self.fromCache = fromCache
    }
}

public enum Describer {
    /// `xcodebuild -list -json`. Cached; takes ~10 s uncached on a large workspace.
    public static func listing(_ container: Container, cache: MetadataCache = .init(), refresh: Bool = false) throws -> (SchemeListing, cached: Bool) {
        let fingerprint = ProjectFingerprint.compute(root: container.rootDirectory, extra: [try xcodeBuildVersion()])
        let key = "list|\(container.path)"
        if !refresh, let hit = cache.read(SchemeListing.self, key: key, fingerprint: fingerprint) {
            return (hit, true)
        }
        let result = try Shell.checked("/usr/bin/xcrun", ["xcodebuild", "-list", "-json"] + container.xcodebuildArguments,
                                       in: container.workingDirectory)
        let listing = try parseListing(result.stdout)
        cache.write(listing, key: key, fingerprint: fingerprint)
        return (listing, false)
    }

    /// App products of a scheme for a destination's SDK. Cached; 8–42 s uncached.
    public static func appProducts(
        _ container: Container, scheme: String, configuration: String?, destination: Destination,
        derivedDataPath: String?, cache: MetadataCache = .init(), refresh: Bool = false
    ) throws -> ([AppProduct], cached: Bool) {
        let fingerprint = ProjectFingerprint.compute(root: container.rootDirectory, extra: [try xcodeBuildVersion()])
        let key = ["settings", container.path, scheme, configuration ?? "", destination.sdk, derivedDataPath ?? ""].joined(separator: "|")
        if !refresh, let hit = cache.read([AppProduct].self, key: key, fingerprint: fingerprint) {
            return (hit, true)
        }
        var arguments = ["xcodebuild", "-showBuildSettings", "-json"] + container.xcodebuildArguments
        arguments += ["-scheme", scheme, "-destination", destination.xcodebuildValue]
        if let configuration { arguments += ["-configuration", configuration] }
        if let derivedDataPath { arguments += ["-derivedDataPath", derivedDataPath] }
        let result = try Shell.checked("/usr/bin/xcrun", arguments, in: container.workingDirectory)
        let products = try parseBuildSettings(result.stdout)
        cache.write(products, key: key, fingerprint: fingerprint)
        return (products, false)
    }

    /// Picks the scheme to use: the given one (validated), or the only one.
    public static func resolveScheme(_ scheme: String?, in listing: SchemeListing) throws -> String {
        if let scheme {
            guard listing.schemes.contains(scheme) else {
                throw IOSError.schemeNotFound(scheme: scheme, schemes: listing.schemes)
            }
            return scheme
        }
        guard listing.schemes.count == 1 else { throw IOSError.schemeRequired(schemes: listing.schemes) }
        return listing.schemes[0]
    }

    /// The app a scheme launches: the product whose target matches the scheme name, else the only one.
    public static func primaryApp(_ products: [AppProduct], scheme: String) throws -> AppProduct {
        if let match = products.first(where: { $0.target == scheme }) { return match }
        guard let first = products.first else { throw IOSError.noAppProduct(scheme: scheme) }
        return first
    }

    // MARK: Parsing

    public static func parseListing(_ data: Data) throws -> SchemeListing {
        struct Raw: Decodable {
            struct Entry: Decodable {
                let name: String
                let schemes: [String]?
                let targets: [String]?
                let configurations: [String]?
            }
            let workspace: Entry?
            let project: Entry?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), let entry = raw.workspace ?? raw.project else {
            throw IOSError.invalidOutput(tool: "xcodebuild -list -json", reason: "no workspace or project entry")
        }
        return SchemeListing(name: entry.name, schemes: entry.schemes ?? [], targets: entry.targets, configurations: entry.configurations)
    }

    /// Parses `xcodebuild -showBuildSettings -json` and keeps application targets.
    public static func parseBuildSettings(_ data: Data) throws -> [AppProduct] {
        struct Raw: Decodable {
            let target: String
            let buildSettings: [String: String]
        }
        guard let raw = try? JSONDecoder().decode([Raw].self, from: data) else {
            throw IOSError.invalidOutput(tool: "xcodebuild -showBuildSettings -json", reason: "not an array of targets")
        }
        return raw.compactMap { entry in
            let s = entry.buildSettings
            guard
                s["PRODUCT_TYPE"] == "com.apple.product-type.application",
                let bundleID = s["PRODUCT_BUNDLE_IDENTIFIER"],
                let name = s["FULL_PRODUCT_NAME"],
                let dir = s["TARGET_BUILD_DIR"]
            else { return nil }
            return AppProduct(
                target: entry.target,
                bundleIdentifier: bundleID,
                productName: name,
                path: (dir as NSString).appendingPathComponent(name),
                configuration: s["CONFIGURATION"] ?? "",
                sdk: s["PLATFORM_NAME"] ?? s["SDK_NAME"] ?? "",
                deploymentTarget: s["IPHONEOS_DEPLOYMENT_TARGET"]
            )
        }
    }

    /// Part of every cache fingerprint: build settings change between Xcode versions.
    /// Loaded once per process (it costs two tool launches).
    private static let cachedXcodeBuild: String = XcodeInfo.currentBuild() ?? (try? XcodeInfo.load().build) ?? "unknown"

    static func xcodeBuildVersion() throws -> String { cachedXcodeBuild }

    /// Symbol databases are kept per Xcode build so they match the installed SDK.
    static var cachedXcodeBuildForSymbols: String { cachedXcodeBuild }
}
