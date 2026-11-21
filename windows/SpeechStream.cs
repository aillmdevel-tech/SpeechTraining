using System.Net.WebSockets;
using System.Text.Json;

namespace SpeechTraining;

internal sealed class SpeechStream : IDisposable
{
    internal record Event(string Type, string Text);
    private readonly ClientWebSocket socket = new();

    public static async Task<SpeechStream> Connect(string key, CancellationToken stop)
    {
        foreach (var model in new[] { "scribe_v3_live", "scribe_v2_realtime" })
        {
            var speech = new SpeechStream();
            try
            {
                var v3 = model == "scribe_v3_live";
                var strategy = v3 ? "turn_prediction&multilang_mode=true" : "vad";
                var uri = new Uri($"wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id={model}&audio_format=pcm_16000&commit_strategy={strategy}&vad_silence_threshold_secs=1.35&keepalive_interval_ms=2000&enable_logging=false");
                speech.socket.Options.SetRequestHeader("xi-api-key", key);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stop);
                timeout.CancelAfter(TimeSpan.FromSeconds(10));
                await speech.socket.ConnectAsync(uri, timeout.Token);
                var first = await speech.Receive(timeout.Token);
                if (first.Type == "session_started") return speech;
                if (!v3 || first.Type != "invalid_request") throw Problem(first.Type);
            }
            catch (Exception ex) when (model == "scribe_v3_live" && !stop.IsCancellationRequested &&
                                       ex is WebSocketException or OperationCanceledException)
            {
                // The older live model is available on accounts without v3 access.
            }
            catch
            {
                speech.Dispose();
                throw;
            }
            speech.Dispose();
        }
        throw new InvalidOperationException("Не удалось подключить живое распознавание ElevenLabs.");
    }

    public async Task<Event> Receive(CancellationToken token)
    {
        using var message = new MemoryStream();
        var chunk = new byte[8192];
        WebSocketReceiveResult result;
        do
        {
            result = await socket.ReceiveAsync(new ArraySegment<byte>(chunk), token);
            if (result.MessageType == WebSocketMessageType.Close || message.Length + result.Count > 512 * 1024)
                throw Problem("");
            message.Write(chunk, 0, result.Count);
        } while (!result.EndOfMessage);

        message.Position = 0;
        using var json = await JsonDocument.ParseAsync(message, cancellationToken: token);
        var root = json.RootElement;
        return new(root.GetProperty("message_type").GetString() ?? "", root.TryGetProperty("text", out var text) ? text.GetString() ?? "" : "");
    }

    public async Task Send(byte[] pcm, CancellationToken token)
    {
        var message = JsonSerializer.SerializeToUtf8Bytes(new
        {
            message_type = "input_audio_chunk", audio_base_64 = Convert.ToBase64String(pcm), sample_rate = 16000, commit = false,
        });
        await socket.SendAsync(message.AsMemory(), WebSocketMessageType.Text, true, token);
    }

    public static Exception Problem(string kind) => new InvalidOperationException(kind switch
    {
        "auth_error" => "ElevenLabs отклонил ключ распознавания.",
        "quota_exceeded" or "rate_limited" or "throttled" => "Достигнут лимит ElevenLabs.",
        "unaccepted_terms" => "Подтверди условия распознавания в кабинете ElevenLabs.",
        _ => "Связь с живым распознаванием ElevenLabs прервалась.",
    });

    public void Dispose() => socket.Dispose();
}
