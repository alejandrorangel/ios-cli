import Foundation
import Testing
@testable import IOSCore

private let source = #"""
import SwiftUI

struct ContentView: View {
    var body: some View { Text("See https://example.com // not a comment") }
}

#Preview { ContentView() }

// #Preview("Commented out") { ContentView() }

#Preview("Dark mode") {
    ContentView().preferredColorScheme(.dark)
}

/* A disabled one:
#Preview("Also disabled") { ContentView() }
*/

#Preview("Dark mode, large text", traits: .sizeThatFitsLayout) { ContentView() }

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
"""#

@Test func listsPreviewsInXcodeOrder() {
    let definitions = Previews.definitions(inSource: source)
    #expect(definitions.map(\.name) == [nil, "Dark mode", "Dark mode, large text", "ContentView_Previews"])
    #expect(definitions.map(\.index) == [0, 1, 2, 3])
    #expect(definitions.map(\.kind) == ["macro", "macro", "macro", "provider"])
    #expect(definitions.map(\.line) == [7, 11, 19, 21])
}

@Test func findsPreviewsByName() throws {
    let definitions = Previews.definitions(inSource: source)
    #expect(try Previews.index(named: "dark mode", in: definitions) == 1)        // exact beats contains
    #expect(try Previews.index(named: "large text", in: definitions) == 2)       // contains
    #expect(try Previews.index(named: "ContentView_Previews", in: definitions) == 3)
    #expect(throws: IOSError.self) { try Previews.index(named: "Dark", in: definitions) }  // two contain it
    #expect(throws: IOSError.self) { try Previews.index(named: "Commented out", in: definitions) }
}

@Test func keepsStringsWhenStrippingComments() {
    var inBlock = false
    #expect(Previews.stripComments(#"let s = "a // b" // trailing"#, inBlockComment: &inBlock) == #"let s = "a // b" "#)
    #expect(Previews.stripComments("code /* start", inBlockComment: &inBlock) == "code ")
    #expect(inBlock)
    #expect(Previews.stripComments("still comment */ after", inBlockComment: &inBlock) == " after")
    #expect(!inBlock)
}

private let packagesLoading = IOSError.bridgeFailed(
    tool: "RenderPreview",
    message: "PreviewBlockedReason: Waiting for packages to load\n\nWait to update previews until all package loading is complete\n\ntearingDown")

/// A clock that only moves when the retry loop sleeps.
private final class FakeClock {
    var time = Date(timeIntervalSince1970: 0)
    var sleeps = 0
    func now() -> Date { time }
    func sleep(_ seconds: TimeInterval) { sleeps += 1; time += seconds }
}

@Test func retriesWhilePackagesLoad() throws {
    let clock = FakeClock()
    var calls = 0, waits = 0
    let value = try Previews.untilPackagesLoad(limit: 60, interval: 3, now: clock.now, sleep: clock.sleep,
                                               onWait: { waits += 1 }) { () throws -> String in
        calls += 1
        if calls < 3 { throw packagesLoading }
        return "rendered"
    }
    #expect(value == "rendered")
    #expect(calls == 3)
    #expect(waits == 2)
    #expect(clock.sleeps == 2)
}

@Test func otherRenderErrorsAreNotRetried() {
    let clock = FakeClock()
    var calls = 0
    let failure = IOSError.bridgeFailed(tool: "RenderPreview", message: "Unsupported variant ‘Purple’")
    #expect(throws: failure) {
        try Previews.untilPackagesLoad(now: clock.now, sleep: clock.sleep) { () throws -> Int in
            calls += 1
            throw failure
        }
    }
    #expect(calls == 1)
    #expect(clock.sleeps == 0)
}

@Test func givesUpWhenPackagesKeepLoading() {
    let clock = FakeClock()
    var calls = 0
    #expect(throws: packagesLoading) {
        try Previews.untilPackagesLoad(limit: 10, interval: 3, now: clock.now, sleep: clock.sleep) { () throws -> Int in
            calls += 1
            throw packagesLoading
        }
    }
    // Tries at 0, 3, 6 and 9 s are inside the limit; the one at 12 s is past it and its error is thrown.
    #expect(calls == 5)
}
