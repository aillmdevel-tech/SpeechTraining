namespace SpeechTraining;

internal sealed class SettingsForm : Form
{
    private readonly TextBox gemini = new() { Dock = DockStyle.Fill, UseSystemPasswordChar = true };
    private readonly TextBox eleven = new() { Dock = DockStyle.Fill, UseSystemPasswordChar = true };
    private readonly TextBox profile = new() { Dock = DockStyle.Fill, Multiline = true, ScrollBars = ScrollBars.Vertical };

    public Settings Value => new(gemini.Text.Trim(), eleven.Text.Trim(), profile.Text.Trim());

    public SettingsForm(Settings value, bool ghost)
    {
        Text = "Настройки SpeechTraining";
        StartPosition = FormStartPosition.CenterParent;
        MinimumSize = new(460, 330);
        ClientSize = new(480, 325);
        Font = new("Segoe UI", 10);
        gemini.Text = value.Gemini;
        eleven.Text = value.Elevenlabs;
        profile.Text = value.Profile;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new(14), ColumnCount = 1, RowCount = 7 };
        for (var index = 0; index < 5; index++) layout.RowStyles.Add(new(SizeType.AutoSize));
        layout.RowStyles.Add(new(SizeType.Percent, 100));
        layout.RowStyles.Add(new(SizeType.AutoSize));
        layout.Controls.Add(TitleLabel("Ключ Gemini"), 0, 0);
        layout.Controls.Add(gemini, 0, 1);
        layout.Controls.Add(TitleLabel("Ключ ElevenLabs"), 0, 2);
        layout.Controls.Add(eleven, 0, 3);
        layout.Controls.Add(TitleLabel("Контекст для тренировки"), 0, 4);
        layout.Controls.Add(profile, 0, 5);
        var save = new Button { Text = "Сохранить", AutoSize = true, DialogResult = DialogResult.OK };
        var cancel = new Button { Text = "Отмена", AutoSize = true, DialogResult = DialogResult.Cancel };
        var actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft };
        actions.Controls.Add(save);
        actions.Controls.Add(cancel);
        layout.Controls.Add(actions, 0, 6);
        Controls.Add(layout);
        AcceptButton = save;
        CancelButton = cancel;
        Shown += (_, _) => Desktop.Protect(Handle, ghost);
    }

    private static Label TitleLabel(string text) => new() { Text = text, AutoSize = true, Margin = new(3, 8, 3, 3) };
}
