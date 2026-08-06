namespace OmagadAddonsInstaller;

// Petite boite de dialogue texte : sert a demander le chemin du jeu quand la
// detection automatique echoue.
//
// Construite avec un TableLayoutPanel plutot que des Dock=Fill/Bottom
// melanges : l'ordre d'ajout des controles avec Dock rend le resultat
// ambigu (bug constate : le bouton OK disparaissait, cache derriere la
// zone Fill). Un TableLayoutPanel a des lignes explicites, pas d'ambiguite.
internal sealed class PromptDialog : Form
{
    private readonly TextBox _input = new() { Dock = DockStyle.Fill };

    public string Value => _input.Text;

    public PromptDialog(string title, string message, string defaultValue = "")
    {
        Text = title;
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ClientSize = new Size(480, 150);

        _input.Text = defaultValue;

        var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Width = 90, Anchor = AnchorStyles.Right };
        var cancel = new Button { Text = "Annuler", DialogResult = DialogResult.Cancel, Width = 90, Anchor = AnchorStyles.Right };

        var buttonRow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft, AutoSize = true };
        buttonRow.Controls.Add(cancel);
        buttonRow.Controls.Add(ok);

        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Padding = new Padding(12) };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 30));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        layout.Controls.Add(new Label { Text = message, AutoSize = false, Dock = DockStyle.Fill, Height = 60 }, 0, 0);
        layout.Controls.Add(_input, 0, 1);
        layout.Controls.Add(buttonRow, 0, 2);

        Controls.Add(layout);
        AcceptButton = ok;
        CancelButton = cancel;
    }
}

// Choix dans une liste (utilise quand plusieurs comptes WoW sont trouves).
internal sealed class ChoiceDialog : Form
{
    private readonly ListBox _list = new() { Dock = DockStyle.Fill };

    public string? Selected => _list.SelectedItem as string;

    public ChoiceDialog(string title, string message, IEnumerable<string> options)
    {
        Text = title;
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ClientSize = new Size(420, 290);

        _list.Items.AddRange(options.Cast<object>().ToArray());
        if (_list.Items.Count > 0) _list.SelectedIndex = 0;
        _list.DoubleClick += (_, _) => { if (_list.SelectedItem is not null) DialogResult = DialogResult.OK; };

        var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Width = 90, Anchor = AnchorStyles.Right };
        var buttonRow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft, AutoSize = true };
        buttonRow.Controls.Add(ok);

        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Padding = new Padding(12) };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        layout.Controls.Add(new Label { Text = message, AutoSize = false, Dock = DockStyle.Fill, Height = 30 }, 0, 0);
        layout.Controls.Add(_list, 0, 1);
        layout.Controls.Add(buttonRow, 0, 2);

        Controls.Add(layout);
        AcceptButton = ok;
    }
}
