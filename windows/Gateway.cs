using System.Diagnostics;
using System.Net.Http.Json;
using System.Text.Json;

namespace SpeechTraining;

internal sealed class Gateway : IDisposable
{
    private record Handshake(int Port, string Token);
    private readonly HttpClient client = new() { Timeout = TimeSpan.FromSeconds(35) };
    private readonly SemaphoreSlim startup = new(1);
    private Process? process;
    private Handshake? session;

    public async Task EnsureReady(Settings settings)
    {
        await startup.WaitAsync();
        try
        {
            if (process is { HasExited: false } && session is not null) return;
            Stop();
            var start = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "speech-gateway.exe"))
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
            };
            var child = Process.Start(start) ?? throw new InvalidOperationException("Не удалось запустить подключение.");
            process = child;
            try
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8));
                var keys = JsonSerializer.Serialize(new { gemini = settings.Gemini, elevenlabs = settings.Elevenlabs }, Storage.Json);
                await child.StandardInput.WriteLineAsync(keys.AsMemory(), timeout.Token);
                await child.StandardInput.FlushAsync(timeout.Token);
                var line = await child.StandardOutput.ReadLineAsync(timeout.Token);
                session = line is null ? null : JsonSerializer.Deserialize<Handshake>(line, Storage.Json);
                if (session is not { Port: > 0 and <= 65535 } || session.Token.Length != 64)
                    throw new InvalidOperationException("Локальное подключение не запустилось.");
            }
            catch
            {
                Stop();
                throw;
            }
        }
        finally { startup.Release(); }
    }

    public Task<ThreadReply> Answer(ThreadRequest request, CancellationToken token) =>
        Post<ThreadRequest, ThreadReply>("/thread", request, token);

    private async Task<TOut> Post<TIn, TOut>(string path, TIn input, CancellationToken token)
    {
        var active = session ?? throw new InvalidOperationException("Подключение к Gemini недоступно.");
        using var message = new HttpRequestMessage(HttpMethod.Post, $"http://127.0.0.1:{active.Port}{path}");
        message.Headers.Add("X-Session-Token", active.Token);
        message.Content = JsonContent.Create(input, options: Storage.Json);
        using var response = await client.SendAsync(message, token);
        if (!response.IsSuccessStatusCode)
        {
            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
            var detail = json.RootElement.GetProperty("error").GetProperty("message").GetString();
            throw new InvalidOperationException(detail ?? "Gemini не обработал запрос.");
        }
        return await response.Content.ReadFromJsonAsync<TOut>(Storage.Json, token)
            ?? throw new InvalidOperationException("Gemini вернул пустой ответ.");
    }

    public void Stop()
    {
        session = null;
        if (process is null) return;
        process.StandardInput.Dispose();
        if (!process.HasExited && !process.WaitForExit(1000)) process.Kill();
        process.Dispose();
        process = null;
    }

    public void Dispose()
    {
        Stop();
        client.Dispose();
        startup.Dispose();
    }
}
