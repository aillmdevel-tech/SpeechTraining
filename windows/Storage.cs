using System.Security.Cryptography;
using System.Text.Json;

namespace SpeechTraining;

internal record Settings(string Gemini = "", string Elevenlabs = "", string Profile = "")
{
    public bool Configured => Gemini.Length > 0 && Elevenlabs.Length > 0;
}

internal record Segment(string Text, string Ru);
internal record ChatTurn(Guid Id, string Input, string Mode, Segment[] Reply);
internal record CoachReply(Segment[] Segments);
internal record CoachRequest(string Prompt, string Input, string Mode, string Language, string Length, bool Translate);
internal record Boundary(string Spoken, string Opening);
internal record BoundaryDecision(bool Separate);

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
