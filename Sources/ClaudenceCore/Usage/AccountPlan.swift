import Foundation

/// Which Claude subscription the usage limits belong to.
///
/// The percentages in the popover are shares of a limit whose size the product
/// never states. A window at 62% means something different on Pro than on Max
/// 20x, and until this existed nothing on screen said which one the reader was
/// looking at.
public struct AccountPlan: Sendable, Equatable {
    /// What to put on screen: `Pro`, `Max 5x`, `Max 20x`, `Team`.
    public let displayName: String

    public init(displayName: String) {
        self.displayName = displayName
    }
}

/// Reads the subscription plan out of Claude Code's own account file.
///
/// ## Where this comes from, and the privacy argument for it
///
/// `~/.claude.json`, key `oauthAccount`. That file is a new source and it is
/// not a quiet one: alongside the two fields read here it holds
/// `emailAddress`, `fullName`, `organizationName`, `accountUuid`, every project
/// path the user has opened, and a good deal of product telemetry. It is by
/// some distance the most sensitive file this application has ever opened.
///
/// So the decoder below declares exactly two fields and the enclosing type
/// declares exactly one key. A field `Account` does not declare is left on disk
/// deliberately, the same rule `SubagentLocator.Meta` follows and for the same
/// reason: the shape of the decoder *is* the privacy boundary, and widening it
/// is an amendment to the contract in CLAUDE.md rather than a detail of parsing.
/// The two fields are:
///
/// ```
/// oauthAccount.organizationType          "claude_max", "claude_pro", ...
/// oauthAccount.organizationRateLimitTier "default_claude_max_5x", ...
/// ```
///
/// Both sides of it, because whoever considers the next field from this file
/// needs both. For: these two name a product tier, not a person. They are the
/// same words Anthropic prints on a pricing page, they are identical for every
/// customer on that tier, and without them the headline number in this
/// application is a percentage of an unstated quantity. Against: they are read
/// out of a file that has the user's name and email two keys away, and every
/// future reader of this code will see a working JSON decoder pointed at that
/// file and find it one line's work to take more. The narrowness is the whole
/// safeguard, and it is enforced by `PrivacyTests`, not by intention.
///
/// The alternative was the usage endpoint, which may well carry the tier too.
/// It was not chosen: this file is local, needs no request, and works while
/// offline, so the plan badge is one thing on screen that cannot be taken away
/// by a rate limit. The usage response is still the only network read.
///
/// ## Never invented
///
/// An `organizationType` this does not recognise produces nil and no badge.
/// Guessing a plan name from an unknown string would put a wrong product tier
/// beside a real percentage, which is worse than saying nothing.
public enum AccountPlanReader {
    private struct Root: Decodable {
        let oauthAccount: Account?
    }

    private struct Account: Decodable {
        let organizationType: String?
        let organizationRateLimitTier: String?
    }

    /// Claude Code's account file. Not configurable: a path this application
    /// takes from somewhere else is a path an attacker can aim at a file the
    /// privacy contract never covered.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// The plan, or nil when the file is absent, unreadable, or names a tier
    /// this does not know.
    ///
    /// Read once per launch by the caller rather than on every render. The file
    /// is 86 KB on this machine and a subscription does not change while the
    /// application is open; parsing it on each popover draw would be paying a
    /// JSON decode for an answer that cannot have moved.
    public static func read(from url: URL? = nil) -> AccountPlan? {
        let url = url ?? defaultURL
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let root = try? JSONDecoder().decode(Root.self, from: data),
              let account = root.oauthAccount else {
            return nil
        }
        return plan(
            organizationType: account.organizationType,
            rateLimitTier: account.organizationRateLimitTier
        )
    }

    /// The mapping, kept pure so it can be tested without a file.
    ///
    /// The multiplier comes from the rate limit tier because that is the only
    /// place it appears: `organizationType` is `claude_max` whether the seat is
    /// 5x or 20x, and those two differ by four times the limit that every
    /// percentage on screen is a share of. A tier string that carries no
    /// recognisable multiplier degrades to the bare plan name rather than
    /// dropping the badge, because "Max" is still true.
    static func plan(organizationType: String?, rateLimitTier: String?) -> AccountPlan? {
        guard let organizationType else { return nil }

        let base: String
        switch organizationType {
        case "claude_max": base = "Max"
        case "claude_pro": base = "Pro"
        case "claude_team", "team": base = "Team"
        case "claude_enterprise", "enterprise": base = "Enterprise"
        // Deliberately no default that guesses. An unknown tier shows nothing.
        default: return nil
        }

        guard let multiplier = multiplier(in: rateLimitTier) else {
            return AccountPlan(displayName: base)
        }
        return AccountPlan(displayName: "\(base) \(multiplier)")
    }

    /// The trailing `5x` of `default_claude_max_5x`.
    ///
    /// Matched at the end of the string rather than anywhere in it, so a tier
    /// that happens to contain a digit somewhere else cannot be read as a
    /// multiplier.
    private static func multiplier(in tier: String?) -> String? {
        guard let tier, let last = tier.split(separator: "_").last else { return nil }
        guard last.hasSuffix("x") else { return nil }
        let digits = last.dropLast()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return String(last)
    }
}
