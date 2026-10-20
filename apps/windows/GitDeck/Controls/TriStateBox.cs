using GitDeck.Common;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace GitDeck.Controls;

/// 树中使用的小复选框（选中 / 未选 / 半选），样式接近 IDEA 的变更树复选框。
/// 状态完全由调用方设置；点击时只触发 <see cref="Toggled"/>，由调用方更新数据后再设置状态。
public sealed class TriStateBox : Grid
{
    private const string CheckMark = "M3,7 L5.6,9.6 L11,4";
    private const string Dash = "M3.5,7 L10.5,7";

    private readonly Border _box = new() { Width = 14, Height = 14, CornerRadius = new CornerRadius(3), BorderThickness = new Thickness(1) };
    private readonly Microsoft.UI.Xaml.Shapes.Path _mark = new()
    {
        Stroke = new SolidColorBrush(Microsoft.UI.Colors.White),
        StrokeThickness = 1.8,
        StrokeStartLineCap = PenLineCap.Round,
        StrokeEndLineCap = PenLineCap.Round,
        StrokeLineJoin = PenLineJoin.Round,
        Margin = new Thickness(-1),
    };
    private bool? _state = false;
    private bool _enabled = true;

    public event Action? Toggled;

    public TriStateBox()
    {
        Width = 20;
        Height = 20;
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _box.Child = _mark;
        Children.Add(_box);
        Tapped += (_, e) =>
        {
            if (_enabled) Toggled?.Invoke();
            e.Handled = true;
        };
        ActualThemeChanged += (_, _) => Update();
        Loaded += (_, _) => Update();
        Update();
    }

    /// true 选中，false 未选，null 半选。
    public bool? State
    {
        get => _state;
        set
        {
            _state = value;
            Update();
        }
    }

    public bool Enabled
    {
        get => _enabled;
        set
        {
            _enabled = value;
            Update();
        }
    }

    private void Update()
    {
        var on = _state != false;
        _box.Background = on ? Icons.ThemeBrush(this, "AccentBrush") : Icons.ThemeBrush(this, "EditorBackgroundBrush");
        _box.BorderBrush = on ? Icons.ThemeBrush(this, "AccentBrush") : Icons.ThemeBrush(this, "SecondaryTextBrush");
        _mark.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        _mark.Data = (Geometry)XamlBindingHelper.ConvertValue(typeof(Geometry), _state == true ? CheckMark : Dash);
        Opacity = _enabled ? 1 : 0.4;
    }
}
