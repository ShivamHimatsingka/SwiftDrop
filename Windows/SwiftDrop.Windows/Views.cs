using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Controls.Primitives;
using SwiftDrop.Core;

namespace SwiftDrop.Windows;

static class UI
{
    public static readonly Color Blue = Color.FromRgb(0x00, 0x7A, 0xFF);
    public static readonly SolidColorBrush BlueBrush = new(Blue), Secondary = new(Color.FromArgb(0x99, 0x3C, 0x3C, 0x43)),
        Red = new(Color.FromRgb(0xFF, 0x3B, 0x30)), Hover = new(Color.FromArgb(0x14, 0, 0, 0)), Separator = new(Color.FromArgb(0x30, 0, 0, 0));
    public static readonly FontFamily Font = new("Segoe UI Variable Text, Segoe UI");

    public static TextBlock Text(string s, double size = 13, FontWeight? w = null, Brush? color = null) =>
        new() { Text = s, FontSize = size, FontWeight = w ?? FontWeights.Normal, Foreground = color ?? Brushes.Black, FontFamily = Font,
                TextTrimming = TextTrimming.CharacterEllipsis };

    public static Border Separator_() => new() { Height = 1, Background = Separator, Margin = new Thickness(14, 6, 14, 6) };

    /// Clickable row with Control Center-style hover highlight.
    public static Border Row(UIElement content, Action onClick, Thickness? margin = null)
    {
        var b = new Border { Child = content, Padding = new Thickness(8, 5, 8, 5), CornerRadius = new CornerRadius(6),
                             Background = Brushes.Transparent, Margin = margin ?? new Thickness(6, 0, 6, 0), Cursor = Cursors.Hand };
        b.MouseEnter += (_, _) => b.Background = Hover;
        b.MouseLeave += (_, _) => b.Background = Brushes.Transparent;
        b.MouseLeftButtonUp += (_, _) => onClick();
        return b;
    }

    public static Border Button(string label, bool primary, Action onClick)
    {
        var b = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(14, 7, 14, 7), Cursor = Cursors.Hand,
            Background = primary ? BlueBrush : new SolidColorBrush(Color.FromRgb(0xE9, 0xE9, 0xEB)),
            Child = new TextBlock { Text = label, FontFamily = Font, FontSize = 13, FontWeight = FontWeights.SemiBold,
                                    Foreground = primary ? Brushes.White : BlueBrush, HorizontalAlignment = HorizontalAlignment.Center } };
        b.MouseLeftButtonUp += (_, _) => onClick();
        b.MouseEnter += (_, _) => b.Opacity = 0.85; b.MouseLeave += (_, _) => b.Opacity = 1;
        return b;
    }

    /// Windows 11 rounded corners + Mica backdrop where available.
    public static void Polish(Window w)
    {
        try
        {
            var h = new WindowInteropHelper(w).EnsureHandle();
            int round = 2; DwmSetWindowAttribute(h, 33, ref round, 4);         // DWMWA_WINDOW_CORNER_PREFERENCE = ROUND
        }
        catch { }
    }
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int value, int size);
}

/// AirDrop monogram avatar with progress ring.
public sealed class Avatar : FrameworkElement
{
    readonly string _initials; readonly double _size;
    Phase _phase; double _progress, _spin;
    readonly System.Windows.Threading.DispatcherTimer _timer;

    public Avatar(string initials, double size)
    {
        _initials = initials; _size = size;
        Width = Height = size + size * 0.2;
        _timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
        _timer.Tick += (_, _) => { _spin = (_spin + 6) % 360; InvalidateVisual(); };
    }

