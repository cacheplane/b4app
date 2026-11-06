import Foundation
import XCTest

/// Execution evidence for legacy scenarios. Assertions remain in the real UI journeys.
final class JourneyCoverage {
  struct Scenario: Decodable {
    let id: String
    let method: String
    let ordinal: Int
    let layouts: Int
  }
  struct Manifest: Decodable { let scenarios: [Scenario] }

  private var manifest: Manifest?
  private var pending: Scenario?
  private var ordinal = 0
  private var layoutOrdinal = 0
  private var registeredTeardown = false
  private var emitted: Set<String> = []

  @MainActor
  func beforeLaunch(in test: XCTestCase) {
    if !registeredTeardown {
      registeredTeardown = true
      test.addTeardownBlock { @MainActor [self, test] () async throws in finishPending(in: test) }
    }
    finishPending(in: test)
    ordinal += 1
    let method = methodName(test)
    if let scenario = scenarios(in: test).first(where: { $0.method == method && $0.ordinal == ordinal }) {
      pending = scenario
      layoutOrdinal = 0
    }
  }

  @MainActor
  func didLaunch(in test: XCTestCase) {
    attach("launch:\(methodName(test))#\(ordinal)", in: test)
  }

  @MainActor
  func layout(in test: XCTestCase, covering identifiers: [String] = []) {
    if identifiers.isEmpty {
      guard let pending else {
        XCTFail("Journey layout has no mapped legacy checkpoint")
        return
      }
      layoutOrdinal += 1
      emit("\(pending.id)/layout#\(layoutOrdinal)", in: test)
    } else {
      for identifier in identifiers { emit(identifier, in: test) }
    }
  }

  @MainActor
  func complete(_ identifiers: [String], in test: XCTestCase) {
    for identifier in identifiers {
      guard let scenario = scenarios(in: test).first(where: { $0.id == identifier }) else {
        XCTFail("Unknown legacy scenario: \(identifier)")
        continue
      }
      for index in 0..<scenario.layouts {
        XCTAssertTrue(
          emitted.contains("\(identifier)/layout#\(index + 1)"),
          "Missing mapped layout before scenario completion: \(identifier)")
      }
      emit(identifier + "/complete", in: test)
    }
  }

  @MainActor
  private func finishPending(in test: XCTestCase) {
    guard let pending else { return }
    XCTAssertEqual(layoutOrdinal, pending.layouts, "Incomplete legacy scenario: \(pending.id)")
    complete([pending.id], in: test)
    self.pending = nil
  }

  @MainActor
  private func emit(_ identifier: String, in test: XCTestCase) {
    XCTAssertTrue(emitted.insert(identifier).inserted, "Duplicate coverage marker: \(identifier)")
    attach("coverage:" + identifier, in: test)
  }

  @MainActor
  private func attach(_ name: String, in test: XCTestCase) {
    let attachment = XCTAttachment(string: name)
    attachment.name = name
    attachment.lifetime = .keepAlways
    test.add(attachment)
  }

  @MainActor
  private func methodName(_ test: XCTestCase) -> String {
    guard let range = test.name.range(of: "test[A-Z][A-Za-z0-9_]*", options: .regularExpression) else {
      XCTFail("Cannot identify UI test method: \(test.name)")
      return "unknown"
    }
    return String(test.name[range])
  }

  @MainActor
  private func scenarios(in test: XCTestCase) -> [Scenario] {
    if let manifest { return manifest.scenarios }
    do {
      let url = try XCTUnwrap(
        Bundle(for: BannerLayoutTests.self).url(forResource: "coverage", withExtension: "json"))
      let value = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
      manifest = value
      return value.scenarios
    } catch {
      XCTFail("Cannot load required UI coverage manifest: \(error)")
      return []
    }
  }
}
