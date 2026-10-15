import Foundation

/// The Xcode container `xcodebuild` builds from.
public enum Container: Codable, Equatable, Sendable {
    case workspace(String)
    case project(String)
    /// A directory with Package.swift; xcodebuild uses it when run from that directory.
    case package(String)

    public var path: String {
        switch self {
        case let .workspace(p), let .project(p), let .package(p): p
        }
    }

    public var kind: String {
        switch self {
        case .workspace: "workspace"
        case .project: "project"
        case .package: "package"
        }
    }

    /// Directory that holds the container; project files are fingerprinted from here.
    public var rootDirectory: String {
        switch self {
        case let .package(dir): dir
        case let .workspace(p), let .project(p): (p as NSString).deletingLastPathComponent
        }
    }

    /// Arguments that select this container for xcodebuild.
    public var xcodebuildArguments: [String] {
        switch self {
        case let .workspace(p): ["-workspace", p]
        case let .project(p): ["-project", p]
        case .package: []
        }
    }

    /// Working directory for xcodebuild (only matters for packages).
    public var workingDirectory: String? {
        if case let .package(dir) = self { return dir }
        return nil
    }
}

public enum ProjectLocator {
    /// Uses the explicit workspace/project when given; otherwise looks in `directory` for a
    /// workspace, then a project, then Package.swift — the same order Xcode uses.
    public static func locate(workspace: String?, project: String?, directory: String) throws -> Container {
        if let workspace { return .workspace(absolute(workspace, in: directory)) }
        if let project { return .project(absolute(project, in: directory)) }

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory))?.sorted() ?? []
        let workspaces = entries.filter { $0.hasSuffix(".xcworkspace") }
        let projects = entries.filter { $0.hasSuffix(".xcodeproj") }

        if workspaces.count == 1 { return .workspace(absolute(workspaces[0], in: directory)) }
        if workspaces.count > 1 {
            throw IOSError.ambiguousProject(directory: directory, candidates: workspaces)
        }
        if projects.count == 1 { return .project(absolute(projects[0], in: directory)) }
        if projects.count > 1 {
            throw IOSError.ambiguousProject(directory: directory, candidates: projects)
        }
        if entries.contains("Package.swift") { return .package(directory) }
        throw IOSError.projectNotFound(directory: directory)
    }

    static func absolute(_ path: String, in directory: String) -> String {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: directory).appendingPathComponent(path)
        return url.standardizedFileURL.path
    }
}
