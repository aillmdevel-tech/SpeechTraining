using System.Buffers.Binary;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace SpeechTraining;

internal sealed class AudioMixer : IDisposable
{
    private readonly List<(WasapiCapture Device, AudioTrack Track)> sources = [];

    public AudioMixer(bool microphone, bool system, Action<Exception> failed)
    {
        try
        {
            if (microphone) Start(new WasapiCapture(), failed);
            if (system) Start(new WasapiLoopbackCapture(), failed);
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    private void Start(WasapiCapture device, Action<Exception> failed)
    {
        var track = new AudioTrack();
        sources.Add((device, track));
        device.DataAvailable += (_, args) => track.Add(args.Buffer.AsSpan(0, args.BytesRecorded), device.WaveFormat);
        device.RecordingStopped += (_, args) =>
        {
            if (args.Exception is { } error) failed(error);
        };
        device.StartRecording();
    }

    public byte[] Take()
    {
        const int frames = 1280;
        var tracks = sources.Select(source => source.Track.Take(frames)).ToArray();
        var bytes = new byte[frames * sizeof(short)];
        for (var index = 0; index < frames; index++)
        {
            var sample = 0;
            foreach (var data in tracks) sample += data[index];
            BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(index * 2), (short)Math.Clamp(sample, short.MinValue, short.MaxValue));
        }
        return bytes;
    }

    public void Dispose()
    {
        foreach (var (device, _) in sources) device.Dispose();
        sources.Clear();
    }
}

internal sealed class AudioTrack
{
    private readonly Lock guard = new();
    private readonly Queue<short> samples = new(16000);
    private int phase;
    private int count;
    private int rate;
    private float sum;

    public void Add(ReadOnlySpan<byte> data, WaveFormat format)
    {
        var encoding = format is WaveFormatExtensible ext ? ext.ToStandardWaveFormat().Encoding : format.Encoding;
        var bytesPerChannel = format.BitsPerSample / 8;
        if (format.SampleRate <= 0 || format.BlockAlign <= 0 || format.Channels <= 0 ||
            bytesPerChannel < 2 || bytesPerChannel > 4 || format.BlockAlign < bytesPerChannel * format.Channels ||
            (encoding != WaveFormatEncoding.Pcm && (encoding != WaveFormatEncoding.IeeeFloat || bytesPerChannel != 4))) return;
        lock (guard)
        {
            if (rate != format.SampleRate)
            {
                rate = format.SampleRate;
                phase = count = 0;
                sum = 0;
            }
            for (var frame = 0; frame + format.BlockAlign <= data.Length; frame += format.BlockAlign)
            {
                float mono = 0;
                for (var channel = 0; channel < format.Channels; channel++)
                {
                    var sample = data.Slice(frame + channel * bytesPerChannel, bytesPerChannel);
                    mono += (encoding, bytesPerChannel) switch
                    {
                        (WaveFormatEncoding.IeeeFloat, 4) => BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(sample)),
                        (_, 2) => BinaryPrimitives.ReadInt16LittleEndian(sample) / 32768f,
                        (_, 3) => ((sample[0] | (sample[1] << 8) | (sample[2] << 16)) << 8) / 2147483648f,
                        _ => BinaryPrimitives.ReadInt32LittleEndian(sample) / 2147483648f,
                    };
                }
                sum += mono / format.Channels;
                count++;
                phase += 16000;
                if (phase < rate) continue;
                var average = sum / count;
                var pcm = float.IsFinite(average) ? (short)(Math.Clamp(average, -1f, 1f) * 32767) : (short)0;
                while (phase >= rate)
                {
                    if (samples.Count == 16000) samples.Dequeue();
                    samples.Enqueue(pcm);
                    phase -= rate;
                }
                sum = 0;
                count = 0;
            }
        }
    }

    public short[] Take(int count)
    {
        var result = new short[count];
        lock (guard)
        {
            for (var sample = 0; sample < count && samples.Count > 0; sample++)
                result[sample] = samples.Dequeue();
        }
        return result;
    }
}
