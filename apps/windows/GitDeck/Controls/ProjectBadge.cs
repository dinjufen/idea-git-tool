using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace GitDeck.Controls;

/// 项目名称首字母的彩色方块（项目组件、欢迎页最近项目）。颜色由名称决定，同一项目每次显示一致。
public sealed class ProjectBadge : Grid
{
    private static readonly uint[] Palette = [0x3574F0, 0x5FB865, 0xE55765, 0xC77D55, 0x955AE0, 0x2E9E9E];
    private readonly TextBlock _text = new()
    {
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
        FontWeight = Microsoft.UI.Text.FontWeights.Bold,
    };

    public ProjectBadge(double size = 20)
    {
        Width = size;
        Height = size;
        CornerRadius = new CornerRadius(size / 5);
        _text.FontSize = size * 0.45;
        Children.Add(_text);
    }

    public string ProjectName
    {
        set
        {
            _text.Text = Initials(value);
            var sum = _text.Text.Sum(c => (int)c);
            var rgb = Palette[sum % Palette.Length];
            Background = new SolidColorBrush(Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
        }
    }

    public static string Initials(string name)
    {
        var words = name.Split(['-', '_', ' ', '.'], StringSplitOptions.RemoveEmptyEntries);
        var letters = words.Length >= 2 ? string.Concat(words.Take(2).Select(w => w[0])) : new string(name.Take(2).ToArray());
        return letters.ToUpperInvariant();
    }
}
