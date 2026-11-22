using System.Text.Json.Serialization;

namespace SpeechTraining;

internal record AnswerChoice(string Language, string Length);
internal record AnswerVariant(AnswerChoice Choice, Segment Question, Segment[] Segments);
internal record PriorReply(string Question, string Answer);
internal record ThreadRequest(string Prompt, string Input, string Mode, string Language, string Length,
    bool Translate, string Source, PriorReply[] History, string Previous, string Continuation);
internal record ThreadItem(Segment Question, Segment[] Segments);
internal record ThreadReply(ThreadItem[] Items, bool Incomplete);

internal record QuestionTurn(Guid Id, string Mode, List<AnswerVariant> Variants, AnswerChoice Displayed)
{
    [JsonIgnore]
    public AnswerVariant? Answer => Variants.Find(item => item.Choice == Displayed) ?? Variants.LastOrDefault();
}

internal record QuestionThread(Guid Id, List<QuestionTurn> Turns)
{
    [JsonIgnore]
    public string Title => Turns.FirstOrDefault()?.Variants.FirstOrDefault()?.Question.Text ?? "Новый вопрос";
}

internal record ThreadHistory(List<QuestionThread> Threads, Guid? ActiveId);

internal sealed class QuestionBook(ThreadHistory history)
{
    public List<QuestionThread> Threads { get; } = history.Threads;
    public Guid? ActiveId { get; private set; } = history.ActiveId;
    public Guid Navigation { get; private set; } = Guid.NewGuid();
    public QuestionThread? Active => Find(ActiveId);

    public ThreadHistory Snapshot() => new(Threads, ActiveId);

    public void Select(Guid? id)
    {
        ActiveId = id;
        Navigation = Guid.NewGuid();
    }

    public QuestionThread? Find(Guid? id) => Threads.Find(thread => thread.Id == id);

    public void Add(ThreadItem item, Guid? target, Guid navigation, string mode, AnswerChoice choice, bool focus)
    {
        var thread = Find(target);
        if (thread is null)
        {
            thread = new QuestionThread(target ?? Guid.NewGuid(), []);
            Threads.Add(thread);
        }
        var variant = new AnswerVariant(choice, item.Question, item.Segments);
        thread.Turns.Add(new QuestionTurn(Guid.NewGuid(), mode, [variant], choice));
        if (target is null && navigation == Navigation && focus) ActiveId = thread.Id;
    }

    public void ShowVariant(Guid thread, Guid id, AnswerChoice choice, AnswerVariant? added)
    {
        var match = Find(thread);
        if (match is null) return;
        var position = match.Turns.FindIndex(turn => turn.Id == id);
        if (position < 0) return;
        var turn = match.Turns[position];
        if (added is not null) turn.Variants.Add(added);
        match.Turns[position] = turn with { Displayed = choice };
    }

    public PriorReply[] Context(Guid? target, Guid? before)
    {
        var turns = Find(target)?.Turns ?? [];
        var previous = turns.TakeWhile(turn => turn.Id != before).ToArray();
        if (previous.Length > 5) previous = [previous[0], .. previous.TakeLast(4)];
        return previous.Select(turn => turn.Answer).OfType<AnswerVariant>().Select(reply =>
            new PriorReply(reply.Question.Text, string.Join(" ", reply.Segments.Select(segment => segment.Text)))).ToArray();
    }
}