    public void Set(Phase p, double progress)
    {
        _phase = p; _progress = progress;
        if (p == Phase.Waiting) _timer.Start(); else _timer.Stop();
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        var c = new Point(Width / 2, Height / 2);
        var grad = new LinearGradientBrush(Color.FromRgb(0xA8, 0xAD, 0xBA), Color.FromRgb(0x85, 0x8A, 0x96), 90);
        dc.DrawEllipse(grad, null, c, _size / 2, _size / 2);
        var ft = new FormattedText(_initials, System.Globalization.CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            new Typeface(UI.Font, FontStyles.Normal, FontWeights.Medium, FontStretches.Normal), _size * 0.38, Brushes.White, 1.0);
        dc.DrawText(ft, new Point(c.X - ft.Width / 2, c.Y - ft.Height / 2));
        if (!_phase.IsActive()) return;
        var r = _size / 2 + _size * 0.07; var w = Math.Max(2, _size * 0.05);
        dc.DrawEllipse(null, new Pen(new SolidColorBrush(Color.FromArgb(0x1A, 0, 0, 0)), w), c, r, r);
        double start = _phase == Phase.Waiting ? _spin : -90, sweep = _phase == Phase.Waiting ? 65 : 360 * Math.Clamp(_progress, 0.01, 0.999);
        dc.DrawGeometry(null, new Pen(UI.BlueBrush, w) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, Arc(c, r, start, sweep));
    }

    static Geometry Arc(Point c, double r, double startDeg, double sweepDeg)
    {
        Point P(double deg) => new(c.X + r * Math.Cos(deg * Math.PI / 180), c.Y + r * Math.Sin(deg * Math.PI / 180));
        var g = new StreamGeometry();
        using var ctx = g.Open();
        ctx.BeginFigure(P(startDeg), false, false);
        ctx.ArcTo(P(startDeg + sweepDeg), new Size(r, r), 0, sweepDeg > 180, SweepDirection.Clockwise, true, false);
        return g;
    }
}

public sealed class DeviceTile : StackPanel
{
    public DeviceTile(Peer p, (Phase phase, double progress) t, bool favorite, double size, Action onClick, Action<ContextMenu> menu)
    {
        Width = size + 34; Margin = new Thickness(0, 0, 0, 8); Cursor = Cursors.Hand; Background = Brushes.Transparent;
        var avatar = new Avatar(p.Initials, size); avatar.Set(t.phase, t.progress);
        Children.Add(avatar);
        Children.Add(new TextBlock { Text = p.Alias + (favorite ? " ★" : ""), FontFamily = UI.Font, FontSize = 11.5, FontWeight = FontWeights.Medium,
            TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxHeight = 32, TextTrimming = TextTrimming.CharacterEllipsis });
        var status = t.phase.Label(t.progress) ?? p.Caption;
        Children.Add(new TextBlock { Text = status, FontFamily = UI.Font, FontSize = 10.5, TextAlignment = TextAlignment.Center,
            Foreground = t.phase switch { Phase.Idle or Phase.Cancelled => UI.Secondary, Phase.Declined or Phase.Failed => UI.Red, _ => UI.BlueBrush } });
        MouseLeftButtonUp += (_, _) => { if (!t.phase.IsActive()) onClick(); };
        var cm = new ContextMenu(); menu(cm); ContextMenu = cm;
    }
}

/// The tray popover / share sheet — same layout as the Mac menu bar popover.
public sealed class FlyoutWindow : Window
{
    readonly App _app;
    readonly StackPanel _root = new();
    public IReadOnlyList<OutItem>? Pending;
    bool _dirty;

