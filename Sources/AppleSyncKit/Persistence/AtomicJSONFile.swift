import Foundation

struct AtomicJSONFile: Sendable {
  let path: String

  func save<T: Encodable>(_ value: T) throws {
    try saveData(JSONEncoder().encode(value))
  }

  func saveData(_ data: Data) throws {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)

    let temporaryPath = path + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
    let fd = open(temporaryPath, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
    guard fd >= 0 else {
      throw SyncError.unknown("Cannot create \(temporaryPath)")
    }

    do {
      try writeData(data, to: fd, path: temporaryPath)
      guard fsync(fd) == 0 else {
        throw SyncError.unknown("Cannot flush \(temporaryPath)")
      }
    } catch {
      close(fd)
      try? FileManager.default.removeItem(atPath: temporaryPath)
      throw error
    }

    close(fd)
    guard rename(temporaryPath, path) == 0 else {
      let error = SyncError.unknown(
        "Cannot save \(path): \(String(cString: strerror(errno)))")
      try? FileManager.default.removeItem(atPath: temporaryPath)
      throw error
    }
    guard fsyncDirectory(at: directory) == 0 else {
      throw SyncError.unknown("Cannot flush directory for \(path)")
    }
  }

  private func fsyncDirectory(at directory: URL) -> Int32 {
    let fd = open(directory.path, O_RDONLY)
    guard fd >= 0 else { return -1 }
    defer { close(fd) }
    return fsync(fd)
  }

  private func writeData(_ data: Data, to fd: Int32, path: String) throws {
    try data.withUnsafeBytes { bytes in
      var written = 0
      while written < bytes.count {
        let count = write(fd, bytes.baseAddress! + written, bytes.count - written)
        guard count > 0 else {
          throw SyncError.unknown("Write failed for \(path)")
        }
        written += count
      }
    }
  }
}
