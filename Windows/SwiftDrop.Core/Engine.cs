using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace SwiftDrop.Core;

public sealed class Settings
{
    public string Name { get; set; } = Environment.MachineName;
    public ReceiveMode Mode { get; set; } = ReceiveMode.Everyone;
    public Dictionary<string, bool> Favorites { get; set; } = new();   // id -> auto-accept
    public List<HistoryEntry> History { get; set; } = new();
    public string? SaveDirectory { get; set; }
    public string? HttpFingerprint { get; set; }
}

/// Platform-independent SwiftDrop engine (used by the Windows app and the CLI).
public sealed class Engine
{
    public static readonly string DataDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SwiftDrop");

    public Settings Settings { get; }
    public int Port { get; }
    public string DeviceModel { get; init; } = OperatingSystem.IsWindows() ? "Windows" : OperatingSystem.IsLinux() ? "Linux" : "Computer";
    public string Fingerprint { get; private set; } = "";
    public string Scheme { get; private set; } = "https";

    public event Action? Changed;
    /// Ask the user. Return true to accept. If unset, offers are declined.
    public Func<Incoming, Task<bool>>? Decide;
    public event Action<Incoming>? IncomingChanged;
    public event Action<string, string>? MessageReceived;   // (from, text)

    readonly ConcurrentDictionary<string, Peer> _peers = new();
    readonly ConcurrentDictionary<string, (Phase phase, double progress)> _transfers = new();
    readonly ConcurrentDictionary<string, CancellationTokenSource> _sendCts = new();
    readonly ConcurrentDictionary<string, Session> _sessions = new();
    readonly ConcurrentDictionary<string, int> _misses = new();
    readonly HttpClient _http, _probe;
    HttpServer? _server;
    UdpClient? _udp;
    DateTime _browsingUntil;
    public Incoming? Current { get; private set; }

    public IReadOnlyList<Peer> Peers => _peers.Values
        .OrderBy(p => Settings.Favorites.ContainsKey(p.Id) ? 0 : 1).ThenBy(p => p.Alias, StringComparer.OrdinalIgnoreCase).ToList();
    public (Phase phase, double progress) TransferOf(string peerId) => _transfers.TryGetValue(peerId, out var t) ? t : (Phase.Idle, 0);
    public string SaveDirectory => Settings.SaveDirectory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");

    public Engine(int port = LS.Port, bool tls = true)
    {
        Port = port;
        Directory.CreateDirectory(DataDir);
        Settings = LoadSettings();
        var handler = new SocketsHttpHandler
        {
            SslOptions = { RemoteCertificateValidationCallback = (_, _, _, _) => true },   // LocalSend uses self-signed certs
            MaxConnectionsPerServer = 8, PooledConnectionIdleTimeout = TimeSpan.FromSeconds(30),
        };
        _http = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        _probe = new HttpClient(new SocketsHttpHandler { SslOptions = { RemoteCertificateValidationCallback = (_, _, _, _) => true },
                                                         ConnectTimeout = TimeSpan.FromMilliseconds(1500) }) { Timeout = TimeSpan.FromSeconds(2) };
        X509Certificate2? cert = tls ? LoadOrCreateCert() : null;
        if (cert != null) { Fingerprint = Convert.ToHexString(SHA256.HashData(cert.RawData)).ToLowerInvariant(); Scheme = "https"; }
        else { Fingerprint = Settings.HttpFingerprint ??= Guid.NewGuid().ToString("N"); Scheme = "http"; Save(); }
        _cert = cert;
    }
    readonly X509Certificate2? _cert;

