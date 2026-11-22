using SwiftDrop.Core;

// Headless SwiftDrop peer — runs on Windows, Linux and macOS.
//   swiftdrop serve [--port N] [--out DIR] [--name NAME] [--accept]
//   swiftdrop send  <host[:port]> <file|folder>... [--text "message"] [--port N]
//   swiftdrop list  [--port N]
var argv = args.ToList();
string? Opt(string name) { var i = argv.IndexOf(name); if (i < 0 || i + 1 >= argv.Count) return null; var v = argv[i + 1]; argv.RemoveRange(i, 2); return v; }
bool Flag(string name) => argv.Remove(name);

var port = int.TryParse(Opt("--port"), out var p) ? p : LS.Port;
var outDir = Opt("--out"); var name = Opt("--name"); var text = Opt("--text"); var accept = Flag("--accept");
var cmd = argv.FirstOrDefault() ?? "help";

var engine = new Engine(port);
if (name != null) engine.Settings.Name = name;
if (outDir != null) { Directory.CreateDirectory(outDir); engine.Settings.SaveDirectory = Path.GetFullPath(outDir); }
engine.Decide = offer =>
{
    Console.WriteLine($"OFFER from {offer.SenderAlias}: {string.Join(", ", offer.Files.Select(f => f.FileName))} ({offer.Total} bytes)");
    if (accept) { Console.WriteLine("  → accepted"); return Task.FromResult(true); }
    Console.Write("  Accept? [y/N] ");
    return Task.FromResult(Console.ReadLine()?.Trim().ToLowerInvariant() is "y" or "yes");
};
engine.IncomingChanged += i => { if (i.Status is Incoming.State.Done or Incoming.State.Failed) Console.WriteLine($"RECEIVED {i.Status}: {string.Join(", ", i.Saved)} {i.Error}"); };
engine.MessageReceived += (from, t) => Console.WriteLine($"MESSAGE from {from}: {t}");

switch (cmd)
{
    case "serve":
        engine.Start();
        Console.WriteLine($"READY {engine.Settings.Name} {engine.Scheme}://0.0.0.0:{port} fp={engine.Fingerprint}");
        await Task.Delay(Timeout.Infinite);
        break;
    case "list":
        engine.Start(); engine.Refresh(deep: true);
        await Task.Delay(6000);
        foreach (var peer in engine.Peers) Console.WriteLine($"{peer.Alias}\t{peer.Caption}\t{peer.BaseUrl}");
        break;
    case "send" when argv.Count >= 2:
    {
        engine.Start();
        var target = argv[1].Split(':');
        var peer = await engine.AddManual(target[0], target.Length > 1 ? int.Parse(target[1]) : LS.Port);
        if (peer == null) { Console.Error.WriteLine("Device not reachable"); return 2; }
        var items = Engine.ItemsFromPaths(argv.Skip(2)).ToList();
        if (text != null) items.Add(Engine.TextItem(text));
        var sw = System.Diagnostics.Stopwatch.StartNew();
        try { await engine.SendAndWait(peer, items); }
        catch (TransferException e) { Console.WriteLine($"RESULT {e.Kind}: {e.Message}"); return 1; }
        Console.WriteLine($"RESULT Done → {peer.Alias} ({items.Count} items, {items.Sum(i => i.Size)} bytes, {sw.Elapsed.TotalSeconds:F2}s)");
        break;
    }
    default:
        Console.WriteLine("usage: swiftdrop serve [--port N] [--out DIR] [--name NAME] [--accept]\n       swiftdrop send <host[:port]> <paths...> [--text msg]\n       swiftdrop list");
        break;
}
engine.Stop();
return 0;
