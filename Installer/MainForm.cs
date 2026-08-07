using System.Diagnostics;
using System.Reflection;

namespace OmagadAddonsInstaller;

public sealed class MainForm : Form
{
    private const string KoFiUrl = "https://ko-fi.com/omagad";

    private readonly PictureBox _logo = new() { Width = 56, Height = 56, SizeMode = PictureBoxSizeMode.Zoom, Margin = new Padding(0, 4, 12, 0) };
    private readonly Label _title = new() { Text = "Omagad Addons", Font = new Font("Segoe UI", 16f, FontStyle.Bold), AutoSize = true };
    private readonly Label _buildLabel = new() { Text = $"Build {BuildInfo.Stamp}", AutoSize = true, ForeColor = Color.Gray, Font = new Font("Segoe UI", 8f) };
    private readonly Label _status = new() { Dock = DockStyle.Top, Height = 24, Padding = new Padding(12, 4, 0, 0), Text = "Detection du client Ascension..." };

    private readonly CheckBox _installAddonsBox = new() { Text = "Installer les addons", Checked = true, AutoSize = true };
    private readonly CheckedListBox _addonList = new() { Height = 110, CheckOnClick = true, IntegralHeight = false, Dock = DockStyle.Fill };
    private readonly CheckBox _overwriteScanBox = new() { Text = "Ecraser la base de prix existante si presente", AutoSize = true };
    private readonly Label _scanInfo = new() { AutoSize = true, ForeColor = Color.DimGray, Margin = new Padding(0, 4, 0, 0) };

    private readonly Button _installButton = new() { Text = "Installer", Width = 140, Height = 36 };
    private readonly Button _kofiButton = new() { Text = "☕ Soutenir sur Ko-fi", Width = 180, Height = 36 };
    private readonly TextBox _log = new()
    {
        Dock = DockStyle.Fill,
        Multiline = true,
        ReadOnly = true,
        ScrollBars = ScrollBars.Vertical,
        Font = new Font(FontFamily.GenericMonospace, 9f)
    };

    private string? _game;
    private string? _displayAccount; // meilleure estimation pour l'affichage seul, pas pour l'installation

    public MainForm()
    {
        Text = "Omagad Addons";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(760, 680);
        MinimumSize = new Size(680, 560);

        _logo.Image = LoadEmbeddedImage("logo-circle.png");
        foreach (var group in AddonCatalog.Groups)
            _addonList.Items.Add(group.Label, true);

        var titleStack = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Margin = new Padding(0, 4, 0, 0) };
        titleStack.Controls.Add(_title);
        titleStack.Controls.Add(_buildLabel);

