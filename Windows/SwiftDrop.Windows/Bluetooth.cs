using System;
using System.Linq;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using SwiftDrop.Core;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;

namespace SwiftDrop.Windows;

/// Bluetooth LE discovery on Windows (WinRT): a GATT service that serves our card,
/// plus a watcher that reads other SwiftDrop devices' cards.
public sealed class Bluetooth
{
    readonly Engine _engine;
    GattServiceProvider? _provider;
    BluetoothLEAdvertisementWatcher? _watcher;
    readonly System.Collections.Concurrent.ConcurrentDictionary<ulong, DateTime> _lastRead = new();
    /// iPhones (and most phones) use *random* Bluetooth addresses; connecting needs the right type.
    readonly System.Collections.Concurrent.ConcurrentDictionary<ulong, BluetoothAddressType> _addressType = new();

    global::Windows.Foundation.IAsyncOperation<BluetoothLEDevice> Open(ulong address) =>
        _addressType.TryGetValue(address, out var t)
            ? BluetoothLEDevice.FromBluetoothAddressAsync(address, t)
            : BluetoothLEDevice.FromBluetoothAddressAsync(address);
    bool _advertising;

    public Bluetooth(Engine engine)
    {
        _engine = engine;
        engine.BluetoothChanged += () => _ = UpdateAdvertising();
        engine.WakeDevice = Knock;
        engine.IsLinked = fp => _linked.ContainsKey(fp);
        engine.WakeLinked = TapLink;
    }

    // iPhones holding a link to us: fingerprint -> Bluetooth device id; knocks they should read back.
    readonly System.Collections.Concurrent.ConcurrentDictionary<string, string> _linked = new();
    readonly System.Collections.Concurrent.ConcurrentDictionary<string, byte[]> _knockFor = new();
    readonly System.Collections.Concurrent.ConcurrentDictionary<string, TaskCompletionSource<bool>> _knockWaiter = new();
    GattLocalCharacteristic? _link;

    async Task<bool> TapLink(string fingerprint, string json)
    {
        if (await TapOverLink(fingerprint, json)) return true;
        // No answer: knock directly over the iPhone's held connection (keeps it reachable while locked).
        if (_linked.TryGetValue(fingerprint, out var id))
        {
            try
            {
                using var dev = await BluetoothLEDevice.FromIdAsync(id);
                if (dev != null && await Knock(dev.BluetoothAddress, json)) return true;
            }
            catch { }
        }
        return false;
    }

    async Task<bool> TapOverLink(string fingerprint, string json)
    {
        if (_link == null || !_linked.TryGetValue(fingerprint, out var deviceId)) return false;
        var client = _link.SubscribedClients.FirstOrDefault(c => c.Session.DeviceId.Id == deviceId);
        if (client == null) { _linked.TryRemove(fingerprint, out _); return false; }
        var tcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _knockFor[deviceId] = Encoding.UTF8.GetBytes(json);
        _knockWaiter[deviceId] = tcs;
        try
        {
            // The knock itself when it fits in one notification, else a 1-byte tap and the iPhone reads it back.
            var body = Encoding.UTF8.GetBytes(json);
            var w = new DataWriter(); w.WriteBytes(body.Length <= client.MaxNotificationSize ? body : Encoding.UTF8.GetBytes("k"));
            await _link.NotifyValueAsync(w.DetachBuffer(), client);
            var ok = await Task.WhenAny(tcs.Task, Task.Delay(8_000)) == tcs.Task && tcs.Task.Result;
            if (!ok) { _linked.TryRemove(fingerprint, out _); _knockFor.TryRemove(deviceId, out _); }
            else _ = Task.Delay(30_000).ContinueWith(t => _knockFor.TryRemove(deviceId, out byte[]? gone));
            return ok;
        }
        catch { return false; }
        finally { _knockWaiter.TryRemove(deviceId, out _); }
    }

