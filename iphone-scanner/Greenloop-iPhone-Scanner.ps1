# Greenloop iPhone Scanner
# Local-only helper for Windows. It listens only on 127.0.0.1:51892.
# It needs Apple Mobile Device Support (installed with Apple Devices or iTunes).

[CmdletBinding()]
param(
  [int]$Port = 51892
)

$ErrorActionPreference = 'Stop'
$appleSupportPath = Join-Path ${env:ProgramFiles} 'Common Files\Apple\Mobile Device Support'
$mobileDeviceDll = Join-Path $appleSupportPath 'MobileDevice.dll'

if (-not (Test-Path -LiteralPath $mobileDeviceDll)) {
  Write-Host 'Apple Mobile Device Support was not found.' -ForegroundColor Red
  Write-Host 'Install Apple Devices for Windows (or iTunes), then start this scanner again.' -ForegroundColor Yellow
  exit 1
}

$env:PATH = "$appleSupportPath;$env:PATH"

$nativeCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public static class GreenloopAppleDeviceReader
{
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct DeviceNotificationInfo
    {
        public IntPtr device;
        public uint message;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void DeviceNotificationCallback(IntPtr notificationInfo, IntPtr userData);

    private static readonly object Gate = new object();
    private static readonly AutoResetEvent DeviceEvent = new AutoResetEvent(false);
    private static readonly DeviceNotificationCallback Callback = DeviceChanged;
    private static readonly ManualResetEvent SubscriptionReady = new ManualResetEvent(false);
    private static IntPtr Subscription = IntPtr.Zero;
    private static IntPtr CurrentDevice = IntPtr.Zero;
    private static bool Started;
    private static string PumpFailure = String.Empty;
    private static string DiagnosticsDebug = String.Empty;
    private const uint Connected = 1;
    private const uint Utf8 = 0x08000100;
    private const int SInt64 = 4;
    private const int XmlPlistFormat = 100;

    [DllImport("MobileDevice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int AMDeviceNotificationSubscribe(DeviceNotificationCallback callback, uint unused1, uint unused2, IntPtr userData, ref IntPtr subscription);

    [DllImport("MobileDevice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int AMDeviceConnect(IntPtr device);

    [DllImport("MobileDevice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int AMDeviceDisconnect(IntPtr device);

    [DllImport("MobileDevice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int AMDeviceIsPaired(IntPtr device);

    [DllImport("MobileDevice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int AMDeviceValidatePairing(IntPtr device);

    [DllImport("MobileDevice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int AMDeviceStartSession(IntPtr device);

    [DllImport("MobileDevice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int AMDeviceStopSession(IntPtr device);

    [DllImport("MobileDevice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr AMDeviceCopyValue(IntPtr device, IntPtr domain, IntPtr key);

    [DllImport("MobileDevice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int AMDeviceSecureStartService(IntPtr device, IntPtr serviceName, IntPtr options, out IntPtr serviceConnection);

    [DllImport("MobileDevice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern ulong AMDServiceConnectionSendMessage(IntPtr serviceConnection, IntPtr message, int format);

    [DllImport("MobileDevice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern ulong AMDServiceConnectionReceiveMessage(IntPtr serviceConnection, out IntPtr message, out int format);

    [DllImport("MobileDevice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void AMDServiceConnectionInvalidate(IntPtr serviceConnection);

    [DllImport("CoreFoundation.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr CFStringCreateWithCString(IntPtr allocator, string value, uint encoding);

    [DllImport("CoreFoundation.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern bool CFStringGetCString(IntPtr value, byte[] buffer, IntPtr bufferSize, uint encoding);

    [DllImport("CoreFoundation.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr CFGetTypeID(IntPtr value);

    [DllImport("CoreFoundation.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr CFNumberGetTypeID();

    [DllImport("CoreFoundation.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern bool CFNumberGetValue(IntPtr value, int numberType, out long number);

    [DllImport("CoreFoundation.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void CFRelease(IntPtr value);

    [DllImport("CoreFoundation.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr CFDictionaryCreateMutable(IntPtr allocator, IntPtr capacity, IntPtr keyCallbacks, IntPtr valueCallbacks);

    [DllImport("CoreFoundation.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void CFDictionarySetValue(IntPtr dictionary, IntPtr key, IntPtr value);

    [DllImport("CoreFoundation.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr CFPropertyListCreateXMLData(IntPtr allocator, IntPtr propertyList);

    [DllImport("CoreFoundation.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr CFDataGetLength(IntPtr data);

    [DllImport("CoreFoundation.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr CFDataGetBytePtr(IntPtr data);

    [DllImport("CoreFoundation.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void CFRunLoopRun();

    private static void DeviceChanged(IntPtr notificationInfo, IntPtr userData)
    {
        if (notificationInfo == IntPtr.Zero) return;
        DeviceNotificationInfo info = (DeviceNotificationInfo)Marshal.PtrToStructure(notificationInfo, typeof(DeviceNotificationInfo));
        if (info.message == Connected && info.device != IntPtr.Zero)
        {
            CurrentDevice = info.device;
            DeviceEvent.Set();
        }
        else if (info.message != Connected && info.device == CurrentDevice)
        {
            CurrentDevice = IntPtr.Zero;
        }
    }

    private static void RunNotificationPump()
    {
        try
        {
            int result = AMDeviceNotificationSubscribe(Callback, 0, 0, IntPtr.Zero, ref Subscription);
            if (result != 0) PumpFailure = "Apple device notification service returned " + result + ".";
            SubscriptionReady.Set();
            if (result == 0) CFRunLoopRun();
        }
        catch (Exception error)
        {
            PumpFailure = error.Message;
            SubscriptionReady.Set();
        }
    }

    private static void EnsureStarted()
    {
        lock (Gate)
        {
            if (Started) return;
            Started = true;
            Thread pumpThread = new Thread(RunNotificationPump);
            pumpThread.IsBackground = true;
            pumpThread.Name = "Greenloop Apple iPhone listener";
            pumpThread.Start();
        }
        if (!SubscriptionReady.WaitOne(3000)) throw new InvalidOperationException("Apple device listener did not start.");
        if (!String.IsNullOrWhiteSpace(PumpFailure)) throw new InvalidOperationException(PumpFailure);
    }

    private static string ValueToString(IntPtr value)
    {
        if (value == IntPtr.Zero) return String.Empty;
        if (CFGetTypeID(value) == CFNumberGetTypeID())
        {
            long number;
            return CFNumberGetValue(value, SInt64, out number) ? number.ToString() : String.Empty;
        }
        byte[] buffer = new byte[4096];
        if (!CFStringGetCString(value, buffer, (IntPtr)buffer.Length, Utf8)) return String.Empty;
        int end = Array.IndexOf<byte>(buffer, 0);
        if (end < 0) end = buffer.Length;
        return Encoding.UTF8.GetString(buffer, 0, end).Trim();
    }

    private static string ReadValue(IntPtr device, string domainName, string keyName)
    {
        IntPtr key = CFStringCreateWithCString(IntPtr.Zero, keyName, Utf8);
        IntPtr domain = String.IsNullOrWhiteSpace(domainName) ? IntPtr.Zero : CFStringCreateWithCString(IntPtr.Zero, domainName, Utf8);
        if (key == IntPtr.Zero || (!String.IsNullOrWhiteSpace(domainName) && domain == IntPtr.Zero)) return String.Empty;
        IntPtr value = IntPtr.Zero;
        try
        {
            value = AMDeviceCopyValue(device, domain, key);
            if (value == IntPtr.Zero) return String.Empty;
            return ValueToString(value);
        }
        finally
        {
            if (value != IntPtr.Zero) CFRelease(value);
            CFRelease(key);
            if (domain != IntPtr.Zero) CFRelease(domain);
        }
    }

    private static string FirstDomainValue(IntPtr device, string domainName, params string[] keys)
    {
        foreach (string key in keys)
        {
            string value = ReadValue(device, domainName, key);
            if (!String.IsNullOrWhiteSpace(value)) return value;
        }
        return String.Empty;
    }

    private static string FirstValue(IntPtr device, params string[] keys)
    {
        foreach (string key in keys)
        {
            string value = ReadValue(device, String.Empty, key);
            if (!String.IsNullOrWhiteSpace(value)) return value;
        }
        return String.Empty;
    }

    private static string PropertyListToXml(IntPtr propertyList)
    {
        if (propertyList == IntPtr.Zero) return String.Empty;
        IntPtr data = CFPropertyListCreateXMLData(IntPtr.Zero, propertyList);
        if (data == IntPtr.Zero) return String.Empty;
        try
        {
            long length = CFDataGetLength(data).ToInt64();
            IntPtr pointer = CFDataGetBytePtr(data);
            if (pointer == IntPtr.Zero || length <= 0 || length > 16 * 1024 * 1024) return String.Empty;
            byte[] bytes = new byte[(int)length];
            Marshal.Copy(pointer, bytes, 0, bytes.Length);
            return Encoding.UTF8.GetString(bytes);
        }
        finally
        {
            CFRelease(data);
        }
    }

    private static string ReadIoRegistry(IntPtr device, string entryName, string entryClass)
    {
        IntPtr serviceName = IntPtr.Zero;
        IntPtr service = IntPtr.Zero;
        IntPtr request = IntPtr.Zero;
        IntPtr response = IntPtr.Zero;
        var strings = new List<IntPtr>();
        try
        {
            DiagnosticsDebug = "Starting diagnostics relay";
            serviceName = CFStringCreateWithCString(IntPtr.Zero, "com.apple.mobile.diagnostics_relay", Utf8);
            int serviceResult = AMDeviceSecureStartService(device, serviceName, IntPtr.Zero, out service);
            if (serviceResult != 0 || service == IntPtr.Zero)
            {
                DiagnosticsDebug = "Diagnostics service failed (" + serviceResult + ")";
                return String.Empty;
            }

            request = CFDictionaryCreateMutable(IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (request == IntPtr.Zero) return String.Empty;

            Action<string, string> addString = (keyText, valueText) => {
                IntPtr key = CFStringCreateWithCString(IntPtr.Zero, keyText, Utf8);
                IntPtr value = CFStringCreateWithCString(IntPtr.Zero, valueText, Utf8);
                strings.Add(key);
                strings.Add(value);
                CFDictionarySetValue(request, key, value);
            };
            addString("Request", "IORegistry");
            if (!String.IsNullOrWhiteSpace(entryName)) addString("EntryName", entryName);
            if (!String.IsNullOrWhiteSpace(entryClass)) addString("EntryClass", entryClass);

            ulong sent = AMDServiceConnectionSendMessage(service, request, XmlPlistFormat);
            DiagnosticsDebug = "Diagnostics request result " + sent;
            int receivedFormat;
            ulong received = AMDServiceConnectionReceiveMessage(service, out response, out receivedFormat);
            DiagnosticsDebug += "; response result " + received + "; format " + receivedFormat + "; pointer " + response;
            if (response == IntPtr.Zero) return String.Empty;
            string xml = PropertyListToXml(response);
            DiagnosticsDebug += "; XML length " + xml.Length;
            return xml;
        }
        catch (Exception error)
        {
            DiagnosticsDebug = "Diagnostics exception: " + error.GetType().Name + ": " + error.Message;
            return String.Empty;
        }
        finally
        {
            if (response != IntPtr.Zero) CFRelease(response);
            if (request != IntPtr.Zero) CFRelease(request);
            foreach (IntPtr item in strings) if (item != IntPtr.Zero) CFRelease(item);
            if (service != IntPtr.Zero) AMDServiceConnectionInvalidate(service);
            if (serviceName != IntPtr.Zero) CFRelease(serviceName);
        }
    }

    private static double PlistNumber(string xml, string key)
    {
        if (String.IsNullOrWhiteSpace(xml)) return 0;
        Match match = Regex.Match(xml, "<key>\\s*" + Regex.Escape(key) + "\\s*</key>\\s*<(?:integer|real)>\\s*([0-9.]+)\\s*</(?:integer|real)>", RegexOptions.IgnoreCase);
        double value;
        return match.Success && Double.TryParse(match.Groups[1].Value, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out value) ? value : 0;
    }

    private static string BatteryHealthFromDiagnostics(IntPtr device)
    {
        string xml = ReadIoRegistry(device, "AppleSmartBattery", String.Empty);
        if (String.IsNullOrWhiteSpace(xml)) xml = ReadIoRegistry(device, String.Empty, "IOPMPowerSource");
        if (String.IsNullOrWhiteSpace(xml)) return String.Empty;

        double direct = PlistNumber(xml, "MaximumCapacityPercent");
        if (direct <= 0) direct = PlistNumber(xml, "BatteryMaximumCapacity");
        if (direct <= 0) direct = PlistNumber(xml, "HealthPercentage");

        double design = PlistNumber(xml, "DesignCapacity");
        double maximum = PlistNumber(xml, "NominalChargeCapacity");
        if (maximum <= 0) maximum = PlistNumber(xml, "AppleRawMaxCapacity");
        if (direct <= 0 && design > 0 && maximum > 0) direct = (maximum / design) * 100.0;

        if (direct <= 0)
        {
            double maxCapacity = PlistNumber(xml, "MaxCapacity");
            if (maxCapacity > 0 && maxCapacity <= 100) direct = maxCapacity;
        }
        if (direct <= 0) return String.Empty;
        int rounded = (int)Math.Round(Math.Max(1, Math.Min(100, direct)), MidpointRounding.AwayFromZero);
        return rounded.ToString();
    }

    private static string FriendlyModel(string productType)
    {
        var models = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
            { "iPhone12,1", "11" }, { "iPhone12,3", "11 Pro" }, { "iPhone12,5", "11 Pro Max" }, { "iPhone12,8", "SE 2" },
            { "iPhone13,1", "12 Mini" }, { "iPhone13,2", "12" }, { "iPhone13,3", "12 Pro" }, { "iPhone13,4", "12 Pro Max" },
            { "iPhone14,2", "13 Pro" }, { "iPhone14,3", "13 Pro Max" }, { "iPhone14,4", "13 Mini" }, { "iPhone14,5", "13" }, { "iPhone14,6", "SE 3" },
            { "iPhone14,7", "14" }, { "iPhone14,8", "14 Plus" }, { "iPhone15,2", "14 Pro" }, { "iPhone15,3", "14 Pro Max" },
            { "iPhone15,4", "15" }, { "iPhone15,5", "15 Plus" }, { "iPhone16,1", "15 Pro" }, { "iPhone16,2", "15 Pro Max" },
            { "iPhone17,1", "16 Pro" }, { "iPhone17,2", "16 Pro Max" }, { "iPhone17,3", "16" }, { "iPhone17,4", "16 Plus" }, { "iPhone17,5", "16e" }
        };
        string model;
        return models.TryGetValue(productType ?? String.Empty, out model) ? model : productType;
    }

    private static Dictionary<string, string> Error(string message)
    {
        return new Dictionary<string, string> { { "ok", "false" }, { "message", message } };
    }

    public static Dictionary<string, string> ReadConnectedDevice()
    {
        try
        {
            EnsureStarted();
            IntPtr device = CurrentDevice;
            if (device == IntPtr.Zero)
            {
                DeviceEvent.WaitOne(2500);
                device = CurrentDevice;
            }
            if (device == IntPtr.Zero) return Error("No iPhone detected. With this scanner window already open, unplug the iPhone, wait two seconds, reconnect it directly to the PC, unlock it, and tap Trust.");

            int connectResult = AMDeviceConnect(device);
            if (connectResult != 0) return Error("iPhone connection failed (" + connectResult + "). Unlock the phone and reconnect the cable.");
            bool sessionStarted = false;
            try
            {
                if (AMDeviceIsPaired(device) == 0) return Error("This iPhone is not trusted. Unlock it and tap Trust This Computer.");
                int pairingResult = AMDeviceValidatePairing(device);
                if (pairingResult != 0) return Error("Trust validation failed (" + pairingResult + "). Tap Trust on the iPhone, then try again.");
                int sessionResult = AMDeviceStartSession(device);
                if (sessionResult != 0) return Error("Could not start an iPhone session (" + sessionResult + "). Keep the iPhone unlocked.");
                sessionStarted = true;

                string productType = FirstValue(device, "ProductType");
                string imei = FirstValue(device, "InternationalMobileEquipmentIdentity", "IMEI");
                string capacity = FirstValue(device, "TotalDiskCapacity", "DeviceCapacity", "TotalDataCapacity");
                if (String.IsNullOrWhiteSpace(capacity)) capacity = FirstDomainValue(device, "com.apple.disk_usage", "TotalDiskCapacity", "TotalDataCapacity", "DiskCapacity", "DeviceCapacity");
                string deviceColor = FirstValue(device, "DeviceColor", "DeviceCoverGlassColor");
                string enclosureColor = FirstValue(device, "DeviceEnclosureColor", "DeviceHousingColor", "DeviceBackingColor");
                string color = !String.IsNullOrWhiteSpace(enclosureColor) ? enclosureColor : deviceColor;
                string batteryHealth = FirstValue(device, "BatteryMaximumCapacity", "MaximumCapacityPercent", "BatteryHealth", "HealthPercentage");
                if (String.IsNullOrWhiteSpace(batteryHealth)) batteryHealth = FirstDomainValue(device, "com.apple.mobile.battery", "BatteryMaximumCapacity", "MaximumCapacityPercent", "BatteryHealth", "HealthPercentage");
                if (String.IsNullOrWhiteSpace(batteryHealth)) batteryHealth = BatteryHealthFromDiagnostics(device);
                string serial = FirstValue(device, "SerialNumber");
                string modelNumber = FirstValue(device, "ModelNumber");
                string activationState = FirstValue(device, "ActivationState", "ActivationStateAcknowledged");

                return new Dictionary<string, string> {
                    { "ok", "true" },
                    { "imei", imei },
                    { "productType", productType },
                    { "model", FriendlyModel(productType) },
                    { "totalDiskCapacity", capacity },
                    { "color", color },
                    { "deviceColor", deviceColor },
                    { "enclosureColor", enclosureColor },
                    { "batteryHealth", batteryHealth },
                    { "batteryDiagnostic", DiagnosticsDebug },
                    { "modelNumber", modelNumber },
                    { "serialNumber", serial },
                    { "activationState", activationState }
                };
            }
            finally
            {
                if (sessionStarted) AMDeviceStopSession(device);
                AMDeviceDisconnect(device);
            }
        }
        catch (DllNotFoundException)
        {
            return Error("Apple Mobile Device Support is unavailable. Reinstall Apple Devices for Windows, then restart this scanner.");
        }
        catch (Exception error)
        {
            return Error("Scanner error: " + error.Message);
        }
    }
}
'@

if (-not ('GreenloopAppleDeviceReader' -as [type])) {
  Add-Type -TypeDefinition $nativeCode -Language CSharp
}

function Get-NearestStorageGb([string]$capacity) {
  [double]$bytes = 0
  if (-not [double]::TryParse($capacity, [ref]$bytes) -or $bytes -le 0) { return $null }
  $estimated = $bytes / 1GB
  $sizes = 16, 32, 64, 128, 256, 512, 1024, 2048
  return $sizes | Sort-Object { [math]::Abs($_ - $estimated) } | Select-Object -First 1
}

function Get-IPhoneColorName([string]$ProductType, [string]$EnclosureColor, [string]$DeviceColor) {
  $rawColor = if (-not [string]::IsNullOrWhiteSpace($EnclosureColor)) { $EnclosureColor.Trim() } else { ([string]$DeviceColor).Trim() }
  if ($rawColor -and $rawColor -notmatch '^(?:#|\d+$)') {
    return (Get-Culture).TextInfo.ToTitleCase(($rawColor -replace '[-_]', ' ').ToLowerInvariant())
  }

  if ($null -eq $script:GreenloopColorTable) {
    $script:GreenloopColorTable = @()
    $tablePaths = @((Join-Path $PSScriptRoot 'devices_table.txt'))
    if (${env:ProgramFiles(x86)}) { $tablePaths += (Join-Path ${env:ProgramFiles(x86)} '3uToolsV3\cache\devices_table\devices_table.txt') }
    $tablePath = $tablePaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($tablePath) {
      try { $script:GreenloopColorTable = @((Get-Content -LiteralPath $tablePath -Raw | ConvertFrom-Json).Images) } catch { $script:GreenloopColorTable = @() }
    }
  }

  $deviceEntry = $script:GreenloopColorTable | Where-Object { @($_.SupportTypes.ProductType) -contains $ProductType } | Select-Object -First 1
  if ($deviceEntry) {
    $matches = @($deviceEntry.imgs | Where-Object { [string]$_.BackColor -eq [string]$EnclosureColor })
    $exact = $matches | Where-Object { [string]$_.FrontColor -eq [string]$DeviceColor } | Select-Object -First 1
    $resolved = if ($exact) { $exact } else { $matches | Select-Object -First 1 }
    if ($resolved -and $resolved.BackColorText) { return [string]$resolved.BackColorText }
  }
  return $null
}

function Send-Json($Client, [int]$StatusCode, $Body) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 5 -Compress))
  $statusText = if ($StatusCode -eq 200) { 'OK' } elseif ($StatusCode -eq 404) { 'Not Found' } elseif ($StatusCode -eq 422) { 'Unprocessable Entity' } else { 'Error' }
  $stream = $Client.GetStream()
  $header = "HTTP/1.1 $StatusCode $statusText`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET, OPTIONS`r`nAccess-Control-Allow-Headers: Content-Type`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
  $stream.Write($headerBytes, 0, $headerBytes.Length)
  $stream.Write($bytes, 0, $bytes.Length)
  $stream.Flush()
}

function Start-3uTools {
  $candidatePaths = @()
  if (${env:ProgramFiles(x86)}) {
    $candidatePaths += (Join-Path ${env:ProgramFiles(x86)} '3uToolsV3\3uTools.exe')
    $candidatePaths += (Join-Path ${env:ProgramFiles(x86)} '3uTools\3uTools.exe')
  }
  if ($env:ProgramFiles) {
    $candidatePaths += (Join-Path $env:ProgramFiles '3uToolsV3\3uTools.exe')
    $candidatePaths += (Join-Path $env:ProgramFiles '3uTools\3uTools.exe')
  }
  if ($env:LOCALAPPDATA) {
    $candidatePaths += (Join-Path $env:LOCALAPPDATA '3uTools\3uTools.exe')
  }
  $executable = $candidatePaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $executable) { throw '3uTools is not installed in a standard Windows folder.' }
  Start-Process -FilePath $executable
  return @{ ok = $true; opened = $true; application = '3uTools' }
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
try {
  $listener.Start()
} catch {
  Write-Host "Could not start the local scanner on port $Port. $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

Write-Host "Greenloop iPhone Scanner is ready on http://127.0.0.1:$Port" -ForegroundColor Green
Write-Host 'Keep this window open. Connect, unlock, and trust the iPhone before using Read connected iPhone.' -ForegroundColor Yellow

while ($true) {
  $tcpClient = $null
  try {
    $tcpClient = $listener.AcceptTcpClient()
    $stream = $tcpClient.GetStream()
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 4096, $true)
    $requestLine = $reader.ReadLine()
    while ($true) {
      $headerLine = $reader.ReadLine()
      if ($null -eq $headerLine -or $headerLine.Length -eq 0) { break }
    }
    if ([string]::IsNullOrWhiteSpace($requestLine)) { continue }
    $requestParts = $requestLine.Split(' ')
    $method = $requestParts[0]
    $path = if ($requestParts.Length -gt 1) { $requestParts[1].Split('?')[0] } else { '/' }
    if ($method -eq 'OPTIONS') {
      Send-Json $tcpClient 200 @{ ok = $true }
      continue
    }
    switch ($path) {
      '/health' { Send-Json $tcpClient 200 @{ ok = $true; service = 'Greenloop iPhone Cable Reader'; version = '2.1'; appleMobileDeviceSupport = $true } }
      '/v1/open-3utools' {
        try { Send-Json $tcpClient 200 (Start-3uTools) }
        catch { Send-Json $tcpClient 422 @{ ok = $false; message = $_.Exception.Message } }
      }
      '/v1/device' {
        $result = [GreenloopAppleDeviceReader]::ReadConnectedDevice()
        if ($result['ok'] -ne 'true') { Send-Json $tcpClient 422 @{ ok = $false; message = $result['message'] }; continue }
        $resolvedColor = Get-IPhoneColorName $result['productType'] $result['enclosureColor'] $result['deviceColor']
        Send-Json $tcpClient 200 @{ ok = $true; device = @{ imei = $result['imei']; model = $result['model']; productType = $result['productType']; modelNumber = $result['modelNumber']; storageGb = (Get-NearestStorageGb $result['totalDiskCapacity']); color = $resolvedColor; batteryHealth = $result['batteryHealth']; serialNumber = $result['serialNumber']; activationState = $result['activationState'] } }
      }
      default { Send-Json $tcpClient 404 @{ ok = $false; message = 'Endpoint not found.' } }
    }
  } catch {
    Write-Host "Request error: $($_.Exception.Message)" -ForegroundColor Red
  } finally {
    if ($null -ne $tcpClient) { $tcpClient.Close() }
  }
}
