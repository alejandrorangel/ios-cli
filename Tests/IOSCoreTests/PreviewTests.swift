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
