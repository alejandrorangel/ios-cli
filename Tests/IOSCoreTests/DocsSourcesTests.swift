import Foundation
import Testing
@testable import IOSCore

// Trimmed samples of each source's markup (structure as published in 2026).

@Test func convertsHTMLToText() {
    #expect(HTMLText.decode("App&nbsp;Store &amp; Apple&rsquo;s &#8220;rules&#8221; &#x2014; &bogus;") == "App Store & Apple’s “rules” — &bogus;")
    let text = HTMLText.text("<p>Intro <strong>bold</strong></p><ul><li><p>First</p></li><li>Second</li></ul><script>x()</script>")
    #expect(text == "Intro bold\n\n- First\n- Second")
    #expect(!text.contains("\n-\n")) // no empty bullets
    #expect(HTMLText.attribute("data-category", in: #"<a href="/x" data-category="swift">"#) == "swift")
}

@Test func parsesReviewGuidelineSections() {
    let html = #"""
    <h3 class="section-title"><a href="#safety">1. Safety</a></h3>
    <p class="section-intro">When people install an app from the App&nbsp;Store, they want to feel confident.</p>
    <ul><li id="objectionable-content"><span id="1.1"></span><strong>1.1 Objectionable Content</strong>
      <p>Apps should not include content that is offensive.</p>
      <ul><li id="1.1.1"><strong>1.1.1</strong> Defamatory, discriminatory, or mean-spirited content, including references or commentary about religion.</li></ul>
    </li></ul>
    <h3>2. Performance</h3><p>Performance intro.</p>
    <footer>Apple</footer>
    """#
    let sections = ReviewGuidelines.sections(in: html)
    #expect(sections.map(\.number) == ["1", "1.1", "1.1.1", "2"])
    #expect(sections[0].title == "Safety")
    #expect(sections[1].title == "1.1 Objectionable Content")
    #expect(sections[2].title == "1.1.1 Defamatory, discriminatory, or mean-spirited content, including references or commentary…")
    #expect(sections[1].text.contains("Apps should not include content that is offensive."))
    #expect(!sections[3].text.contains("Apple")) // the footer isn't part of the last section

    let pages = ReviewGuidelines.pages(in: html)
    #expect(pages[1].path == "/app-store/review/guidelines/1.1")
    #expect(pages[1].parent == "1. Safety")
    #expect(pages[0].title == "1. Safety")
    #expect(pages.allSatisfy { $0.framework == "app-review" })
}

@Test func parsesWWDCListingCards() {
    let html = #"""
    <a href="/videos/play/wwdc2026/258/" class="vc-card tile" data-released="true" data-category="swift">
      <span class="vc-card__duration">28:00</span>
      <h5 class="vc-card__title">What&rsquo;s new in Xcode 27</h5>
      <span class="vc-card__keywords hidden" data-filter-title="what’s new in xcode 27" data-filter-description-en="discover the latest productivity enhancements in xcode 27. explore updates in localization."></span>
    </a>
    <a href="/videos/play/wwdc2026/258/" class="vc-card">duplicate link</a>
    <a href="/videos/play/wwdc2026/101/" class="vc-card" data-category="essentials"><h5 class="vc-card__title">Keynote</h5></a>
    """#
    let sessions = WWDC.sessions(in: html, year: 2026)
    #expect(sessions.map(\.id) == ["258", "101"])
    #expect(sessions[0].title == "What’s new in Xcode 27")
    #expect(sessions[0].category == "swift")
    #expect(sessions[0].duration == "28:00")
    #expect(sessions[0].description == "Discover the latest productivity enhancements in xcode 27. Explore updates in localization.")
}

@Test func rendersWWDCTranscript() {
    let html = #"""
    <title>What’s new in Xcode 27 - WWDC26 - Videos - Apple Developer</title>
    <meta name="description" content="Discover the latest productivity enhancements.">
    <section id="transcript-content"><p><span class="sentence"><span data-start="7.0">Hey, I'm Jake.</span></span></p>
    <p><span class="sentence"><span data-start="75.0">Let's dig in.</span></span></p></section>
    """#
    let markdown = WWDC.render(html, url: "https://developer.apple.com/videos/play/wwdc2026/258/")
    #expect(markdown.hasPrefix("# What’s new in Xcode 27 - WWDC26"))
    #expect(markdown.contains("## Transcript\n\n[0:07] Hey, I'm Jake.\n\n[1:15] Let's dig in."))
    #expect(WWDC.parse("2026/258")! == (2026, "258"))
    #expect(WWDC.parse("wwdc26/101")! == (2026, "101"))
}

@Test func routesNewDocumentationSchemes() {
    #expect(DocsPage.normalizePath("tutorial://swiftui/creating-and-combining-views") == "/tutorials/swiftui/creating-and-combining-views")
    #expect(DocsPage.normalizePath("https://docs.swift.org/swift-book/documentation/the-swift-programming-language/closures#Capturing-Values")
            == "/documentation/the-swift-programming-language/closures")
    #expect(DocsPaths.docURL(forPath: "/tutorials/swiftui/building-lists-and-navigation") == "tutorial://swiftui/building-lists-and-navigation")
    #expect(DocsPaths.docURL(forPath: "/app-store/review/guidelines/4.2") == "asrg://4.2")
    #expect(DocsPaths.docURL(forPath: "/videos/play/wwdc2026/258") == "wwdc://2026/258")
}

@Test func rendersTutorialSteps() throws {
    let page = #"""
    {"kind": "project", "metadata": {"title": "Creating and combining views", "role": "project"},
     "sections": [
       {"kind": "hero", "title": "Creating and combining views", "estimatedTimeInMinutes": 40,
        "content": [{"type": "paragraph", "inlineContent": [{"type": "text", "text": "Build Landmarks."}]}]},
       {"kind": "tasks", "tasks": [{"title": "Customize the text view",
          "contentSection": [{"kind": "contentAndMedia", "content": [{"type": "paragraph", "inlineContent": [{"type": "text", "text": "Change the text."}]}]}],
          "stepsSection": [{"type": "step", "content": [{"type": "paragraph", "inlineContent": [{"type": "text", "text": "Open the file."}]}],
                            "code": "file-1", "caption": []}]}]},
       {"kind": "callToAction", "action": {"identifier": "next"}}
     ],
     "references": {
       "file-1": {"fileName": "ContentView.swift", "syntax": "swift", "content": ["import SwiftUI", "struct ContentView: View {}"]},
       "next": {"title": "Building lists and navigation", "url": "/tutorials/swiftui/building-lists-and-navigation"}
     }}
    """#
    let markdown = try DocsPage.toMarkdown(Data(page.utf8))
    #expect(markdown.contains("Build Landmarks."))
    #expect(markdown.contains("*Estimated time: 40 minutes*"))
    #expect(markdown.contains("## Section 1: Customize the text view"))
    #expect(markdown.contains("**Step 1.** Open the file."))
    #expect(markdown.contains("`ContentView.swift`\n```swift\nimport SwiftUI\nstruct ContentView: View {}\n```"))
    #expect(markdown.contains("**Next:** [`Building lists and navigation`](tutorial://swiftui/building-lists-and-navigation)"))

    let (guide, _) = try #require(DocCCrawler.parse(Data(page.utf8), path: "/tutorials/swiftui/creating-and-combining-views",
                                                     parent: "SwiftUI", linkPrefix: "/tutorials/", framework: "tutorials"))
    #expect(guide.kind == "tutorial")
    #expect(guide.abstract == "Build Landmarks.") // from the hero when there's no abstract
}
