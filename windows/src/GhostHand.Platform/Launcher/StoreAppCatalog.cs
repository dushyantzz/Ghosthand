using Windows.ApplicationModel.Core;
using Windows.Management.Deployment;

namespace GhostHand.Platform.Launcher;

/// <summary>
/// Installed Microsoft Store (packaged) apps by display name → AppUserModelId. Store apps such as Camera,
/// Photos, Clock or the Store editions of WhatsApp/Spotify have no .exe on PATH, no App Paths entry and no
/// Start-menu .lnk, so the other lookups can't find them; they launch via shell:AppsFolder\{AUMID}.
/// The catalog is loaded once in the background (enumerating packages takes ~1s).
/// </summary>
public static class StoreAppCatalog
{
    private static readonly Lazy<Task<IReadOnlyList<(string Name, string Aumid)>>> Entries =
        new(() => Task.Run(Load), LazyThreadSafetyMode.ExecutionAndPublication);

    public static void Preload() => _ = Entries.Value;

    public static bool TryFind(string appName, TimeSpan wait, out string aumid)
    {
        aumid = string.Empty;
        var query = appName.Trim();
        if (query.Length < 2)
            return false;

        var task = Entries.Value;
        if (!task.Wait(wait))
            return false;

        var match = FindBest(task.Result, query);
        if (match == null)
            return false;

        aumid = match;
        return true;
    }

    /// <summary>Exact display name, then "Windows Camera"-style prefixes, then a whole-word match.</summary>
    public static string? FindBest(IReadOnlyList<(string Name, string Aumid)> entries, string query)
    {
        foreach (var (name, aumid) in entries)
            if (name.Equals(query, StringComparison.OrdinalIgnoreCase))
                return aumid;

        foreach (var (name, aumid) in entries)
            if (name.Equals($"Windows {query}", StringComparison.OrdinalIgnoreCase) ||
                name.Equals($"Microsoft {query}", StringComparison.OrdinalIgnoreCase))
                return aumid;

        if (query.Length >= 4)
        {
            foreach (var (name, aumid) in entries)
                if (System.Text.RegularExpressions.Regex.IsMatch(name, $@"\b{System.Text.RegularExpressions.Regex.Escape(query)}\b",
                        System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                    return aumid;
        }

        return null;
    }

    private static IReadOnlyList<(string Name, string Aumid)> Load()
    {
        var result = new List<(string, string)>();
        try
        {
            foreach (var package in new PackageManager().FindPackagesForUser(string.Empty))
            {
                try
                {
                    if (package.IsFramework || package.IsResourcePackage)
                        continue;

                    foreach (AppListEntry entry in package.GetAppListEntries())
                    {
                        var name = entry.DisplayInfo?.DisplayName;
                        var aumid = entry.AppUserModelId;
                        if (!string.IsNullOrWhiteSpace(name) && !string.IsNullOrWhiteSpace(aumid))
                            result.Add((name.Trim(), aumid));
                    }
                }
                catch
                {
                    // Skip packages whose manifest can't be read
                }
            }
        }
        catch
        {
            // Package enumeration unavailable; Store apps simply won't resolve
        }
        return result;
    }
}
