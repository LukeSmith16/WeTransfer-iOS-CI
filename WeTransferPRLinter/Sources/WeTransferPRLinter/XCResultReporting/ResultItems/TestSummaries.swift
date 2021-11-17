import Foundation
import XCResultKit

/// Creates test summary messages like:
/// `StormTests: Executed 66 tests, with 0 failures in 9.181 seconds`
extension ActionRecord: XCResultItemsConvertible {
    func testPlanRunSummaries(resultFile: XCResultFile) -> ActionTestPlanRunSummaries? {
        guard let testsReferenceID = actionResult.testsRef?.id, let testPlanRunSummaries = resultFile.getTestPlanRunSummaries(id: testsReferenceID) else {
            return nil
        }
        return testPlanRunSummaries
    }

    func createResults(context: ResultGenerationContext) -> [XCResultItem] {
        guard let testPlanRunSummaries = testPlanRunSummaries(resultFile: context.resultFile) else {
            return []
        }

        let issueResultItems = actionResult.issues.createResults(context: context, testPlanRunSummaries: testPlanRunSummaries)

        let testPlanResultItems = testPlanRunSummaries.summaries.flatMap { testPlanRunSummary in
            testPlanRunSummary.testableSummaries.flatMap { actionTestableSummary in
                actionTestableSummary.createResults(context: context)
            }
        }

        return issueResultItems + testPlanResultItems
    }
}

extension ActionTestPlanRunSummaries {
    /// - Returns: A set of identifiers for tests that failed, even after retrying.
    var failedTestIdentifiers: Set<String> {
        Set<String>(summaries.flatMap { $0.testableSummaries.flatMap { $0.failedTestIdentifiers }})
    }


    /// - Returns: A set of identifiers for the tests that were retried.
    var retriedTestIdentifiers: Set<String> {
        Set<String>(summaries.flatMap { $0.testableSummaries.flatMap { $0.retriedTestIdentifiers }})
    }
}

extension ActionTestableSummary: XCResultItemsConvertible {
    var failedTestIdentifiers: Set<String> {
        tests.failedTestIdentifiers
    }

    var retriedTestIdentifiers: Set<String> {
        tests.retriedTestIdentifiers
    }

    var totalNumberOfTests: Int {
        tests.totalNumberOfTests
    }

    var totalDuration: String {
        let totalDuration: Double = tests.reduce(0) { totalDuration, testSummaryGroup in
            var totalDuration = totalDuration
            totalDuration += testSummaryGroup.duration
            return totalDuration
        }
        return String(format: "%.3f", totalDuration)
    }

    var totalNumberOfFailingTests: Int {
        failedTestIdentifiers.count
    }

    func createResults(context: ResultGenerationContext) -> [XCResultItem] {
        guard let targetName = targetName else { return [] }
        let message = "\(targetName): Executed \(totalNumberOfTests) tests, with \(totalNumberOfFailingTests) failures and \(retriedTestIdentifiers.count) retried tests in \(totalDuration) seconds"
        return [XCResultItem(message: message, category: .message)]
    }
}

extension Array where Element == ActionTestSummaryGroup {
    var totalNumberOfTests: Int {
        reduce(0) { totalCount, testSummaryGroup in
            var totalCount = totalCount
            totalCount += testSummaryGroup.totalNumberOfTests
            return totalCount
        }
    }

    var failedTestIdentifiers: Set<String> {
        reduce([]) { identifiers, testSummaryGroup in
            identifiers.union(testSummaryGroup.failedTestIdentifiers)
        }
    }

    var retriedTestIdentifiers: Set<String> {
        reduce([]) { identifiers, testSummaryGroup in
            identifiers.union(testSummaryGroup.retriedTestIdentifiers)
        }
    }
}

extension ActionTestSummaryGroup {
    var totalNumberOfTests: Int {
        subtests.count + subtestGroups.totalNumberOfTests
    }

    var failedTestIdentifiers: Set<String> {
        subtests.failedTestIdentifiers.union(subtestGroups.failedTestIdentifiers)
    }

    var retriedTestIdentifiers: Set<String> {
        subtests.retriedTestIdentifiers.union(subtestGroups.retriedTestIdentifiers)
    }
}

extension Array where Element == ActionTestMetadata {
    private var successIdentifiers: Set<String> {
        Set<String>(filter { $0.testStatus == "Success" }.map { $0.identifier })
    }
    private var failedIdentifiers: Set<String> {
        Set<String>(filter { $0.testStatus == "Failure" }.map { $0.identifier })
    }

    var failedTestIdentifiers: Set<String> {
        /// Substract success identifiers to filter out retried tests.
        return failedIdentifiers.subtracting(successIdentifiers)
    }

    var retriedTestIdentifiers: Set<String> {
        /// Tests that succeeded eventually intersect with failed tests.
        return successIdentifiers.intersection(failedIdentifiers)
    }
}