    static X509Certificate2? LoadOrCreateCert()
    {
        var path = Path.Combine(DataDir, "identity.pfx");
        try
        {
            if (File.Exists(path)) return new X509Certificate2(path, (string?)null, X509KeyStorageFlags.Exportable);
            using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
            var req = new CertificateRequest("CN=SwiftDrop", key, HashAlgorithmName.SHA256);
            using var c = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(10));
            File.WriteAllBytes(path, c.Export(X509ContentType.Pfx));
            return new X509Certificate2(path, (string?)null, X509KeyStorageFlags.Exportable);
        }
        catch { return null; }
    }

    public DeviceInfo Me(bool? announce = null) => new()
    {
        Alias = Settings.Name, DeviceModel = DeviceModel, DeviceType = "desktop", Fingerprint = Fingerprint,
        Port = Port, Protocol = Scheme, Announce = announce, Announcement = announce,
    };

    // ------------------------------------------------------------ lifecycle

    public void Start()
    {
        _server = new HttpServer(Port, _cert, Route);
        _server.Start();
        try { StartMulticast(); } catch { /* HTTP scan still works */ }
        NetworkChange.NetworkAddressChanged += (_, _) => { JoinGroups(); Announce(); };
        Announce();
        _ = Task.Delay(1500).ContinueWith(_ => Announce());
    }

    public void Stop() { _server?.Stop(); _udp?.Dispose(); }

    static IEnumerable<IPAddress> LocalIPv4() => NetworkInterface.GetAllNetworkInterfaces()
        .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback && n.SupportsMulticast)
        .SelectMany(n => n.GetIPProperties().UnicastAddresses).Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
        .Select(a => a.Address);

    void StartMulticast()
    {
        var u = new UdpClient(AddressFamily.InterNetwork);
        u.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        u.ExclusiveAddressUse = false;
        u.Client.Bind(new IPEndPoint(IPAddress.Any, LS.Port));
        u.Ttl = 4;
        _udp = u;
        JoinGroups();
        _ = Task.Run(async () =>
        {
            while (true)
            {
                UdpReceiveResult r;
                try { r = await u.ReceiveAsync(); } catch (ObjectDisposedException) { break; } catch { continue; }
                try
                {
                    var info = JsonSerializer.Deserialize<DeviceInfo>(r.Buffer, LS.Json);
                    if (info != null) OnMulticast(info, r.RemoteEndPoint.Address.ToString());
                }
                catch { }
            }
        });
    }

    void JoinGroups()
    {
        if (_udp == null) return;
        foreach (var ip in LocalIPv4())
            try { _udp.JoinMulticastGroup(IPAddress.Parse(LS.Multicast), ip); } catch { }
    }

    void SendMulticast(DeviceInfo info)
    {
        if (_udp == null) return;
        var data = JsonSerializer.SerializeToUtf8Bytes(info, LS.Json);
        foreach (var ip in LocalIPv4())
            try
            {
                _udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, ip.GetAddressBytes());
                _udp.Send(data, data.Length, new IPEndPoint(IPAddress.Parse(LS.Multicast), LS.Port));
            }
            catch { }
    }

    public void Announce() { if (IsDiscoverable(null)) SendMulticast(Me(true)); BluetoothChanged?.Invoke(); }

    // ------------------------------------------------------------ Bluetooth

    /// Raised when visibility changes so the platform Bluetooth layer can start/stop advertising.
    public event Action? BluetoothChanged;

    /// Our Bluetooth card, or null when we shouldn't be discoverable.
    public BleCard? Card() => IsDiscoverable(null)
        ? new BleCard(Settings.Name, Fingerprint, DeviceModel, "desktop", Port, Scheme, LocalIPv4().Select(a => a.ToString()).ToList(), new())
        : null;

    /// Platform hook: write a knock to the device at this Bluetooth address. Returns true if delivered.
    public Func<ulong, string, Task<bool>>? WakeDevice;
    readonly ConcurrentDictionary<string, (ulong address, DateTime seen)> _wakeable = new();

    /// A card read over Bluetooth: connect over the normal network if possible.
    public async Task HandleCard(BleCard card, ulong address = 0)
    {
        if (card.Fingerprint == Fingerprint) return;
        if (address != 0 && card.Caps.Contains("wake")) _wakeable[card.Fingerprint] = (address, DateTime.UtcNow);
        if (_peers.ContainsKey(card.Fingerprint)) return;
        foreach (var ip in card.Ips)
            foreach (var scheme in new[] { card.Scheme, card.Scheme == "https" ? "http" : "https" })
                if (await Register($"{scheme}://{ip}:{card.Port}", probe: true) is { } info) { Ingest(info, ip, card.Port, scheme); return; }
    }

    /// Call while a sending UI is visible.
    public void Refresh(bool deep = false)
    {
        _browsingUntil = DateTime.UtcNow.AddMinutes(2);
        JoinGroups();
        SendMulticast(Me(true));
        _ = Task.Run(async () =>
        {
            await Task.WhenAll(_peers.Values.ToList().Select(async p =>
            {
                if (await Register(p.BaseUrl, probe: false) != null) { _misses.TryRemove(p.Id, out _); return; }
                // Two consecutive misses before a device disappears (slow Wi-Fi / sleeping phones).
                var sleeping = _wakeable.TryGetValue(p.Id, out var wk) && DateTime.UtcNow - wk.seen < TimeSpan.FromMinutes(15);
                if (_misses.AddOrUpdate(p.Id, 1, (_, n) => n + 1) >= 2 && !TransferOf(p.Id).phase.IsActive() && !sleeping)
                { _peers.TryRemove(p.Id, out _); _misses.TryRemove(p.Id, out _); Changed?.Invoke(); }
            }));
            if (deep || _peers.IsEmpty) await Scan();
        });
    }

    async Task Scan()
    {
        var hosts = LocalIPv4().SelectMany(ip =>
        {
            var b = ip.GetAddressBytes();
            return Enumerable.Range(1, 254).Where(i => i != b[3]).Select(i => $"{b[0]}.{b[1]}.{b[2]}.{i}");
        }).Distinct().ToList();
        using var gate = new SemaphoreSlim(64);
        await Task.WhenAll(hosts.Select(async h =>
        {
            await gate.WaitAsync();
            try
            {
                foreach (var scheme in new[] { "https", "http" })
                    if (await Register($"{scheme}://{h}:{LS.Port}", probe: true) is { } info) { Ingest(info, h, LS.Port, scheme); break; }
            }
            finally { gate.Release(); }
        }));
    }

    async Task<DeviceInfo?> Register(string baseUrl, bool probe)
    {
        try
        {
            var content = new StringContent(JsonSerializer.Serialize(Me(), LS.Json), Encoding.UTF8, "application/json");
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(probe ? 2 : 5));
            using var resp = await (probe ? _probe : _http).PostAsync($"{baseUrl}/api/localsend/v2/register", content, cts.Token);
            return resp.IsSuccessStatusCode ? JsonSerializer.Deserialize<DeviceInfo>(await resp.Content.ReadAsStringAsync(), LS.Json) : null;
        }
        catch { return null; }
    }

    /// Add a peer by address (useful when multicast is blocked).
    public async Task<Peer?> AddManual(string host, int port = LS.Port)
    {
        foreach (var scheme in new[] { "https", "http" })
            if (await Register($"{scheme}://{host}:{port}", probe: true) is { } info) return Ingest(info, host, port, scheme);
        return null;
    }

    Peer? Ingest(DeviceInfo info, string host, int? port = null, string? scheme = null)
    {
        if (string.IsNullOrEmpty(info.Fingerprint) || info.Fingerprint == Fingerprint) return null;
        var p = new Peer(info.Fingerprint, info.Alias, info.DeviceModel, info.DeviceType, host,
                         port ?? info.Port ?? LS.Port, scheme ?? info.Protocol ?? "https");
        _peers[p.Id] = p;
        Changed?.Invoke();
        return p;
    }

    void OnMulticast(DeviceInfo info, string ip)
    {
        var p = Ingest(info, ip);
        if (p == null || !info.IsAnnouncement || !IsDiscoverable(info.Fingerprint)) return;
        _ = Task.Run(async () => { if (await Register(p.BaseUrl, probe: true) == null) SendMulticast(Me(false)); });
    }

    // ------------------------------------------------------------ policy

    public bool IsFavorite(string? id) => id != null && Settings.Favorites.ContainsKey(id);
    public bool IsDiscoverable(string? id) => DateTime.UtcNow < _browsingUntil || Settings.Mode switch
    {
        ReceiveMode.Everyone => true, ReceiveMode.Favorites => IsFavorite(id), _ => false,
    };
    bool CanReceive(string id) => Settings.Mode switch { ReceiveMode.Everyone => true, ReceiveMode.Favorites => IsFavorite(id), _ => false };

    public void SetMode(ReceiveMode m) { Settings.Mode = m; Save(); Announce(); Changed?.Invoke(); }
    public void SetFavorite(string id, bool? autoAccept)
    {
        if (autoAccept is null) Settings.Favorites.Remove(id); else Settings.Favorites[id] = autoAccept.Value;
        Save(); Changed?.Invoke();
    }

    // ------------------------------------------------------------ server

    sealed class Session(Incoming offer, Dictionary<string, string> tokens)
    {
        public Incoming Offer = offer;
        public readonly Dictionary<string, string> Tokens = tokens;
        public readonly ConcurrentDictionary<string, bool> Pending = new(tokens.Keys.Select(k => KeyValuePair.Create(k, true)));
        public readonly ConcurrentBag<string> Saved = new();
        public readonly ConcurrentDictionary<string, string> Folders = new();
        public long Received;
        public DateTime LastActivity = DateTime.UtcNow, LastReport;
        public volatile bool Cancelled;
    }

    async Task<Response> Route(Request r)
    {
        var path = r.Path.Replace("/api/localsend/v1/", "/api/localsend/v2/");
        switch ($"{r.Method} {path}")
        {
            case "POST /api/localsend/v2/register":
            {
                var info = JsonSerializer.Deserialize<DeviceInfo>(await r.TextAsync(), LS.Json);
                if (info == null) return Response.Bad;
                Ingest(info, r.Remote);
                return IsDiscoverable(info.Fingerprint) ? Response.Json(Me()) : Response.Forbidden;
            }
            case "GET /api/localsend/v2/info":
                return IsDiscoverable(r.Query.GetValueOrDefault("fingerprint")) ? Response.Json(Me()) : Response.Forbidden;
            case "POST /api/localsend/v2/prepare-upload":
                return await Prepare(r);
            case "POST /api/localsend/v2/upload":
                return await Upload(r);
            case "POST /api/localsend/v2/cancel":
                if (_sessions.TryRemove(r.Query.GetValueOrDefault("sessionId") ?? "", out var s)) { s.Cancelled = true; Finish(s, "Cancelled by sender"); }
                return Response.Ok;
            default:
                return Response.NotFound;
        }
    }

    async Task<Response> Prepare(Request r)
    {
        var dto = JsonSerializer.Deserialize<PrepareRequest>(await r.TextAsync(), LS.Json);
        if (dto?.Files == null || dto.Files.Count == 0) return Response.Bad;
        var sender = Ingest(dto.Info, r.Remote);
        if (!CanReceive(dto.Info.Fingerprint)) return Response.Forbidden;
        var offer = new Incoming(Guid.NewGuid().ToString(), dto.Info.Fingerprint, dto.Info.Alias,
            dto.Info.DeviceModel ?? sender?.DeviceModel, dto.Info.DeviceType, dto.Files.Values.OrderBy(f => f.FileName).ToList());
        if (offer.IsMessage)
        {
            var text = string.Join("\n\n", offer.Files.Select(f => f.Preview));
            AddHistory(new HistoryEntry(false, text.Length > 80 ? text[..80] : text, offer.SenderAlias, DateTime.Now, null));
            MessageReceived?.Invoke(offer.SenderAlias, text);
            return Response.NoContent;
        }
        foreach (var old in _sessions.Values.Where(s => s.Offer.SenderId == offer.SenderId || DateTime.UtcNow - s.LastActivity > TimeSpan.FromSeconds(45)).ToList())
        { _sessions.TryRemove(old.Offer.Id, out _); old.Cancelled = true; }
        if (!_sessions.IsEmpty || Current?.Status == Incoming.State.Asking) return new Response(409, "{\"message\":\"Busy\"}");

        var free = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(SaveDirectory))!).AvailableFreeSpace;
        if (free < offer.Total + 50_000_000) return new Response(403, "{\"message\":\"Not enough storage\"}");

        bool accepted;
        if (Settings.Favorites.TryGetValue(offer.SenderId, out var auto) && auto) accepted = true;
        else
        {
            SetCurrent(offer);
            var decide = Decide?.Invoke(offer) ?? Task.FromResult(false);
            accepted = await Task.WhenAny(decide, Task.Delay(120_000)) == decide && decide.Result;
        }
        if (!accepted) { SetCurrent(null); return Response.Forbidden; }
        var s = new Session(offer with { Status = Incoming.State.Receiving }, offer.Files.ToDictionary(f => f.Id, _ => Guid.NewGuid().ToString()));
        _sessions[offer.Id] = s;
        SetCurrent(s.Offer);
        return Response.Json(new PrepareResponse(offer.Id, s.Tokens));
    }

    void SetCurrent(Incoming? i) { Current = i; if (i != null) IncomingChanged?.Invoke(i); Changed?.Invoke(); }
    public void Dismiss() { Current = null; Changed?.Invoke(); }

    string Destination(Session s, string raw)
    {
        var parts = raw.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Where(p => p != "." && p != "..").Select(p => string.Concat(p.Select(c => Path.GetInvalidFileNameChars().Contains(c) || c == ':' ? '-' : c))).ToList();
        if (parts.Count == 0) parts.Add("File");
        var dir = SaveDirectory;
        if (parts.Count > 1)
        {
            var root = s.Folders.GetOrAdd(parts[0], r => Path.GetFileName(Unique(Path.Combine(SaveDirectory, r), dir: true)));
            dir = Path.Combine(new[] { SaveDirectory, root }.Concat(parts.Skip(1).SkipLast(1)).ToArray());
            Directory.CreateDirectory(dir);
            if (!s.Saved.Contains(Path.Combine(SaveDirectory, root))) s.Saved.Add(Path.Combine(SaveDirectory, root));
        }
        return Unique(Path.Combine(dir, parts[^1]));
    }

    static string Unique(string path, bool dir = false)
    {
        bool Exists(string p) => File.Exists(p) || Directory.Exists(p);
        if (!Exists(path)) { if (dir) Directory.CreateDirectory(path); return path; }
        var d = Path.GetDirectoryName(path)!; var stem = dir ? Path.GetFileName(path) : Path.GetFileNameWithoutExtension(path);
        var ext = dir ? "" : Path.GetExtension(path);
        for (var i = 2; ; i++)
        {
            var c = Path.Combine(d, $"{stem} ({i}){ext}");
            if (!Exists(c)) { if (dir) Directory.CreateDirectory(c); return c; }
        }
    }

    async Task<Response> Upload(Request r)
    {
        if (!_sessions.TryGetValue(r.Query.GetValueOrDefault("sessionId") ?? "", out var s)) return Response.Forbidden;
        var fid = r.Query.GetValueOrDefault("fileId") ?? "";
        if (!s.Tokens.TryGetValue(fid, out var tok) || tok != r.Query.GetValueOrDefault("token")) return Response.Forbidden;
        var dto = s.Offer.Files.First(f => f.Id == fid);
        string dest;
        lock (s) dest = Destination(s, dto.FileName);
        var part = Path.Combine(Path.GetDirectoryName(dest)!, "." + Path.GetFileName(dest) + ".swiftdrop-part");
        try
        {
            await using (var fs = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20, FileOptions.Asynchronous))
            {
                var buf = new byte[512 * 1024];
                int n;
                while ((n = await r.Body.ReadAsync(buf)) > 0)
                {
                    if (s.Cancelled) throw new TransferException(Phase.Cancelled, "Cancelled");
                    await fs.WriteAsync(buf.AsMemory(0, n));
                    var got = Interlocked.Add(ref s.Received, n);
                    s.LastActivity = DateTime.UtcNow;
                    if (DateTime.UtcNow - s.LastReport > TimeSpan.FromMilliseconds(100))
                    { s.LastReport = DateTime.UtcNow; SetCurrent(s.Offer with { Progress = (double)got / Math.Max(1, s.Offer.Total) }); }
                }
            }
            File.Move(part, dest, true);
            if (Path.GetDirectoryName(dest) == SaveDirectory) s.Saved.Add(dest);
        }
        catch
        {
            try { File.Delete(part); } catch { }
            if (!s.Cancelled && _sessions.TryRemove(s.Offer.Id, out _)) Finish(s, "Transfer interrupted");
            return new Response(500, "{\"message\":\"Upload failed\"}");
        }
        s.Pending.TryRemove(fid, out _);
        if (s.Pending.IsEmpty && _sessions.TryRemove(s.Offer.Id, out _)) Finish(s, null);
        return Response.Ok;
    }

    void Finish(Session s, string? error)
    {
        var done = s.Offer with { Status = error == null ? Incoming.State.Done : Incoming.State.Failed, Progress = 1, Saved = s.Saved.Distinct().ToList(), Error = error };
        SetCurrent(done);
        if (error == null)
            AddHistory(new HistoryEntry(false, done.Files.Count == 1 ? Path.GetFileName(done.Files[0].FileName) : $"{done.Files.Count} items",
                done.SenderAlias, DateTime.Now, done.Saved.FirstOrDefault()));
    }

    // ------------------------------------------------------------ send

    public static IEnumerable<OutItem> ItemsFromPaths(IEnumerable<string> paths)
    {
        foreach (var p in paths)
        {
            if (Directory.Exists(p))
            {
                var root = Path.GetFileName(Path.TrimEndingDirectorySeparator(p));
                foreach (var f in Directory.EnumerateFiles(p, "*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.System }))
                {
                    if (Path.GetFileName(f) is ".DS_Store" or "desktop.ini" or "Thumbs.db") continue;
                    var rel = Path.GetRelativePath(p, f).Replace('\\', '/');
                    var path = f;
                    yield return new OutItem($"{root}/{rel}", new FileInfo(f).Length, Mime.Of(f), () => File.OpenRead(path));
                }
            }
            else if (File.Exists(p))
            {
                var path = p;
                yield return new OutItem(Path.GetFileName(p), new FileInfo(p).Length, Mime.Of(p), () => File.OpenRead(path));
            }
        }
    }

    public static OutItem TextItem(string text) =>
        new($"{Guid.NewGuid().ToString()[..8]}.txt", Encoding.UTF8.GetByteCount(text), "text/plain", () => new MemoryStream(Encoding.UTF8.GetBytes(text)), text);

    public void Send(Peer peer, IReadOnlyList<OutItem> items)
    {
        if (items.Count == 0 || TransferOf(peer.Id).phase.IsActive()) return;
        var cts = new CancellationTokenSource();
        _sendCts[peer.Id] = cts;
        SetPhase(peer.Id, Phase.Waiting, 0);
        _ = Task.Run(async () =>
        {
            Phase result;
            try { await SendAsync(peer, items, cts.Token); result = Phase.Done; }
            catch (TransferException e) { result = e.Kind; }
            catch (OperationCanceledException) { result = Phase.Cancelled; }
            catch { result = Phase.Failed; }
            SetPhase(peer.Id, result, result == Phase.Done ? 1 : 0, force: true);
            if (result == Phase.Done)
                AddHistory(new HistoryEntry(true, items.Count == 1 ? Path.GetFileName(items[0].Name) : $"{items.Count} items", peer.Alias, DateTime.Now, null));
            await Task.Delay(8000);
            if (TransferOf(peer.Id).phase.IsTerminal()) { _transfers.TryRemove(peer.Id, out _); Changed?.Invoke(); }
        });
    }

    public Task SendAndWait(Peer peer, IReadOnlyList<OutItem> items, CancellationToken ct = default) => SendAsync(peer, items, ct);

    public void Cancel(string peerId) { if (_sendCts.TryGetValue(peerId, out var c)) c.Cancel(); }

    void SetPhase(string id, Phase p, double progress, bool force = false)
    {
        if (!force && _transfers.TryGetValue(id, out var cur) && cur.phase.IsTerminal()) return;
        _transfers[id] = (p, progress);
        Changed?.Invoke();
    }

    async Task<bool> Reachable(Peer p) => await Register(p.BaseUrl, probe: true) != null;

    /// A paused iPhone can't answer: knock over Bluetooth, then wait for the user to tap "Tap to receive".
    /// A locked iPhone is invisible to non-Apple scans and rotates its address (~15 min), so we use the
    /// address saved from its last card and only for iPhones seen recently.
    async Task WakeIfNeeded(Peer peer, IReadOnlyList<OutItem> items, CancellationToken ct)
    {
        if (!_wakeable.TryGetValue(peer.Id, out var w) || WakeDevice == null) return;
        if (await Reachable(peer)) return;
        if (DateTime.UtcNow - w.seen > TimeSpan.FromMinutes(15))
            throw new TransferException(Phase.Failed, $"{peer.Alias} is asleep — open SwiftDrop on it and try again");
        var what = items.Count == 1 ? Path.GetFileName(items[0].Name) : $"{items.Count} items";
        var knock = JsonSerializer.Serialize(new Dictionary<string, string> { ["a"] = Settings.Name, ["f"] = Fingerprint, ["n"] = what });
        if (!await WakeDevice(w.address, knock))
            throw new TransferException(Phase.Failed, $"{peer.Alias} is asleep — open SwiftDrop on it and try again");
        var deadline = DateTime.UtcNow.AddMinutes(2);
        while (DateTime.UtcNow < deadline)
        {
            await Task.Delay(1500, ct);
            if (await Reachable(peer)) return;
        }
        throw new TransferException(Phase.Failed, $"{peer.Alias} didn’t open SwiftDrop");
    }

    async Task SendAsync(Peer peer, IReadOnlyList<OutItem> items, CancellationToken ct)
    {
        await WakeIfNeeded(peer, items, ct);
        var ids = items.Select(_ => Guid.NewGuid().ToString()).ToList();
        var files = items.Select((it, i) => new FileDto { Id = ids[i], FileName = it.Name, Size = Math.Max(0, it.Size), FileType = it.Mime, Preview = it.Preview })
            .ToDictionary(f => f.Id);
        var body = new StringContent(JsonSerializer.Serialize(new PrepareRequest(Me(), files), LS.Json), Encoding.UTF8, "application/json");
        HttpResponseMessage resp;
        try
        {
            using var waitCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            waitCts.CancelAfter(TimeSpan.FromMinutes(10));
            resp = await _http.PostAsync($"{peer.BaseUrl}/api/localsend/v2/prepare-upload", body, waitCts.Token);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception e) { throw new TransferException(Phase.Failed, e.Message); }
        switch ((int)resp.StatusCode)
        {
            case 200: break;
            case 204: return;
            case 403: throw new TransferException(Phase.Declined, "Declined");
            default: throw new TransferException(Phase.Failed, $"Error {(int)resp.StatusCode}");
        }
        var pr = JsonSerializer.Deserialize<PrepareResponse>(await resp.Content.ReadAsStringAsync(ct), LS.Json)!;
        var total = Math.Max(1, items.Sum(i => Math.Max(0, i.Size)));
        var sent = new ConcurrentDictionary<int, long>();
        var last = DateTime.MinValue;
        SetPhase(peer.Id, Phase.Sending, 0);
        using var gate = new SemaphoreSlim(4);
        var order = Enumerable.Range(0, items.Count).Where(i => pr.Files.ContainsKey(ids[i])).OrderByDescending(i => items[i].Size);
        try
        {
            await Task.WhenAll(order.Select(async i =>
            {
                await gate.WaitAsync(ct);
                try
                {
                    var q = $"sessionId={Uri.EscapeDataString(pr.SessionId)}&fileId={Uri.EscapeDataString(ids[i])}&token={Uri.EscapeDataString(pr.Files[ids[i]])}";
                    await using var src = items[i].Open();
                    var content = new StreamContent(new ProgressStream(src, n =>
                    {
                        sent[i] = n;
                        if (DateTime.UtcNow - last > TimeSpan.FromMilliseconds(50))
                        { last = DateTime.UtcNow; SetPhase(peer.Id, Phase.Sending, (double)sent.Values.Sum() / total); }
                    }), 256 * 1024);
                    if (items[i].Size >= 0) content.Headers.ContentLength = items[i].Size;
                    content.Headers.ContentType = new("application/octet-stream");
                    using var up = await _http.PostAsync($"{peer.BaseUrl}/api/localsend/v2/upload?{q}", content, ct);
                    if (!up.IsSuccessStatusCode) throw new TransferException(Phase.Failed, $"Error {(int)up.StatusCode}");
                }
                finally { gate.Release(); }
            }));
        }
        catch
        {
            try { await _probe.PostAsync($"{peer.BaseUrl}/api/localsend/v2/cancel?sessionId={Uri.EscapeDataString(pr.SessionId)}", null); } catch { }
            throw;
        }
    }

    // ------------------------------------------------------------ persistence

    static Settings LoadSettings()
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(Path.Combine(DataDir, "settings.json")), LS.Json) ?? new(); }
        catch { return new(); }
    }

    readonly object _saveLock = new();
    public void Save() { lock (_saveLock) File.WriteAllText(Path.Combine(DataDir, "settings.json"), JsonSerializer.Serialize(Settings, LS.Json)); }

    void AddHistory(HistoryEntry h)
    {
        lock (_saveLock) { Settings.History.Insert(0, h); if (Settings.History.Count > 50) Settings.History.RemoveRange(50, Settings.History.Count - 50); }
        Save(); Changed?.Invoke();
    }
}

