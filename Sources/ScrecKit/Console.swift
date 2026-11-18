import Foundation

/// Writes a line to standard error. Standard output is reserved for data such as the `--list` output.
func say(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Prints `screc: <message>` to standard error and exits with status 1.
func fail(_ message: String) -> Never {
    say("screc: " + message)
    exit(1)
}
