namespace OmagadAddonsInstaller;

// Portage de la logique de detection deja utilisee dans console.hta et
// install.ps1 : chemins courants d'abord, puis scan des disques en largeur,
// profondeur et budget bornes.
internal static class GameLocator
{
    private static readonly string[] SkipNames =
    {
        "windows", "$recycle.bin", "system volume information", "programdata", "appdata",
        "onedrive", "node_modules", ".git", "perflogs", "recovery", "msocache", "intel", "nvidia",
        "documents and settings", "config.msi", "windows.old", "packages", "temp", "tmp"
    };

    private static readonly string[] CandidatePaths =
    {
        @"C:\Ascension\Launcher\resources\ascension-live",
        @"C:\Ascension\ascension-live",
        @"C:\Ascension",
        @"C:\Program Files (x86)\Ascension\ascension-live",
        @"D:\Ascension\Launcher\resources\ascension-live",
        @"D:\Ascension\ascension-live"
    };

    public static bool LooksLikeGame(string? path)
    {
        if (string.IsNullOrEmpty(path) || !Directory.Exists(path)) return false;
        return Directory.Exists(Path.Combine(path, "WTF")) &&
               (Directory.Exists(Path.Combine(path, "Interfaces")) || Directory.Exists(Path.Combine(path, "Interface")));
    }

    public static string? Find(Action<string> log)
    {
        foreach (var candidate in CandidatePaths)
        {
            if (LooksLikeGame(candidate)) return candidate;
        }
        return ScanDrives(log);
    }

    private static string? ScanDrives(Action<string> log)
    {
        const int maxDepth = 4;
        const int budget = 9000;
        var visited = 0;
        var queue = new Queue<(string Path, int Depth)>();

        foreach (var drive in DriveInfo.GetDrives())
        {
            if (drive.DriveType is not (DriveType.Fixed or DriveType.Removable)) continue;
            if (!drive.IsReady) continue;
            queue.Enqueue((drive.RootDirectory.FullName, 0));
        }

        log($"Scan de {queue.Count} disque(s) en cours, ca peut prendre une minute...");

        while (queue.Count > 0 && visited < budget)
        {
            var (path, depth) = queue.Dequeue();
            visited++;

            if (depth > 0 && LooksLikeGame(path))
            {
                log($"Jeu trouve : {path} ({visited} dossiers parcourus).");
                return path;
            }

            if (depth >= maxDepth) continue;
            try
            {
                foreach (var sub in Directory.EnumerateDirectories(path))
                {
                    var name = Path.GetFileName(sub).ToLowerInvariant();
                    if (Array.IndexOf(SkipNames, name) >= 0) continue;
                    queue.Enqueue((sub, depth + 1));
                }
            }
            catch { /* dossier proteges, disque expulse pendant le scan, etc. */ }
        }

        log($"Aucune installation trouvee apres {visited} dossiers.");
        return null;
    }

    public static string GetAddonsFolder(string game)
    {
        var a = Path.Combine(game, "Interfaces", "Addons");
        if (Directory.Exists(a)) return a;
        var b = Path.Combine(game, "Interface", "AddOns");
        if (Directory.Exists(b)) return b;
        Directory.CreateDirectory(b);
        return b;
    }

    // Retourne toujours une liste (jamais un scalaire nu) : c'est le piege qui
    // a cause le bug "compte tronque a une lettre" dans install.ps1.
    public static List<string> GetAccounts(string game)
    {
        var accountsDir = Path.Combine(game, "WTF", "Account");
        var result = new List<string>();
        if (!Directory.Exists(accountsDir)) return result;
        foreach (var dir in Directory.EnumerateDirectories(accountsDir))
        {
            var name = Path.GetFileName(dir);
            if (!string.Equals(name, "SavedVariables", StringComparison.OrdinalIgnoreCase))
                result.Add(name);
        }
        return result;
    }
}
