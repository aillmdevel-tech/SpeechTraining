namespace SpeechTraining;

internal sealed class MainForm : Form
{
    private const int ListenKey = 101;
    private const int WindowKey = 102;
    private readonly Storage storage;
    private readonly Gateway gateway = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly List<ChatTurn> history;
    private readonly ToolTip tooltips = new();
    private readonly ComboBox mode = Choices("Ответ", "Разбор", "Тренировка");
    private readonly ComboBox length = Choices("Кратко", "Средне", "Подробно");
    private readonly ComboBox language = Choices("Русский", "Українська", "English");
    private readonly CheckBox microphone = Toggle("Микрофон", true);
    private readonly CheckBox system = Toggle("Звук ПК", false);
    private readonly CheckBox translation = Toggle("Перевод на русский", true);
    private readonly CheckBox ghost = Toggle("Ghost", true);
    private readonly TextBox input = new() { Multiline = true, Dock = DockStyle.Fill, ScrollBars = ScrollBars.Vertical, PlaceholderText = "Вопрос или ответ для тренировки" };
    private readonly RichTextBox chat = new() { ReadOnly = true, DetectUrls = false, BackColor = SystemColors.Window, Dock = DockStyle.Fill };
    private readonly Label draft = new() { AutoSize = true, Dock = DockStyle.Fill, ForeColor = SystemColors.GrayText, Padding = new(4) };
    private readonly Label status = new() { AutoSize = true, Dock = DockStyle.Fill, ForeColor = SystemColors.GrayText };
    private readonly Button listen = new() { Text = "Слушать", AutoSize = true };
    private readonly Button send = new() { Text = "Отправить", AutoSize = true };
    private readonly Button settingsButton = new() { Text = "Настройки", AutoSize = true };
    private LiveTurns turns = new();
    private CancellationTokenSource? capture;
    private CancellationTokenSource? checking;
    private Task commitQueue = Task.CompletedTask;
    private Task replyQueue = Task.CompletedTask;
    private int pending;
    private string lastQuestion = "";
    private string? listenShortcut;
    private string? windowShortcut;
    private bool settingsOpen;
    private bool captureProtection;
    private readonly bool hotkeysEnabled;
    private IntPtr registeredHandle;
    private readonly Font translationFont;
    private readonly Font questionFont;

