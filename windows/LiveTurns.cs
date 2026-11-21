using System.Text.RegularExpressions;

namespace SpeechTraining;

internal sealed partial class LiveTurns
{
    private int consumed;
    private string[] parts = [];
    public string Draft => string.Join(" ", parts.Skip(consumed));
    public string? CheckedSpoken { get; set; }

    public void Update(string value)
    {
        parts = SentenceSeparator().Split(value.Trim()).Where(piece => !string.IsNullOrWhiteSpace(piece)).ToArray();
    }

    public Boundary? Candidate
    {
        get
        {
            for (var index = consumed + 1; index < parts.Length; index++)
            {
                var spoken = string.Join(" ", parts[consumed..index]);
                var opening = string.Join(" ", parts[index..]);
                if (spoken.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length >= 4 &&
                    opening.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length >= 4)
                    return new(spoken, opening);
            }
            return null;
        }
    }

    public string? SplitAt(Boundary value)
    {
        if (Candidate?.Spoken != value.Spoken) return null;
        consumed += SentenceSeparator().Split(value.Spoken).Length;
        CheckedSpoken = null;
        return value.Spoken;
    }

    public string Finish(string final)
    {
        Update(final);
        var result = Draft;
        parts = [];
        consumed = 0;
        CheckedSpoken = null;
        return result;
    }

    [GeneratedRegex(@"(?<=[.!?…])\s+")]
    private static partial Regex SentenceSeparator();
}
