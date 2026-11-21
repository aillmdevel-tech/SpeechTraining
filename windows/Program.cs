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
            var turns = new LiveTurns();
            turns.Update("How would you help a new student? What would you change about climate policy?");
            if (turns.Candidate is not { } boundary || turns.SplitAt(boundary) != boundary.Spoken ||
                turns.Finish($"{boundary.Spoken} {boundary.Opening}") != boundary.Opening) return 4;
            var track = new AudioTrack();
            var audio = new byte[480 * 2 * 2];
            for (var sample = 0; sample < audio.Length; sample += 2)
                BinaryPrimitives.WriteInt16LittleEndian(audio.AsSpan(sample), 8192);
            track.Add(audio, new WaveFormat(48000, 16, 2));
            var pcm = track.Take(161);
            if (pcm.Take(160).Any(sample => sample != 8191) || pcm[160] != 0) return 5;
            using var form = new MainForm(storage, hotkeysEnabled: false);
            if (form.Handle == IntPtr.Zero || form.Text != "SpeechTraining") return 6;
            return 0;
        }
        catch { return 1; }
        finally { if (Directory.Exists(path)) Directory.Delete(path, recursive: true); }
    }
}