    public MainForm(Storage storage, bool hotkeysEnabled = true)
    {
        this.storage = storage;
        this.hotkeysEnabled = hotkeysEnabled;
        Text = "SpeechTraining";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new(540, 520);
        ClientSize = new(710, 650);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new("Segoe UI", 10);
        translationFont = new Font(Font, FontStyle.Italic);
        questionFont = new Font(Font, FontStyle.Bold);
        Icon = SystemIcons.Application;
        try { history = storage.ReadHistory(); }
        catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException) { history = []; }
        BuildLayout();
        DrawChat();
        listen.Click += async (_, _) => await ToggleCapture();
        send.Click += (_, _) => SendTyped();
        settingsButton.Click += (_, _) => OpenSettings();
        ghost.CheckedChanged += (_, _) => ApplyGhost();
        translation.CheckedChanged += (_, _) => DrawChat();
        language.SelectedIndexChanged += (_, _) => RefreshControls();
        mode.SelectedIndexChanged += (_, _) => RefreshControls();
        microphone.CheckedChanged += (_, _) => RefreshControls();
        system.CheckedChanged += (_, _) => RefreshControls();
        input.TextChanged += (_, _) => RefreshControls();
        Shown += (_, _) =>
        {
            ApplyGhost();
            try { if (!storage.ReadSettings().Configured) SetStatus("Добавь ключи Gemini и ElevenLabs в настройках."); }
            catch { SetStatus("Открой настройки и сохрани ключи заново."); }
        };
        RefreshControls();
    }

    private void BuildLayout()
    {
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new(14), ColumnCount = 1, RowCount = 8 };
        layout.RowStyles.Add(new(SizeType.AutoSize));
        layout.RowStyles.Add(new(SizeType.AutoSize));
        layout.RowStyles.Add(new(SizeType.AutoSize));
        layout.RowStyles.Add(new(SizeType.Absolute, 68));
        layout.RowStyles.Add(new(SizeType.AutoSize));
        layout.RowStyles.Add(new(SizeType.Percent, 100));
        layout.RowStyles.Add(new(SizeType.AutoSize));
        layout.RowStyles.Add(new(SizeType.AutoSize));
        var header = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, ColumnCount = 3 };
        header.ColumnStyles.Add(new(SizeType.Percent, 100));
        header.ColumnStyles.Add(new(SizeType.AutoSize));
        header.ColumnStyles.Add(new(SizeType.AutoSize));
        header.Controls.Add(new Label { Text = "SpeechTraining", AutoSize = true, Font = new Font(Font.FontFamily, 17, FontStyle.Bold) }, 0, 0);
        header.Controls.Add(ghost, 1, 0);
        header.Controls.Add(settingsButton, 2, 0);
        layout.Controls.Add(header, 0, 0);
        var selectors = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 2 };
        for (var column = 0; column < 3; column++) selectors.ColumnStyles.Add(new(SizeType.Percent, 100f / 3));
        selectors.Controls.Add(LabelFor("Режим"), 0, 0);
        selectors.Controls.Add(LabelFor("Длина"), 1, 0);
        selectors.Controls.Add(LabelFor("Язык ответа"), 2, 0);
        selectors.Controls.Add(mode, 0, 1);
        selectors.Controls.Add(length, 1, 1);
        selectors.Controls.Add(language, 2, 1);
        layout.Controls.Add(selectors, 0, 1);
        layout.Controls.Add(Row(microphone, system, translation), 0, 2);
        layout.Controls.Add(input, 0, 3);
        layout.Controls.Add(Row(listen, send), 0, 4);
        layout.Controls.Add(chat, 0, 5);
        layout.Controls.Add(draft, 0, 6);
        layout.Controls.Add(status, 0, 7);
        layout.SizeChanged += (_, _) => draft.MaximumSize = new(Math.Max(160, layout.ClientSize.Width - layout.Padding.Horizontal), 0);
        Controls.Add(layout);
    }

    private static FlowLayoutPanel Row(params Control[] controls)
    {
        var row = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, Margin = new(0, 4, 0, 4) };
        row.Controls.AddRange(controls);
        return row;
    }

    private static Label LabelFor(string text) => new() { Text = text, AutoSize = true, ForeColor = SystemColors.GrayText };
    private static CheckBox Toggle(string text, bool active) => new() { Text = text, AutoSize = true, Checked = active };
    private static ComboBox Choices(params string[] labels)
    {
        var picker = new ComboBox { Dock = DockStyle.Fill, DropDownStyle = ComboBoxStyle.DropDownList };
        picker.Items.AddRange(labels);
        picker.SelectedIndex = 0;
        return picker;
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        ApplyGhost();
        if (!hotkeysEnabled) return;
        registeredHandle = Handle;
        listenShortcut = Desktop.Register(registeredHandle, ListenKey, Keys.Oemtilde, Keys.F8);
        windowShortcut = Desktop.Register(registeredHandle, WindowKey, Keys.Space, Keys.F9);
        tooltips.SetToolTip(listen, listenShortcut ?? "Системная клавиша прослушивания занята");
        tooltips.SetToolTip(ghost, windowShortcut is null
            ? "Защита зависит от способа захвата экрана. Системная клавиша окна занята."
            : $"Защита зависит от способа захвата экрана. Показать или скрыть окно — {windowShortcut}");
    }

    protected override void OnHandleDestroyed(EventArgs e)
    {
        if (registeredHandle != IntPtr.Zero)
        {
            Desktop.Unregister(registeredHandle, ListenKey);
            Desktop.Unregister(registeredHandle, WindowKey);
            registeredHandle = IntPtr.Zero;
        }
        base.OnHandleDestroyed(e);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == Desktop.HotKeyMessage && !settingsOpen)
        {
            if (m.WParam.ToInt32() == ListenKey) BeginInvoke(new Action(async () => await ToggleCapture()));
            if (m.WParam.ToInt32() == WindowKey) BeginInvoke(ToggleWindow);
            return;
        }
        base.WndProc(ref m);
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Oemtilde && !input.Focused)
        {
            if ((msg.LParam.ToInt64() & (1L << 30)) == 0) _ = ToggleCapture();
            return true;
        }
        if (keyData == (Keys.Control | Keys.Enter))
        {
            SendTyped();
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    internal void ToggleWindow()
    {
        if (Visible && WindowState != FormWindowState.Minimized) Hide();
        else Desktop.BringToFront(this);
    }

    private void ApplyGhost()
    {
        if (!IsHandleCreated) return;
        captureProtection = Desktop.Protect(Handle, ghost.Checked);
        if (ghost.Checked && !captureProtection) SetStatus("Windows отклонила защиту окна. Используй горячую клавишу скрытия.");
    }

    private void OpenSettings()
    {
        if (capture is not null || pending > 0) return;
        try
        {
            Settings old;
            try { old = storage.ReadSettings(); }
            catch { old = new(); }
            using var window = new SettingsForm(old, ghost.Checked);
            settingsOpen = true;
            if (window.ShowDialog(this) != DialogResult.OK) return;
            storage.WriteSettings(window.Value);
            gateway.Stop();
            SetStatus(window.Value.Configured ? "Настройки сохранены." : "Для распознавания и ответов нужны оба ключа.");
        }
        catch { SetStatus("Не удалось сохранить настройки."); }
        finally { settingsOpen = false; }
    }

    private async Task ToggleCapture()
    {
        if (capture is { } active)
        {
            active.Cancel();
            return;
        }
        if (settingsOpen || pending > 0 || (!microphone.Checked && !system.Checked)) return;
        var stop = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var selectedMic = microphone.Checked;
        var selectedSystem = system.Checked;
        string? deviceError = null;
        capture = stop;
        turns = new();
        SetStatus("Подключаю звук…");
        RefreshControls();
        try
        {
            var settings = Credentials();
            await gateway.EnsureReady(settings);
            stop.Token.ThrowIfCancellationRequested();
            using var audio = new AudioMixer(selectedMic, selectedSystem, _ =>
            {
                deviceError = "Звуковое устройство отключилось или стало недоступно.";
                stop.Cancel();
            });
            using var speech = await SpeechStream.Connect(settings.Elevenlabs, stop.Token);
            SetStatus("Слушаю. Ответ появится автоматически.");
            var sender = SendAudio(audio, speech, stop.Token);
            var reader = ReceiveAudio(speech, stop.Token);
            var finished = await Task.WhenAny(sender, reader);
            try { await finished; }
            finally
            {
                stop.Cancel();
                try { await Task.WhenAll(sender, reader); }
                catch { /* The loop that stopped first supplies the error. */ }
            }
            SetStatus(deviceError ?? "Прослушивание остановлено.");
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested) { SetStatus(deviceError ?? "Прослушивание остановлено."); }
        catch (Exception error) { SetStatus(error.Message); }
        finally
        {
            checking?.Cancel();
            checking = null;
            if (turns.Draft.Length > 0) input.AppendText((input.TextLength > 0 ? Environment.NewLine : "") + turns.Draft);
            draft.Text = "";
            capture = null;
            stop.Dispose();
            RefreshControls();
        }
    }

    private static async Task SendAudio(AudioMixer audio, SpeechStream speech, CancellationToken cancellation)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(80));
        while (await timer.WaitForNextTickAsync(cancellation)) await speech.Send(audio.Take(), cancellation);
    }

    private async Task ReceiveAudio(SpeechStream speech, CancellationToken cancellation)
    {
        while (!cancellation.IsCancellationRequested)
        {
            var message = await speech.Receive(cancellation);
            switch (message.Type)
            {
                case "partial_transcript" when message.Text.Length > 0:
                    turns.Update(message.Text);
                    draft.Text = turns.Draft;
                    _ = CheckBoundary(cancellation);
                    break;
                case "committed_transcript" when message.Text.Length > 0:
                    var interrupted = checking is not null;
                    checking?.Cancel();
                    checking = null;
                    turns.Update(message.Text);
                    var suggestion = turns.Candidate;
                    if (!interrupted && suggestion?.Spoken == turns.CheckedSpoken) suggestion = null;
                    Commit(turns.Finish(message.Text), suggestion);
                    draft.Text = "";
                    break;
                case "session_started" or "warning" or "partial_transcript" or "committed_transcript" or "committed_transcript_with_timestamps":
                    break;
                default:
                    throw SpeechStream.Problem(message.Type);
            }
        }
    }

    private async Task CheckBoundary(CancellationToken cancellation)
    {
        if (checking is not null || turns.Candidate is not { } candidate || turns.CheckedSpoken == candidate.Spoken) return;
        using var request = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        checking = request;
        turns.CheckedSpoken = candidate.Spoken;
        var separate = await gateway.IsNewTopic(candidate, request.Token);
        if (!ReferenceEquals(checking, request)) return;
        checking = null;
        if (!request.IsCancellationRequested && separate && turns.SplitAt(candidate) is { } text)
        {
            Commit(text, null);
            draft.Text = turns.Draft;
        }
    }

    private void Commit(string text, Boundary? boundary)
    {
        if (!text.Any(char.IsLetter)) return;
        var selection = SelectedMode == "practice" ? "review" : SelectedMode;
        pending++;
        RefreshControls();
        commitQueue = FinishTurn(commitQueue, text, boundary, selection);
    }

    private async Task FinishTurn(Task prior, string text, Boundary? boundary, string selectedMode)
    {
        try
        {
            await prior;
            if (boundary is not null && await gateway.IsNewTopic(boundary, lifetime.Token))
            {
                QueueAnswer(boundary.Spoken, selectedMode);
                QueueAnswer(boundary.Opening, selectedMode);
            }
            else QueueAnswer(text, selectedMode);
        }
        finally
        {
            pending--;
            RefreshControls();
        }
    }

    private void SendTyped()
    {
        if (!send.Enabled) return;
        var text = input.Text.Trim();
        if (text.Length == 0) text = "Следующий тренировочный вопрос";
        input.Clear();
        QueueAnswer(text, SelectedMode);
    }

    private string SelectedMode => new[] { "answer", "review", "practice" }[mode.SelectedIndex];
    private string SelectedLanguage => new[] { "ru", "uk", "en" }[language.SelectedIndex];

    private void QueueAnswer(string text, string selectedMode)
    {
        var question = new ChatTurn(Guid.NewGuid(), text, selectedMode, []);
        history.Add(question);
        SaveHistory();
        DrawChat();
        var request = new CoachRequest("", text, selectedMode, SelectedLanguage,
            new[] { "short", "medium", "long" }[length.SelectedIndex], translation.Checked && SelectedLanguage != "ru");
        pending++;
        RefreshControls();
        replyQueue = AnswerAfter(replyQueue, question, request);
    }

    private async Task AnswerAfter(Task prior, ChatTurn turn, CoachRequest request)
    {
        try
        {
            await prior;
            lifetime.Token.ThrowIfCancellationRequested();
            var settings = Credentials();
            await gateway.EnsureReady(settings);
            var profile = await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory, "CoachPrompt.txt"), lifetime.Token);
            var utterance = request.Input;
            if (lastQuestion.Length > 0 && request.Mode == "review")
                utterance = $"Последний тренировочный вопрос: {lastQuestion}\n\nОтвет кандидата: {utterance}";
            if (lastQuestion.Length > 0 && request.Mode == "practice")
                utterance += $"\nНе повторяй прошлый вопрос: {lastQuestion}";
            var reply = await gateway.Answer(request with { Prompt = profile + "\n\n" + settings.Profile, Input = utterance }, lifetime.Token);
            if (reply.Length == 0) throw new InvalidOperationException("Gemini вернул пустой ответ.");
            if (request.Mode == "practice") lastQuestion = string.Join(" ", reply.Select(segment => segment.Text));
            var index = history.FindIndex(item => item.Id == turn.Id);
            if (index >= 0) history[index] = turn with { Reply = reply };
            SaveHistory();
            DrawChat();
            SetStatus(capture is not null ? "Слушаю…" : "Ответ готов.");
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception error) { SetStatus(error.Message); }
        finally
        {
            pending--;
            RefreshControls();
        }
    }

    private Settings Credentials()
    {
        var value = storage.ReadSettings();
        return value.Configured ? value : throw new InvalidOperationException("Добавь ключи Gemini и ElevenLabs в настройках.");
    }

    private void SaveHistory()
    {
        try { storage.WriteHistory(history); }
        catch { SetStatus("Не удалось сохранить локальную историю."); }
    }

    private void DrawChat()
    {
        chat.SuspendLayout();
        chat.Clear();
        foreach (var turn in history.TakeLast(100))
        {
            ChatLine(turn.Input + "\n", questionFont, SystemColors.WindowText);
            foreach (var row in turn.Reply)
            {
                ChatLine(row.Text + "\n", Font, SystemColors.WindowText);
                if (translation.Checked && row.Ru.Length > 0) ChatLine(row.Ru + "\n", translationFont, SystemColors.GrayText);
            }
            chat.AppendText("\n");
        }
        chat.SelectionStart = chat.TextLength;
        chat.ScrollToCaret();
        chat.ResumeLayout();
    }

    private void ChatLine(string value, Font font, Color color)
    {
        chat.SelectionStart = chat.TextLength;
        chat.SelectionLength = 0;
        chat.SelectionFont = font;
        chat.SelectionColor = color;
        chat.AppendText(value);
    }

    private void RefreshControls()
    {
        if (IsDisposed) return;
        var recording = capture is not null;
        microphone.Enabled = system.Enabled = !recording;
        settingsButton.Enabled = !recording && pending == 0;
        listen.Enabled = recording || (pending == 0 && (microphone.Checked || system.Checked));
        listen.Text = recording ? "Остановить" : "Слушать";
        input.Enabled = !recording;
        send.Text = SelectedMode == "practice" ? "Новый вопрос" : "Отправить";
        send.Enabled = !recording && pending == 0 && (SelectedMode == "practice" || !string.IsNullOrWhiteSpace(input.Text));
        length.Enabled = SelectedMode != "practice";
        translation.Enabled = SelectedLanguage != "ru";
    }

    private void SetStatus(string value)
    {
        if (!IsDisposed) status.Text = value;
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        lifetime.Cancel();
        gateway.Dispose();
        translationFont.Dispose();
        questionFont.Dispose();
        tooltips.Dispose();
        base.OnFormClosed(e);
    }
}
