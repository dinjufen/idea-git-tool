using GitDeck.Common;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Editor;

/// 编辑器字体设置（视图 > 编辑器字体…）：字体、字号、行距与预览。确定后立即应用到所有编辑器。
/// 对应 mac 端的字体面板与 设置 > 编辑器；完整的设置窗口在 W7 中实现，届时复用这里的内容。
public static class EditorFontDialog
{
    private const string Sample = "public static int Answer() {\n    return 42; // 中文注释 0O1lI\n}";

    public static async Task Show(XamlRoot root)
    {
        var dialog = Dialogs.Create(root, L10n.Tr("menu.view.editorFont").TrimEnd('…'));
        dialog.PrimaryButtonText = L10n.Tr("common.ok");
        dialog.SecondaryButtonText = L10n.Tr("menu.view.fontReset");
        dialog.CloseButtonText = L10n.Tr("common.cancel");

        var defaultLabel = L10n.Tr("settings.editor.systemFont");
        var family = new ComboBox { IsEditable = true, MinWidth = 280 };
        family.Items.Add(defaultLabel);
        foreach (var name in FontCatalog.EditorCandidates()) family.Items.Add(name);
        family.Text = EditorSettings.FontFamily ?? defaultLabel;
        family.SelectedItem = family.Items.FirstOrDefault(i => (string)i == (EditorSettings.FontFamily ?? defaultLabel));

        var size = new NumberBox
        {
            Minimum = EditorSettings.MinSize,
            Maximum = EditorSettings.MaxSize,
            Value = EditorSettings.FontSize,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline,
            SmallChange = 1,
            Width = 120,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        var spacing = new ComboBox { Width = 120 };
        foreach (var value in EditorSettings.LineSpacingOptions) spacing.Items.Add(value.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture));
        spacing.SelectedIndex = Math.Max(0, Array.IndexOf(EditorSettings.LineSpacingOptions, EditorSettings.LineSpacing));

        var preview = new TextBlock
        {
            Text = Sample,
            Padding = new Thickness(10),
            TextWrapping = TextWrapping.NoWrap,
        };
        var previewBox = Themed.Background(new Border { CornerRadius = new CornerRadius(4), Child = preview, MinHeight = 90 }, "EditorBackgroundBrush");
        previewBox.BorderThickness = new Thickness(1);
        Themed.Brush(previewBox, "SeparatorBrush", (b, brush) => b.BorderBrush = brush);

        string? SelectedFamily()
        {
            var text = (family.SelectedItem as string ?? family.Text ?? "").Trim();
            return text.Length == 0 || text == defaultLabel ? null : text;
        }

        void UpdatePreview()
        {
            var name = SelectedFamily() is { } chosen && FontCatalog.IsInstalled(chosen)
                ? chosen
                : EditorSettings.FallbackFamilies.FirstOrDefault(FontCatalog.IsInstalled) ?? "Consolas";
            preview.FontFamily = new FontFamily(name);
            preview.FontSize = double.IsNaN(size.Value) ? EditorSettings.DefaultSize : size.Value;
            preview.LineHeight = preview.FontSize * EditorSettings.LineSpacingOptions[Math.Max(0, spacing.SelectedIndex)] * 1.2;
        }

        family.SelectionChanged += (_, _) => UpdatePreview();
        family.TextSubmitted += (_, _) => UpdatePreview();
        size.ValueChanged += (_, _) => UpdatePreview();
        spacing.SelectionChanged += (_, _) => UpdatePreview();
        UpdatePreview();

        var grid = new Grid { RowSpacing = 10, ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        AddRow(grid, 0, L10n.Tr("settings.editor.font"), family);
        AddRow(grid, 1, L10n.Tr("settings.editor.size"), size);
        AddRow(grid, 2, L10n.Tr("settings.editor.lineSpacing"), spacing);
        AddRow(grid, 3, L10n.Tr("settings.editor.preview"), previewBox);
        dialog.Content = grid;

        switch (await dialog.ShowAsync())
        {
            case ContentDialogResult.Primary:
                EditorSettings.FontFamily = SelectedFamily();
                if (!double.IsNaN(size.Value)) EditorSettings.FontSize = size.Value;
                EditorSettings.LineSpacing = EditorSettings.LineSpacingOptions[Math.Max(0, spacing.SelectedIndex)];
                break;
            case ContentDialogResult.Secondary:
                EditorSettings.Reset();
                break;
        }
    }

    private static void AddRow(Grid grid, int row, string label, FrameworkElement control)
    {
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var text = new TextBlock { Text = label, VerticalAlignment = row == 3 ? VerticalAlignment.Top : VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };
        Grid.SetRow(text, row);
        Grid.SetRow(control, row);
        Grid.SetColumn(control, 1);
        grid.Children.Add(text);
        grid.Children.Add(control);
    }
}
