import Foundation
import Darwin

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("copy-memory-test-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
try fm.createDirectory(at: source, withIntermediateDirectories: true)
try fm.createDirectory(at: target, withIntermediateDirectories: true)
let input = source.appendingPathComponent("large.bin"), output = target.appendingPathComponent("large.bin")
fm.createFile(atPath: input.path, contents: nil)
let handle = try FileHandle(forWritingTo: input)
let bytes: Int64 = 512 * 1024 * 1024
try handle.truncate(atOffset: UInt64(bytes)); try handle.close()
let stop = CopyCancellation()
let partial = try DirectoryCopyEngine(source: source, destination: target, includeHidden: false, cancellation: stop).run(
    update: { if $0.bytes >= bytes / 2 { stop.cancel() } }, log: { _ in })
guard partial.bytes >= bytes / 2 && partial.bytes < bytes, !fm.fileExists(atPath: output.path) else { fatalError("Large-file interruption failed") }
let resumed = try DirectoryCopyEngine(source: source, destination: target, includeHidden: false, cancellation: CopyCancellation()).run(update: { _ in }, log: { _ in })
guard resumed.failed == 0, resumed.copied == 1, resumed.resumedBytes == partial.bytes,
      try fileSize(output) == bytes, try fileHash(input) == fileHash(output) else { fatalError("Large-file resume or integrity failed") }
var usage = rusage()
guard getrusage(RUSAGE_SELF, &usage) == 0 else { fatalError("Cannot measure process high-water memory") }
guard usage.ru_maxrss < 128 * 1024 * 1024 else { fatalError("Streaming buffers accumulated: peak resident bytes=\(usage.ru_maxrss)") }
print("PASS: 512 MiB streaming, interruption, prefix validation, resume and hashing; peak resident bytes=\(usage.ru_maxrss) (<128 MiB).")
