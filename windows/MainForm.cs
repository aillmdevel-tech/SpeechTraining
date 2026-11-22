namespace SpeechTraining;

internal sealed class MainForm : Form
{
    private const int ListenKey = 101;
    private const int WindowKey = 102;
    private readonly Storage storage;
    private readonly Gateway gateway = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly QuestionBook book;
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
    private readonly Label status = new() { AutoSize = true, Dock = DockStyle.Fill, ForeColor = SystemColors.GrayText };
    private readonly Button listen = new() { Text = "Слушать", AutoSize = true };
    private readonly Button send = new() { Text = "Отправить", AutoSize = true };
    private readonly Button settingsButton = new() { Text = "Настройки", AutoSize = true };
    private sealed record Work(string Text, Guid? Target, Guid Navigation, string Mode, AnswerChoice Choice, string Source,
        Guid? Session = null, QuestionTurn? Rewrite = null);

    private readonly CheckBox voiceFollowUp = Toggle("Уточнять голосом", false);
    private readonly Button archive = new() { Text = "История", AutoSize = true };
    private readonly Button closeQuestion = new() { Text = "Закрыть вопрос", AutoSize = true };
    private readonly Button rewrite = new() { Text = "Обновить ответ", AutoSize = true };
    private readonly Button retry = new() { Text = "Повторить", AutoSize = true, Visible = false };
    private readonly ContextMenuStrip archiveMenu = new();
    private readonly Dictionary<Guid, string> drafts = [];
    private readonly HashSet<Guid> rewriting = [];
    private CancellationTokenSource? capture;
    private Task replyQueue = Task.CompletedTask;
    private Guid voiceSession;
    private (string Text, Guid Session, Guid? Target, Guid Navigation, DateTimeOffset Time)? incomplete;
    private Work? failed;
    private int pending;
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
        translationFont = new Font(Font.FontFamily, Font.Size - 1, FontStyle.Italic);
        questionFont = new Font(Font, FontStyle.Bold);
        Icon = SystemIcons.Application;
        try { book = new QuestionBook(storage.ReadThreads()); }
        catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException) { book = new QuestionBook(new([], null)); }
        BuildLayout();
        DrawChat();
        listen.Click += async (_, _) => await ToggleCapture();
        send.Click += (_, _) => SendTyped();
        archive.Click += (_, _) => ShowHistory();
        closeQuestion.Click += (_, _) => Navigate(null);
        rewrite.Click += (_, _) => RewriteAnswer();
        retry.Click += (_, _) => { if (failed is { } request) Enqueue(request); };
        length.SelectedIndexChanged += (_, _) => RefreshControls();
        tooltips.SetToolTip(closeQuestion, "Ctrl+N");
        tooltips.SetToolTip(rewrite, "Ctrl+R");
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
        for (var row = 0; row < 4; row++) layout.RowStyles.Add(new(SizeType.AutoSize));
        layout.RowStyles.Add(new(SizeType.Percent, 100));
        layout.RowStyles.Add(new(SizeType.Absolute, 60));
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
        layout.Controls.Add(Row(archive, closeQuestion, rewrite), 0, 3);
        layout.Controls.Add(chat, 0, 4);
        layout.Controls.Add(input, 0, 5);
        layout.Controls.Add(Row(listen, voiceFollowUp, send), 0, 6);
        layout.Controls.Add(Row(status, retry), 0, 7);
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
        if (keyData == (Keys.Control | Keys.N))
        {
            Navigate(null);
            return true;
        }
        if (keyData == (Keys.Control | Keys.R))
        {
            RewriteAnswer();
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
        if (settingsOpen || (!microphone.Checked && !system.Checked)) return;
        var stop = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var selectedMic = microphone.Checked;
        var selectedSystem = system.Checked;
        string? deviceError = null;
        capture = stop;
        voiceSession = Guid.NewGuid();
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
                    SetStatus("Слышу речь…");
                    break;
                case "committed_transcript" when message.Text.Any(char.IsLetter):
                    var reviewExercise = SelectedMode == "practice" && book.Active?.Turns.FirstOrDefault()?.Mode == "practice";
                    var target = voiceFollowUp.Checked || reviewExercise ? book.ActiveId : null;
                    var task = SelectedMode == "practice" ? "review" : SelectedMode;
                    Enqueue(new(message.Text, target, book.Navigation, task, SelectedChoice, "voice", voiceSession));
                    break;
                case "session_started" or "warning" or "partial_transcript" or "committed_transcript" or "committed_transcript_with_timestamps":
                    break;
                default:
                    throw SpeechStream.Problem(message.Type);
            }
        }
    }

    private void Navigate(Guid? id)
    {
        drafts[book.ActiveId ?? Guid.Empty] = input.Text;
        book.Select(id);
        voiceFollowUp.Checked = false;
        input.Text = drafts.GetValueOrDefault(id ?? Guid.Empty, "");
        SaveHistory();
        DrawChat();
        RefreshControls();
    }

    private void ShowHistory()
    {
        archiveMenu.Items.Clear();
        foreach (var thread in book.Threads.AsEnumerable().Reverse().Where(thread => thread.Id != book.ActiveId))
        {
            var title = thread.Title.Replace("&", "&&", StringComparison.Ordinal).ReplaceLineEndings(" ");
            if (title.Length > 88) title = title[..88] + "…";
            archiveMenu.Items.Add(title, null, (_, _) => Navigate(thread.Id));
        }
        if (archiveMenu.Items.Count > 0) archiveMenu.Show(archive, new Point(0, archive.Height));
    }

    private void SendTyped()
    {
        if (!send.Enabled) return;
        var text = input.Text.Trim();
        input.Clear();
        if (text.Length == 0 && SelectedMode == "practice") Navigate(null);
        if (book.ActiveId is null) book.Select(Guid.NewGuid());
        Enqueue(new(text.Length > 0 ? text : "Задай новый вопрос для репетиции UWC.",
            book.ActiveId, book.Navigation, SelectedMode, SelectedChoice, "typed"));
    }

    private string SelectedMode => new[] { "answer", "review", "practice" }[mode.SelectedIndex];
    private AnswerChoice SelectedChoice => new(new[] { "ru", "uk", "en" }[language.SelectedIndex],
        new[] { "short", "medium", "long" }[length.SelectedIndex]);

    private void RewriteAnswer()
    {
        if (!rewrite.Enabled || book.Active is not { } thread ||
            thread.Turns.LastOrDefault() is not { } turn || turn.Answer is not { } answer) return;
        if (turn.Variants.Exists(variant => variant.Choice == SelectedChoice))
        {
            book.ShowVariant(thread.Id, turn.Id, SelectedChoice, null);
            SaveHistory();
            DrawChat(toLast: true);
            RefreshControls();
            return;
        }
        Enqueue(new(answer.Question.Text, thread.Id, book.Navigation, turn.Mode, SelectedChoice, "rewrite", Rewrite: turn));
    }

    private void Enqueue(Work request)
    {
        failed = null;
        retry.Visible = false;
        if (request.Rewrite is { } turn) rewriting.Add(turn.Id);
        pending++;
        SetStatus(pending > 1 ? $"В очереди {pending}" : "Готовлю ответ…");
        RefreshControls();
        replyQueue = DeliverAfter(replyQueue, request);
    }

    private async Task DeliverAfter(Task prior, Work request)
    {
        try
        {
            await prior;
            lifetime.Token.ThrowIfCancellationRequested();
            var settings = Credentials();
            await gateway.EnsureReady(settings);
            var profile = await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory, "CoachPrompt.txt"), lifetime.Token);
            var previous = request.Rewrite?.Answer?.Segments ?? [];
            var carry = "";
            if (request.Session is { } session && incomplete is { } fragment && fragment.Session == session &&
                fragment.Target == request.Target && fragment.Navigation == request.Navigation &&
                DateTimeOffset.UtcNow - fragment.Time < TimeSpan.FromSeconds(15)) carry = fragment.Text;
            var response = await gateway.Answer(new ThreadRequest(profile + "\n\n" + settings.Profile, request.Text,
                request.Mode, request.Choice.Language, request.Choice.Length, request.Choice.Language != "ru", request.Source,
                book.Context(request.Target, request.Rewrite?.Id), string.Join(" ", previous.Select(line => line.Text)), carry), lifetime.Token);

            if (request.Session is { } incoming)
            {
                var combined = carry + " " + request.Text;
                incomplete = response.Incomplete
                    ? (combined.Length > 1200 ? combined[^1200..] : combined, incoming, request.Target, request.Navigation, DateTimeOffset.UtcNow)
                    : null;
            }
            if (request.Rewrite is { } turn && request.Target is { } thread && response.Items.FirstOrDefault() is { } replacement)
            {
                var question = request.Mode == "practice" ? replacement.Question : turn.Answer?.Question ?? replacement.Question;
                book.ShowVariant(thread, turn.Id, request.Choice, new AnswerVariant(request.Choice, question, replacement.Segments));
            }
            else
            {
                foreach (var item in response.Items)
                    book.Add(item, request.Target, request.Navigation, request.Mode, request.Choice,
                        input.TextLength == 0 && !voiceFollowUp.Checked);
            }

            SetStatus(pending > 1 ? $"В очереди {pending - 1}" : capture is not null ? "Слушаю…" : "");
            if (response.Items.Length == 0) return;
            SaveHistory();
            if (request.Target == book.ActiveId || request.Target is null && request.Navigation == book.Navigation)
                DrawChat(toLast: true);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (IsDisposed || lifetime.IsCancellationRequested) return;
            failed = request;
            retry.Visible = true;
            SetStatus(error.Message);
        }
        finally
        {
            pending--;
            if (request.Rewrite is { } turn) rewriting.Remove(turn.Id);
            RefreshControls();
        }
    }

    private void SaveHistory()
    {
        try { storage.WriteThreads(book.Snapshot()); }
        catch { SetStatus("Не удалось сохранить локальную историю."); }
    }

    private void DrawChat(bool toLast = false)
    {
        chat.SuspendLayout();
        chat.Clear();
        int lastPosition = 0;
        if (book.Active is { } thread)
        {
            foreach (var turn in thread.Turns)
            {
                lastPosition = chat.TextLength;
                if (turn.Answer is not { } reply) continue;
                ChatLine(turn.Mode == "practice" ? "Вопрос для репетиции\n" :
                    turn == thread.Turns[0] ? "Вопрос\n" : "Уточнение\n", Font, SystemColors.GrayText);
                ChatLine(reply.Question.Text + "\n", questionFont, SystemColors.WindowText);
                DrawTranslation(reply.Question);
                if (reply.Segments.Length > 0)
                {
                    ChatLine(turn.Mode == "review" ? "\nРазбор\n" : "\nОтвет\n", Font, SystemColors.GrayText);
                    for (var index = 0; index < reply.Segments.Length; index++)
                    {
                        var line = reply.Segments[index];
                        ChatLine($"{index + 1}. {line.Text}\n", Font, SystemColors.WindowText);
                        DrawTranslation(line);
                        chat.AppendText("\n");
                    }
                }
                chat.AppendText("\n");
            }
        }
        else ChatLine("Напиши вопрос или нажми «Слушать».", Font, SystemColors.GrayText);
        chat.SelectionStart = toLast ? lastPosition : 0;
        chat.ScrollToCaret();
        chat.ResumeLayout();
    }

    private void DrawTranslation(Segment line)
    {
        if (translation.Checked && line.Ru.Length > 0) ChatLine(line.Ru + "\n", translationFont, SystemColors.GrayText);
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
        listen.Enabled = recording || microphone.Checked || system.Checked;
        listen.Text = recording ? "Остановить" : "Слушать";
        send.Text = SelectedMode == "practice" && input.TextLength == 0 ? "Новый вопрос" : "Отправить";
        send.Enabled = SelectedMode == "practice" || !string.IsNullOrWhiteSpace(input.Text);
        length.Enabled = SelectedMode != "practice";
        voiceFollowUp.Visible = book.Active is not null;
        input.PlaceholderText = book.Active is null ? "Напиши вопрос" : "Напиши уточнение к этому вопросу";
        closeQuestion.Enabled = book.ActiveId is not null;
        archive.Enabled = book.Threads.Any(thread => thread.Id != book.ActiveId);
        var turn = book.Active?.Turns.LastOrDefault();
        rewrite.Visible = turn is not null && turn.Displayed != SelectedChoice;
        rewrite.Enabled = turn is not null && turn.Displayed != SelectedChoice && !rewriting.Contains(turn.Id);
    }

    private Settings Credentials()
    {
        var value = storage.ReadSettings();
        return value.Configured ? value : throw new InvalidOperationException("Добавь ключи Gemini и ElevenLabs в настройках.");
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
        archiveMenu.Dispose();
        base.OnFormClosed(e);
    }
}