sealed class ProgressStream(Stream inner, Action<long> progress) : Stream
{
    long _read;
    public override async ValueTask<int> ReadAsync(Memory<byte> b, CancellationToken ct = default)
    { var n = await inner.ReadAsync(b, ct); _read += n; progress(_read); return n; }
    public override int Read(byte[] b, int o, int c) { var n = inner.Read(b, o, c); _read += n; progress(_read); return n; }
    public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
    public override long Length => inner.Length; public override long Position { get => _read; set => throw new NotSupportedException(); }
    public override void Flush() { } public override long Seek(long o, SeekOrigin s) => throw new NotSupportedException();
    public override void SetLength(long v) => throw new NotSupportedException(); public override void Write(byte[] b, int o, int c) => throw new NotSupportedException();
}

public static class Mime
{
    static readonly Dictionary<string, string> Map = new(StringComparer.OrdinalIgnoreCase)
    {
        [".jpg"] = "image/jpeg", [".jpeg"] = "image/jpeg", [".png"] = "image/png", [".gif"] = "image/gif", [".heic"] = "image/heic",
        [".webp"] = "image/webp", [".bmp"] = "image/bmp", [".svg"] = "image/svg+xml", [".mp4"] = "video/mp4", [".mov"] = "video/quicktime",
        [".mkv"] = "video/x-matroska", [".avi"] = "video/x-msvideo", [".mp3"] = "audio/mpeg", [".m4a"] = "audio/mp4", [".wav"] = "audio/wav",
        [".flac"] = "audio/flac", [".pdf"] = "application/pdf", [".zip"] = "application/zip", [".txt"] = "text/plain", [".json"] = "application/json",
        [".apk"] = "application/vnd.android.package-archive", [".docx"] = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        [".xlsx"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", [".pptx"] = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    };
    public static string Of(string path) => Map.GetValueOrDefault(Path.GetExtension(path), "application/octet-stream");
}
