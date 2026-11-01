import Foundation
import Darwin
import ImageIO
import CoreGraphics
import AVFoundation

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("camera-import-tests-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
var checks = 0
func expect(_ condition: @autoclosure () throws -> Bool, _ text: String) throws {
    guard try condition() else { fatalError(text) }; checks += 1
}
func folder(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name); try fm.createDirectory(at: url, withIntermediateDirectories: true); return url
}
func write(_ directory: URL, _ name: String, _ data: String) throws {
    let url = directory.appendingPathComponent(name)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(data.utf8).write(to: url)
}
func date(_ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))!
}
let rule = try CameraDateRule("yyyymmdd")
try expect(rule.name(date(29)) == "20261029", "Default lowercase mm must mean month")
try expect(try CameraDateRule("yyyy-mm-dd_旅行").name(date(29)) == "2026-10-29_旅行", "Custom rules must render literals and date")
try expect(try CameraDateRule("yyyy年MM月dd日").name(date(29)) == "2026年10月29日", "Chinese naming must render")
for invalid in ["../yyyymmdd", "yyyy/mm/dd", "yyyy-mm", ".yyyymmdd", "yyyymmdd\n"] {
    do { _ = try CameraDateRule(invalid); if invalid == "yyyymmdd\n" { checks += 1; continue }; fatalError("Unsafe rule accepted") } catch { checks += 1 }
}
for ext in ["JPG", "HEIF", "HIF", "ARW", "DNG", "CR3", "NEF", "MP4", "MOV", "MTS"] {
    try expect(CameraMedia.accepts(URL(fileURLWithPath: "sample.\(ext)")), "Common camera media type must be supported")
}
try expect(!CameraMedia.accepts(URL(fileURLWithPath: "sample.xml")), "Unrelated sidecars must not import")
func run(_ source: URL, _ target: URL, onlyNew: Bool = true, pattern: String = "yyyymmdd", stop: CopyCancellation = CopyCancellation(),
         update: (DirectoryCopyProgress) -> Void = { _ in },
         choose: (String, [String]) -> CameraConflictChoice = { _, _ in .importFiles }) throws -> DirectoryCopyProgress {
    let engine = try CameraImportEngine(source: source, destination: target, pattern: pattern, onlyNew: onlyNew, cancellation: stop,
        dateReader: { url in url.lastPathComponent.hasPrefix("day30") ? date(30) : date(29) })
    return try engine.run(update: update, log: { if $0.contains("失败") { print($0); fflush(stdout) } }, conflict: choose)
}
let source = try folder("card"), dest = try folder("destination")
try write(source, "DCIM/100SONY/DSC0001.JPG", "jpeg data")
try write(source, "DCIM/100SONY/DSC0001.ARW", "raw data")
try write(source, "PRIVATE/M4ROOT/CLIP/movie.MP4", "video data")
try write(source, "other/DSC0002.HEIF", "heif data")
try write(source, ".Trashes/ignored.JPG", "system trash")
try write(source, "PRIVATE/info.XML", "ignore")
try fm.createSymbolicLink(at: source.appendingPathComponent("linked"), withDestinationURL: dest)
let first = try run(source, dest)
try expect(first.copied == 4 && first.failed == 0, "All visible card directories must import images, RAW and video")
try expect(fm.fileExists(atPath: dest.appendingPathComponent("20261029/RAW/DSC0001.ARW").path), "RAW belongs in date/RAW")
try expect(fm.fileExists(atPath: dest.appendingPathComponent("20261029/movie.MP4").path), "Video belongs in date root")
try expect(!fm.fileExists(atPath: dest.appendingPathComponent("20261029/ignored.JPG").path), "Hidden camera metadata must not import")
try expect(try fileHash(source.appendingPathComponent("DCIM/100SONY/DSC0001.JPG")) == fileHash(dest.appendingPathComponent("20261029/DSC0001.JPG")), "Imported bytes must be preserved")
let second = try run(source, dest, choose: { _, _ in fatalError("Already imported files must not prompt") })
try expect(second.copied == 0 && second.skipped == 4, "Persistent history must skip successful files on restart")
try fm.removeItem(at: dest.appendingPathComponent("20261029/DSC0001.JPG"))
let missing = try run(source, dest)
try expect(missing.copied == 1 && missing.failed == 0, "Missing target must retry even when history exists")
try write(source, "DCIM/100SONY/day30.JPG", "new photograph")
let new = try run(source, dest)
try expect(new.copied == 1 && new.skipped == 4, "Only a newly photographed file must import")
let full = try run(source, dest, onlyNew: false)
try expect(full.copied == 0 && full.skipped == 5 && full.failed == 0, "Full import must deduplicate identical bytes without extra copies")
try write(source, "another/DSC0001.JPG", "different photo, same filename")
let collision = try run(source, dest)
try expect(collision.copied == 1 && collision.failed == 0, "Same name with different data must retain both files")
try expect(fm.fileExists(atPath: dest.appendingPathComponent("20261029/DSC0001_2.JPG").path), "Collisions need a new suffix")
let conflictDest = try folder("conflict-destination")
try fm.createDirectory(at: conflictDest.appendingPathComponent("20261029_旅行"), withIntermediateDirectories: true)
try fm.createDirectory(at: conflictDest.appendingPathComponent("20261030 notes"), withIntermediateDirectories: true)
var prompts = 0
let skipAll = try run(source, conflictDest, choose: { day, names in
    prompts += 1
    try! expect(names.contains("20261029_旅行") && day == "20261029", "Date-prefix directory must trigger prompt")
    return .skipAll
})
try expect(prompts == 1 && skipAll.copied == 0 && skipAll.skipped == 6, "Skip all must suppress later existing-day prompts")
try write(source, "novel/day31.MOV", "another date") // Inject date reader separately below.
let skipSource = try folder("skip-card"), skipDest = try folder("skip-target")
try write(skipSource, "same.JPG", "jpg"); try write(skipSource, "same.ARW", "raw")
try write(skipSource, "day30.MOV", "new video")
try fm.createDirectory(at: skipDest.appendingPathComponent("20261029_event"), withIntermediateDirectories: true)
let skippedDay = try run(skipSource, skipDest, choose: { _, _ in .skip })
try expect(skippedDay.skipped == 2 && skippedDay.copied == 1, "Skip must cover all files of that date and continue new dates")
let retry = try run(skipSource, skipDest)
try expect(retry.copied == 2 && retry.skipped == 1, "User-skipped files must not become successfully imported history")
let allDest = try folder("all-with-new-day")
try fm.createDirectory(at: allDest.appendingPathComponent("20261029"), withIntermediateDirectories: true)
let allNew = try run(skipSource, allDest, choose: { _, _ in .skipAll })
try expect(allNew.skipped == 2 && allNew.copied == 1, "Skip all must still import dates absent from target")
let unsafeDest = try folder("unsafe-destination"), outside = try folder("outside")
try fm.createSymbolicLink(at: unsafeDest.appendingPathComponent("20261029"), withDestinationURL: outside)
let unsafe = try run(skipSource, unsafeDest)
try expect(unsafe.failed == 2 && (try fm.contentsOfDirectory(atPath: outside.path)).isEmpty, "Import must not write through target date links")
let customDest = try folder("custom-target")
let custom = try run(skipSource, customDest, pattern: "yyyy-mm-dd_相机")
try expect(custom.failed == 0 && fm.fileExists(atPath: customDest.appendingPathComponent("2026-10-29_相机/RAW/same.ARW").path), "Custom date naming must apply to RAW routing")
let stoppedDest = try folder("stopped-target"), control = CopyCancellation(); control.cancel()
let cancelled = try run(skipSource, stoppedDest, stop: control)
try expect(cancelled.copied == 0, "Pre-cancelled import must not copy files")
let resumed = try run(skipSource, stoppedDest)
try expect(resumed.copied == 3 && resumed.failed == 0, "Cancelled work must remain eligible on restart")
let hiddenSource = try folder("hidden-card"), hiddenDest = try folder("hidden-target")
try write(hiddenSource, ".hidden/photos.JPG", "hidden folder photograph")
try write(hiddenSource, "DCIM/._photos.JPG", "AppleDouble resource fork")
let hiddenImport = try run(hiddenSource, hiddenDest)
try expect(hiddenImport.copied == 1 && fm.fileExists(atPath: hiddenDest.appendingPathComponent("20261029/photos.JPG").path), "Camera import must traverse hidden media folders but ignore AppleDouble metadata")
let streamSource = try folder("stream-card"), streamDest = try folder("stream-target")
let streamFile = streamSource.appendingPathComponent("clip.MP4")
fm.createFile(atPath: streamFile.path, contents: nil)
let streamHandle = try FileHandle(forWritingTo: streamFile)
try streamHandle.truncate(atOffset: 24 * 1024 * 1024); try streamHandle.close()
let streamStop = CopyCancellation()
let partialImport = try run(streamSource, streamDest, stop: streamStop, update: { if $0.bytes > 0 { streamStop.cancel() } })
try expect(partialImport.copied == 0 && partialImport.bytes < 24 * 1024 * 1024, "Stop must interrupt a large camera file before publishing it")
try expect(!fm.fileExists(atPath: streamDest.appendingPathComponent("20261029/clip.MP4").path), "Partial camera files must not appear as final files")
let streamRetry = try run(streamSource, streamDest)
try expect(streamRetry.copied == 1 && streamRetry.failed == 0, "Interrupted camera file must remain new on retry")
try expect(try fileHash(streamFile) == fileHash(streamDest.appendingPathComponent("20261029/clip.MP4")), "Retried camera bytes must be exact")
let latestRecord = try JSONDecoder().decode(CameraReceipt.self, from: Data(contentsOf: dest.appendingPathComponent(".camera-import/last-import.json")))
try expect(latestRecord.captured == date(30), "Last-file marker must track latest capture date, not directory iteration order")
let journalURL = try fm.contentsOfDirectory(at: dest.appendingPathComponent(".camera-import"), includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" }!
let damagedTail = try FileHandle(forWritingTo: journalURL); try damagedTail.seekToEnd(); try damagedTail.write(contentsOf: Data("{incomplete".utf8)); try damagedTail.close()
let recoverJournal = try run(source, dest)
try expect(recoverJournal.failed == 0, "Incomplete receipt tail must not prevent later imports")
let deletedSource = try folder("deleted-day-card"), deletedDest = try folder("deleted-day-target")
try write(deletedSource, "same.JPG", "original jpg")
try write(deletedSource, "same.ARW", "original raw")
_ = try run(deletedSource, deletedDest)
try fm.removeItem(at: deletedDest.appendingPathComponent("20261029"))
try write(deletedSource, "later.JPG", "later same date")
let excludedDay = try run(deletedSource, deletedDest, choose: { _, _ in fatalError("Deleted dates must skip without prompting") })
try expect(excludedDay.copied == 0 && excludedDay.skipped == 3, "Deleted dates must exclude both old and newly discovered files of that date")
try expect(!fm.fileExists(atPath: deletedDest.appendingPathComponent("20261029").path), "Deleted date directory must not be recreated")
try write(deletedSource, "day30.MOV", "new date")
let nextDate = try run(deletedSource, deletedDest)
try expect(nextDate.copied == 1 && nextDate.skipped == 3, "New dates must still import when a prior date is excluded")
let reimport = try run(deletedSource, deletedDest, onlyNew: false)
try expect(reimport.copied == 3 && reimport.failed == 0, "Disabling only-new must permit intentional reimport of excluded dates")
try write(deletedSource, "another.JPG", "same excluded date after restoring directory")
let persistent = try run(deletedSource, deletedDest)
try expect(persistent.copied == 0 && persistent.skipped == 5, "Date exclusions must persist after restart and manual restoration")
let renamedSource = try folder("renamed-card"), renamedDest = try folder("renamed-target")
try write(renamedSource, "photo.JPG", "first photo")
_ = try run(renamedSource, renamedDest)
try fm.moveItem(at: renamedDest.appendingPathComponent("20261029"), to: renamedDest.appendingPathComponent("20261029_旅行"))
try write(renamedSource, "more.JPG", "new same-day photo")
let renamedDay = try run(renamedSource, renamedDest)
try expect(renamedDay.copied > 0 && renamedDay.failed == 0, "A date-prefix rename must not create a deletion exclusion")
let imageURL = root.appendingPathComponent("exif.jpg")
let color = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: color, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let image = context.makeImage()!
let output = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.jpeg" as CFString, 1, nil)!
CGImageDestinationAddImage(output, image, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:29 12:00:00"]] as CFDictionary)
try expect(CGImageDestinationFinalize(output), "EXIF fixture must encode")
try expect(rule.name(try CameraMedia.captureDate(imageURL)) == "20261029", "EXIF capture date must take precedence over filesystem time")
let movieURL = root.appendingPathComponent("metadata.mov")
let movieWriter = try AVAssetWriter(outputURL: movieURL, fileType: .mov)
let creation = AVMutableMetadataItem()
creation.keySpace = .common; creation.key = AVMetadataKey.commonKeyCreationDate as NSString
creation.value = ISO8601DateFormatter().string(from: date(29)) as NSString
movieWriter.metadata = [creation]
let movieInput = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: movieInput, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16])
movieWriter.add(movieInput)
try expect(movieWriter.startWriting(), "Video metadata fixture must start")
movieWriter.startSession(atSourceTime: .zero)
var pixel: CVPixelBuffer?
try expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB, nil, &pixel) == kCVReturnSuccess, "Video fixture pixel buffer must allocate")
CVPixelBufferLockBaseAddress(pixel!, [])
memset(CVPixelBufferGetBaseAddress(pixel!), 0, CVPixelBufferGetDataSize(pixel!))
CVPixelBufferUnlockBaseAddress(pixel!, [])
let readyDeadline = Date().addingTimeInterval(5)
while !movieInput.isReadyForMoreMediaData && Date() < readyDeadline { usleep(1000) }
try expect(adaptor.append(pixel!, withPresentationTime: .zero), "Video fixture must append frame")
movieInput.markAsFinished()
let finishedMovie = DispatchSemaphore(value: 0)
movieWriter.finishWriting { finishedMovie.signal() }
try expect(finishedMovie.wait(timeout: .now() + 10) == .success && movieWriter.status == .completed, "Video metadata fixture must finish")
try expect(rule.name(try CameraMedia.captureDate(movieURL)) == "20261029", "Video creation metadata must take precedence over filesystem time")
let fallback = root.appendingPathComponent("fallback.ARW")
try Data("unsupported raw fixture".utf8).write(to: fallback)
try fm.setAttributes([.modificationDate: date(30)], ofItemAtPath: fallback.path)
try expect(rule.name(try CameraMedia.captureDate(fallback)) == "20261030", "Unreadable metadata must fall back to file modification date")
try expect(!fm.fileExists(atPath: source.appendingPathComponent(".camera-import").path), "Source card must never be modified")
print("PASS: \(checks) camera import checks; date rules, capture metadata, media formats, RAW routing, incremental receipts, conflicts, skipping, retry and link safety.")
