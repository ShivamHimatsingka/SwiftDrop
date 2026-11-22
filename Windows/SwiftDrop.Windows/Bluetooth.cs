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
    bool _advertising;

    public Bluetooth(Engine engine) { _engine = engine; engine.BluetoothChanged += () => _ = UpdateAdvertising(); }

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
                    await UpdateAdvertising();
                }
            }
            _watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
            _watcher.AdvertisementFilter.Advertisement.ServiceUuids.Add(BleCard.Service);
            _watcher.Received += (s, e) => { _ = ReadCard(e.BluetoothAddress); };
            _watcher.Start();
        }
        catch { /* no Bluetooth: Wi‑Fi discovery still works */ }
    }

    public void Refresh() => _lastRead.Clear();

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
        if (_lastRead.TryGetValue(address, out var t) && DateTime.UtcNow - t < TimeSpan.FromMinutes(1)) return;
        _lastRead[address] = DateTime.UtcNow;
        try
        {
            using var device = await BluetoothLEDevice.FromBluetoothAddressAsync(address);
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
                if (JsonSerializer.Deserialize<BleCard>(json) is { } card) await _engine.HandleCard(card);
            }
        }
        catch { }
    }
}
