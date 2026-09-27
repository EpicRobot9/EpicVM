param([int]$DelaySeconds = 0, [int]$DurationSeconds = 12)

$ErrorActionPreference = 'Stop'
$source = @'
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class DeviceEnumeratorCom {}
[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
interface IDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int flow, int state, out IntPtr devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IDevice device);
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IDevice device);
}
[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("D666063F-1587-4E43-81F1-B948E807363F")]
interface IDevice {
    [PreserveSig] int Activate(ref Guid iid, int clsctx, IntPtr activation, out IntPtr iface);
    [PreserveSig] int OpenPropertyStore(int access, out IntPtr props);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetState(out int state);
}
[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064")]
interface IAudioMeter {
    [PreserveSig] int GetPeakValue(out float peak);
    [PreserveSig] int GetMeteringChannelCount(out int channels);
    [PreserveSig] int GetChannelsPeakValues(int channels, IntPtr peaks);
    [PreserveSig] int QueryHardwareSupport(out int flags);
}
public static class EpicVMAudioMeter {
    public static string DefaultId() {
        var enumerator = (IDeviceEnumerator)new DeviceEnumeratorCom();
        IDevice device;
        Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out device));
        string id;
        Marshal.ThrowExceptionForHR(device.GetId(out id));
        return id;
    }
    public static float Peak(string id) {
        var enumerator = (IDeviceEnumerator)new DeviceEnumeratorCom();
        IDevice device;
        Marshal.ThrowExceptionForHR(enumerator.GetDevice(id, out device));
        var iid = new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");
        IntPtr pointer;
        Marshal.ThrowExceptionForHR(device.Activate(ref iid, 23, IntPtr.Zero, out pointer));
        try {
            var meter = (IAudioMeter)Marshal.GetObjectForIUnknown(pointer);
            float peak;
            Marshal.ThrowExceptionForHR(meter.GetPeakValue(out peak));
            return peak;
        } finally { Marshal.Release(pointer); }
    }
}
'@
Add-Type -TypeDefinition $source

$rate = 48000
$count = $rate * 2
$pcm = [byte[]]::new($count * 2)
for ($i = 0; $i -lt $count; $i++) {
    $sample = [int16]([Math]::Sin(2 * [Math]::PI * 440 * $i / $rate) * 8000)
    [BitConverter]::GetBytes($sample).CopyTo($pcm, $i * 2)
}
$memory = [IO.MemoryStream]::new()
$writer = [IO.BinaryWriter]::new($memory)
$writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
$writer.Write([int](36 + $pcm.Length))
$writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
$writer.Write([int]16)
$writer.Write([int16]1)
$writer.Write([int16]1)
$writer.Write([int]$rate)
$writer.Write([int]($rate * 2))
$writer.Write([int16]2)
$writer.Write([int16]16)
$writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
$writer.Write([int]$pcm.Length)
$writer.Write($pcm)
$writer.Flush()
$memory.Position = 0
$player = [System.Media.SoundPlayer]::new($memory)
$id = [EpicVMAudioMeter]::DefaultId()
$peak = 0.0
try {
    if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
    $player.PlayLooping()
    $deadline = [DateTime]::UtcNow.AddSeconds($DurationSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $reading = [EpicVMAudioMeter]::Peak($id)
        if ($reading -gt $peak) { $peak = $reading }
        Start-Sleep -Milliseconds 100
    }
} finally {
    $player.Stop()
    $player.Dispose()
    $writer.Dispose()
    $memory.Dispose()
}
[pscustomobject]@{defaultEndpoint=$id;peak=$peak}
