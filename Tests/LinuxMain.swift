import XCTest

import StackdriverLoggingTests

var tests = [XCTestCaseEntry]()
tests += StackdriverLoggingTests.allTests()
XCTMain(tests)
