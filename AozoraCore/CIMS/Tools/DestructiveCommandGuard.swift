import Foundation

/// Guards against destructive shell commands that permanently delete files.
///
/// The guard intercepts `rm`, `shred`, `unlink`, and `find -delete` before
/// execution. Simple standalone `rm` invocations are automatically rewritten
/// to `trash` (recoverable via macOS Trash). Complex or chained commands that
/// cannot be safely rewritten are blocked with a clear error message.
///
/// Detection strategy:
/// 1. Check for safe tool prefixes (`git rm`, `cargo rm`, etc.) → allow immediately.
/// 2. Strip quoted string literals to avoid false positives (`echo 'rm -rf'` is safe).
/// 3. Check for `find -delete` and `find -exec rm` patterns → block.
/// 4. Check for subshell invocations (`bash -c 'rm ...'`) on the original command → block.
/// 5. Split by shell operators (`&&`, `||`, `;`, `|`, `$(`) and inspect each segment.
/// 6. Single-segment `rm` invocations → rewrite to `trash`.
/// 7. Multi-segment commands containing `rm` → block (cannot safely rewrite in place).
public enum DestructiveCommandGuard {
    // MARK: - Verdict

    /// The outcome of a guard check.
    public enum Verdict: Equatable, Sendable {
        /// The command is safe to execute as-is.
        case allowed

        /// The command has been rewritten to a safe equivalent. Execute `cmd` instead.
        case rewrite(String)

        /// The command is destructive and cannot be safely rewritten. `reason` explains why.
        case blocked(String)
    }

    // MARK: - Public API

    /// Inspect `command` and return a ``Verdict``.
    ///
    /// - Parameter command: The raw shell command string to inspect.
    /// - Returns: `.allowed`, `.rewrite(safeCommand)`, or `.blocked(reason)`.
    public static func check(_ command: String) -> Verdict {
        let trimmed = command.trimmingCharacters(in: .whitespaces)

        // 1. Safe tool prefixes — allow without further checks.
        if hasSafePrefix(trimmed) { return .allowed }

        // 2. Strip quoted strings to avoid false positives from string literals.
        let stripped = stripQuotedStrings(trimmed)

        // 3. find -delete or find -exec rm patterns.
        if containsFindDelete(stripped) {
            return .blocked(
                "find -delete and find -exec rm are not allowed. " +
                    "Use 'trash' to move files to Trash instead.",
            )
        }

        // 4. Subshell invocations — check the ORIGINAL command to catch quoted content.
        if containsSubshellRm(trimmed) {
            return .blocked(
                "Subshell rm invocations (e.g., bash -c 'rm ...') are not allowed. " +
                    "Use 'trash' to move files to Trash instead.",
            )
        }

        // 5. Split by shell operators and inspect each segment.
        let segments = splitByShellOperators(stripped)
        let destructiveSegments = segments.filter { isDestructiveSegment($0) }

        guard !destructiveSegments.isEmpty else { return .allowed }

        // 6. Single-segment command: attempt rewrite.
        if segments.count == 1, let rewritten = rewriteRmToTrash(segments[0]) {
            return .rewrite(rewritten)
        }

        // 7. Multi-segment or non-rewritable: block.
        return .blocked(
            "This command contains a destructive operation (rm/shred/unlink) that cannot be " +
                "safely rewritten. Use 'trash <path>' to move files to Trash (recoverable). " +
                "'git rm' is allowed for tracked files.",
        )
    }

    // MARK: - Safe Prefix Detection

    /// Tool prefixes that use `rm` as a subcommand in a completely safe way.
    ///
    /// These are package managers or VCS tools where `rm` is their own subcommand,
    /// not a delegation to the system `rm`. The list is intentionally conservative.
    private static let safePrefixPattern = try! NSRegularExpression(
        pattern: #"^(git|cargo|brew|npm|yarn|pnpm|poetry|pip|gem|bundle)\s+rm\b"#,
        options: [],
    )

    /// Returns `true` if `command` starts with a known-safe tool prefix like `git rm`.
    private static func hasSafePrefix(_ command: String) -> Bool {
        let range = NSRange(command.startIndex..., in: command)
        return safePrefixPattern.firstMatch(in: command, range: range) != nil
    }

    // MARK: - Quoted String Stripping

    /// Replace single- and double-quoted string literals with empty placeholders.
    ///
    /// This prevents content inside strings from triggering false positives.
    /// For example, `echo 'rm -rf /'` becomes `echo ''` after stripping.
    private static func stripQuotedStrings(_ input: String) -> String {
        var result = ""
        var i = input.startIndex
        while i < input.endIndex {
            let ch = input[i]
            if ch == "'" || ch == "\"" {
                // Consume the quoted span
                let quote = ch
                result.append(quote)
                i = input.index(after: i)
                while i < input.endIndex, input[i] != quote {
                    if input[i] == "\\", quote == "\"" {
                        // Skip escaped character inside double quotes
                        i = input.index(after: i)
                        if i < input.endIndex { i = input.index(after: i) }
                    } else {
                        i = input.index(after: i)
                    }
                }
                if i < input.endIndex { result.append(quote); i = input.index(after: i) }
            } else {
                result.append(ch)
                i = input.index(after: i)
            }
        }
        return result
    }

