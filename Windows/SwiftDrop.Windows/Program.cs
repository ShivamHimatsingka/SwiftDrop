using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Win32;
using SwiftDrop.Core;
using Forms = System.Windows.Forms;

namespace SwiftDrop.Windows;

/// Tray app entry point. Single instance: extra launches (Explorer "Send with
/// SwiftDrop") forward their paths to the running instance over a named pipe.
public static class Program
{
    const string PipeName = "SwiftDrop.Windows.Pipe";

    [STAThread]
    public static int Main(string[] args)
    {
        var paths = args.SkipWhile(a => a != "--send").Skip(1).ToList();
        using var mutex = new Mutex(true, "SwiftDrop.Windows.Instance", out var first);
        if (!first)
        {
            try
            {
                using var c = new NamedPipeClientStream(".", PipeName, PipeDirection.Out);
                c.Connect(3000);
                using var w = new StreamWriter(c);
                w.WriteLine(paths.Count == 0 ? "--show" : string.Join("\0", paths));
            }
            catch { }
            return 0;
        }
        var app = new App();
        app.Startup += (_, _) =>
        {
            app.Boot(background: args.Contains("--background"));
            if (paths.Count > 0) app.Queue(paths);
            Task.Run(() => PipeLoop(app));
        };
        return app.Run();
    }

    static void PipeLoop(App app)
    {
        while (true)
        {
            try
            {
                using var s = new NamedPipeServerStream(PipeName, PipeDirection.In, 1);
                s.WaitForConnection();
                using var r = new StreamReader(s);
                var line = r.ReadLine();
                if (line == null) continue;
                app.Dispatcher.Invoke(() =>
                {
                    if (line == "--show") app.ShowFlyout(); else app.Queue(line.Split('\0'));
                });
            }
            catch { Thread.Sleep(200); }
        }
    }
}

public sealed class App : Application
{
    public Engine Engine { get; private set; } = null!;
    Forms.NotifyIcon? _tray;
    Bluetooth? _bluetooth;
    FlyoutWindow? _flyout;
    IncomingWindow? _incoming;
    readonly List<string> _queued = new();
    DispatcherTimerLite? _queueTimer;

