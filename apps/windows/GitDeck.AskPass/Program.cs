using System.Text.Json;

namespace GitDeck.AskPass;

/// askpass 模式：git / ssh 需要凭据时以 `GIT_ASKPASS` / `SSH_ASKPASS` 调用本程序，参数为提示语。
/// 弹出输入框，把用户输入写到标准输出后退出（对应 IDEA 内置的 askpass，与 mac 端 AskPass 一致）。
///
/// 输入内容只交给发起请求的 git 进程，本程序不保存；凭据是否记住由 git 的 credential helper 决定。
internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        var prompt = string.Join(" ", args).Trim();
        ApplicationConfiguration.Initialize();
        Application.SetColorMode(SystemColorMode.System);
        var strings = Strings.Load();

        // ssh 首次连接确认主机指纹：只需回答 yes / no。
        if (prompt.Contains("(yes/no", StringComparison.Ordinal))
        {
            var answer = MessageBox.Show(prompt, strings["askpass.title"], MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            Write(answer == DialogResult.Yes ? "yes" : "no");
            return 0;
        }

        using var form = new PromptForm(prompt, IsSecret(prompt), strings);
        if (form.ShowDialog() != DialogResult.OK) return 1;
        Write(form.Value);
        return 0;
    }

    private static bool IsSecret(string prompt)
    {
        var lower = prompt.ToLowerInvariant();
        return new[] { "password", "passphrase", "token", "pin" }.Any(lower.Contains);
    }

    private static void Write(string value)
    {
        using var stdout = Console.OpenStandardOutput();
        var bytes = System.Text.Encoding.UTF8.GetBytes(value + "\n");
        stdout.Write(bytes, 0, bytes.Length);
    }
}

/// 输入框：提示语 + 输入框（密码时掩码）+ 确定 / 取消。
internal sealed class PromptForm : Form
{
    private readonly TextBox _input;

    public PromptForm(string prompt, bool secret, IReadOnlyDictionary<string, string> strings)
    {
        Text = strings["askpass.title"];
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true;
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Segoe UI", 9.5f);
        Padding = new Padding(14);
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;

        var label = new Label { Text = prompt, AutoSize = true, MaximumSize = new Size(420, 0), Margin = new Padding(0, 0, 0, 8) };
        _input = new TextBox
        {
            Width = 420,
            UseSystemPasswordChar = secret,
            PlaceholderText = secret ? strings["askpass.password"] : strings["askpass.username"],
            Margin = new Padding(0, 0, 0, 12),
        };
        var ok = new Button { Text = strings["askpass.ok"], DialogResult = DialogResult.OK, AutoSize = true };
        var cancel = new Button { Text = strings["common.cancel"], DialogResult = DialogResult.Cancel, AutoSize = true };
        AcceptButton = ok;
        CancelButton = cancel;
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Fill, AutoSize = true, Controls = { cancel, ok } };
        var layout = new TableLayoutPanel { ColumnCount = 1, AutoSize = true, Dock = DockStyle.Fill };
        layout.Controls.Add(label);
        layout.Controls.Add(_input);
        layout.Controls.Add(buttons);
        Controls.Add(layout);
        Shown += (_, _) =>
        {
            Activate();
            _input.Focus();
        };
    }

    public string Value => _input.Text;
}

/// 读取与主程序共用的 Localizable.xcstrings 中需要的文案。语言由主程序通过 GITDECK_LANG 环境变量传入。
internal static class Strings
{
    private static readonly string[] Keys = ["askpass.title", "askpass.ok", "askpass.password", "askpass.username", "common.cancel"];

    public static IReadOnlyDictionary<string, string> Load()
    {
        var language = Environment.GetEnvironmentVariable("GITDECK_LANG") is { Length: > 0 } lang
            ? lang
            : System.Globalization.CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "zh-Hans" : "en";
        var result = Keys.ToDictionary(k => k, k => k);
        using var stream = typeof(Strings).Assembly.GetManifestResourceStream("Localizable.xcstrings");
        if (stream is null) return result;
        using var document = JsonDocument.Parse(stream);
        var strings = document.RootElement.GetProperty("strings");
        foreach (var key in Keys)
        {
            if (!strings.TryGetProperty(key, out var entry) || !entry.TryGetProperty("localizations", out var localizations)) continue;
            foreach (var candidate in new[] { language, "en" })
            {
                if (localizations.TryGetProperty(candidate, out var localization)
                    && localization.TryGetProperty("stringUnit", out var unit)
                    && unit.TryGetProperty("value", out var value))
                {
                    result[key] = value.GetString() ?? key;
                    break;
                }
            }
        }
        return result;
    }
}
