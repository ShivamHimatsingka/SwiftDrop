using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace SwiftDrop.Core;

/// LocalSend v2 wire format — https://github.com/localsend/protocol
public static class LS
{
    public const string Version = "2.1";
    public const string Multicast = "224.0.0.167";
    public const int Port = 53317;
    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = true,
    };
}

public record DeviceInfo
{
    public string Alias { get; init; } = "Unknown";
    public string? Version { get; init; } = LS.Version;
    public string? DeviceModel { get; init; }
    public string? DeviceType { get; init; }
    public string Fingerprint { get; init; } = "";
    public int? Port { get; init; }
    public string? Protocol { get; init; }
    public bool? Download { get; init; } = false;
    public bool? Announce { get; init; }
    public bool? Announcement { get; init; }
    [JsonIgnore] public bool IsAnnouncement => Announce == true || Announcement == true;
}

public record FileDto
{
    public string Id { get; init; } = "";
    public string FileName { get; init; } = "";
    public long Size { get; init; }
    public string FileType { get; init; } = "application/octet-stream";
    public string? Sha256 { get; init; }
    public string? Preview { get; init; }
}

public record PrepareRequest(DeviceInfo Info, Dictionary<string, FileDto> Files);
public record PrepareResponse(string SessionId, Dictionary<string, string> Files);

public record Peer(string Id, string Alias, string? DeviceModel, string? DeviceType, string Host, int Port, string Scheme)
{
    public DateTime LastSeen { get; init; } = DateTime.UtcNow;
    public string BaseUrl => $"{Scheme}://{(Host.Contains(':') ? $"[{Host}]" : Host)}:{Port}";
    public string Caption => DeviceModel ?? DeviceType switch { "mobile" => "Phone", "web" => "Browser", _ => "Computer" };
    public string Initials => string.Concat(Alias.Split(' ', '-', '_', '’', '\'')
        .Where(w => w.Length > 0 && char.IsLetterOrDigit(w[0])).Take(2).Select(w => char.ToUpperInvariant(w[0]))) is { Length: > 0 } s ? s : "?";
}

public enum Phase { Idle, Waiting, Sending, Done, Declined, Failed, Cancelled }
public static class PhaseExt
{
    public static bool IsActive(this Phase p) => p is Phase.Waiting or Phase.Sending;
    public static bool IsTerminal(this Phase p) => p is Phase.Done or Phase.Declined or Phase.Failed or Phase.Cancelled;
    public static string? Label(this Phase p, double progress) => p switch
    {
        Phase.Waiting => "Waiting…",
        Phase.Sending => progress > 0 ? $"Sending… {(int)(progress * 100)}%" : "Sending…",
        Phase.Done => "Sent", Phase.Declined => "Declined", Phase.Failed => "Failed", Phase.Cancelled => "Cancelled",
        _ => null,
    };
}

public enum ReceiveMode { Off, Favorites, Everyone }

public class TransferException(Phase kind, string message) : Exception(message)
{
    public Phase Kind { get; } = kind;
}

public record OutItem(string Name, long Size, string Mime, Func<Stream> Open, string? Preview = null);

public record Incoming(string Id, string SenderId, string SenderAlias, string? SenderModel, string? SenderType, IReadOnlyList<FileDto> Files)
{
    public enum State { Asking, Receiving, Done, Failed }
    public State Status { get; init; } = State.Asking;
    public double Progress { get; init; }
    public IReadOnlyList<string> Saved { get; init; } = [];
    public string? Error { get; init; }
    public long Total => Files.Sum(f => f.Size);
    public bool IsMessage => Files.Count > 0 && Files.All(f => f.FileType.StartsWith("text/plain") && f.Preview != null);
    public string Noun
    {
        get
        {
            var n = Files.Count;
            if (Files.All(f => f.FileType.StartsWith("image/"))) return n == 1 ? "a photo" : $"{n} photos";
            if (Files.All(f => f.FileType.StartsWith("video/"))) return n == 1 ? "a video" : $"{n} videos";
            return n == 1 ? $"“{Path.GetFileName(Files[0].FileName.Replace('\\', '/'))}”" : $"{n} items";
        }
    }
}

public record HistoryEntry(bool Sent, string Title, string Device, DateTime Time, string? Path);

/// Card exchanged over Bluetooth LE (same JSON as the Mac/iPhone/Android apps).
public record BleCard(
    [property: System.Text.Json.Serialization.JsonPropertyName("a")] string Alias,
    [property: System.Text.Json.Serialization.JsonPropertyName("f")] string Fingerprint,
    [property: System.Text.Json.Serialization.JsonPropertyName("m")] string? Model,
    [property: System.Text.Json.Serialization.JsonPropertyName("t")] string? Type,
    [property: System.Text.Json.Serialization.JsonPropertyName("p")] int Port,
    [property: System.Text.Json.Serialization.JsonPropertyName("s")] string Scheme,
    [property: System.Text.Json.Serialization.JsonPropertyName("ip")] List<string> Ips,
    [property: System.Text.Json.Serialization.JsonPropertyName("x")] List<string> Caps)
{
    public static readonly Guid Service = Guid.Parse("7A4F0001-5D3F-4B6E-9C2A-53574946544F");
    public static readonly Guid Info = Guid.Parse("7A4F0002-5D3F-4B6E-9C2A-53574946544F");
    /// Write-only knock that wakes a paused iPhone app ("Tap to receive").
    public static readonly Guid Wake = Guid.Parse("7A4F0004-5D3F-4B6E-9C2A-53574946544F");
}
