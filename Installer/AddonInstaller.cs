using System.IO.Compression;

namespace OmagadAddonsInstaller;

// Un "groupe" est ce que l'utilisateur coche dans l'interface. AuctionatorCoA
// entraine toujours ses deux dependances : separement, l'addon ne charge pas.
// Le premier dossier de Folders porte le .toc dont on lit "## Version:" pour
// afficher la version installee.
internal sealed record AddonGroup(string Label, string[] Folders)
{
    public string PrimaryFolder => Folders[0];
}

internal static class AddonCatalog
{
    public static readonly AddonGroup[] Groups =
    {
        new("Auctionator (hotel des ventes)", new[] { "AuctionatorCoA", "AuctionatorCoA_Price_Database", "AuctionatorCoA_Pricing_History" }),
        new("CoABuffManager", new[] { "CoABuffManager" }),
        new("DPSLogger", new[] { "DPSLogger" }),
        new("EasyLoot", new[] { "EasyLoot" }),
    };

    public const string ScanFileName = "AuctionatorCoA_Price_Database.lua";
}

internal sealed class InstallResult
{
    public List<string> AddonsInstalled { get; } = new();
    public List<string> VersionChanges { get; } = new();
    public bool ScanInstalled { get; set; }
    public string? ScanMessage { get; set; }
    public List<string> Errors { get; } = new();
}

internal static class AddonInstaller
{
    private const string RepoZipUrl = "https://github.com/Omagad-FR/Coa-addons/archive/refs/heads/main.zip";

    public static async Task<string> DownloadAndExtractAsync(Action<string> log, CancellationToken ct)
    {
        var work = Path.Combine(Path.GetTempPath(), "coa-addons-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        var zipPath = Path.Combine(work, "coa-addons.zip");

        log("Telechargement depuis GitHub...");
        using (var http = new HttpClient())
        {
            http.Timeout = TimeSpan.FromMinutes(3);
            http.DefaultRequestHeaders.UserAgent.ParseAdd("OmagadAddonsInstaller");
            using var response = await http.GetAsync(RepoZipUrl, HttpCompletionOption.ResponseHeadersRead, ct);
            response.EnsureSuccessStatusCode();
            await using var fs = File.Create(zipPath);
            await response.Content.CopyToAsync(fs, ct);
        }

        log("Extraction de l'archive...");
        ZipFile.ExtractToDirectory(zipPath, work);

        var extracted = Directory.EnumerateDirectories(work, "Coa-addons-*").FirstOrDefault()
                         ?? Directory.EnumerateDirectories(work, "coa-addons-*").FirstOrDefault();
        if (extracted is null)
            throw new InvalidOperationException("Archive inattendue : dossier extrait introuvable.");

        return extracted;
    }

    public static InstallResult Install(
        string extractedRoot,
        string addonsDest,
        string savedVarsDest,
        IEnumerable<AddonGroup> selectedGroups,
        bool overwriteScan,
        Action<string> log)
    {
        var result = new InstallResult();
        var sourceAddonsRoot = Path.Combine(extractedRoot, "Addons");

        foreach (var group in selectedGroups)
        {
            var oldVersion = ReadTocVersion(addonsDest, group.PrimaryFolder);

            foreach (var folderName in group.Folders)
            {
                var source = Path.Combine(sourceAddonsRoot, folderName);
                if (!Directory.Exists(source))
                {
                    result.Errors.Add($"Addon introuvable dans l'archive : {folderName}");
                    continue;
                }
                var target = Path.Combine(addonsDest, folderName);
                try
                {
                    if (Directory.Exists(target)) Directory.Delete(target, recursive: true);
                    CopyDirectory(source, target);
                    result.AddonsInstalled.Add(folderName);
                }
                catch (Exception ex)
                {
                    result.Errors.Add($"{folderName} : {ex.Message}");
                }
            }

            var newVersion = ReadTocVersion(addonsDest, group.PrimaryFolder);
            if (newVersion is not null)
            {
                var line = (oldVersion is null || oldVersion == newVersion)
                    ? $"{group.Label} : version {newVersion}"
                    : $"{group.Label} : {oldVersion} -> {newVersion}";
                result.VersionChanges.Add(line);
                log(line);
            }
            else
            {
                log($"{group.Label} installe (version introuvable dans le .toc).");
            }
        }

        var sourceSaved = Path.Combine(extractedRoot, "SavedVariables", AddonCatalog.ScanFileName);
        var targetSaved = Path.Combine(savedVarsDest, AddonCatalog.ScanFileName);
        if (File.Exists(sourceSaved))
        {
            Directory.CreateDirectory(savedVarsDest);
            if (!File.Exists(targetSaved))
            {
                File.Copy(sourceSaved, targetSaved);
                result.ScanInstalled = true;
                result.ScanMessage = "Base de prix installee (premier scan pret a l'emploi).";
            }
            else if (overwriteScan)
            {
                var backup = targetSaved + ".bak";
                File.Copy(targetSaved, backup, overwrite: true);
                File.Copy(sourceSaved, targetSaved, overwrite: true);
                result.ScanInstalled = true;
                result.ScanMessage = $"{AddonCatalog.ScanFileName} ecrase (ancien scan sauvegarde en .bak).";
            }
            else
            {
                result.ScanMessage = $"{AddonCatalog.ScanFileName} existe deja : conserve.";
            }
        }
        else if (overwriteScan)
        {
            result.Errors.Add("Fichier de scan absent de l'archive telechargee.");
        }

        return result;
    }

    // Lit "## Version: ..." dans <addonsFolder>\<folderName>\<folderName>.toc. Renvoie null si
    // l'addon n'est pas installe ou si son .toc n'a pas de champ Version (cas des dependances
    // AuctionatorCoA_Price_Database/Pricing_History, qui n'en declarent pas).
    public static string? ReadTocVersion(string addonsFolder, string folderName)
    {
        var tocPath = Path.Combine(addonsFolder, folderName, folderName + ".toc");
        if (!File.Exists(tocPath)) return null;
        foreach (var line in File.ReadLines(tocPath))
        {
            if (line.StartsWith("## Version:", StringComparison.OrdinalIgnoreCase))
                return line["## Version:".Length..].Trim();
        }
        return null;
    }

    private static void CopyDirectory(string source, string target)
    {
        Directory.CreateDirectory(target);
        foreach (var dir in Directory.GetDirectories(source, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(dir.Replace(source, target));
        foreach (var file in Directory.GetFiles(source, "*", SearchOption.AllDirectories))
            File.Copy(file, file.Replace(source, target), overwrite: true);
    }
}
