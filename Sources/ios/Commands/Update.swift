import ArgumentParser
import IOSCore

struct UpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update ios to the latest release, in place.",
        discussion: """
        Replaces the installed copy this command runs from (and its resources) after checking the \
        download's checksum. Set IOS_CLI_SIGN_IDENTITY to a signing certificate's SHA-1 or name to sign the \
        new binary, so Xcode keeps its tool-service approval. Run `ios skills add ios-cli --force` after \
        updating to refresh an installed skill.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Only report whether a newer release exists.")
    var check = false

    @Flag(help: "Reinstall even if this version is the latest.")
    var force = false

    func run() throws {
        let result = try Updater.update(current: IOS.configuration.version, check: check, force: force, progress: Docs.progress)
        try Output.emit(result, json: global.json) {
            switch result.status {
            case "upToDate": "ios \(result.current) is the latest release."
            case "available": "ios \(result.latest) is available (this is \(result.current)); run `ios update`."
            default: "Updated ios \(result.current) → \(result.latest) at \(result.path)" + (result.signed ? " (signed)" : "")
            }
        }
    }
}
