import Foundation
import Testing
@testable import IOSCore

// Trimmed from `xcresulttool get test-results tests` (Xcode 27) for a Swift Testing suite and an XCTest class.
private let tree = #"""
{
  "devices": [{ "deviceName": "iPhone 17", "osVersion": "27.0", "platform": "iOS Simulator" }],
  "testNodes": [{
    "name": "App", "nodeType": "Test Plan", "result": "Failed",
    "children": [{
      "name": "AppTests", "nodeType": "Unit test bundle", "result": "Failed",
      "nodeIdentifierURL": "test://com.apple.xcode/App/AppTests",
      "children": [
        {
          "name": "LegacyTests", "nodeType": "Test Suite", "result": "Failed",
          "children": [
            {
              "name": "testFails()", "nodeIdentifier": "LegacyTests/testFails()", "nodeType": "Test Case",
              "nodeIdentifierURL": "test://com.apple.xcode/App/AppTests/LegacyTests/testFails",
              "result": "Failed", "durationInSeconds": 0.22193503379821777,
              "children": [{
                "name": "XCTAssertEqual failed: (\"2\") is not equal to (\"3\")", "nodeType": "Failure Message",
                "sourceLocation": { "filePath": "/src/AppTests/AppTests.swift", "lineNumber": 23 }
              }]
            },
            {
              "name": "testPasses()", "nodeIdentifier": "LegacyTests/testPasses()", "nodeType": "Test Case",
              "nodeIdentifierURL": "test://com.apple.xcode/App/AppTests/LegacyTests/testPasses",
              "result": "Passed", "durationInSeconds": 0.0004730224609375
            }
          ]
        },
        {
          "name": "AppTests", "nodeType": "Test Suite", "result": "Failed",
          "children": [
            {
              "name": "skipped()", "nodeType": "Test Case", "result": "Skipped",
              "nodeIdentifierURL": "test://com.apple.xcode/App/AppTests/AppTests/skipped()",
              "children": [{ "name": "Test skipped: not ready", "nodeType": "Skip Message" }]
            },
            {
              "name": "parameterized(n:)", "nodeType": "Test Case", "result": "Failed",
              "nodeIdentifierURL": "test://com.apple.xcode/App/AppTests/AppTests/parameterized(n:)",
              "children": [
                { "name": "1", "nodeType": "Arguments", "result": "Passed" },
                {
                  "name": "3", "nodeType": "Arguments", "result": "Failed",
                  "children": [{
                    "name": "Expectation failed: n < 3\nn → 3", "nodeType": "Failure Message",
                    "sourceLocation": { "filePath": "/src/AppTests/AppTests.swift", "lineNumber": 15 }
                  }]
                }
              ]
            }
          ]
        }
      ]
    }]
  }]
}
"""#

@Test func parsesTestCasesFromResultTree() throws {
    let cases = try TestRunner.parseTestTree(Data(tree.utf8))
    #expect(cases.map(\.id) == ["AppTests/LegacyTests/testFails", "AppTests/LegacyTests/testPasses",
                                "AppTests/AppTests/skipped()", "AppTests/AppTests/parameterized(n:)"])
    #expect(cases.map(\.result) == ["failed", "passed", "skipped", "failed"])
    #expect(cases[0].duration == 0.222)
    #expect(cases[0].failures == [TestFailure(message: #"XCTAssertEqual failed: ("2") is not equal to ("3")"#,
                                              file: "/src/AppTests/AppTests.swift", line: 23, arguments: nil)])
    #expect(cases[2].skipReason == "not ready")
    #expect(cases[3].failures.map(\.summary) == ["/src/AppTests/AppTests.swift:15: [3] Expectation failed: n < 3\nn → 3"])
    #expect(cases[3].arguments?.map(\.name) == ["1", "3"])
    #expect(cases[3].arguments?.map(\.result) == ["passed", "failed"])
    #expect(cases[0].arguments == nil)
}

@Test func findsSuitesThatRanAtTheSameTime() {
    let log = """
    ◇ Suite Outer started.
    ◇ Suite Inner started.
    ✔ Suite Inner passed after 1.0 seconds.
    ✔ Suite Outer passed after 1.0 seconds.
    ◇ Suite ClickStemDriftTests started.
    ◇ Suite "Sustained alignment" started.
    ✘ Suite "Sustained alignment" failed after 2.0 seconds with 1 issue.
    ✔ Suite ClickStemDriftTests passed after 5.0 seconds.
    ◇ Suite Later started.
    ✔ Suite Later passed after 1.0 seconds.
    """
    let ancestors: [String: Set<String>] = ["Inner": ["Outer"], "Outer": []]
    #expect(TestRunner.overlappingSuites(log, ancestors: ancestors) == ["ClickStemDriftTests", "Sustained alignment"])
    #expect(TestRunner.overlappingSuites("◇ Suite A started.\n✔ Suite A passed after 1.0 seconds.\n◇ Suite B started.",
                                         ancestors: [:]).isEmpty)
}

@Test func assignsPrintedLinesToTests() {
    let log = """
    Test Case '-[AppTests.LegacyTests testPrints]' started.
    legacy says hi
    /src/Legacy.swift:3: error: -[AppTests.LegacyTests testPrints] : XCTAssertEqual failed
    Test Case '-[AppTests.LegacyTests testPrints]' failed (0.535 seconds).
    ◇ Test run started.
    ↳ Testing Library Version: 2084
    ◇ Suite PrintA started.
    ◇ Test runs() started.
    from PrintA

    ✘ Test runs() recorded an issue at Prints.swift:2:71: Expectation failed: 1 == 2
    ↳ 1 == 2 → false
    ✘ Test runs() failed after 0.004 seconds with 1 issue.
    ✘ Suite PrintA failed after 0.005 seconds with 1 issue.
    ◇ Suite PrintB started.
    ◇ Test "Pretty name" started.
    2026-10-28 12:04:07.860 xcodebuild[123:456] some warning
    from PrintB
    ✔ Test "Pretty name" passed after 0.001 seconds.
    ✔ Suite PrintB passed after 0.001 seconds.
    ✘ Test run with 2 tests in 2 suites failed after 0.005 seconds with 1 issue.
    """
    let tests = ["PrintA": ["runs()": "AppTests/PrintA/runs()"], "PrintB": ["Pretty name": "AppTests/PrintB/runs()"]]
    #expect(TestRunner.testOutput(log, tests: tests) == [
        TestOutput(test: "AppTests/LegacyTests/testPrints", argument: nil, logLine: 2, text: "legacy says hi",
                   beforeIssue: nil, interleaved: false),
        TestOutput(test: "AppTests/PrintA/runs()", argument: nil, logLine: 9, text: "from PrintA\n",
                   beforeIssue: "from PrintA\n", interleaved: false),
        TestOutput(test: "AppTests/PrintB/runs()", argument: nil, logLine: 18, text: "from PrintB",
                   beforeIssue: nil, interleaved: false),
    ])

    let parallel = """
    ◇ Suite A started.
    ◇ Suite B started.
    ◇ Test runs() started.
    only one running
    ◇ Test runs() started.
    both running
    ✔ Test runs() passed after 1.0 seconds.
    ✔ Test runs() passed after 1.0 seconds.
    """
    let output = TestRunner.testOutput(parallel, tests: ["A": ["runs()": "T/A/runs()"], "B": ["runs()": "T/B/runs()"]])
    #expect(output.map(\.test) == ["T/B/runs()", "T/A/runs()"])
    #expect(output.map(\.text) == ["only one running\nboth running", "both running"])
    #expect(output.map(\.interleaved) == [true, true])
}

@Test func parsesSwiftTestingEvents() {
    #expect(TestRunner.swiftTestingEvent("\u{200B}◇ Test case passing 1 argument n → 2 to param(n:) started.")
            == .caseStarted(test: "param(n:)", arguments: "n → 2"))
    #expect(TestRunner.swiftTestingEvent("\u{200B}✔ Test param(n:) with 2 test cases passed after 3.017 seconds.")
            == .testEnded("param(n:)"))
    #expect(TestRunner.swiftTestingEvent(#"✘ Test f(speed:) recorded an issue with 1 argument speed → .full at X.swift:89:9: Expectation failed: a"#)
            == .issue("f(speed:)"))
    #expect(TestRunner.swiftTestingEvent(#"➜ Test "Pretty name" skipped: "not ready""#) == .testEnded("Pretty name"))
    #expect(TestRunner.swiftTestingEvent("✘ Test run with 2 tests in 2 suites failed after 0.005 seconds.") == nil)
    #expect(TestRunner.swiftTestingEvent("◇ Test run started.") == nil)
    #expect(TestRunner.swiftTestingEvent("↳ onsets stopped alternating click/blip") == nil)
}

// From an app-hosted device run (iOS 27.0.1): the host app prints too, and logs through os_log.
@Test func splitsParameterizedOutputPerArgumentAndFindsTheLinesBeforeTheIssue() {
    let log = """
    ◇ Suite SustainedTests started.
    ◇ Test drift(speed:) started.
    ◇ Test case passing 1 argument speed → .full to drift(speed:) started.
    🚄 fetchPathLevel from Contentful success
    83
    2026-10-28 11:49:43.015759-0700 Play-Dev[842:104918] [AVAudioSession Hang Risk]     AVAudioSession_iOS.mm:978
    sustained @1.00x over 159s: drift -585.40ms, worst 12215.92ms
    ✘ Test drift(speed:) recorded an issue with 1 argument speed → .full at S.swift:89:9: Expectation failed: …
    ↳ onsets stopped alternating click/blip
    after the issue
    \u{200B}◇ Test case passing 1 argument speed → .threeQuarter to drift(speed:) started.
    sustained @0.75x over 212s: drift -3.10ms
    ✘ Test drift(speed:) with 2 test cases failed after 400.0 seconds with 1 issue.
    ✘ Suite SustainedTests failed after 400.0 seconds with 1 issue.
    """
    let output = TestRunner.testOutput(log, tests: ["SustainedTests": ["drift(speed:)": "T/SustainedTests/drift(speed:)"]])
    #expect(output.map(\.argument) == ["speed → .full", "speed → .threeQuarter"])
    #expect(output[0].text == "🚄 fetchPathLevel from Contentful success\n83\nsustained @1.00x over 159s: drift -585.40ms, worst 12215.92ms\nafter the issue")
    #expect(output[0].beforeIssue?.hasSuffix("sustained @1.00x over 159s: drift -585.40ms, worst 12215.92ms") == true)
    #expect(output[1].text == "sustained @0.75x over 212s: drift -3.10ms")
    #expect(output[1].beforeIssue == nil)
    #expect(output.allSatisfy { !$0.interleaved })
}

@Test func readsAttachmentManifest() throws {
    let manifest = #"""
    [{
      "attachments": [
        { "exportedFileName": "1A33.txt", "suggestedHumanReadableName": "drift-1.0_0_E8FD5ABB-B28B-4339-9EC3-DC6A0E232F94.txt" },
        { "exportedFileName": "77B2", "suggestedHumanReadableName": "raw_1_E8FD5ABB-B28B-4339-9EC3-DC6A0E232F94" }
      ],
      "testIdentifier": "SuiteA/a1()",
      "testIdentifierURL": "test://com.apple.xcode/EnvGate/EnvGateTests/SuiteA/a1()"
    }]
    """#
    let entries = try TestRunner.parseAttachmentManifest(Data(manifest.utf8))
    #expect(entries.map(\.test) == ["EnvGateTests/SuiteA/a1()", "EnvGateTests/SuiteA/a1()"])
    #expect(entries.map(\.name) == ["drift-1.0.txt", "raw"])
    #expect(entries.map(\.file) == ["1A33.txt", "77B2"])
    #expect(entries.map(\.testIdentifier) == ["SuiteA/a1()", "SuiteA/a1()"])
    #expect(entries[0].suggested == "drift-1.0_0_E8FD5ABB-B28B-4339-9EC3-DC6A0E232F94.txt")
}

@Test func readsWhichArgumentRecordedEachAttachment() throws {
    // Trimmed from `xcresulttool get test-results activities` (Xcode 27).
    let activities = #"""
    { "testRuns": [
      { "arguments": [{ "value": "1" }], "activities": [{
          "attachments": [{ "name": "summary_0_928A6E36-F2A1-4D3A-8992-041B5A04746C.txt" }],
          "childActivities": [{ "title": "summary.txt" }] }] },
      { "arguments": [{ "value": ".full" }, { "value": "2" }], "activities": [{ "childActivities": [{
          "attachments": [{ "name": "summary_0_8EA68A3D-BBBD-43B5-80A0-8AE51FBFBBC8.txt" }] }] }] },
      { "activities": [{ "attachments": [{ "name": "plain.txt" }] }] }
    ] }
    """#
    #expect(try TestRunner.attachmentArguments(Data(activities.utf8)) == [
        "summary_0_928A6E36-F2A1-4D3A-8992-041B5A04746C.txt": "1",
        "summary_0_8EA68A3D-BBBD-43B5-80A0-8AE51FBFBBC8.txt": ".full, 2",
    ])
}

@Test func makesShellSafeAttachmentFolders() {
    #expect(TestRunner.folderName("T/ClickStemDriftTests/clicksHoldTheirPlaceAgainstTheStems(speed:)")
            == "ClickStemDriftTests.clicksHoldTheirPlaceAgainstTheStems-speed")
    #expect(TestRunner.folderName("T/SuiteA/a1()") == "SuiteA.a1")
    #expect(TestRunner.folderName("T/LegacyTests/testPrints") == "LegacyTests.testPrints")
    #expect(TestRunner.folderName("T/S/f(a:b:)") == "S.f-a-b")
}

@Test func keepsTheAttachmentsFolderWhenNothingWasExported() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ios-cli-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("mine".utf8).write(to: directory.appendingPathComponent("keep.txt"))
    let missing = directory.appendingPathComponent("missing.xcresult")
    #expect(try TestRunner.exportAttachments(bundle: missing, to: directory).isEmpty)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("keep.txt").path))
}

@Test func disablesParallelTesting() {
    let request = TestRequest(
        container: .package("/src"), scheme: "App", configuration: nil, destination: .genericSimulator,
        derivedDataPath: nil, only: [], skip: [], testPlan: nil, withoutBuilding: false, retries: nil, serial: true
    )
    let arguments = request.xcodebuildArguments(resultBundle: "/tmp/r.xcresult")
    #expect(arguments.firstIndex(of: "-parallel-testing-enabled").map { arguments[$0 + 1] } == "NO")
}

@Test func buildsTestArguments() {
    let request = TestRequest(
        container: .project("/src/App.xcodeproj"), scheme: "App", configuration: nil, destination: .genericSimulator,
        derivedDataPath: nil, only: ["AppTests/LegacyTests"], skip: ["AppUITests"], testPlan: "Smoke",
        withoutBuilding: true, retries: 2
    )
    let arguments = request.xcodebuildArguments(resultBundle: "/tmp/r.xcresult")
    #expect(arguments.prefix(2) == ["xcodebuild", "test-without-building"])
    #expect(arguments.contains("-only-testing:AppTests/LegacyTests"))
    #expect(arguments.contains("-skip-testing:AppUITests"))
    #expect(arguments.suffix(3) == ["-retry-tests-on-failure", "-test-iterations", "3"])
    #expect(arguments.contains("Smoke"))
}

@Test func parsesTestEnvironment() throws {
    let environment = try TestRequest.parseEnvironment(["SECONDS=180", "TEST_RUNNER_MODE=a=b", "EMPTY="])
    #expect(environment == ["SECONDS": "180", "MODE": "a=b", "EMPTY": ""])
    let request = TestRequest(
        container: .package("/src"), scheme: "App", configuration: nil, destination: .genericSimulator,
        derivedDataPath: nil, only: [], skip: [], testPlan: nil, withoutBuilding: false, retries: nil,
        environment: environment
    )
    #expect(request.xcodebuildEnvironment == ["TEST_RUNNER_SECONDS": "180", "TEST_RUNNER_MODE": "a=b", "TEST_RUNNER_EMPTY": ""])
    #expect(throws: IOSError.invalidEnvironment("SECONDS")) { try TestRequest.parseEnvironment(["SECONDS"]) }
    #expect(throws: IOSError.invalidEnvironment("=1")) { try TestRequest.parseEnvironment(["=1"]) }
}

@Test func readsXcodebuildErrorsWhenNothingRan() {
    let log = """
    xcodebuild: error: Failed to build workspace App with scheme App.
    xcodebuild: error: Scheme App is not currently configured for the test action.
    xcodebuild: error: Scheme App is not currently configured for the test action.
    """
    #expect(TestRunner.logIssues(log) == ["Failed to build workspace App with scheme App.",
                                          "Scheme App is not currently configured for the test action."])
    let cancelled = "Testing failed:\n\tUnable to boot the simulator.\n\tTesting cancelled.\n\n** TEST FAILED **"
    #expect(TestRunner.logIssues(cancelled) == ["Unable to boot the simulator.", "Testing cancelled."])
}

@Test func parsesProjectLevelDiagnostics() {
    let log = "/src/App.xcodeproj: error: Signing for \"App\" requires a development team. (in target 'App' from project 'App')"
    let diagnostics = Builder.parseDiagnostics(log)
    #expect(diagnostics.map(\.file) == ["/src/App.xcodeproj"])
    #expect(diagnostics.first?.summary.hasPrefix("/src/App.xcodeproj: error: Signing for") == true)
}
