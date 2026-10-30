import Foundation

@main struct MigrationTool {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw BackupError.message("Usage: migrate /absolute/backup/path")
        }
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let identity = try String(contentsOf: root.appendingPathComponent(".photo-backup/identity.txt"), encoding: .utf8)
        let archive = try Archive(root: root, expectedIdentity: identity)
        print("Resources: \(archive.receipts.count); bytes: \(archive.receipts.values.reduce(Int64(0)) { $0 + $1.bytes })")
        let moved = try archive.migrateLayout { completed, total in
            if completed % 25 == 0 || completed == total { print("Migrated and verified: \(completed)/\(total)") }
        }
        let invalid = archive.receipts.values.filter { !archive.alreadyCopied($0.key) || $0.layoutVersion != 2 }
        guard invalid.isEmpty else { throw BackupError.message("\(invalid.count) resources did not pass final validation") }
        print("COMPLETE: migrated \(moved); all \(archive.receipts.count) receipts resolve to valid v2 files.")
    }
}
