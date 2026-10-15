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
