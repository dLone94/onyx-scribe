import Foundation

/// Neutralizes the XML-ish delimiter tokens the cleanup/draft/rewrite prompts
/// use to fence untrusted text. Third-party content (an email thread read for
/// drafting, a web selection) can contain a literal `</context>` followed by
/// "ignore prior instructions…" and break out of its fence to hijack the
/// generated message the user then pastes. Turning `<context>`/`</context>` into
/// `(context)`/`(/context)` keeps the words readable to the model but strips
/// their power as delimiters. (The transform path avoids this entirely by
/// sending a JSON payload — see `TransformPayload`.)
public enum PromptSanitizer {
    private static let reservedTags = [
        "existing_text", "context", "intent", "transcript",
        "original", "command", "selection",
    ]

    public static func neutralizeTags(_ s: String) -> String {
        var out = s
        for tag in reservedTags {
            out = out.replacingOccurrences(of: "<\(tag)>", with: "(\(tag))",
                                           options: .caseInsensitive)
            out = out.replacingOccurrences(of: "</\(tag)>", with: "(/\(tag))",
                                           options: .caseInsensitive)
        }
        return out
    }
}
