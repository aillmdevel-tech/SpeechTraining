using System.Security.Cryptography;
using System.Text.Json;

namespace SpeechTraining;

internal record Settings(string Gemini = "", string Elevenlabs = "", string Profile = "")
{
    public bool Configured => Gemini.Length > 0 && Elevenlabs.Length > 0;
}

internal record Segment(string Text, string Ru);
internal record ChatTurn(Guid Id, string Input, string Mode, Segment[] Reply);
internal sealed class Storage(string root)
{
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public Storage() : this(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SpeechTraining")) { }

    public Settings ReadSettings()
    {
        var path = Path.Combine(root, "settings.dat");
        if (!File.Exists(path)) return new();
        var bytes = ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.CurrentUser);
        return JsonSerializer.Deserialize<Settings>(bytes, Json) ?? new();
    }

    public void WriteSettings(Settings value)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(value, Json);
        Write("settings.dat", ProtectedData.Protect(payload, null, DataProtectionScope.CurrentUser));
    }

    public List<ChatTurn> ReadHistory()
    {
        var path = Path.Combine(root, "history.json");
        return File.Exists(path) ? JsonSerializer.Deserialize<List<ChatTurn>>(File.ReadAllBytes(path), Json) ?? [] : [];
    }

    public void WriteHistory(IEnumerable<ChatTurn> turns) =>
        Write("history.json", JsonSerializer.SerializeToUtf8Bytes(turns.TakeLast(200), Json));

    public ThreadHistory ReadThreads()
    {
        var path = Path.Combine(root, "threads.json");
        if (File.Exists(path)) return JsonSerializer.Deserialize<ThreadHistory>(File.ReadAllBytes(path), Json) ?? new([], null);
        var migrated = ReadHistory().Select(old =>
        {
            var phrase = string.Join(" ", old.Reply.Select(line => line.Text));
            var language = phrase.Any(character => "іїєґІЇЄҐ".Contains(character)) ? "uk" :
                phrase.All(character => character < '\u0400' || character > '\u04FF') ? "en" : "ru";
            var choice = new AnswerChoice(language, "short");
            var variant = new AnswerVariant(choice, new Segment(old.Input, ""), old.Reply);
            return new QuestionThread(old.Id, [new QuestionTurn(Guid.NewGuid(), old.Mode, [variant], choice)]);
        }).ToList();
        return new(migrated, null);
    }

    public void WriteThreads(ThreadHistory history) =>
        Write("threads.json", JsonSerializer.SerializeToUtf8Bytes(history, Json));

    private void Write(string name, byte[] bytes)
    {
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, name);
        var temporary = path + "." + Guid.NewGuid() + ".tmp";
        try
        {
            File.WriteAllBytes(temporary, bytes);
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}
