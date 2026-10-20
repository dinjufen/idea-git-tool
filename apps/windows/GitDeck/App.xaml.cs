using GitDeck.Common;
using Microsoft.UI.Xaml;

namespace GitDeck;

public partial class App : Application
{
    public App()
    {
        if (DebugOptions.Get("debug.theme") is { } theme && Enum.TryParse<AppearanceSetting>(theme, ignoreCase: true, out var value))
        {
            Appearance.Override = value;
        }
        L10n.Initialize(DebugOptions.Get("debug.lang"));
        InitializeComponent();
        UnhandledException += (_, e) => Log.Error("unhandled", e.Exception);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args) => AppController.Shared.Start();
}
