import Foundation

/// Audit OPS-3: debug artefacts go into a private directory under the user's temporary directory,
/// never a fixed name in the shared `/tmp` that another local user could pre-create as a symlink.
/// Audit OPS-107: the directory is the SAME one on every run (`aetherctl-<uid>`, mode 0700, checked
/// with `lstat` for being a real directory we own), so the next run overwrites the last one's files
/// instead of leaving another multi-gigabyte `dovitest` output behind. A directory that fails the
/// check (a symlink, someone else's) is not used: the run falls back to a fresh `mkdtemp` one.
let debugOutputDirectory: String = {
    let temporary = FileManager.default.temporaryDirectory
    let stable = temporary.appendingPathComponent("aetherctl-\(getuid())").path
    if privateOwnedDirectory(stable) { return stable }

    let template = temporary.appendingPathComponent("aetherctl-XXXXXX").path
    var buffer = Array(template.utf8CString)
    if let made = mkdtemp(&buffer) {
        return String(cString: made)
    }
    let fallback = temporary.appendingPathComponent("aetherctl-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: fallback, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: 0o700])
    return fallback
}()

/// Creates `path` (mode 0700) when it is absent and reports whether what stands there is a real
/// directory owned by this user that nobody else can enter.
private func privateOwnedDirectory(_ path: String) -> Bool {
    if mkdir(path, 0o700) != 0, errno != EEXIST { return false }
    var info = stat()
    guard lstat(path, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFDIR,
          info.st_uid == getuid() else { return false }
    if info.st_mode & 0o077 != 0, chmod(path, 0o700) != 0 { return false }
    return true
}

func debugOutputPath(_ name: String) -> String {
    (debugOutputDirectory as NSString).appendingPathComponent(name)
}
