import Foundation

extension ISO8601DateFormatter {
  /// ISO 8601 formatter for sync timestamps (internet date-time + fractional
  /// seconds). Configured once and only used for formatting, which Foundation
  /// guarantees is thread-safe, so it is safe to share as an immutable global.
  public nonisolated(unsafe) static let syncISO8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}
