import Foundation

/// The file a recording ends up in, and the private place it is written to until then.
///
/// A recording is written into a staging directory of its own, on the same volume as the destination, and moved to
/// its final name only once it is complete. As a result:
///
/// - an unfinished or failed recording never appears under the final name;
/// - nothing that already exists is overwritten, and a symbolic link at the destination is never followed;
/// - screc only ever deletes what it created itself (the staging directory);
/// - the published file is readable by its owner only, since a screen recording may show private content.
struct OutputFile {
    enum Failure: Error, CustomStringConvertible {
        case exists(String)
        case noStaging(Error)

        var description: String {
            switch self {
            case .exists(let path): "\(path) already exists"
            case .noStaging(let error): "cannot create a place to write the recording: \(error.localizedDescription)"
            }
        }
    }

    let destination: URL
    /// A directory created for this recording only.
    let staging: URL

    /// Where the recording is written while it is being made.
    var recording: URL { staging.appendingPathComponent("recording.mp4") }

    /// Reserves a staging directory for a recording that will be saved as `destination`.
    /// Fails if anything, even a dangling symbolic link, already exists there.
    init(destination: URL) throws {
        guard !Self.entryExists(at: destination.path) else { throw Failure.exists(destination.path) }
        do {
            // A unique directory on the destination's volume, so that publishing is a rename rather than a copy.
            staging = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination.deletingLastPathComponent(), create: true)
        } catch {
            throw Failure.noStaging(error)
        }
        self.destination = destination
    }

    /// Whether anything exists at `path`. Unlike `FileManager.fileExists`, a symbolic link is not followed, so a
    /// dangling link counts as existing.
    static func entryExists(at path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Moves the finished recording to its final name and removes the staging directory. Returns where it was saved.
    ///
    /// An existing entry is never replaced: if the destination appeared while recording, the next free name of the form
    /// "name-2.mp4" is used. On failure the recording stays in `recording`.
    func publish() throws -> URL {
        guard chmod(recording.path, 0o600) == 0 else { throw posixError() }
        for candidate in candidates() {
            // RENAME_EXCL fails instead of replacing an existing entry, atomically.
            if renamex_np(recording.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                discard()
                return candidate
            }
            guard errno == EEXIST else { throw posixError() }
        }
        throw Failure.exists(destination.path)
    }

    /// Deletes the staging directory and whatever is in it. Nothing outside it is touched.
    func discard() {
        try? FileManager.default.removeItem(at: staging)
    }

    /// The destination, then "name-2.ext" up to "name-99.ext".
    private func candidates() -> [URL] {
        let directory = destination.deletingLastPathComponent()
        let stem = destination.deletingPathExtension().lastPathComponent
        let suffix = destination.pathExtension.isEmpty ? "" : "." + destination.pathExtension
        return [destination] + (2...99).map { directory.appendingPathComponent("\(stem)-\($0)\(suffix)") }
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
