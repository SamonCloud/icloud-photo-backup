import Foundation
import Darwin

setbuf(stdout, nil)
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("directory-copy-tests-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
var checks = 0
func expect(_ value: @autoclosure () throws -> Bool, _ text: String) throws {
    guard try value() else { fatalError(text) }; checks += 1
}
func folder(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name); try fm.createDirectory(at: url, withIntermediateDirectories: true); return url
}
func write(_ root: URL, _ path: String, _ value: String) throws {
    let file = root.appendingPathComponent(path)
    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(value.utf8).write(to: file)
}
func copy(_ source: URL, _ dest: URL, hidden: Bool = false, keep: Bool = true,
          control: CopyCancellation = CopyCancellation(), quick: Bool = false, update: (DirectoryCopyProgress) -> Void = { _ in }) throws -> DirectoryCopyProgress {
    let engine = try DirectoryCopyEngine(source: source, destination: dest, includeHidden: hidden, keepExtras: keep, quickCheck: quick, cancellation: control)
    return try engine.run(update: update, log: { print("LOG", $0) })
}
let source = try folder("source"), dest = try folder("destination")
try write(source, "normal.txt", "new data")
try write(source, "nested/deep.txt", "nested data")
try write(source, ".hidden-file", "include hidden files")
try write(source, ".secret/inside.txt", "hidden directory")
try write(source, "nested/.hidden/inside.txt", "nested hidden directory")
try fm.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
try fm.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "nested/deep.txt")
try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.appendingPathComponent("normal.txt").path)
let value = Data("test extended attribute".utf8)
let attrResult = value.withUnsafeBytes { setxattr(source.appendingPathComponent("normal.txt").path, "com.example.directory-copy", $0.baseAddress, value.count, 0, 0) }
try expect(attrResult == 0, "Fixture xattr must be set")
try write(dest, "normal.txt", "old")
try write(dest, "extra.txt", "keep this")
let first = try copy(source, dest)
try expect(first.failed == 0, "Initial copy must preserve all supported metadata")
try expect(first.copied == 4, "Normal files, nested file, hidden file and symlink must copy")
try expect(!fm.fileExists(atPath: dest.appendingPathComponent(".secret").path), "Hidden directory must be excluded by default")
try expect(!fm.fileExists(atPath: dest.appendingPathComponent("nested/.hidden").path), "Nested hidden directory must be excluded")
try expect(fm.fileExists(atPath: dest.appendingPathComponent("empty").path), "Empty directories must be copied")
try expect(try CopyFileStamp.read(source.appendingPathComponent("normal.txt")) == CopyFileStamp.read(dest.appendingPathComponent("normal.txt")), "Metadata and xattrs must match")
try expect(try fm.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("link").path) == "nested/deep.txt", "Symlinks must be preserved without traversal")
try expect(fm.fileExists(atPath: dest.appendingPathComponent("extra.txt").path), "Destination-only files must be retained by default")
let second = try copy(source, dest)
try expect(second.failed == 0 && second.copied == 0 && second.skipped == 4, "Second run must skip unchanged files without transfers")
let hidden = try copy(source, dest, hidden: true)
try expect(hidden.failed == 0 && hidden.copied == 2, "Include-hidden option must include both hidden directories")
let removed = try copy(source, dest, keep: false)
try expect(removed.failed == 0 && removed.archivedExtras == 1, "Unselected keep-extras option must archive destination-only content")
try expect(!fm.fileExists(atPath: dest.appendingPathComponent("extra.txt").path), "Extra must leave the active destination")
let archive = dest.appendingPathComponent(".directory-copy-archive")
let batches = try fm.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
try expect(try String(contentsOf: batches[0].appendingPathComponent("files/extra.txt"), encoding: .utf8) == "keep this", "Destination-only content must remain recoverable")
try expect(fm.fileExists(atPath: dest.appendingPathComponent(".secret/inside.txt").path), "Excluded hidden directories must not be treated as destination-only extras")

let resumeSource = try folder("resume-source"), resumeDest = try folder("resume-destination")
let large = Data(repeating: 0x3A, count: 24 * 1024 * 1024)
try large.write(to: resumeSource.appendingPathComponent("large.bin"))
let stop = CopyCancellation()
let partial = try copy(resumeSource, resumeDest, control: stop, update: { state in if state.bytes > 0 { stop.cancel() } })
try expect(partial.bytes > 0 && partial.bytes < Int64(large.count), "Stop must interrupt inside a large file")
try expect(!fm.fileExists(atPath: resumeDest.appendingPathComponent("large.bin").path), "Incomplete file must not become the final target")
let resumed = try copy(resumeSource, resumeDest, quick: true)
try expect(resumed.failed == 0 && resumed.resumedBytes == partial.bytes, "Restart must reuse validated bytes instead of starting over")
try expect(try Data(contentsOf: resumeDest.appendingPathComponent("large.bin")) == large, "Resumed data must be exact")
try fm.removeItem(at: resumeDest.appendingPathComponent("large.bin"))
let corruptStop = CopyCancellation()
_ = try copy(resumeSource, resumeDest, control: corruptStop, update: { if $0.bytes > 0 { corruptStop.cancel() } })
let work = try fm.contentsOfDirectory(at: resumeDest, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".directory-copy-") }!
let partialFile = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first { $0.pathExtension == "partial" }!
try Data(repeating: 0x44, count: 8 * 1024 * 1024).write(to: partialFile)
let repaired = try copy(resumeSource, resumeDest)
try expect(repaired.failed == 0 && repaired.resumedBytes == 0, "Corrupt partial must restart only its own file automatically")
try expect(try Data(contentsOf: resumeDest.appendingPathComponent("large.bin")) == large, "Corrupt partial recovery must produce exact data")

