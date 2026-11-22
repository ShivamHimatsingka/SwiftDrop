using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace SwiftDrop.Core;

public sealed class Request(string method, string path, Dictionary<string, string> query,
                            Dictionary<string, string> headers, string remote, BodyStream body)
{
    public string Method { get; } = method;
    public string Path { get; } = path;
    public Dictionary<string, string> Query { get; } = query;
    public Dictionary<string, string> Headers { get; } = headers;
    public string Remote { get; } = remote;
    public BodyStream Body { get; } = body;

    public async Task<string> TextAsync(int limit = 64 << 20)
    {
        using var ms = new MemoryStream();
        await Body.CopyToAsync(ms);
        if (ms.Length > limit) throw new InvalidDataException("too large");
        return Encoding.UTF8.GetString(ms.ToArray());
    }
}

public sealed record Response(int Status, string Body = "")
{
    public static Response Json(object o) => new(200, System.Text.Json.JsonSerializer.Serialize(o, LS.Json));
    public static readonly Response Ok = new(200), NoContent = new(204),
        Forbidden = new(403, "{\"message\":\"Forbidden\"}"), NotFound = new(404, "{\"message\":\"Not found\"}"),
        Bad = new(400, "{\"message\":\"Bad request\"}");
}

/// Streaming HTTP/1.1 server (keep-alive, Content-Length and chunked bodies, optional TLS).
public sealed class HttpServer(int port, X509Certificate2? cert, Func<Request, Task<Response>> handler)
{
    private TcpListener? _listener;
    private CancellationTokenSource _cts = new();

    public void Start()
    {
        var l = new TcpListener(IPAddress.IPv6Any, port);
        l.Server.DualMode = true;
        l.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        l.Start(64);
        _listener = l;
        _ = Task.Run(async () =>
        {
            while (!_cts.IsCancellationRequested)
            {
                TcpClient c;
                try { c = await l.AcceptTcpClientAsync(_cts.Token); } catch { break; }
                _ = Task.Run(() => Serve(c));
            }
        });
    }

    public void Stop() { _cts.Cancel(); _listener?.Stop(); }

    private async Task Serve(TcpClient client)
    {
        using var _ = client;
        client.NoDelay = true;
        var remote = (client.Client.RemoteEndPoint as IPEndPoint)?.Address is { } a
            ? (a.IsIPv4MappedToIPv6 ? a.MapToIPv4().ToString() : a.ToString()) : "0.0.0.0";
        Stream stream = client.GetStream();
        try
        {
            if (cert != null)
            {
                var ssl = new SslStream(stream, false);
                await ssl.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
                {
                    ServerCertificate = cert, ClientCertificateRequired = false,
                    EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                });
                stream = ssl;
            }
            var input = new BufferedStream(stream, 256 * 1024);
            while (true)
            {
                var head = await ReadHead(input);
                if (head == null) return;
                var lines = head.Split("\r\n");
                var parts = lines[0].Split(' ');
                if (parts.Length < 2) return;
                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (var l in lines.Skip(1))
                {
                    var i = l.IndexOf(':'); if (i > 0) headers[l[..i].Trim()] = l[(i + 1)..].Trim();
                }
                var target = parts[1];
                var qi = target.IndexOf('?');
                var query = new Dictionary<string, string>();
                if (qi >= 0)
                    foreach (var kv in target[(qi + 1)..].Split('&', StringSplitOptions.RemoveEmptyEntries))
                    {
                        var e = kv.IndexOf('=');
                        if (e > 0) query[Uri.UnescapeDataString(kv[..e])] = Uri.UnescapeDataString(kv[(e + 1)..].Replace('+', ' '));
                    }
                long.TryParse(headers.GetValueOrDefault("content-length"), out var len);
                var body = new BodyStream(input, len, headers.GetValueOrDefault("transfer-encoding")?.Contains("chunked", StringComparison.OrdinalIgnoreCase) == true);
                if (string.Equals(headers.GetValueOrDefault("expect"), "100-continue", StringComparison.OrdinalIgnoreCase))
                { await stream.WriteAsync("HTTP/1.1 100 Continue\r\n\r\n"u8.ToArray()); await stream.FlushAsync(); }
                var req = new Request(parts[0].ToUpperInvariant(), qi >= 0 ? target[..qi] : target, query, headers, remote, body);
                Response resp;
                try { resp = await handler(req); } catch (Exception ex) { resp = new Response(500, $"{{\"message\":\"{ex.Message}\"}}"); }
                if (!await body.DrainAsync(4L << 20)) { await Write(stream, resp, true); return; }
                var close = string.Equals(headers.GetValueOrDefault("connection"), "close", StringComparison.OrdinalIgnoreCase);
                await Write(stream, resp, close);
                if (close) return;
            }
        }
        catch { /* connection dropped */ }
    }

    private static async Task Write(Stream s, Response r, bool close)
    {
        var body = Encoding.UTF8.GetBytes(r.Body);
        var head = $"HTTP/1.1 {r.Status} {(r.Status < 400 ? "OK" : "Error")}\r\nContent-Type: application/json\r\n" +
                   $"Content-Length: {body.Length}\r\nConnection: {(close ? "close" : "keep-alive")}\r\n\r\n";
        await s.WriteAsync(Encoding.ASCII.GetBytes(head));
        await s.WriteAsync(body);
        await s.FlushAsync();
    }

    private static async Task<string?> ReadHead(Stream s)
    {
        var buf = new List<byte>(1024);
        var one = new byte[1];
        while (buf.Count < 65536)
        {
            if (await s.ReadAsync(one) <= 0) return null;
            buf.Add(one[0]);
            var n = buf.Count;
            if (n >= 4 && buf[n - 4] == '\r' && buf[n - 3] == '\n' && buf[n - 2] == '\r' && buf[n - 1] == '\n')
                return Encoding.UTF8.GetString(buf.ToArray(), 0, n - 4);
        }
        return null;
    }
}

