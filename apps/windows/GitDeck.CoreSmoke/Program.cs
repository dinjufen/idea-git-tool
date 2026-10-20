using GitDeck.Core;

// 用法：GitDeck.CoreSmoke [仓库路径]（默认当前目录）
var path = args.Length > 0 ? args[0] : Environment.CurrentDirectory;

Console.WriteLine($"core {CoreApi.CoreVersion()}");
var git = CoreApi.GitInfo();
Console.WriteLine($"git  {git.Version} ({git.Path})");

try
{
    using var repo = Repository.Open(path);
    var status = repo.Status();
    var branch = status.Branch;
    var head = branch.Head ?? $"(detached {branch.Oid?[..8]})";
    var upstream = branch.Upstream is null ? "" : $" -> {branch.Upstream} +{branch.Ahead}/-{branch.Behind}";
    Console.WriteLine($"repo {path}");
    Console.WriteLine($"on   {head}{upstream}  state={status.State}");
    Console.WriteLine($"{status.Changes.Length} change(s)");
    foreach (var change in status.Changes)
    {
        Console.WriteLine($"  {change.Staged,-10} {change.Unstaged,-10} {change.Path}");
    }
    return 0;
}
catch (CoreException e)
{
    Console.Error.WriteLine($"error: {e.GetType().Name}: {e.Message}");
    return 1;
}