    async void OnLinkWrite(GattLocalCharacteristic sender, GattWriteRequestedEventArgs args)
    {
        using var deferral = args.GetDeferral();
        var request = await args.GetRequestAsync();
        if (request == null) return;
        var json = Encoding.UTF8.GetString(request.Value.ToArray());
        if (request.Option == GattWriteOption.WriteWithResponse) request.Respond();
        if (json == "ack")                       // the iPhone got our knock
        {
            if (_knockWaiter.TryGetValue(args.Session.DeviceId.Id, out var waiter)) waiter.TrySetResult(true);
            return;
        }
        try
        {
            if (JsonSerializer.Deserialize<BleCard>(json) is not { } card) return;
            var id = args.Session.DeviceId.Id;
            foreach (var k in _linked.Where(kv => kv.Value == id).Select(kv => kv.Key).ToList()) _linked.TryRemove(k, out _);
            _linked[card.Fingerprint] = id;
            await _engine.HandleCard(card);
        }
        catch { }
    }

    async void OnLinkRead(GattLocalCharacteristic sender, GattReadRequestedEventArgs args)
    {
        using var deferral = args.GetDeferral();
        var request = await args.GetRequestAsync();
        if (request == null) return;
        var id = args.Session.DeviceId.Id;
        if (!_knockFor.TryGetValue(id, out var bytes)) { request.RespondWithProtocolError(GattProtocolError.AttributeNotFound); return; }
        var offset = (int)Math.Min(request.Offset, (uint)bytes.Length);
        var w = new DataWriter(); w.WriteBytes(bytes.Skip(offset).ToArray());
        request.RespondWithValue(w.DetachBuffer());
        if (offset == 0 && _knockWaiter.TryGetValue(id, out var tcs)) tcs.TrySetResult(true);
    }

    /// Write a wake-up knock to a (paused) iPhone at a known address.
    async Task<bool> Knock(ulong address, string json)
    {
        try
        {
            using var device = await Open(address);
            if (device == null) return false;
            var services = await device.GetGattServicesForUuidAsync(BleCard.Service, BluetoothCacheMode.Uncached);
            var svc = services.Services.FirstOrDefault();
            if (svc == null) return false;
            using (svc)
            {
                var chars = await svc.GetCharacteristicsForUuidAsync(BleCard.Wake, BluetoothCacheMode.Uncached);
                var ch = chars.Characteristics.FirstOrDefault();
                if (ch == null) return false;
                var w = new DataWriter();
                w.WriteBytes(Encoding.UTF8.GetBytes(json));
                var result = await ch.WriteValueWithResultAsync(w.DetachBuffer(), GattWriteOption.WriteWithResponse);
                return result.Status == GattCommunicationStatus.Success;
            }
        }
        catch { return false; }
    }

