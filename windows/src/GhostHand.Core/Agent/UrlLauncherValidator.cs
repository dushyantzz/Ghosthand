using System.Text.RegularExpressions;

namespace GhostHand.Core.Agent;

public static class UrlLauncherValidator
{
    private static readonly Regex UrlRegex = new(
        @"https?://[^\s""'<>]+",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    public static bool IsValidWebUrl(string? rawUrl, out Uri? validatedUri)
    {
        validatedUri = null;
        if (string.IsNullOrWhiteSpace(rawUrl))
            return false;

        // Strip trailing punctuation like period, comma, paren
        var trimmed = rawUrl.Trim().TrimEnd('.', ',', ')', ']', ';');

        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var uri))
            return false;

        // Strictly enforce http or https
        if (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps)
            return false;

        // Must have a valid host
        if (string.IsNullOrWhiteSpace(uri.Host) || uri.Host.Length < 3)
            return false;

        // Disallow dangerous embedded user info
        if (!string.IsNullOrEmpty(uri.UserInfo))
            return false;

        validatedUri = uri;
        return true;
    }

    /// <param name="activeContext">Process name + window title of the app the user is in. When the prompt
    /// doesn't name a platform ("play X"), a Spotify/YouTube context is used instead of defaulting to YouTube.</param>
    public static IReadOnlyList<Uri> ExtractWebUrls(string prompt, string? activeContext = null)
    {
        var contextPlatform = activeContext switch
        {
            string c when c.Contains("spotify", StringComparison.OrdinalIgnoreCase) => "spotify",
            string c when c.Contains("youtube", StringComparison.OrdinalIgnoreCase) => "youtube",
            _ => string.Empty
        };

        if (string.IsNullOrWhiteSpace(prompt))
            return Array.Empty<Uri>();

        var list = new List<Uri>();

        // 1. Explicit http/https URLs in the text
        var matches = UrlRegex.Matches(prompt);
        foreach (Match match in matches)
        {
            if (IsValidWebUrl(match.Value, out var uri) && uri != null)
            {
                list.Add(uri);
            }
        }

        if (list.Count > 0)
            return list;

        // 2. Generic web domain in prompt (e.g. "open github.com", "go to wikipedia.org", "visit reddit.com")
        var domainMatch = Regex.Match(prompt, @"(?:open|go\s+to|visit)\s+([a-zA-Z0-9\-_]+\.[a-zA-Z]{2,}(?:/[^\s]*)?)", RegexOptions.IgnoreCase);
        if (domainMatch.Success)
        {
            var rawDomain = domainMatch.Groups[1].Value.Trim();
            if (IsValidWebUrl($"https://{rawDomain}", out var domainUri) && domainUri != null)
            {
                list.Add(domainUri);
                return list;
            }
        }

        // 3. Search intent on any search engine (e.g. "search for Adele on youtube", "search for X on google")
        var searchOnMatch = Regex.Match(prompt, @"(?:search|look)\s+for\s+(.+?)\s+(?:on|in)\s+([a-zA-Z0-9\-_]+)", RegexOptions.IgnoreCase);
        if (searchOnMatch.Success)
        {
            var query = searchOnMatch.Groups[1].Value.Trim().Trim('"', '\'');
            var engine = searchOnMatch.Groups[2].Value.Trim().ToLowerInvariant();
            var searchUrl = engine switch
            {
                "youtube" => $"https://www.youtube.com/results?search_query={Uri.EscapeDataString(query)}",
                "bing" => $"https://www.bing.com/search?q={Uri.EscapeDataString(query)}",
                "reddit" => $"https://www.reddit.com/search/?q={Uri.EscapeDataString(query)}",
                "wikipedia" => $"https://en.wikipedia.org/wiki/Special:Search?search={Uri.EscapeDataString(query)}",
                _ => $"https://www.google.com/search?q={Uri.EscapeDataString(query)}"
            };
            if (IsValidWebUrl(searchUrl, out var uri) && uri != null)
            {
                list.Add(uri);
                return list;
            }
        }

        // 4. Direct search command (e.g. "google <query>" or "search google for <query>")
        var googleMatch = Regex.Match(prompt, @"^(?:please\s+)?(?:google|search\s+google\s+for)\s+(.+)$", RegexOptions.IgnoreCase);
        if (googleMatch.Success)
        {
            var query = googleMatch.Groups[1].Value.Trim().Trim('"', '\'');
            if (!string.IsNullOrEmpty(query))
            {
                var searchUrl = $"https://www.google.com/search?q={Uri.EscapeDataString(query)}";
                if (IsValidWebUrl(searchUrl, out var uri) && uri != null)
                {
                    list.Add(uri);
                    return list;
                }
            }
        }

        var youtubeMatch = Regex.Match(prompt, @"^(?:please\s+)?(?:youtube|search\s+youtube\s+for)\s+(.+)$", RegexOptions.IgnoreCase);
        if (youtubeMatch.Success)
        {
            var query = youtubeMatch.Groups[1].Value.Trim().Trim('"', '\'');
            if (!string.IsNullOrEmpty(query))
            {
                var searchUrl = $"https://www.youtube.com/results?search_query={Uri.EscapeDataString(query)}";
                if (IsValidWebUrl(searchUrl, out var uri) && uri != null)
                {
                    list.Add(uri);
                    return list;
                }
            }
        }

        // 5. Chained platform and query search (e.g. "open brave and search for youtube and search honey singh songs")
        var chainedMatch = Regex.Match(
            prompt,
            @"(?:(?:open|launch|start)\s+[a-zA-Z0-9_\- ]+?\s+(?:and|then)\s+)?(?:search|go\s+to|open)\s+(?:for\s+)?([a-zA-Z0-9_\-]+)\s+(?:and|then)\s+(?:search|play|find|look\s+up)\s+(?:for\s+)?(.+?)(?:\.|$)",
            RegexOptions.IgnoreCase);

        if (chainedMatch.Success)
        {
            var platform = chainedMatch.Groups[1].Value.Trim().ToLowerInvariant();
            var targetQuery = chainedMatch.Groups[2].Value.Trim().Trim('"', '\'');

            if (!string.IsNullOrWhiteSpace(targetQuery) && targetQuery.Length > 1)
            {
                var targetUrl = platform switch
                {
                    "youtube" => $"https://www.youtube.com/results?search_query={Uri.EscapeDataString(targetQuery)}",
                    "spotify" => $"https://open.spotify.com/search/{Uri.EscapeDataString(targetQuery)}",
                    "reddit" => $"https://www.reddit.com/search/?q={Uri.EscapeDataString(targetQuery)}",
                    "google" => $"https://www.google.com/search?q={Uri.EscapeDataString(targetQuery)}",
                    "bing" => $"https://www.bing.com/search?q={Uri.EscapeDataString(targetQuery)}",
                    "wikipedia" => $"https://en.wikipedia.org/wiki/Special:Search?search={Uri.EscapeDataString(targetQuery)}",
                    _ => $"https://www.google.com/search?q={Uri.EscapeDataString(targetQuery)}"
                };

                if (IsValidWebUrl(targetUrl, out var uri) && uri != null)
                {
                    list.Add(uri);
                    return list;
                }
            }
        }

        // 6. Music streaming intent (e.g. "open spotify and play any song of aditya rikhari", "play aditya rikhari on spotify")
        var musicMatch = Regex.Match(
            prompt,
            @"(?:(?:open|launch|start)\s+([a-zA-Z0-9_\- ]+?)\s+(?:and|then)\s+)?(?:play|listen\s+to|stream)(?:\s+(?:any\s+song\s+(?:of|by)|songs?\s+(?:of|by)|music\s+(?:of|by)|tracks?\s+(?:of|by)))?\s+(.+?)(?:\s+(?:on|in|using|with)\s+([a-zA-Z0-9_\-]+)|\.|$)",
            RegexOptions.IgnoreCase);

        if (musicMatch.Success)
        {
            var query = musicMatch.Groups[2].Value.Trim().Trim('"', '\'');
            query = Regex.Replace(query, @"^(?:any\s+song\s+(?:of|by)|songs?\s+(?:of|by)|music\s+(?:of|by)|track\s+(?:of|by))\s+", "", RegexOptions.IgnoreCase).Trim();
            var platform = (musicMatch.Groups[3].Success ? musicMatch.Groups[3].Value : (musicMatch.Groups[1].Success ? musicMatch.Groups[1].Value : "")).Trim().ToLowerInvariant();
            if (platform.Length == 0)
                platform = contextPlatform;

            if (!string.IsNullOrWhiteSpace(query) && query.Length > 1)
            {
                var streamUrl = platform.Contains("spotify")
                    ? $"https://open.spotify.com/search/{Uri.EscapeDataString(query)}"
                    : $"https://www.youtube.com/results?search_query={Uri.EscapeDataString(query)}";

                if (IsValidWebUrl(streamUrl, out var uri) && uri != null)
                {
                    list.Add(uri);
                    return list;
                }
            }
        }

        // 7. General search intent (e.g. "open brave and search lion", "search about lion", "search python in chrome")
        var generalSearchMatch = Regex.Match(
            prompt,
            @"(?:(?:open|launch|start)\s+[a-zA-Z0-9_\- ]+?\s+(?:and|then)\s+)?(?:search|look\s+up|find|query)(?:\s+(?:for|about|on|regarding|the\s+web\s+for))?\s+(.+?)(?:\s+(?:on|in|using|with)\s+([a-zA-Z0-9\-_]+)|\.|$)",
            RegexOptions.IgnoreCase);

        if (generalSearchMatch.Success)
        {
            var query = generalSearchMatch.Groups[1].Value.Trim().Trim('"', '\'');
            var engineOrApp = generalSearchMatch.Groups[2].Success ? generalSearchMatch.Groups[2].Value.Trim().ToLowerInvariant() : contextPlatform;

            if (!string.IsNullOrWhiteSpace(query) && query.Length > 1 && !query.Equals("there", StringComparison.OrdinalIgnoreCase))
            {
                var searchUrl = engineOrApp switch
                {
                    "youtube" => $"https://www.youtube.com/results?search_query={Uri.EscapeDataString(query)}",
                    "spotify" => $"https://open.spotify.com/search/{Uri.EscapeDataString(query)}",
                    "bing" => $"https://www.bing.com/search?q={Uri.EscapeDataString(query)}",
                    "reddit" => $"https://www.reddit.com/search/?q={Uri.EscapeDataString(query)}",
                    "wikipedia" => $"https://en.wikipedia.org/wiki/Special:Search?search={Uri.EscapeDataString(query)}",
                    _ => $"https://www.google.com/search?q={Uri.EscapeDataString(query)}"
                };

                if (IsValidWebUrl(searchUrl, out var uri) && uri != null)
                {
                    list.Add(uri);
                    return list;
                }
            }
        }

        return list;
    }
}
