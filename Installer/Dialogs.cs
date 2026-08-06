namespace OmagadAddonsInstaller;

// Petite boite de dialogue texte : sert a demander le chemin du jeu quand la
// detection automatique echoue.
internal sealed class PromptDialog : Form
{
    private readonly TextBox _input = new() { Dock = DockStyle.Top, Margin = new Padding(0, 8, 0, 0) };

    public string Value => _input.Text;

    public PromptDialog(string title, string message, string defaultValue = "")
    {
        Text = title;
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ClientSize = new Size(480, 130);

        var label = new Label { Text = message, Dock = DockStyle.Top, AutoSize = false, Height = 40, Padding = new Padding(0, 0, 0, 4) };
        _input.Text = defaultValue;

        var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Dock = DockStyle.Right, Width = 90 };
        var cancel = new Button { Text = "Annuler", DialogResult = DialogResult.Cancel, Dock = DockStyle.Right, Width = 90 };
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, FlowDirection = FlowDirection.RightToLeft, Height = 40 };
        buttons.Controls.Add(cancel);
        buttons.Controls.Add(ok);

        var panel = new Panel { Dock = DockStyle.Fill, Padding = new Padding(10) };
        panel.Controls.Add(_input);
        panel.Controls.Add(label);

        Controls.Add(panel);
        Controls.Add(buttons);
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
        ClientSize = new Size(420, 260);

        var label = new Label { Text = message, Dock = DockStyle.Top, AutoSize = false, Height = 36 };
        _list.Items.AddRange(options.Cast<object>().ToArray());
        if (_list.Items.Count > 0) _list.SelectedIndex = 0;

        var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Dock = DockStyle.Right, Width = 90 };
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, FlowDirection = FlowDirection.RightToLeft, Height = 40 };
        buttons.Controls.Add(ok);

        var panel = new Panel { Dock = DockStyle.Fill, Padding = new Padding(10) };
        panel.Controls.Add(_list);
        panel.Controls.Add(label);

        Controls.Add(panel);
        Controls.Add(buttons);
        AcceptButton = ok;
    }
}