    public async Task Start()
    {
        try
        {
            var adapter = await BluetoothAdapter.GetDefaultAsync();
            if (adapter == null || !adapter.IsLowEnergySupported) return;
            if (adapter.IsPeripheralRoleSupported)
            {
                var created = await GattServiceProvider.CreateAsync(BleCard.Service);
                if (created.Error == BluetoothError.Success)
                {
                    _provider = created.ServiceProvider;
                    var ch = await _provider.Service.CreateCharacteristicAsync(BleCard.Info, new GattLocalCharacteristicParameters
                    {
                        CharacteristicProperties = GattCharacteristicProperties.Read,
                        ReadProtectionLevel = GattProtectionLevel.Plain,
                    });
                    if (ch.Error == BluetoothError.Success) ch.Characteristic.ReadRequested += OnRead;
                    var link = await _provider.Service.CreateCharacteristicAsync(BleCard.Link, new GattLocalCharacteristicParameters
                    {
                        CharacteristicProperties = GattCharacteristicProperties.Read | GattCharacteristicProperties.Write | GattCharacteristicProperties.Notify,
                        ReadProtectionLevel = GattProtectionLevel.Plain,
                        WriteProtectionLevel = GattProtectionLevel.Plain,
                    });
                    if (link.Error == BluetoothError.Success)
                    {
                        _link = link.Characteristic;
                        _link.WriteRequested += OnLinkWrite;
                        _link.ReadRequested += OnLinkRead;
                        _link.SubscribedClientsChanged += (c, e) =>
                        {
                            var ids = c.SubscribedClients.Select(x => x.Session.DeviceId.Id).ToHashSet();
                            foreach (var k in _linked.Where(kv => !ids.Contains(kv.Value)).Select(kv => kv.Key).ToList()) _linked.TryRemove(k, out _);
                        };
                    }
                    await UpdateAdvertising();
                }
            }
            _watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Passive };
            _watcher.AdvertisementFilter.Advertisement.ServiceUuids.Add(BleCard.Service);
            _watcher.Received += (s, e) => { _addressType[e.BluetoothAddress] = e.BluetoothAddressType; _ = ReadCard(e.BluetoothAddress); };
            // Lightweight: scan in bursts (20 s now, 15 s every 5 min, 60 s when the panel opens).
            Burst(TimeSpan.FromSeconds(20));
            _periodic = new System.Threading.Timer(_ => Burst(TimeSpan.FromSeconds(15)), null, TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(5));
        }
        catch { /* no Bluetooth: Wi‑Fi discovery still works */ }
    }

    System.Threading.Timer? _periodic;
    DateTime _scanUntil;

    public void Refresh() { _lastRead.Clear(); Burst(TimeSpan.FromSeconds(60)); }

    void Burst(TimeSpan length)
    {
        var w = _watcher;
        if (w == null) return;
        lock (this)
        {
            if (DateTime.UtcNow + length > _scanUntil) _scanUntil = DateTime.UtcNow + length;
            if (w.Status != BluetoothLEAdvertisementWatcherStatus.Started) { try { w.Start(); } catch { return; } }
        }
        _ = Task.Delay(length + TimeSpan.FromMilliseconds(500)).ContinueWith(_ =>
        {
            lock (this) if (DateTime.UtcNow >= _scanUntil && w.Status == BluetoothLEAdvertisementWatcherStatus.Started) w.Stop();
        });
    }

    async Task UpdateAdvertising()
    {
        if (_provider == null) return;
        var visible = _engine.Card() != null;
        if (visible && !_advertising)
        {
            _provider.StartAdvertising(new GattServiceProviderAdvertisingParameters { IsDiscoverable = true, IsConnectable = true });
            _advertising = true;
        }
        else if (!visible && _advertising) { _provider.StopAdvertising(); _advertising = false; }
        await Task.CompletedTask;
    }

    async void OnRead(GattLocalCharacteristic sender, GattReadRequestedEventArgs args)
    {
        using var deferral = args.GetDeferral();
        var request = await args.GetRequestAsync();
        if (request == null) return;
        var card = _engine.Card();
        if (card == null) { request.RespondWithProtocolError(GattProtocolError.AttributeNotFound); return; }
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(card));
        var offset = (int)Math.Min(request.Offset, (uint)bytes.Length);
        var w = new DataWriter();
        w.WriteBytes(bytes.Skip(offset).ToArray());
        request.RespondWithValue(w.DetachBuffer());
    }

    async Task ReadCard(ulong address)
    {
        // At most every 5 min per device: each read wakes a sleeping iPhone.
        if (_lastRead.TryGetValue(address, out var t) && DateTime.UtcNow - t < TimeSpan.FromMinutes(5)) return;
        _lastRead[address] = DateTime.UtcNow;
        try
        {
            using var device = await Open(address);
            if (device == null) return;
            var services = await device.GetGattServicesForUuidAsync(BleCard.Service, BluetoothCacheMode.Uncached);
            var svc = services.Services.FirstOrDefault();
            if (svc == null) return;
            using (svc)
            {
                var chars = await svc.GetCharacteristicsForUuidAsync(BleCard.Info, BluetoothCacheMode.Uncached);
                var ch = chars.Characteristics.FirstOrDefault();
                if (ch == null) return;
                var read = await ch.ReadValueAsync(BluetoothCacheMode.Uncached);
                if (read.Status != GattCommunicationStatus.Success) return;
                var json = Encoding.UTF8.GetString(read.Value.ToArray());
                if (JsonSerializer.Deserialize<BleCard>(json) is { } card) await _engine.HandleCard(card, address);
            }
        }
        catch { }
    }
}