/// Request body view over the connection stream.
public sealed class BodyStream(Stream src, long remaining, bool chunked) : Stream
{
    private long _remaining = remaining, _chunkLeft;
    private bool _done = !chunked && remaining <= 0;

    private async Task<string> Line()
    {
        var sb = new StringBuilder(); var b = new byte[1];
        while (await src.ReadAsync(b) > 0 && b[0] != '\n') if (b[0] != '\r') sb.Append((char)b[0]);
        return sb.ToString();
    }

    private async Task<bool> Ensure()
    {
        if (_done) return false;
        if (!chunked) return _remaining > 0;
        if (_chunkLeft == 0)
        {
            var size = Convert.ToInt64((await Line()).Split(';')[0].Trim() is { Length: > 0 } h ? h : "0", 16);
            if (size == 0) { while ((await Line()).Length > 0) { } _done = true; return false; }
            _chunkLeft = size;
        }
        return true;
    }

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
    {
        if (!await Ensure()) return 0;
        var want = (int)Math.Min(buffer.Length, chunked ? _chunkLeft : _remaining);
        var n = await src.ReadAsync(buffer[..want], ct);
        if (n <= 0) { _done = true; return 0; }
        if (chunked) { _chunkLeft -= n; if (_chunkLeft == 0) await Line(); }
        else { _remaining -= n; if (_remaining == 0) _done = true; }
        return n;
    }

    public override Task<int> ReadAsync(byte[] b, int o, int c, CancellationToken ct) => ReadAsync(b.AsMemory(o, c), ct).AsTask();
    public override int Read(byte[] b, int o, int c) => ReadAsync(b, o, c, default).GetAwaiter().GetResult();

    public async Task<bool> DrainAsync(long limit)
    {
        if (_done) return true;
        if (!chunked && _remaining > limit) return false;
        var buf = new byte[65536]; long total = 0;
        while (true) { var n = await ReadAsync(buf); if (n == 0) return true; total += n; if (total > limit) return false; }
    }

    public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => 0; set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override long Seek(long o, SeekOrigin s) => throw new NotSupportedException();
    public override void SetLength(long v) => throw new NotSupportedException();
    public override void Write(byte[] b, int o, int c) => throw new NotSupportedException();
}