    public FlyoutWindow(App app)
    {
        _app = app;
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent; ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false; Topmost = true; Width = 348; SizeToContent = SizeToContent.Height; AllowDrop = true;
        Content = new Border
        {
            Margin = new Thickness(12), CornerRadius = new CornerRadius(12), Padding = new Thickness(0, 10, 0, 8),
            Background = new SolidColorBrush(Color.FromArgb(0xF7, 0xF9, 0xF9, 0xFB)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x22, 0, 0, 0)), BorderThickness = new Thickness(1),
            Effect = new DropShadowEffect { BlurRadius = 24, ShadowDepth = 4, Opacity = 0.22 }, Child = _root,
        };
        Deactivated += (_, _) => { if (!_app.Engine.Peers.Any(p => _app.Engine.TransferOf(p.Id).phase.IsActive())) Hide(); };
        Drop += (_, e) =>
        {
            if (e.Data.GetData(DataFormats.FileDrop) is string[] files) { Pending = Engine.ItemsFromPaths(files).ToList(); Render(); }
            else if (e.Data.GetData(DataFormats.UnicodeText) is string s) { Pending = [Engine.TextItem(s)]; Render(); }
        };
        SourceInitialized += (_, _) => UI.Polish(this);
        _app.Engine.Changed += () => { if (_dirty) return; _dirty = true; Dispatcher.BeginInvoke(() => { _dirty = false; if (IsVisible) Render(); }); };
    }

    public void ShowNearTray(bool centered)
    {
        Render();
        Show(); UpdateLayout();
        var wa = SystemParameters.WorkArea;
        if (centered) { Left = wa.Left + (wa.Width - ActualWidth) / 2; Top = wa.Top + (wa.Height - ActualHeight) / 2; }
        else { Left = wa.Right - ActualWidth - 4; Top = wa.Bottom - ActualHeight - 4; }
        Activate();
    }

    void Render()
    {
        var e = _app.Engine;
        _root.Children.Clear();

        // Header: icon, title, switch
        var on = e.Settings.Mode != ReceiveMode.Off;
        var header = new DockPanel { Margin = new Thickness(14, 0, 14, 6), LastChildFill = true };
        var icon = new Grid { Width = 28, Height = 28, Margin = new Thickness(0, 0, 10, 0) };
        icon.Children.Add(new Ellipse { Fill = on ? UI.BlueBrush : new SolidColorBrush(Color.FromArgb(0x20, 0, 0, 0)) });
        icon.Children.Add(new TextBlock { Text = "", FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 13,
            Foreground = on ? Brushes.White : Brushes.Black, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        DockPanel.SetDock(icon, Dock.Left); header.Children.Add(icon);
        var sw = Switch(on, v => e.SetMode(v ? ReceiveMode.Everyone : ReceiveMode.Off));
        DockPanel.SetDock(sw, Dock.Right); header.Children.Add(sw);
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(UI.Text("SwiftDrop", 13, FontWeights.SemiBold));
        titles.Children.Add(UI.Text(e.Settings.Mode switch { ReceiveMode.Off => "Receiving Off", ReceiveMode.Favorites => "Favorites Only", _ => "Everyone" }, 11, color: UI.Secondary));
        header.Children.Add(titles);
        _root.Children.Add(header);

        if (on)
            foreach (var (m, label) in new[] { (ReceiveMode.Favorites, "Favorites Only"), (ReceiveMode.Everyone, "Everyone") })
            {
                var row = new DockPanel();
                var check = UI.Text(e.Settings.Mode == m ? "✓" : "", 12, FontWeights.SemiBold); check.Width = 20;
                row.Children.Add(check); row.Children.Add(UI.Text(label, 13));
                _root.Children.Add(UI.Row(row, () => e.SetMode(m)));
            }
        _root.Children.Add(UI.Separator_());

        if (Pending is { Count: > 0 } pending)
        {
            var banner = new Border { Background = new SolidColorBrush(Color.FromArgb(0x1F, 0x00, 0x7A, 0xFF)), CornerRadius = new CornerRadius(9),
                                      Padding = new Thickness(10, 7, 10, 7), Margin = new Thickness(14, 0, 14, 8) };
            var sp = new StackPanel();
            sp.Children.Add(UI.Text(pending.Count == 1 ? System.IO.Path.GetFileName(pending[0].Name) : $"{pending.Count} Items", 12.5, FontWeights.SemiBold));
            sp.Children.Add(UI.Text("Click a person to send", 11, color: UI.Secondary));
            banner.Child = sp;
            _root.Children.Add(banner);
        }

        // Nearby
        var peers = e.Peers;
        if (peers.Count == 0)
        {
            var empty = new StackPanel { Margin = new Thickness(0, 14, 0, 14), HorizontalAlignment = HorizontalAlignment.Center };
            empty.Children.Add(new Radar(90));
            var t1 = UI.Text("Looking for people nearby…", 12.5, FontWeights.Medium); t1.HorizontalAlignment = HorizontalAlignment.Center; empty.Children.Add(t1);
            var t2 = UI.Text("Devices running SwiftDrop or LocalSend on this network appear here.", 10.5, color: UI.Secondary);
            t2.HorizontalAlignment = HorizontalAlignment.Center; empty.Children.Add(t2);
            _root.Children.Add(empty);
        }
        else
        {
            var wrap = new WrapPanel { Margin = new Thickness(10, 2, 10, 2) };
            foreach (var p in peers)
                wrap.Children.Add(new DeviceTile(p, e.TransferOf(p.Id), e.IsFavorite(p.Id), 50, () => Tap(p), cm =>
                {
                    MenuItem Item(string h, Action a) { var i = new MenuItem { Header = h }; i.Click += (_, _) => a(); return i; }
                    if (e.TransferOf(p.Id).phase.IsActive()) cm.Items.Add(Item("Stop Sending", () => e.Cancel(p.Id)));
                    cm.Items.Add(Item("Send Files…", () => PickAndSend(p)));
                    cm.Items.Add(Item("Send Clipboard", () => SendClipboard(p)));
                    cm.Items.Add(new Separator());
                    cm.Items.Add(Item(e.IsFavorite(p.Id) ? "Remove from Favorites" : "Add to Favorites", () => e.SetFavorite(p.Id, e.IsFavorite(p.Id) ? null : false)));
                    if (e.IsFavorite(p.Id))
                    {
                        var auto = e.Settings.Favorites[p.Id];
                        cm.Items.Add(new MenuItem { Header = "Auto-Accept from This Device", IsCheckable = true, IsChecked = auto });
                        ((MenuItem)cm.Items[^1]).Click += (_, _) => e.SetFavorite(p.Id, !auto);
                    }
                }));
            _root.Children.Add(wrap);
            _root.Children.Add(UI.Separator_());
            var clip = new DockPanel();
            clip.Children.Add(UI.Text("Send Clipboard", 13));
            var targets = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            foreach (var p in peers.Take(3))
            {
                var a = new Avatar(p.Initials, 20) { Margin = new Thickness(2, 0, 0, 0), Cursor = Cursors.Hand, ToolTip = $"Send clipboard to {p.Alias}" };
                var tr = e.TransferOf(p.Id); a.Set(tr.phase, tr.progress);
                a.MouseLeftButtonUp += (_, ev) => { ev.Handled = true; SendClipboard(p); };
                targets.Children.Add(a);
            }
            DockPanel.SetDock(targets, Dock.Right); clip.Children.Insert(0, targets);
            _root.Children.Add(UI.Row(clip, () => { }));
        }

        // Recent
        if (e.Settings.History.Count > 0)
        {
            _root.Children.Add(UI.Separator_());
            var h = UI.Text("Recent", 11, FontWeights.SemiBold, UI.Secondary); h.Margin = new Thickness(22, 0, 0, 2);
            _root.Children.Add(h);
            foreach (var item in e.Settings.History.Take(4))
            {
                var sp = new StackPanel();
                sp.Children.Add(UI.Text(item.Title, 12));
                sp.Children.Add(UI.Text($"{(item.Sent ? "To" : "From")} {item.Device} · {item.Time:t}", 10.5, color: UI.Secondary));
                var it = item;
                _root.Children.Add(UI.Row(sp, () =>
                {
                    if (it.Path != null && (System.IO.File.Exists(it.Path) || System.IO.Directory.Exists(it.Path)))
                        Process.Start("explorer.exe", $"/select,\"{it.Path}\"");
                }));
            }
        }

        _root.Children.Add(UI.Separator_());
        _root.Children.Add(UI.Row(UI.Text("Open Downloads Folder", 13), () => Process.Start("explorer.exe", $"\"{e.SaveDirectory}\"")));
        _root.Children.Add(UI.Row(UI.Text("Quit SwiftDrop", 13), () => _app.Quit()));
    }

    void Tap(Peer p)
    {
        if (Pending is { Count: > 0 } items) { _app.Engine.Send(p, items); Pending = null; Render(); }
        else PickAndSend(p);
    }

    void PickAndSend(Peer p)
    {
        var dlg = new Microsoft.Win32.OpenFileDialog { Multiselect = true, Title = $"Send to {p.Alias}" };
        if (dlg.ShowDialog(this) == true) _app.Engine.Send(p, Engine.ItemsFromPaths(dlg.FileNames).ToList());
    }

    void SendClipboard(Peer p)
    {
        if (Clipboard.ContainsFileDropList())
            _app.Engine.Send(p, Engine.ItemsFromPaths(Clipboard.GetFileDropList().Cast<string>()).ToList());
        else if (Clipboard.ContainsImage() && Clipboard.GetImage() is { } img)
        {
            var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"Clipboard {DateTime.Now:yyyy-MM-dd HH.mm.ss}.png");
            using (var fs = System.IO.File.Create(path)) { var enc = new PngBitmapEncoderShim(img); enc.Save(fs); }
            _app.Engine.Send(p, Engine.ItemsFromPaths([path]).ToList());
        }
        else if (Clipboard.ContainsText()) _app.Engine.Send(p, [Engine.TextItem(Clipboard.GetText())]);
    }

    static Border Switch(bool on, Action<bool> changed)
    {
        var knob = new Ellipse { Width = 16, Height = 16, Fill = Brushes.White, HorizontalAlignment = on ? HorizontalAlignment.Right : HorizontalAlignment.Left,
                                 Margin = new Thickness(2), Effect = new DropShadowEffect { BlurRadius = 3, ShadowDepth = 1, Opacity = 0.25 } };
        var b = new Border { Width = 36, Height = 20, CornerRadius = new CornerRadius(10), Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center,
                             Background = on ? UI.BlueBrush : new SolidColorBrush(Color.FromRgb(0xD1, 0xD1, 0xD6)), Child = knob };
        b.MouseLeftButtonUp += (_, _) => changed(!on);
        return b;
    }
}

