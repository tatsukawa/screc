import Foundation

/// Formats a size for display: "5.8 GB", "801 MB" or "3 KB".
func formatBytes(_ bytes: Double) -> String {
    if bytes >= 1e9 { return String(format: "%.1f GB", bytes / 1e9) }
    return bytes >= 1e6 ? String(format: "%.0f MB", bytes / 1e6) : String(format: "%.0f KB", bytes / 1e3)
}

/// Formats an elapsed time: "0:12", or "1:02:03" from one hour on.
func formatClock(_ seconds: Double) -> String {
    let s = Int(seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
