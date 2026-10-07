import Foundation
import XCTest
@testable import DustPan

final class DestinationSafetyTests: XCTestCase {
    private let fileManager = FileManager.default

    func testAcceptsCoreFolderAndRealNestedDirectories() throws {
        let root = try makeDirectory(named: "core")
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: false)

        XCTAssertTrue(DestinationPathSafety.isSafeDirectory(root, under: root))
        XCTAssertTrue(DestinationPathSafety.isSafeDirectory(nested, under: root))
    }

    func testRejectsSymlinkAtDestinationAndInParentChain() throws {
        let base = try makeDirectory(named: "sandbox")
        let root = base.appendingPathComponent("core", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: false)

        let directLink = root.appendingPathComponent("direct-link", isDirectory: true)
        try fileManager.createSymbolicLink(at: directLink, withDestinationURL: outside)
        XCTAssertFalse(DestinationPathSafety.isSafeDirectory(directLink, under: root))

        let parentLink = root.appendingPathComponent("parent-link", isDirectory: true)
        try fileManager.createSymbolicLink(at: parentLink, withDestinationURL: outside)
        let throughParent = parentLink.appendingPathComponent("nested", isDirectory: true)
        XCTAssertFalse(DestinationPathSafety.isSafeDirectory(throughParent, under: root))
    }

    func testRejectsPathOutsideCoreRoot() throws {
        let base = try makeDirectory(named: "containment")
        let root = base.appendingPathComponent("core", isDirectory: true)
        let outside = root.appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)

        XCTAssertFalse(DestinationPathSafety.isSafeDirectory(outside, under: root))
    }

    func testFileIdentityDetectsReplacementAtSamePath() throws {
        let root = try makeDirectory(named: "undo")
        let movedItem = root.appendingPathComponent("moved.txt")
        let replacement = root.appendingPathComponent("replacement.txt")
        try Data("original".utf8).write(to: movedItem)
        try Data("different item".utf8).write(to: replacement)

        let originalIdentity = try XCTUnwrap(FileIdentity.read(at: movedItem))
        let replacementIdentity = try XCTUnwrap(FileIdentity.read(at: replacement))
        XCTAssertNotEqual(originalIdentity, replacementIdentity)

        try fileManager.removeItem(at: movedItem)
        try fileManager.moveItem(at: replacement, to: movedItem)
        XCTAssertNotEqual(try XCTUnwrap(FileIdentity.read(at: movedItem)), originalIdentity)
    }

    private func makeDirectory(named name: String) throws -> URL {
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("DustPanTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: false)
        let directory = base.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return directory
    }
}
