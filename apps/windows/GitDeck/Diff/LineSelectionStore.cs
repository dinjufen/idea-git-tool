using GitDeck.Core;

namespace GitDeck.Diff;

/// 部分提交的行选择（IDEA 在 Diff 中勾选要提交的改动块 / 行）：按文件记录不提交的行（与 mac 端 LineSelectionStore 一致）。
///
/// 记录选择时两侧的内容；提交时若文件已改变，选择失效，由提交流程提示用户重新选择。
public sealed class LineSelectionStore
{
    private readonly Dictionary<string, Selection> _selections = [];

    public event Action? Changed;

    public sealed class Selection
    {
        public Selection(string baseText, string text)
        {
            Base = baseText;
            Text = text;
        }

        /// 工作区（新）文本中不提交的行。
        public HashSet<uint> ExcludedLines { get; } = [];

        /// 基准（HEAD）文本中不提交的删除行。
        public HashSet<uint> ExcludedBaseLines { get; } = [];

        /// 选择时的基准与工作区内容。
        public string Base { get; }

        public string Text { get; }

        public bool IsEmpty => ExcludedLines.Count == 0 && ExcludedBaseLines.Count == 0;

        /// 要提交的内容。
        public string Content => CoreApi.PartialText(Base, Text, [.. ExcludedLines], [.. ExcludedBaseLines]);

        public Selection Copy()
        {
            var copy = new Selection(Base, Text);
            copy.ExcludedLines.UnionWith(ExcludedLines);
            copy.ExcludedBaseLines.UnionWith(ExcludedBaseLines);
            return copy;
        }
    }

    public Selection? Get(string path) => _selections.GetValueOrDefault(path);

    /// 该文件只提交部分改动。
    public bool IsPartial(string path) => _selections.TryGetValue(path, out var selection) && !selection.IsEmpty;

    public void Update(string path, Selection selection)
    {
        if (selection.IsEmpty) _selections.Remove(path);
        else _selections[path] = selection;
        Changed?.Invoke();
    }

    public void Remove(IEnumerable<string> paths)
    {
        var changed = false;
        foreach (var path in paths) changed |= _selections.Remove(path);
        if (changed) Changed?.Invoke();
    }
}