        var header = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 70, Padding = new Padding(12, 8, 12, 8) };
        header.Controls.Add(_logo);
        header.Controls.Add(titleStack);

        var addonsGroup = new GroupBox { Text = "Mise a jour des addons", Dock = DockStyle.Top, Height = 200, Padding = new Padding(12) };
        var addonsLayout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2 };
        addonsLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        addonsLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        addonsLayout.Controls.Add(_installAddonsBox, 0, 0);
        addonsLayout.Controls.Add(_addonList, 0, 1);
        addonsGroup.Controls.Add(addonsLayout);
        _installAddonsBox.CheckedChanged += (_, _) => _addonList.Enabled = _installAddonsBox.Checked;

        var scanGroup = new GroupBox { Text = "Mise a jour du Full Scan Auctionator (base de prix)", Dock = DockStyle.Top, Height = 90, Padding = new Padding(12) };
        var scanLayout = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = false };
        scanLayout.Controls.Add(_overwriteScanBox);
        scanLayout.Controls.Add(_scanInfo);
        scanGroup.Controls.Add(scanLayout);

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 48, Padding = new Padding(12, 6, 12, 6) };
        buttons.Controls.Add(_installButton);
        buttons.Controls.Add(_kofiButton);

        var logPanel = new Panel { Dock = DockStyle.Fill, Padding = new Padding(12, 0, 12, 12) };
        logPanel.Controls.Add(_log);

        Controls.Add(logPanel);
        Controls.Add(buttons);
        Controls.Add(scanGroup);
        Controls.Add(addonsGroup);
        Controls.Add(_status);
        Controls.Add(header);

        Icon = LoadEmbeddedIcon();

        _installButton.Click += async (_, _) => await RunInstallAsync();
        _kofiButton.Click += (_, _) => OpenUrl(KoFiUrl);

        Load += async (_, _) => await DetectGameAsync();
    }

    private static Image LoadEmbeddedImage(string fileName)
    {
        var asm = Assembly.GetExecutingAssembly();
        var name = asm.GetManifestResourceNames().First(n => n.EndsWith(fileName, StringComparison.OrdinalIgnoreCase));
        using var stream = asm.GetManifestResourceStream(name)!;
        return Image.FromStream(stream);
    }

    private static Icon LoadEmbeddedIcon()
    {
        using var img = LoadEmbeddedImage("logo-circle.png");
        using var bmp = new Bitmap(img, new Size(64, 64));
        return Icon.FromHandle(bmp.GetHicon());
    }

    private static void OpenUrl(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Impossible d'ouvrir le lien : {ex.Message}", "Omagad Addons",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private void Log(string message)
    {
        if (_log.InvokeRequired)
        {
            _log.Invoke(new Action<string>(Log), message);
            return;
        }
        var stamp = DateTime.Now.ToString("HH:mm:ss");
        _log.AppendText($"[{stamp}] {message}{Environment.NewLine}");
    }

    private async Task DetectGameAsync()
    {
        _game = await Task.Run(() => GameLocator.Find(Log));
        _status.Text = _game is null
            ? "Client introuvable automatiquement — clique sur Installer pour le renseigner a la main."
            : $"Jeu detecte : {_game}";
        RefreshInstalledVersions();
        RefreshScanInfo();
    }

    // Affiche la version installee (lue dans le .toc) a cote de chaque addon, ou
    // "non installe" si le dossier n'existe pas encore chez ce joueur.
    private void RefreshInstalledVersions()
    {
        if (_game is null) return;
        var addonsDest = GameLocator.GetAddonsFolder(_game);
        for (var i = 0; i < AddonCatalog.Groups.Length; i++)
        {
            var group = AddonCatalog.Groups[i];
            var version = AddonInstaller.ReadTocVersion(addonsDest, group.PrimaryFolder);
            var label = version is not null
                ? $"{group.Label} — installe : {version}"
                : $"{group.Label} — non installe";
            var wasChecked = _addonList.GetItemChecked(i);
            _addonList.Items[i] = label;
            _addonList.SetItemChecked(i, wasChecked);
        }
    }

    // Affiche l'age du scan actuellement installe (date du fichier sur disque), pour
    // decider si ca vaut le coup de l'ecraser. Purement informatif : le compte utilise
    // ici est une estimation (le premier compte trouve) — le vrai choix, s'il y en a
    // plusieurs, se fait au moment d'installer.
    private void RefreshScanInfo()
    {
        if (_game is null) { _scanInfo.Text = ""; return; }
        var accounts = GameLocator.GetAccounts(_game);
        if (accounts.Count == 0) { _scanInfo.Text = "Aucun compte detecte."; return; }

        _displayAccount = accounts[0];
        var scanPath = Path.Combine(_game, "WTF", "Account", _displayAccount, "SavedVariables", AddonCatalog.ScanFileName);
        if (!File.Exists(scanPath))
        {
            _scanInfo.Text = $"Aucun scan installe pour le compte {_displayAccount}.";
            return;
        }

        var age = DateTime.Now - File.GetLastWriteTime(scanPath);
        _scanInfo.Text = $"Scan actuel ({_displayAccount}) : {FormatAge(age)} — {File.GetLastWriteTime(scanPath):dd/MM/yyyy HH:mm}";
    }

    private static string FormatAge(TimeSpan age)
    {
        if (age.TotalMinutes < 1) return "a l'instant";
        if (age.TotalHours < 1) return $"il y a {(int)age.TotalMinutes} min";
        if (age.TotalDays < 1) return $"il y a {(int)age.TotalHours} h";
        return $"il y a {(int)age.TotalDays} j";
    }

    private async Task RunInstallAsync()
    {
        _installButton.Enabled = false;
        try
        {
            var game = _game;
            if (game is null || !GameLocator.LooksLikeGame(game))
            {
                using var prompt = new PromptDialog(
                    "Dossier du jeu",
                    "Colle le chemin du dossier du jeu (celui qui contient WTF et Interfaces) :");
                if (prompt.ShowDialog(this) != DialogResult.OK) return;
                game = prompt.Value.Trim();
                if (!GameLocator.LooksLikeGame(game))
                {
                    MessageBox.Show("Ce dossier ne ressemble pas a une installation du jeu.", "Omagad Addons",
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }
                _game = game;
                RefreshInstalledVersions();
                RefreshScanInfo();
            }

            var accounts = GameLocator.GetAccounts(game);
            if (accounts.Count == 0)
            {
                MessageBox.Show(
                    "Aucun compte trouve dans WTF\\Account. Connecte-toi au moins une fois au jeu avant d'installer les addons.",
                    "Omagad Addons", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            string account;
            if (accounts.Count == 1)
            {
                account = accounts[0];
            }
            else
            {
                using var choice = new ChoiceDialog("Plusieurs comptes trouves", "Quel compte utiliser ?", accounts);
                if (choice.ShowDialog(this) != DialogResult.OK || choice.Selected is null) return;
                account = choice.Selected;
            }
            Log($"Compte : {account}");

            var addonsDest = GameLocator.GetAddonsFolder(game);
            var savedVarsDest = Path.Combine(game, "WTF", "Account", account, "SavedVariables");

            var selectedGroups = new List<AddonGroup>();
            if (_installAddonsBox.Checked)
            {
                for (var i = 0; i < _addonList.Items.Count; i++)
                {
                    if (_addonList.GetItemChecked(i)) selectedGroups.Add(AddonCatalog.Groups[i]);
                }
            }
            var overwriteScan = _overwriteScanBox.Checked;

            if (selectedGroups.Count == 0 && !overwriteScan)
            {
                MessageBox.Show("Rien a faire : coche au moins un addon, ou la case pour la base de prix.",
                    "Omagad Addons", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            string extractedRoot;
            try
            {
                extractedRoot = await AddonInstaller.DownloadAndExtractAsync(Log, CancellationToken.None);
            }
            catch (Exception ex)
            {
                Log($"ERREUR de telechargement : {ex.Message}");
                MessageBox.Show($"Le telechargement a echoue : {ex.Message}", "Omagad Addons",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            var result = await Task.Run(() =>
                AddonInstaller.Install(extractedRoot, addonsDest, savedVarsDest, selectedGroups, overwriteScan, Log));

            if (result.ScanMessage is not null) Log(result.ScanMessage);
            foreach (var error in result.Errors) Log($"ERREUR : {error}");

            try { Directory.Delete(Path.GetDirectoryName(extractedRoot)!, recursive: true); } catch { }

            RefreshInstalledVersions();
            RefreshScanInfo();
            Log("Termine. Relance le jeu (ou /reload en jeu) pour charger les addons.");
            var summary = result.VersionChanges.Count > 0
                ? string.Join("\n", result.VersionChanges)
                : "Aucun addon installe.";
            MessageBox.Show(
                summary + "\n\n" + (result.ScanMessage ?? "") +
                (result.Errors.Count > 0 ? $"\n\n{result.Errors.Count} erreur(s) — voir le journal." : ""),
                "Omagad Addons", MessageBoxButtons.OK,
                result.Errors.Count > 0 ? MessageBoxIcon.Warning : MessageBoxIcon.Information);
        }
        finally
        {
            _installButton.Enabled = true;
        }
    }
}