    // MARK: - find Pattern Detection

    /// Detects `find ... -delete` or `find ... -exec rm` patterns.
    private static let findDeletePattern = try! NSRegularExpression(
        pattern: #"\bfind\b.*?(-delete\b|-exec\s+(rm|/\S*/rm)\b)"#,
        options: [.dotMatchesLineSeparators],
    )

    /// Returns `true` if `stripped` contains a `find` command with `-delete` or `-exec rm`.
    private static func containsFindDelete(_ stripped: String) -> Bool {
        let range = NSRange(stripped.startIndex..., in: stripped)
        return findDeletePattern.firstMatch(in: stripped, range: range) != nil
    }

    // MARK: - Subshell Detection

    /// Detects `bash -c '...'`, `sh -c '...'` wrapping an `rm` command.
    ///
    /// We check the ORIGINAL (unstripped) command here because the `rm` resides
    /// inside the quoted string argument to the shell, which stripping would remove.
    private static let subshellPattern = try! NSRegularExpression(
        pattern: #"(bash|sh|zsh|dash)\s+-c\s+['""].*?\b(rm|shred|unlink)\b"#,
        options: [],
    )

    /// Returns `true` if `original` invokes a subshell containing a destructive command.
    private static func containsSubshellRm(_ original: String) -> Bool {
        let range = NSRange(original.startIndex..., in: original)
        return subshellPattern.firstMatch(in: original, range: range) != nil
    }

    // MARK: - Shell Operator Splitting

    /// Split a stripped command string by shell operators into individual segments.
    ///
    /// Recognized operators: `&&`, `||`, `;`, `|`, `$(`. Each segment is trimmed.
    private static func splitByShellOperators(_ stripped: String) -> [String] {
        // Replace all shell operators with a single delimiter, then split.
        // Order matters: `&&` and `||` before `&` and `|`.
        var normalized = stripped
        for op in ["&&", "||", ";", "$(", "|", "&"] {
            normalized = normalized.replacingOccurrences(of: op, with: "\u{0}")
        }
        return normalized
            .components(separatedBy: "\u{0}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Segment Destructiveness Check

    /// Pattern matching a destructive command at the start of a segment.
    ///
    /// Matches:
    /// - `rm`, `\rm` (backslash-escaped alias bypass)
    /// - `/bin/rm`, `/usr/bin/rm` (absolute paths to rm)
    /// - `sudo rm` (privilege escalation + rm)
    /// - `xargs rm` (piped rm via xargs)
    /// - `shred`
    /// - `unlink`
    private static let destructiveCommandPattern = try! NSRegularExpression(
        pattern: #"(?:^|(?<=\s))(sudo\s+)?(xargs\s+)?(\\|(?:/\S+/))?(rm|shred|unlink)\b"#,
        options: [],
    )

    /// Returns `true` if `segment` contains a destructive shell command.
    private static func isDestructiveSegment(_ segment: String) -> Bool {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        // First token of the segment — check if it's a safe "pass-through" command
        // whose arguments we shouldn't inspect (echo, grep, cat, printf, etc.).
        if hasTextOnlyPrefix(trimmed) { return false }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return destructiveCommandPattern.firstMatch(in: trimmed, range: range) != nil
    }

    /// Commands whose first token means the remaining tokens are data, not commands.
    private static let textOnlyPrefixes: Set<String> = [
        "echo", "printf", "grep", "rg", "cat", "less", "more", "head",
        "tail", "sed", "awk", "sort", "uniq", "wc", "cut", "tr", "tee",
    ]

    /// Returns `true` if the segment's first word is a text-only command.
    private static func hasTextOnlyPrefix(_ segment: String) -> Bool {
        let firstWord = segment.components(separatedBy: .whitespaces).first ?? ""
        return textOnlyPrefixes.contains(firstWord)
    }

    // MARK: - Rewrite Logic

    /// Attempt to rewrite a simple `rm [flags] <args>` segment as `trash <args>`.
    ///
    /// Returns `nil` if the segment is too complex to rewrite safely (e.g., it
    /// contains glob expansion through `xargs`, or `sudo`).
    private static func rewriteRmToTrash(_ segment: String) -> String? {
        let tokens = segment
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return nil }

        var idx = 0

        // Reject if prefixed by sudo, xargs, or an absolute path to rm.
        let first = tokens[idx]
        if first == "sudo" || first == "xargs" { return nil }
        if first.hasPrefix("/") { return nil }

        // Advance past `\rm` or `rm`.
        let commandToken = first.hasPrefix("\\") ? String(first.dropFirst()) : first
        guard commandToken == "rm" else { return nil }
        idx += 1

        // Skip option flags (tokens starting with `-`).
        while idx < tokens.count, tokens[idx].hasPrefix("-") {
            // `--` ends flag parsing.
            if tokens[idx] == "--" { idx += 1; break }
            idx += 1
        }

        // Everything remaining is file/directory arguments.
        let fileArgs = tokens[idx...]
        guard !fileArgs.isEmpty else { return nil }

        return "trash " + fileArgs.joined(separator: " ")
    }
}