    public void Boot(bool background)
    {
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        Engine = new Engine();
        Engine.Decide = offer => Dispatcher.Invoke(() => ShowIncoming(offer));
        Engine.IncomingChanged += i => Dispatcher.BeginInvoke(() =>
        {
            // Auto-accepted (favourite) transfers never asked, so open the status window now.
            if ((_incoming == null || !_incoming.IsVisible || _incoming.OfferId != i.Id) && i.Status != Incoming.State.Asking)
            {
                _incoming?.Close();
                var done = new TaskCompletionSource<bool>(); done.SetResult(true);
                _incoming = new IncomingWindow(this, i, done);
                _incoming.Show();
            }
            _incoming?.Update(i);
        });
        Engine.MessageReceived += (from, text) => Dispatcher.BeginInvoke(() =>
            new MessageWindow(from, text).Show());
        Engine.Start();
        _bluetooth = new Bluetooth(Engine);
        _ = _bluetooth.Start();
        Integration.Register();

        var exe = Environment.ProcessPath!;
        _tray = new Forms.NotifyIcon
        {
            Icon = System.Drawing.Icon.ExtractAssociatedIcon(exe),
            Text = "SwiftDrop",
            Visible = true,
            ContextMenuStrip = new Forms.ContextMenuStrip(),
        };
        _tray.ContextMenuStrip.Items.Add("Open SwiftDrop", null, (_, _) => ShowFlyout());
        _tray.ContextMenuStrip.Items.Add("Quit SwiftDrop", null, (_, _) => Quit());
        _tray.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) ToggleFlyout(); };
        if (!background) ShowFlyout();
        // Lightweight while idle in the tray: once a minute, if no window is open, hand unused memory
        // back to Windows (start-up code and libraries are paged back in only if needed again).
        _trimTimer = new System.Windows.Threading.DispatcherTimer(TimeSpan.FromSeconds(60),
            System.Windows.Threading.DispatcherPriority.ApplicationIdle, (_, _) => TrimIfIdle(), Dispatcher);
        _trimTimer.Start();
        _ = new DispatcherTimerLite(Dispatcher, TimeSpan.FromSeconds(15), TrimIfIdle);
    }

    System.Windows.Threading.DispatcherTimer? _trimTimer;

    void TrimIfIdle()
    {
        if (Windows.OfType<Window>().Any(w => w.IsVisible)) return;
        GC.Collect(2, GCCollectionMode.Optimized, blocking: false, compacting: true);
        try { SetProcessWorkingSetSize(System.Diagnostics.Process.GetCurrentProcess().Handle, -1, -1); } catch { }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    static extern bool SetProcessWorkingSetSize(IntPtr process, nint min, nint max);

    public void Quit() { _tray!.Visible = false; Engine.Stop(); Shutdown(); }

    public void ToggleFlyout()
    {
        if (_flyout is { IsVisible: true }) _flyout.Hide(); else ShowFlyout();
    }

    public void ShowFlyout(IReadOnlyList<OutItem>? pending = null)
    {
        _flyout ??= new FlyoutWindow(this);
        if (pending != null) _flyout.Pending = pending;
        Engine.Refresh(deep: Engine.Peers.Count == 0);
        _bluetooth?.Refresh();
        _flyout.ShowNearTray(centered: pending != null);
    }

    /// Paths from Explorer arrive one process per file — collect for a moment, then open the sheet.
    public void Queue(IEnumerable<string> paths)
    {
        _queued.AddRange(paths.Where(p => !string.IsNullOrWhiteSpace(p)));
        _queueTimer?.Cancel();
        _queueTimer = new DispatcherTimerLite(Dispatcher, TimeSpan.FromMilliseconds(400), () =>
        {
            var items = Engine.ItemsFromPaths(_queued.Distinct()).ToList();
            _queued.Clear();
            if (items.Count > 0) ShowFlyout(items);
        });
    }

    Task<bool> ShowIncoming(Incoming offer)
    {
        var tcs = new TaskCompletionSource<bool>();
        _incoming?.Close();
        _incoming = new IncomingWindow(this, offer, tcs);
        _incoming.Show();
        System.Media.SystemSounds.Asterisk.Play();
        return tcs.Task;
    }
}

/// Tiny one-shot dispatcher timer.
public sealed class DispatcherTimerLite
{
    readonly System.Windows.Threading.DispatcherTimer _t;
    public DispatcherTimerLite(System.Windows.Threading.Dispatcher d, TimeSpan delay, Action action)
    {
        _t = new System.Windows.Threading.DispatcherTimer(delay, System.Windows.Threading.DispatcherPriority.Normal, (_, _) => { _t!.Stop(); action(); }, d);
        _t.Start();
    }
    public void Cancel() => _t.Stop();
}

/// Explorer + startup integration (per-user, no admin rights needed).
public static class Integration
{
    public static void Register()
    {
        var exe = Environment.ProcessPath!;
        foreach (var root in new[] { @"Software\Classes\*\shell\SwiftDrop", @"Software\Classes\Directory\shell\SwiftDrop" })
        {
            using var k = Registry.CurrentUser.CreateSubKey(root);
            k.SetValue("MUIVerb", "Send with SwiftDrop");
            k.SetValue("Icon", $"\"{exe}\",0");
            k.SetValue("MultiSelectModel", "Player");
            using var cmd = k.CreateSubKey("command");
            cmd.SetValue("", $"\"{exe}\" --send \"%1\"");
        }
        using var run = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        run.SetValue("SwiftDrop", $"\"{exe}\" --background");
    }

    public static void Unregister()
    {
        Registry.CurrentUser.DeleteSubKeyTree(@"Software\Classes\*\shell\SwiftDrop", false);
        Registry.CurrentUser.DeleteSubKeyTree(@"Software\Classes\Directory\shell\SwiftDrop", false);
        using var run = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        run.DeleteValue("SwiftDrop", false);
    }
}
