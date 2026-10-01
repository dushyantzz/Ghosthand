import Foundation

/// Compiles a regular expression from a compile-time literal.
///
/// Every pattern in GhostHand is a hand-written constant, so an invalid pattern is a programmer
/// error rather than a runtime condition. Centralising the compile here keeps `try!` out of the
/// call sites while still failing loudly (and loudly *once*, at first use) if a literal is broken.
func makeRegex(
    _ pattern: String,
    options: NSRegularExpression.Options = []
) -> NSRegularExpression {
    do {
        return try NSRegularExpression(pattern: pattern, options: options)
    } catch {
        preconditionFailure("Invalid regular-expression literal \(pattern): \(error)")
    }
}
