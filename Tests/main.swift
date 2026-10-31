import Foundation
setbuf(stdout, nil)

var checks = 0
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { fatalError(message) }
    checks += 1
}
func expectFailure(_ message: String, _ action: () throws -> Void) throws {
    do { try action() } catch { checks += 1; return }
    fatalError(message)
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("photo-backup-tests-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let destination = root.appendingPathComponent("destination")
try fm.createDirectory(at: destination, withIntermediateDirectories: true)
var archive: Archive? = try Archive(root: destination)
let identity = archive!.identity

func copy(_ key: String, _ name: String, _ content: String, path: String? = nil) throws -> Receipt {
    let partial = archive!.stagingDirectory.appendingPathComponent(".partial-test")
    try Data(content.utf8).write(to: partial)
    let relative = path ?? "2026/10/\(key)/\(name)"
    try fm.createDirectory(at: destination.appendingPathComponent(relative).deletingLastPathComponent(), withIntermediateDirectories: true)
    return try archive!.commit(staging: partial, relativePath: relative, key: key,
        assetIdentifier: key, originalFilename: name, resourceType: 1, creationDate: nil, modificationDate: nil)
}

try expect(!archive!.alreadyCopied("first"), "New resource must require copying")
let first = try copy("first", "IMG_0001.HEIC", "original-image-content")
try expect(archive!.alreadyCopied("first"), "Committed resource must be skipped")
try expect(first.sha256 == digest("original-image-content"), "Checksum must match content")
let second = try copy("second", "IMG_0001.HEIC", "different-image-content")
try expect(first.relativePath != second.relativePath, "Same filename must not overwrite another asset")
let live = try copy("live", "IMG_0001.MOV", "paired-live-video")
try expect(archive!.alreadyCopied("live"), "Live Photo video needs an independent receipt")
try expectFailure("Concurrent writer must be refused") { _ = try Archive(root: destination) }
try fm.removeItem(at: destination.appendingPathComponent(second.relativePath))
try expect(!archive!.alreadyCopied("second"), "Missing file must be retried")
try Data("short".utf8).write(to: destination.appendingPathComponent(first.relativePath))
try expect(!archive!.alreadyCopied("first"), "Truncated file must be retried")
let recovered = try copy("first", "IMG_0001.HEIC", "original-image-content")
try expect(recovered.relativePath != first.relativePath, "Conflicting files must be preserved")
try expect(try String(contentsOf: destination.appendingPathComponent(first.relativePath), encoding: .utf8) == "short", "Never overwrite a target conflict")
try expectFailure("Empty exports must never be committed") { _ = try copy("empty", "empty.mov", "") }

// Simulate a crash after rename but before receipt persistence.
let orphanPath = "2026/10/orphan/original.mov"
let orphan = destination.appendingPathComponent(orphanPath)
try fm.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("orphan-content".utf8).write(to: orphan)
let orphanReceipt = try copy("orphan", "original.mov", "orphan-content", path: orphanPath)
try expect(orphanReceipt.relativePath == orphanPath, "Uncommitted identical files should be reconciled")
let stale = archive!.stagingDirectory.appendingPathComponent(".partial-interrupted")
try Data("partial".utf8).write(to: stale)
archive = nil

let broken = destination.appendingPathComponent(".photo-backup/9999999999999-interrupted.jsonl")
try Data("{truncated-json".utf8).write(to: broken)
archive = try Archive(root: destination, expectedIdentity: identity)
try expect(archive!.alreadyCopied("first"), "Receipts must survive relaunch")
try expect(archive!.alreadyCopied("live"), "Video receipt must survive relaunch")
try expect(archive!.damagedLines == 1, "Torn journal should be detected and ignored")
try expect(!fm.fileExists(atPath: stale.path), "Stale partial should be cleaned under lock")
archive = nil
try expectFailure("Wrong destination must be refused") { _ = try Archive(root: destination, expectedIdentity: "other-drive") }
let missing = root.appendingPathComponent("missing-mount/backup")
try expectFailure("Disconnected target must not be recreated") { _ = try Archive(root: missing) }
try expect(!fm.fileExists(atPath: missing.path), "Disconnected target path must stay absent")
let networkError = NSError(domain: "PHPhotosErrorDomain", code: 3164)
let otherError = NSError(domain: "PHPhotosErrorDomain", code: 3311)
var attempts: [Bool] = []
let fallbackResult = exportWithFallback(allowNetwork: true, shouldStop: { false }) { network in
    attempts.append(network); return network ? nil : networkError
}
try expect(fallbackResult == nil && attempts == [false, true], "3164 must retry with network enabled")
attempts = []
let localResult = exportWithFallback(allowNetwork: true, shouldStop: { false }) { network in
    attempts.append(network); return nil
}
try expect(localResult == nil && attempts == [false], "Available local resources must not trigger network retry")
attempts = []
let offlineResult = exportWithFallback(allowNetwork: false, shouldStop: { false }) { network in
    attempts.append(network); return networkError
}
try expect(offlineResult != nil && attempts == [false], "Offline preference must prevent network retry")
attempts = []
let denied = exportWithFallback(allowNetwork: true, shouldStop: { false }) { network in
    attempts.append(network); return otherError
}
try expect((denied as NSError?)?.code == 3311 && attempts == [false], "Unrelated errors must not trigger downloads")
attempts = []
_ = exportWithFallback(allowNetwork: true, shouldStop: { true }) { network in
    attempts.append(network); return networkError
}
try expect(attempts == [false], "Stop must suppress subsequent cloud retry")
let migrationRoot = root.appendingPathComponent("migration")
let meta = migrationRoot.appendingPathComponent(".photo-backup")
try fm.createDirectory(at: meta, withIntermediateDirectories: true)
try "test-identity".write(to: meta.appendingPathComponent("identity.txt"), atomically: true, encoding: .utf8)
let shotDate = ISO8601DateFormatter().date(from: "2026-09-30T18:30:00Z")!
let fixture: [(String, String, Int, String)] = [
    ("photo", "IMG_1234.HEIC", 1, "image-original"),
    ("live", "IMG_1234.MOV", 9, "live-video-original"),
    ("edited", "FullSizeRender.JPG", 5, "edited-image"),
    ("unknown", "无日期.JPG", 1, "undated-image")
]
var legacy = Data()
for (key, name, type, content) in fixture {
    let relative = "2026/09/\(key)/oldversion/0-\(name)"
    let file = migrationRoot.appendingPathComponent(relative)
    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: file)
    let receipt = Receipt(key: key, relativePath: relative, bytes: Int64(content.utf8.count), sha256: digest(content),
        assetIdentifier: key == "unknown" ? "unknown-asset" : "live-asset", originalFilename: name,
        resourceType: type, creationDate: key == "unknown" ? nil : shotDate, modificationDate: shotDate)
    legacy.append(try JSONEncoder().encode(receipt)); legacy.append(10)
}
try legacy.write(to: meta.appendingPathComponent("legacy.jsonl"))
var migrated: Archive? = try Archive(root: migrationRoot)
let preexisting = BackupLayout.path(date: shotDate, baseFilename: "IMG_1234.HEIC", originalFilename: "IMG_1234.HEIC",
    type: 1, token: migrated!.token(for: "live-asset"))
try fm.createDirectory(at: migrationRoot.appendingPathComponent(preexisting).deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("unrelated-existing-file".utf8).write(to: migrationRoot.appendingPathComponent(preexisting))
try expect(try migrated!.migrateLayout() == 4, "All legacy resources must be migrated")
try expect(try migrated!.migrateLayout() == 0, "Migration must be idempotent")
let photo = migrated!.receipts["photo"]!
let livePhoto = migrated!.receipts["live"]!
try expect(photo.relativePath.hasPrefix("2026/10/20261001_023000_IMG_1234_"), "Layout must use Shanghai date and flat month folders")
try expect(photo.relativePath.split(separator: "/").count == 3, "Normal month must contain files directly")
try expect(livePhoto.assetToken == photo.assetToken, "Live Photo image and video must share an asset token")
try expect(migrated!.receipts["edited"]!.relativePath.contains("_edited.JPG"), "Edited rendition must be marked")
try expect(migrated!.receipts["unknown"]!.relativePath.hasPrefix("_undated/"), "Unknown dates must not use backup date")
try expect(try String(contentsOf: migrationRoot.appendingPathComponent(preexisting), encoding: .utf8) == "unrelated-existing-file", "Migration must preserve unrelated destination conflicts")
try expect(migrated!.receipts.values.allSatisfy { migrated!.alreadyCopied($0.key) }, "Migrated keys must still support incremental skip")
try expect(!fm.fileExists(atPath: migrationRoot.appendingPathComponent("2026/09/photo").path), "Empty old per-asset directories must be removed")
migrated = nil
migrated = try Archive(root: migrationRoot)
try expect(migrated!.receipts["photo"]!.relativePath == photo.relativePath, "New paths must override retained legacy journals after relaunch")

let temp = migrated!.stagingDirectory.appendingPathComponent(".partial-test")
try Data("image-original".utf8).write(to: temp)
let same = try migrated!.commit(staging: temp, relativePath: photo.relativePath, key: "metadata-only-update",
    assetIdentifier: "live-asset", originalFilename: "IMG_1234.HEIC", resourceType: 1,
    creationDate: shotDate, modificationDate: shotDate.addingTimeInterval(1), assetToken: photo.assetToken)
try expect(same.relativePath == photo.relativePath, "Metadata-only changes must reuse identical resource contents")
try expect(migrated!.lastCommitReused, "Identical content reuse must be counted as skipped")
try Data("changed-image-content".utf8).write(to: temp)
let changed = try migrated!.commit(staging: temp, relativePath: photo.relativePath, key: "content-update",
    assetIdentifier: "live-asset", originalFilename: "IMG_1234.HEIC", resourceType: 1,
    creationDate: shotDate, modificationDate: shotDate.addingTimeInterval(2), assetToken: photo.assetToken)
try expect(changed.relativePath == photo.relativePath, "New content must occupy the current main path")
try expect(!migrated!.lastCommitReused, "Changed content must be counted as copied")
try expect(changed.bytes == Int64("changed-image-content".utf8.count), "Reused staging URL must not return a cached file size")
try expect(migrated!.receipts["photo"]!.relativePath.hasPrefix("_versions/2026/10/"), "Previous contents must be moved to versions")
try expect(migrated!.receipts["photo"]!.relativePath == migrated!.receipts["metadata-only-update"]!.relativePath, "All aliases of archived contents must be updated together")
try expect(try fileHash(migrationRoot.appendingPathComponent(migrated!.receipts["photo"]!.relativePath)) == digest("image-original"), "Previous original contents must remain intact")

// Simulate a crash between a filesystem rename and its receipt update.
let before = migrated!.receipts["live"]!
let pendingTarget = BackupLayout.addingSuffix("_recovery-test", to: before.relativePath)
let pending = PendingMove(from: before.relativePath, to: pendingTarget, bytes: before.bytes, sha256: before.sha256,
    updates: [before.relocating(to: pendingTarget)])
try JSONEncoder().encode(pending).write(to: meta.appendingPathComponent("pending-move.json"), options: .atomic)
try fm.moveItem(at: migrationRoot.appendingPathComponent(before.relativePath), to: migrationRoot.appendingPathComponent(pendingTarget))
migrated = nil
migrated = try Archive(root: migrationRoot)
try expect(migrated!.receipts["live"]!.relativePath == pendingTarget && migrated!.alreadyCopied("live"), "Interrupted move must repair its journal on reopen")
try expect(!fm.fileExists(atPath: meta.appendingPathComponent("pending-move.json").path), "Recovered operation must clear its pending intent")
try expect(BackupLayout.safe(String(repeating: "照", count: 200)).utf8.count <= 110, "Long Unicode filenames must respect byte limits")
let stillLive: Set<String> = ["live-asset"]
let incomplete = try migrated!.reconcileDeleted(liveAssets: stillLive, fullSuccessfulScan: false, sourceStable: true)
try expect(incomplete.archived == 0 && incomplete.warning != nil, "Partial scans must not archive missing assets")
let unstable = try migrated!.reconcileDeleted(liveAssets: stillLive, fullSuccessfulScan: true, sourceStable: false)
try expect(unstable.archived == 0 && unstable.warning != nil, "Changed source must prevent deletion reconciliation")
let emptySource = try migrated!.reconcileDeleted(liveAssets: [], fullSuccessfulScan: true, sourceStable: true)
try expect(emptySource.archived == 0 && emptySource.warning != nil, "Empty source must not trigger mass archival")
let cancelled = try migrated!.reconcileDeleted(liveAssets: stillLive, fullSuccessfulScan: true, sourceStable: true, shouldStop: { true })
try expect(cancelled.archived == 0, "Cancelled scans must not archive")
let reappeared = try migrated!.reconcileDeleted(liveAssets: stillLive, fullSuccessfulScan: true, sourceStable: true, stillMissing: { _ in false })
try expect(reappeared.archived == 0, "Asset restored during reconciliation must not be archived")
let oldUnknownPath = migrated!.receipts["unknown"]!.relativePath
let removed = try migrated!.reconcileDeleted(liveAssets: stillLive, fullSuccessfulScan: true, sourceStable: true)
try expect(removed.archived == 1, "Missing asset must be moved into deletion archive")
try expect(migrated!.receipts["unknown"]!.relativePath.hasPrefix("_deleted/") && migrated!.alreadyCopied("unknown"), "Archived file must retain content and an updated receipt")
try expect(!fm.fileExists(atPath: migrationRoot.appendingPathComponent(oldUnknownPath).path), "Archived resource must leave the active month directory")
let repeated = try migrated!.reconcileDeleted(liveAssets: stillLive, fullSuccessfulScan: true, sourceStable: true)
try expect(repeated.archived == 0, "Already archived deletions must not be processed twice")
migrated = nil
migrated = try Archive(root: migrationRoot)
try expect(migrated!.receipts["unknown"]!.deletedOriginalPath == oldUnknownPath, "Deletion metadata must survive relaunch")
try expect(try migrated!.restoreAsset("unknown-asset") == 1, "Reappearing asset must restore from the deletion archive")
try expect(migrated!.receipts["unknown"]!.relativePath == oldUnknownPath && migrated!.receipts["unknown"]!.deletedOriginalPath == nil, "Restore must clear deletion metadata and recover the original path")
let groupSize = Set(migrated!.receipts.values.filter { $0.assetIdentifier == "live-asset" }.map(\.relativePath)).count
let removedGroup = try migrated!.reconcileDeleted(liveAssets: ["unknown-asset"], fullSuccessfulScan: true, sourceStable: true)
try expect(removedGroup.archived == groupSize, "Originals, paired video and historical versions must archive together, counting aliases once")
try expect(try migrated!.restoreAsset("live-asset") == groupSize, "All paired resources and versions must be restorable")
for index in 0..<101 {
    try migrated!.append(Receipt(key: "guard-\(index)", relativePath: "guard-\(index).JPG", bytes: 1,
        sha256: digest("x"), assetIdentifier: "guard-\(index)", originalFilename: "guard.JPG",
        resourceType: 1, creationDate: nil, modificationDate: nil, layoutVersion: 2))
}
let massMissing = try migrated!.reconcileDeleted(liveAssets: ["live-asset", "unknown-asset"], fullSuccessfulScan: true, sourceStable: true)
try expect(massMissing.archived == 0 && massMissing.warning != nil, "A large unexpected disappearance must be deferred for source verification")
let logFolder = root.appendingPathComponent("logs")
try expect(TaskLogHistory.latest(in: logFolder) == nil, "Missing log directory must be supported")
try fm.createDirectory(at: logFolder, withIntermediateDirectories: true)
try expect(TaskLogHistory.latest(in: logFolder) == nil, "Empty history must disable opening")
let olderLog = logFolder.appendingPathComponent("older.txt")
let newestLog = logFolder.appendingPathComponent("newest.txt")
for (file, seconds) in [(olderLog, 1000.0), (newestLog, 2000.0)] {
    try Data("test log".utf8).write(to: file)
    try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: seconds), .modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: file.path)
}
try Data().write(to: logFolder.appendingPathComponent("ignored.json"))
try Data().write(to: logFolder.appendingPathComponent(".hidden.txt"))
try fm.createDirectory(at: logFolder.appendingPathComponent("directory.txt"), withIntermediateDirectories: true)
try fm.createSymbolicLink(at: logFolder.appendingPathComponent("link.txt"), withDestinationURL: olderLog)
try expect(TaskLogHistory.latest(in: logFolder)?.lastPathComponent == "newest.txt", "History must ignore non-log files, hidden files, directories and links")
try expect(TaskLogHistory.latest(in: logFolder, excluding: newestLog)?.lastPathComponent == "older.txt", "Running task must expose the preceding log")
try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: olderLog.path)
try expect(TaskLogHistory.latest(in: logFolder)?.lastPathComponent == "newest.txt", "Editing an older log must not change task order")
try fm.removeItem(at: newestLog)
try expect(TaskLogHistory.latest(in: logFolder)?.lastPathComponent == "older.txt", "History must rescan after restart or removal")
try expect(TaskLogHistory.directory(.photo) != TaskLogHistory.directory(.directory), "Tabs must have independent log histories")
print("PASS: \(checks) assertions; backup safety, recovery and task log history.")