let changedSource = try folder("changing-source"), changedDest = try folder("changing-target")
try large.write(to: changedSource.appendingPathComponent("large.bin"))
try write(changedDest, "extra.txt", "keep when source changes")
var added = false
let changed = try copy(changedSource, changedDest, keep: false, update: { state in
    if state.bytes > 0 && !added { added = true; try! write(changedSource, "new.txt", "created during copy") }
})
try expect(changed.failed > 0 && fm.fileExists(atPath: changedDest.appendingPathComponent("extra.txt").path), "Source structure changes must prevent destination cleanup")

let unicodeSource = try folder("中文 源目录"), unicodeDest = try folder("中文 目标目录")
try write(unicodeSource, "子目录/文 件.txt", "unicode")
let unicode = try copy(unicodeSource, unicodeDest)
try expect(unicode.failed == 0 && fm.fileExists(atPath: unicodeDest.appendingPathComponent("子目录/文 件.txt").path), "Unicode and space-containing paths must copy correctly")

do { _ = try DirectoryCopyEngine(source: source, destination: source.appendingPathComponent("nested"), includeHidden: true, cancellation: CopyCancellation()); fatalError("Nested target must be refused") }
catch { checks += 1 }
let unsafe = try folder("unsafe-target"), outside = try folder("outside")
try fm.createSymbolicLink(atPath: unsafe.appendingPathComponent("nested").path, withDestinationPath: outside.path)
do { _ = try copy(source, unsafe); fatalError("Destination parent symlink must be refused") }
catch { checks += 1 }
try expect(!fm.fileExists(atPath: outside.appendingPathComponent("deep.txt").path), "Never write through a target parent symlink")

let failedDest = try folder("failed-target")
try fm.createDirectory(at: failedDest.appendingPathComponent("normal.txt"), withIntermediateDirectories: true)
try write(failedDest, "extra.txt", "must survive failed copy")
let failed = try copy(source, failedDest, keep: false)
try expect(failed.failed > 0 && fm.fileExists(atPath: failedDest.appendingPathComponent("extra.txt").path), "Failed copies must never clean destination extras")
var estimate = DirectoryCopyProgress()
estimate.scanning = false; estimate.bytes = 100; estimate.totalBytes = 300; estimate.elapsed = 10
try expect(estimate.remaining == 20, "ETA must use actual transfer throughput and remaining pending bytes")
estimate.resumedBytes = 50
try expect(estimate.remaining == 40, "Previously transferred bytes must not inflate the current transfer rate")
estimate.scanning = true
try expect(estimate.remaining == nil, "ETA must remain unknown during the initial scan")

func changedStamp(_ original: CopyFileStamp, _ values: [String: Any]) throws -> CopyFileStamp {
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
    for (key, value) in values { json[key] = value }
    return try JSONDecoder().decode(CopyFileStamp.self, from: JSONSerialization.data(withJSONObject: json))
}
let originalStamp = try CopyFileStamp.read(source.appendingPathComponent("normal.txt"))
let nasStamp = try changedStamp(originalStamp, ["mode": 0o700, "uid": 999, "gid": 999,
    "createdNano": 0, "modifiedNano": 0, "flags": 32768,
    "attributes": ["com.apple.quarantine": "system-rewritten"], "acl": "server-mapped-acl"])
try expect(originalStamp.matchesCopyRequirements(nasStamp), "NAS permissions, ACL, xattrs and subsecond differences must not fail")
try expect(!originalStamp.sameSourceVersion(try changedStamp(originalStamp, ["modifiedNano": (originalStamp.modifiedNano + 1) % 1_000_000_000])), "Resume safety must still detect a subsecond source change")
try expect(!originalStamp.matchesCopyRequirements(try changedStamp(originalStamp, ["size": originalStamp.size + 1])), "Size difference must still require copying")
try expect(!originalStamp.matchesCopyRequirements(try changedStamp(originalStamp, ["created": originalStamp.created - 1])), "Creation seconds must match exactly")
try expect(!originalStamp.matchesCopyRequirements(try changedStamp(originalStamp, ["modified": originalStamp.modified + 1])), "Modification seconds must match exactly")
try expect(!copyFilenameMatches(source.appendingPathComponent("normal.txt"), sourceName: "another.txt"), "A different filename must never match")

