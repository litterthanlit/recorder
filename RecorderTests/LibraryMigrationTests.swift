import Foundation
import Testing
@testable import RecorderCore

@Suite("Library migration")
struct LibraryMigrationTests {
    private func bundleName(_ index: Int) -> String {
        "0000000\(index)-0000-0000-0000-000000000000.recorder"
    }

    private func contents(of url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    @Test func renamesAFolderThatHoldsOnlyProjects() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanup() }
        try root.write("{}", to: "Recorder/\(bundleName(1))/meta.json")
        try root.write("{}", to: "Recorder/\(bundleName(2))/meta.json")
        try root.write("", to: "Recorder/.DS_Store")
        let legacy = root.url.appendingPathComponent("Recorder")
        let destination = root.url.appendingPathComponent("Trace")

        let report = LibraryMigration.migrate(from: legacy, to: destination)

        #expect(report.renamedFolder)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(contents(of: destination) == [".DS_Store", bundleName(1), bundleName(2)])
    }

    @Test func neverOverwritesAnExistingProject() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanup() }
        try root.write("old", to: "Recorder/\(bundleName(1))/meta.json")
        try root.write("{}", to: "Recorder/\(bundleName(2))/meta.json")
        try root.write("new", to: "Trace/\(bundleName(1))/meta.json")
        let legacy = root.url.appendingPathComponent("Recorder")
        let destination = root.url.appendingPathComponent("Trace")

        let report = LibraryMigration.migrate(from: legacy, to: destination)

        #expect(!report.renamedFolder)
        #expect(report.movedBundles == [bundleName(2)])
        #expect(report.skippedBundles == [bundleName(1)])
        #expect(!report.removedLegacyFolder)
        let kept = try String(contentsOf: destination.appendingPathComponent("\(bundleName(1))/meta.json"), encoding: .utf8)
        #expect(kept == "new")
        #expect(contents(of: legacy) == [bundleName(1)])
    }

    @Test func leavesUnrelatedFilesAndTheirFolderAlone() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanup() }
        try root.write("{}", to: "Recorder/\(bundleName(1))/meta.json")
        try root.write("someone else's", to: "Recorder/notes.txt")
        let legacy = root.url.appendingPathComponent("Recorder")
        let destination = root.url.appendingPathComponent("Trace")

        let report = LibraryMigration.migrate(from: legacy, to: destination)

        #expect(!report.renamedFolder)
        #expect(report.movedBundles == [bundleName(1)])
        #expect(!report.removedLegacyFolder)
        #expect(contents(of: legacy) == ["notes.txt"])
        #expect(contents(of: destination) == [bundleName(1)])
    }

    @Test func runningTwiceChangesNothing() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanup() }
        try root.write("{}", to: "Recorder/\(bundleName(1))/meta.json")
        try root.write("{}", to: "Trace/\(bundleName(2))/meta.json")
        let legacy = root.url.appendingPathComponent("Recorder")
        let destination = root.url.appendingPathComponent("Trace")

        let first = LibraryMigration.migrate(from: legacy, to: destination)
        #expect(first.movedBundles == [bundleName(1)])
        #expect(first.removedLegacyFolder)

        let second = LibraryMigration.migrate(from: legacy, to: destination)
        #expect(second == LibraryMigration.Report())
        #expect(contents(of: destination) == [bundleName(1), bundleName(2)])
    }

    @Test func missingOrEmptyLegacyFolderIsANoOp() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanup() }
        let legacy = root.url.appendingPathComponent("Recorder")
        let destination = root.url.appendingPathComponent("Trace")

        #expect(LibraryMigration.migrate(from: legacy, to: destination) == LibraryMigration.Report())

        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        #expect(LibraryMigration.migrate(from: legacy, to: destination) == LibraryMigration.Report())
        // An unrelated empty "Recorder" folder isn't claimed.
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
