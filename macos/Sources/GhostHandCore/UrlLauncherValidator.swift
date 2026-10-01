import Foundation

// MARK: - UrlLauncherValidator
//
// Port of GhostHand.Core.Agent.UrlLauncherValidator. Validates http/https URLs
// (rejecting embedded user-info) and extracts launchable URLs from a natural
// language prompt, including search-engine and music-streaming intents.

public enum UrlLauncherValidator {

    // MARK: Validation

    /// Returns the validated URL, or nil when `rawUrl` is not a safe http/https
    /// URL. Mirrors `IsValidWebUrl(string?, out Uri?)`.
    public static func isValidWebURL(_ rawUrl: String?) -> URL? {
        guard let rawUrl, !rawUrl.isBlank else { return nil }

        // Strip trailing punctuation like period, comma, paren.
        var trimmed = rawUrl.trimmed
        while let last = trimmed.last, ".,);]".contains(last) {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else { return nil }

        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }

        // Strictly enforce http or https.
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }

        // Must have a valid host of length >= 3.
        guard let host = url.host, host.count >= 3 else { return nil }

        // Disallow dangerous embedded user info.
        guard url.user == nil, url.password == nil else { return nil }

        return url
    }

    // MARK: Extraction

    public static func extractWebURLs(from prompt: String) -> [URL] {
        guard !prompt.isBlank else { return [] }

        var list: [URL] = []

        // 1. Explicit http/https URLs in the text.
        for match in allMatches(urlRegex, in: prompt) {
            guard let value = group(0, of: match, in: prompt) else { continue }
            if let url = isValidWebURL(value) {
                list.append(url)
            }
        }
        if !list.isEmpty { return list }

        // 2. Generic web domain in the prompt (e.g. "open github.com").
        if let match = firstMatch(domainRegex, in: prompt),
           let rawDomain = group(1, of: match, in: prompt)?.trimmed,
           let url = isValidWebURL("https://\(rawDomain)") {
            list.append(url)
            return list
        }

        // 3. Search intent on any search engine
        //    (e.g. "search for Adele on youtube").
        if let match = firstMatch(searchOnRegex, in: prompt),
           let rawQuery = group(1, of: match, in: prompt),
           let rawEngine = group(2, of: match, in: prompt) {
            let query = trimQuotes(rawQuery.trimmed)
            let engine = rawEngine.trimmed.lowercased()
            let searchURL = engineSearchURL(engine: engine, query: query, spotifyPath: false)
            if let url = isValidWebURL(searchURL) {
                list.append(url)
                return list
            }
        }

        // 4. Direct search command (e.g. "google <query>", "youtube <query>").
        if let match = firstMatch(googleCommandRegex, in: prompt),
           let rawQuery = group(1, of: match, in: prompt) {
            let query = trimQuotes(rawQuery.trimmed)
            if !query.isEmpty,
               let url = isValidWebURL("https://www.google.com/search?q=\(query.escapedForURLQuery)") {
                list.append(url)
                return list
            }
        }

        if let match = firstMatch(youtubeCommandRegex, in: prompt),
           let rawQuery = group(1, of: match, in: prompt) {
            let query = trimQuotes(rawQuery.trimmed)
            if !query.isEmpty,
               let url = isValidWebURL("https://www.youtube.com/results?search_query=\(query.escapedForURLQuery)") {
                list.append(url)
                return list
            }
        }

        // 5. Chained platform+query search
        //    (e.g. "open brave and search for youtube and search honey singh songs").
        if let match = firstMatch(chainedSearchRegex, in: prompt),
           let rawPlatform = group(1, of: match, in: prompt),
           let rawQuery = group(2, of: match, in: prompt) {
            let platform = rawPlatform.trimmed.lowercased()
            let targetQuery = trimQuotes(rawQuery.trimmed)

            if !targetQuery.isBlank && targetQuery.count > 1 {
                let targetURL = engineSearchURL(engine: platform, query: targetQuery, spotifyPath: true)
                if let url = isValidWebURL(targetURL) {
                    list.append(url)
                    return list
                }
            }
        }

        // 6. Music streaming intent
        //    (e.g. "open spotify and play any song of aditya rikhari").
        if let match = firstMatch(musicStreamRegex, in: prompt),
           let rawQuery = group(2, of: match, in: prompt) {
            var query = trimQuotes(rawQuery.trimmed)
            query = replace(musicPrefixRegex, in: query, with: "").trimmed

            let platform: String
            if let platformGroup = group(3, of: match, in: prompt) {
                platform = platformGroup
            } else if let appGroup = group(1, of: match, in: prompt) {
                platform = appGroup
            } else {
                platform = ""
            }
            let normalizedPlatform = platform.trimmed.lowercased()

            if !query.isBlank && query.count > 1 {
                let streamURL = normalizedPlatform.contains("spotify")
                    ? "https://open.spotify.com/search/\(query.escapedForURLQuery)"
                    : "https://www.youtube.com/results?search_query=\(query.escapedForURLQuery)"
                if let url = isValidWebURL(streamURL) {
                    list.append(url)
                    return list
                }
            }
        }

        // 7. General search intent (e.g. "open brave and search lion").
        if let match = firstMatch(generalSearchRegex, in: prompt),
           let rawQuery = group(1, of: match, in: prompt) {
            let query = trimQuotes(rawQuery.trimmed)
            let engineOrApp = group(2, of: match, in: prompt)?.trimmed.lowercased() ?? ""

            if !query.isBlank && query.count > 1 && query.lowercased() != "there" {
                let searchURL = engineSearchURL(engine: engineOrApp, query: query, spotifyPath: true)
                if let url = isValidWebURL(searchURL) {
                    list.append(url)
                    return list
                }
            }
        }

        return list
    }

    // MARK: Search URL mapping

    /// Maps a search-engine/platform token to a search URL. `spotifyPath` selects
    /// the open.spotify.com/search/ form used by the chained and general branches.
    private static func engineSearchURL(engine: String, query: String, spotifyPath: Bool) -> String {
        let escaped = query.escapedForURLQuery
        switch engine {
        case "youtube":
            return "https://www.youtube.com/results?search_query=\(escaped)"
        case "spotify":
            return spotifyPath
                ? "https://open.spotify.com/search/\(escaped)"
                : "https://www.google.com/search?q=\(escaped)"
        case "bing":
            return "https://www.bing.com/search?q=\(escaped)"
        case "reddit":
            return "https://www.reddit.com/search/?q=\(escaped)"
        case "wikipedia":
            return "https://en.wikipedia.org/wiki/Special:Search?search=\(escaped)"
        default:
            return "https://www.google.com/search?q=\(escaped)"
        }
    }

    private static func trimQuotes(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    // MARK: Regex plumbing

    private static func regex(_ pattern: String) -> NSRegularExpression {
        makeRegex(pattern, options: [.caseInsensitive])
    }

    private static let urlRegex = regex(#"https?://[^\s"'<>]+"#)

    private static let domainRegex = regex(
        #"(?:open|go\s+to|visit)\s+([a-zA-Z0-9\-_]+\.[a-zA-Z]{2,}(?:/[^\s]*)?)"#
    )

    private static let searchOnRegex = regex(
        #"(?:search|look)\s+for\s+(.+?)\s+(?:on|in)\s+([a-zA-Z0-9\-_]+)"#
    )

    private static let googleCommandRegex = regex(
        #"^(?:please\s+)?(?:google|search\s+google\s+for)\s+(.+)$"#
    )

    private static let youtubeCommandRegex = regex(
        #"^(?:please\s+)?(?:youtube|search\s+youtube\s+for)\s+(.+)$"#
    )

    private static let chainedSearchRegex = regex(
        #"(?:(?:open|launch|start)\s+[a-zA-Z0-9_\- ]+?\s+(?:and|then)\s+)?"# +
        #"(?:search|go\s+to|open)\s+(?:for\s+)?([a-zA-Z0-9_\-]+)\s+(?:and|then)\s+"# +
        #"(?:search|play|find|look\s+up)\s+(?:for\s+)?(.+?)(?:\.|$)"#
    )

    private static let musicStreamRegex = regex(
        #"(?:(?:open|launch|start)\s+([a-zA-Z0-9_\- ]+?)\s+(?:and|then)\s+)?"# +
        #"(?:play|listen\s+to|stream)"# +
        #"(?:\s+(?:any\s+song\s+(?:of|by)|songs?\s+(?:of|by)|music\s+(?:of|by)|tracks?\s+(?:of|by)))?"# +
        #"\s+(.+?)(?:\s+(?:on|in|using|with)\s+([a-zA-Z0-9_\-]+)|\.|$)"#
    )

    private static let musicPrefixRegex = regex(
        #"^(?:any\s+song\s+(?:of|by)|songs?\s+(?:of|by)|music\s+(?:of|by)|track\s+(?:of|by))\s+"#
    )

    private static let generalSearchRegex = regex(
        #"(?:(?:open|launch|start)\s+[a-zA-Z0-9_\- ]+?\s+(?:and|then)\s+)?"# +
        #"(?:search|look\s+up|find|query)"# +
        #"(?:\s+(?:for|about|on|regarding|the\s+web\s+for))?"# +
        #"\s+(.+?)(?:\s+(?:on|in|using|with)\s+([a-zA-Z0-9\-_]+)|\.|$)"#
    )

    private static func firstMatch(
        _ regex: NSRegularExpression,
        in text: String
    ) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
    }

    private static func allMatches(
        _ regex: NSRegularExpression,
        in text: String
    ) -> [NSTextCheckingResult] {
        regex.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
    }

    private static func group(
        _ index: Int,
        of match: NSTextCheckingResult,
        in text: String
    ) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private static func replace(
        _ regex: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: template
        )
    }
}