let relaxedSource = try folder("seconds-source"), relaxedDest = try folder("seconds-target")
try write(relaxedSource, "same.txt", "keep content")
_ = try copy(relaxedSource, relaxedDest)
let sameFile = relaxedDest.appendingPathComponent("same.txt")
let stamp = try CopyFileStamp.read(relaxedSource.appendingPathComponent("same.txt"))
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sameFile.path)
let rewritten = Data("server rewrite".utf8)
_ = rewritten.withUnsafeBytes { setxattr(sameFile.path, "com.example.server-only", $0.baseAddress, rewritten.count, 0, 0) }
var attrs = attrlist(); attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
attrs.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
struct TestTimes { var created: timespec; var modified: timespec }
var times = TestTimes(created: timespec(tv_sec: Int(stamp.created), tv_nsec: 0), modified: timespec(tv_sec: Int(stamp.modified), tv_nsec: 0))
try expect(setattrlist(sameFile.path, &attrs, &times, MemoryLayout<TestTimes>.size, UInt32(FSOPT_NOFOLLOW)) == 0, "Subsecond fixture must be set")
let relaxed = try copy(relaxedSource, relaxedDest)
try expect(relaxed.failed == 0 && relaxed.copied == 0 && relaxed.skipped == 1, "Different optional attributes and nanoseconds must skip the actual file without recopying")
try expect(try fileHash(relaxedSource.appendingPathComponent("same.txt")) == fileHash(sameFile), "Skipping optional attribute differences must preserve content")
func quickCopy(_ input: URL, _ output: URL, keep: Bool = true, enabled: Bool = true,
               control: CopyCancellation = CopyCancellation()) throws -> DirectoryCopyProgress {
    try DirectoryCopyEngine(source: input, destination: output, includeHidden: false, keepExtras: keep,
        quickCheck: enabled, cancellation: control).run(update: { _ in }, log: { _ in })
}
let fastSource = try folder("fast-source"), fastDest = try folder("fast-destination")
try write(fastSource, "same.txt", "AAAA")
try write(fastDest, "same.txt", "BBBB")
try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: fastDest.appendingPathComponent("same.txt").path)
let fast = try quickCopy(fastSource, fastDest)
try expect(fast.copied == 0 && fast.skipped == 1 && fast.failed == 0, "Equal counts and total sizes must bypass timestamps")
try expect(try String(contentsOf: fastDest.appendingPathComponent("same.txt"), encoding: .utf8) == "BBBB", "Quick mode deliberately skips same-size content changes")
let full = try quickCopy(fastSource, fastDest, enabled: false)
try expect(full.copied == 1 && full.failed == 0, "Disabling quick mode must restore timestamp comparison")
try write(fastSource, "child/new.txt", "new child")
let childCopy = try quickCopy(fastSource, fastDest)
try expect(childCopy.copied == 1 && childCopy.failed == 0, "Matching parent files must not hide missing child directories")
try write(fastSource, "child/new.txt", "changed length")
let sizeChange = try quickCopy(fastSource, fastDest)
try expect(sizeChange.copied == 1 && sizeChange.failed == 0, "Changed total size must trigger original checks")
try write(fastSource, "child/empty.txt", "")
let countChange = try quickCopy(fastSource, fastDest)
try expect(countChange.copied == 1 && countChange.failed == 0, "Changed count with unchanged total bytes must trigger original checks")
let renameSource = try folder("fast-rename-source"), renameDest = try folder("fast-rename-dest")
try write(renameSource, "new.txt", "same")
try write(renameDest, "old.txt", "same")
let renamedResult = try quickCopy(renameSource, renameDest, keep: false)
try expect(renamedResult.copied == 1 && renamedResult.archivedExtras == 1 && renamedResult.failed == 0, "Archival must not remove old name before copying renamed equal-size file")
let linkSource = try folder("fast-link-source"), linkDest = try folder("fast-link-dest")
try write(linkSource, "nested/file.txt", "abc")
try fm.createSymbolicLink(atPath: linkDest.appendingPathComponent("nested").path, withDestinationPath: fastSource.path)
do { _ = try quickCopy(linkSource, linkDest); fatalError("Quick mode must reject destination parent links") }
catch { checks += 1 }
let stopped = CopyCancellation(); stopped.cancel()
let interrupted = try quickCopy(fastSource, fastDest, control: stopped)
try expect(interrupted.copied == 0, "Cancelled quick scans must not start copying")
let restarted = try quickCopy(fastSource, fastDest)
try expect(restarted.copied == 0 && restarted.failed == 0, "Restarted scans must skip already copied groups")
print("PASS: \(checks) directory-copy checks; metadata, xattrs, symlinks, diff, hidden directories, extras archive, large-file resume and failure safety.")
