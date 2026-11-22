using System.Buffers.Binary;
using NAudio.Wave;

namespace SpeechTraining;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.SequenceEqual(new[] { "--self-test" })) return SmokeTest();
        Application.Run(new MainForm(new Storage()));
        return 0;
    }

    private static int SmokeTest()
    {
        var path = Path.Combine(Path.GetTempPath(), "SpeechTraining-" + Guid.NewGuid());
        try
        {
            var storage = new Storage(path);
            storage.WriteSettings(new Settings("synthetic-a", "synthetic-b", "test"));
            if (!storage.ReadSettings().Configured) return 2;
            using (var gateway = new Gateway())
                Task.Run(() => gateway.EnsureReady(storage.ReadSettings())).GetAwaiter().GetResult();
            var fixture = new ChatTurn(Guid.NewGuid(), "Question", "answer", [new("Answer", "Перевод")]);
            storage.WriteHistory([fixture]);
            if (storage.ReadHistory().Single().Reply.Single().Ru != "Перевод") return 3;
            if (!CheckQuestionThreads(storage, fixture.Id)) return 4;
            var track = new AudioTrack();
            var audio = new byte[480 * 2 * 2];
            for (var sample = 0; sample < audio.Length; sample += 2)
                BinaryPrimitives.WriteInt16LittleEndian(audio.AsSpan(sample), 8192);
            track.Add(audio, new WaveFormat(48000, 16, 2));
            var pcm = track.Take(161);
            if (pcm.Take(160).Any(sample => sample != 8191) || pcm[160] != 0) return 5;
            using var form = new MainForm(storage, hotkeysEnabled: false);
            if (form.Handle == IntPtr.Zero || form.Text != "SpeechTraining") return 6;
            form.Show();
            form.ToggleWindow();
            if (form.Visible) return 7;
            form.ToggleWindow();
            if (!form.Visible) return 8;
            return 0;
        }
        catch { return 1; }
        finally { if (Directory.Exists(path)) Directory.Delete(path, recursive: true); }
    }

    private static bool CheckQuestionThreads(Storage storage, Guid legacy)
    {
        var book = new QuestionBook(storage.ReadThreads());
        if (book.Find(legacy)?.Title != "Question" || book.Active is not null) return false;
        var english = new AnswerChoice("en", "short");
        var russian = new AnswerChoice("ru", "short");
        var first = new ThreadItem(new("Fair school budget?", "Справедливый школьный бюджет?"), [new("Choose a criterion.", "Выбери критерий.")]);
        var second = new ThreadItem(new("Help a new student?", "Помочь новому ученику?"), [new("Offer a guide.", "Предложи помощь.")]);
        var original = book.Navigation;
        book.Add(first, null, original, "answer", english, true);
        if (book.Active is not { } thread) return false;
        book.Select(null);
        book.Add(second, null, original, "answer", english, true);
        if (book.Active is not null || book.Threads.Count != 3 || book.Context(null, null).Length != 0) return false;
        book.Select(thread.Id);
        if (book.Context(thread.Id, null).Single().Question != first.Question.Text) return false;
        var followUp = new ThreadItem(new("What criterion?", "Какой критерий?"), [new("Choose reach.", "Выбери охват.")]);
        book.Add(followUp, thread.Id, book.Navigation, "answer", english, true);
        var last = thread.Turns.Last();
        book.ShowVariant(thread.Id, last.Id, russian, new AnswerVariant(russian, followUp.Question, [new("Выбери охват.", "")]));
        if (thread.Turns.Last().Answer?.Choice != russian || book.Context(thread.Id, last.Id).Length != 1) return false;
        book.ShowVariant(thread.Id, last.Id, english, null);
        storage.WriteThreads(book.Snapshot());
        var restored = new QuestionBook(storage.ReadThreads());
        return restored.Active?.Turns.Last().Answer?.Choice == english && restored.Threads.Count == 3;
    }
}