sealed class PngBitmapEncoderShim(System.Windows.Media.Imaging.BitmapSource src)
{
    public void Save(System.IO.Stream s)
    {
        var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
        enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(src));
        enc.Save(s);
    }
}

/// AirDrop-style radar animation.
public sealed class Radar : Grid
{
    public Radar(double size)
    {
        Width = Height = size; Margin = new Thickness(0, 0, 0, 6);
        for (var i = 0; i < 3; i++)
        {
            var ring = new Ellipse { Stroke = UI.BlueBrush, StrokeThickness = 1, RenderTransformOrigin = new Point(0.5, 0.5),
                                     RenderTransform = new ScaleTransform(0.35, 0.35), Opacity = 0 };
            Children.Add(ring);
            var begin = TimeSpan.FromSeconds(i * 0.8);
            var dur = new Duration(TimeSpan.FromSeconds(2.4));
            var sx = new DoubleAnimation(0.35, 1, dur) { BeginTime = begin, RepeatBehavior = RepeatBehavior.Forever };
            var op = new DoubleAnimation(0.8, 0, dur) { BeginTime = begin, RepeatBehavior = RepeatBehavior.Forever };
            ((ScaleTransform)ring.RenderTransform).BeginAnimation(ScaleTransform.ScaleXProperty, sx);
            ((ScaleTransform)ring.RenderTransform).BeginAnimation(ScaleTransform.ScaleYProperty, sx);
            ring.BeginAnimation(OpacityProperty, op);
        }
        Children.Add(new Ellipse { Width = size * 0.36, Height = size * 0.36,
            Fill = new LinearGradientBrush(Color.FromRgb(0x40, 0xA8, 0xFF), UI.Blue, 90) });
        Children.Add(new TextBlock { Text = "", FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = size * 0.15,
            Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
    }
}

/// Incoming request, styled like a Windows 11 notification, above the tray.
public sealed class IncomingWindow : Window
{
    readonly App _app; readonly TaskCompletionSource<bool> _tcs; readonly StackPanel _body = new();
    Incoming _offer;
    public string OfferId => _offer.Id;

    public IncomingWindow(App app, Incoming offer, TaskCompletionSource<bool> tcs)
    {
        _app = app; _offer = offer; _tcs = tcs;
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent; ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false; Topmost = true; Width = 380; SizeToContent = SizeToContent.Height; ShowActivated = true;
        Content = new Border { Margin = new Thickness(12), CornerRadius = new CornerRadius(10), Padding = new Thickness(14),
            Background = new SolidColorBrush(Color.FromArgb(0xFA, 0xF9, 0xF9, 0xFB)), BorderBrush = new SolidColorBrush(Color.FromArgb(0x22, 0, 0, 0)),
            BorderThickness = new Thickness(1), Effect = new DropShadowEffect { BlurRadius = 24, ShadowDepth = 4, Opacity = 0.22 }, Child = _body };
        SourceInitialized += (_, _) => UI.Polish(this);
        Loaded += (_, _) => { var wa = SystemParameters.WorkArea; Left = wa.Right - ActualWidth - 4; Top = wa.Bottom - ActualHeight - 4; };
        Closed += (_, _) => _tcs.TrySetResult(false);
        Render();
    }

    public void Update(Incoming i)
    {
        if (i.Id != _offer.Id) return;
        _offer = i; Render();
        if (i.Status == Incoming.State.Done) System.Media.SystemSounds.Asterisk.Play();
    }

    void Render()
    {
        _body.Children.Clear();
        var top = new DockPanel();
        var av = new Avatar(new Peer("", _offer.SenderAlias, null, null, "", 0, "").Initials, 40) { Margin = new Thickness(0, 0, 10, 0) };
        av.Set(_offer.Status == Incoming.State.Receiving ? Phase.Sending : Phase.Idle, _offer.Progress);
        DockPanel.SetDock(av, Dock.Left); top.Children.Add(av);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(UI.Text("SwiftDrop", 13, FontWeights.SemiBold));
        var msg = _offer.Status switch
        {
            Incoming.State.Asking => $"“{_offer.SenderAlias}” would like to share {_offer.Noun}.",
            Incoming.State.Receiving => $"Receiving {_offer.Noun} from “{_offer.SenderAlias}”… {(int)(_offer.Progress * 100)}%",
            Incoming.State.Done => $"Received {_offer.Noun} from “{_offer.SenderAlias}”.",
            _ => _offer.Error ?? "Transfer failed",
        };
        var tb = UI.Text(msg, 12.5); tb.TextWrapping = TextWrapping.Wrap; text.Children.Add(tb);
        top.Children.Add(text);
        _body.Children.Add(top);

        var buttons = new UniformGrid { Columns = 2, Margin = new Thickness(0, 12, 0, 0) };
        switch (_offer.Status)
        {
            case Incoming.State.Asking:
                buttons.Children.Add(Pad(UI.Button("Decline", false, () => { _tcs.TrySetResult(false); Close(); })));
                buttons.Children.Add(Pad(UI.Button("Accept", true, () => _tcs.TrySetResult(true))));
                _body.Children.Add(buttons);
                var always = UI.Text("Always accept from this device", 11.5, color: UI.BlueBrush);
                always.Margin = new Thickness(0, 8, 0, 0); always.Cursor = Cursors.Hand; always.HorizontalAlignment = HorizontalAlignment.Center;
                always.MouseLeftButtonUp += (_, _) => { _app.Engine.SetFavorite(_offer.SenderId, true); _tcs.TrySetResult(true); };
                _body.Children.Add(always);
                break;
            case Incoming.State.Receiving:
                _body.Children.Add(new ProgressBar { Value = _offer.Progress * 100, Height = 4, Margin = new Thickness(0, 10, 0, 0), Foreground = UI.BlueBrush });
                break;
            default:
                buttons.Children.Add(Pad(UI.Button("Close", false, () => { _app.Engine.Dismiss(); Close(); })));
                buttons.Children.Add(Pad(UI.Button("Show in Folder", true, () =>
                {
                    var p = _offer.Saved.FirstOrDefault();
                    Process.Start("explorer.exe", p != null ? $"/select,\"{p}\"" : $"\"{_app.Engine.SaveDirectory}\"");
                    Close();
                })));
                _body.Children.Add(buttons);
                break;
        }
    }

    static Border Pad(Border b) { b.Margin = new Thickness(3, 0, 3, 0); return b; }
}

public sealed class MessageWindow : Window
{
    public MessageWindow(string from, string text)
    {
        Title = $"Message from {from}"; Width = 380; SizeToContent = SizeToContent.Height; Topmost = true;
        WindowStartupLocation = WindowStartupLocation.CenterScreen; ResizeMode = ResizeMode.NoResize;
        var sp = new StackPanel { Margin = new Thickness(16) };
        sp.Children.Add(UI.Text($"Message from “{from}”", 14, FontWeights.SemiBold));
        sp.Children.Add(new TextBox { Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 12),
                                      MaxHeight = 200, BorderThickness = new Thickness(0), Background = Brushes.Transparent, FontFamily = UI.Font });
        var row = new UniformGrid { Columns = 2 };
        row.Children.Add(UI.Button("Close", false, Close));
        row.Children.Add(UI.Button("Copy", true, () => { Clipboard.SetText(text); Close(); }));
        sp.Children.Add(row);
        Content = sp;
    }
}
