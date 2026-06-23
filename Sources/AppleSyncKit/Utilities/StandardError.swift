import Foundation

/// Writes a message to standard error. Use instead of `fputs(_, stderr)`: under
/// Swift 6 strict concurrency the C global `stderr` is an unsafe mutable global
/// and trips the checker (notably on Linux/glibc), while `FileHandle.standardError`
/// is `Sendable`.
func writeStderr(_ message: String) {
  FileHandle.standardError.write(Data(message.utf8))
}
