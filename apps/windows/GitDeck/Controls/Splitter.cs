using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Controls;

/// 工具窗口与编辑器之间的分隔条：显示 1 像素线，拖动区域更宽；拖动时回报位移（逻辑像素）。
public sealed class Splitter : Grid
{
    private readonly bool _vertical;
    private double _start;
    private bool _dragging;

    public event Action<double>? Dragged;

    public event Action? DragCompleted;

    /// <param name="vertical">true：竖直分隔条（左右调整宽度）；false：水平分隔条（上下调整高度）。</param>
    public Splitter(bool vertical)
    {
        _vertical = vertical;
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        var line = Common.Themed.Background(new Border(), "SeparatorBrush");
        if (vertical)
        {
            Width = 5;
            Margin = new Thickness(-2, 0, -2, 0);
            line.Width = 1;
        }
        else
        {
            Height = 5;
            Margin = new Thickness(0, -2, 0, -2);
            line.Height = 1;
        }
        Children.Add(line);
        ProtectedCursor = InputSystemCursor.Create(vertical ? InputSystemCursorShape.SizeWestEast : InputSystemCursorShape.SizeNorthSouth);
        PointerPressed += OnPressed;
        PointerMoved += OnMoved;
        PointerReleased += OnReleased;
        PointerCaptureLost += (_, _) => Finish();
    }

    private double Coordinate(PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(XamlRoot.Content).Position;
        return _vertical ? point.X : point.Y;
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        _dragging = CapturePointer(e.Pointer);
        _start = Coordinate(e);
        e.Handled = true;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging) return;
        var current = Coordinate(e);
        Dragged?.Invoke(current - _start);
        _start = current;
        e.Handled = true;
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        ReleasePointerCapture(e.Pointer);
        Finish();
    }

    private void Finish()
    {
        if (!_dragging) return;
        _dragging = false;
        DragCompleted?.Invoke();
    }
}
