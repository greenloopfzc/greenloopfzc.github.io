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
$activationToolFolder = Join-Path $PSScriptRoot 'libimobiledevice'
$activationTool = Join-Path $activationToolFolder 'ideviceactivation.exe'
$pairTool = Join-Path $activationToolFolder 'idevicepair.exe'
$deviceInfoTool = Join-Path $activationToolFolder 'ideviceinfo.exe'
$diagnosticsTool = Join-Path $activationToolFolder 'idevicediagnostics.exe'
$deviceIdTool = Join-Path $activationToolFolder 'idevice_id.exe'

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
    private static extern int AMDeviceSetValue(IntPtr device, IntPtr domain, IntPtr key, IntPtr value);

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

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string moduleName);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    private static extern IntPtr GetProcAddress(IntPtr module, string procedureName);

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

    private static IntPtr TrueBoolean()
    {
        IntPtr module = GetModuleHandle("CoreFoundation.dll");
        if (module == IntPtr.Zero) throw new InvalidOperationException("CoreFoundation is not loaded.");
        IntPtr symbol = GetProcAddress(module, "kCFBooleanTrue");
        if (symbol == IntPtr.Zero) throw new InvalidOperationException("Apple CoreFoundation Boolean support is unavailable.");
        IntPtr value = Marshal.ReadIntPtr(symbol);
        if (value == IntPtr.Zero) throw new InvalidOperationException("Apple CoreFoundation returned an invalid Boolean value.");
        return value;
    }

    private static void SetBooleanValue(IntPtr device, string domainName, string keyName)
    {
        IntPtr domain = CFStringCreateWithCString(IntPtr.Zero, domainName, Utf8);
        IntPtr key = CFStringCreateWithCString(IntPtr.Zero, keyName, Utf8);
        if (domain == IntPtr.Zero || key == IntPtr.Zero) throw new InvalidOperationException("Could not create the Apple setup preference key.");
        try
        {
            int result = AMDeviceSetValue(device, domain, key, TrueBoolean());
            if (result != 0) throw new InvalidOperationException("Apple rejected setup preference " + keyName + " (" + result + ").");
        }
        finally
        {
            if (key != IntPtr.Zero) CFRelease(key);
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

    public static Dictionary<string, string> CompleteSetupAssistant()
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
            if (device == IntPtr.Zero) return Error("No iPhone detected. Reconnect the cable, unlock the phone, and tap Trust.");

            int connectResult = AMDeviceConnect(device);
            if (connectResult != 0) return Error("iPhone connection failed (" + connectResult + ").");
            bool sessionStarted = false;
            try
            {
                if (AMDeviceIsPaired(device) == 0) return Error("Trust Required: unlock the iPhone and tap Trust This Computer.");
                int pairingResult = AMDeviceValidatePairing(device);
                if (pairingResult != 0) return Error("Trust validation failed (" + pairingResult + ").");
                int sessionResult = AMDeviceStartSession(device);
                if (sessionResult != 0) return Error("Could not start an iPhone session (" + sessionResult + ").");
                sessionStarted = true;

                string activationState = FirstValue(device, "ActivationState");
                if (!String.Equals(activationState, "Activated", StringComparison.OrdinalIgnoreCase))
                    return Error("The iPhone is not activated through Apple services. Setup Assistant was not changed.");

                SetBooleanValue(device, "com.apple.purplebuddy", "SetupDone");
                SetBooleanValue(device, "com.apple.purplebuddy", "SetupFinishedAllSteps");
                SetBooleanValue(device, "com.apple.purplebuddy", "UserChoseLanguage");

                return new Dictionary<string, string> {
                    { "ok", "true" },
                    { "activationState", activationState },
                    { "setupAssistantCompleted", "true" }
                };
            }
            finally
            {
                if (sessionStarted) AMDeviceStopSession(device);
                AMDeviceDisconnect(device);
            }
        }
        catch (Exception error)
        {
            return Error("Setup Assistant could not be completed: " + error.Message);
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

function Get-GreenloopInfoValue([string]$Text, [string]$Key) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $match = [regex]::Match($Text, ('(?im)^' + [regex]::Escape($Key) + ':\s*(.*?)\s*$'))
  return $(if ($match.Success) { $match.Groups[1].Value.Trim() } else { '' })
}

function Get-GreenloopFriendlyModel([string]$ProductType) {
  $models = @{
    'iPhone12,1' = '11'; 'iPhone12,3' = '11 Pro'; 'iPhone12,5' = '11 Pro Max'; 'iPhone12,8' = 'SE 2'
    'iPhone13,1' = '12 Mini'; 'iPhone13,2' = '12'; 'iPhone13,3' = '12 Pro'; 'iPhone13,4' = '12 Pro Max'
    'iPhone14,2' = '13 Pro'; 'iPhone14,3' = '13 Pro Max'; 'iPhone14,4' = '13 Mini'; 'iPhone14,5' = '13'; 'iPhone14,6' = 'SE 3'
    'iPhone14,7' = '14'; 'iPhone14,8' = '14 Plus'; 'iPhone15,2' = '14 Pro'; 'iPhone15,3' = '14 Pro Max'
    'iPhone15,4' = '15'; 'iPhone15,5' = '15 Plus'; 'iPhone16,1' = '15 Pro'; 'iPhone16,2' = '15 Pro Max'
    'iPhone17,1' = '16 Pro'; 'iPhone17,2' = '16 Pro Max'; 'iPhone17,3' = '16'; 'iPhone17,4' = '16 Plus'; 'iPhone17,5' = '16e'
  }
  if ($models.ContainsKey($ProductType)) { return [string]$models[$ProductType] }
  return $ProductType
}

function Get-GreenloopCliDevice {
  $basicResult = Invoke-GreenloopCommand $deviceInfoTool '' 35
  if ($basicResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$basicResult.Output)) {
    throw 'No iPhone data is available from Apple Mobile Device Support.'
  }
  $basic = [string]$basicResult.Output
  $diskResult = Invoke-GreenloopCommand $deviceInfoTool '-q com.apple.disk_usage' 35
  $disk = if ($diskResult.ExitCode -eq 0) { [string]$diskResult.Output } else { '' }
  $batteryHealth = ''
  if (Test-Path -LiteralPath $diagnosticsTool) {
    $diagnostics = Invoke-GreenloopCommand $diagnosticsTool 'ioregentry AppleSmartBattery' 35
    if ($diagnostics.ExitCode -eq 0) {
      $xml = [string]$diagnostics.Output
      foreach ($key in @('MaximumCapacityPercent', 'BatteryMaximumCapacity', 'HealthPercentage')) {
        $match = [regex]::Match($xml, ('(?is)<key>\s*' + [regex]::Escape($key) + '\s*</key>\s*<(?:integer|real)>\s*([0-9.]+)'))
        if ($match.Success -and [double]$match.Groups[1].Value -gt 0) {
          $batteryHealth = [math]::Round([double]$match.Groups[1].Value).ToString()
          break
        }
      }
      if (-not $batteryHealth) {
        $designMatch = [regex]::Match($xml, '(?is)<key>\s*DesignCapacity\s*</key>\s*<(?:integer|real)>\s*([0-9.]+)')
        $maximumMatch = [regex]::Match($xml, '(?is)<key>\s*(?:NominalChargeCapacity|AppleRawMaxCapacity)\s*</key>\s*<(?:integer|real)>\s*([0-9.]+)')
        if ($designMatch.Success -and $maximumMatch.Success) {
          $design = [double]$designMatch.Groups[1].Value
          $maximum = [double]$maximumMatch.Groups[1].Value
          if ($design -gt 0 -and $maximum -gt 0) {
            $batteryHealth = [math]::Round([math]::Min(100, [math]::Max(1, ($maximum / $design) * 100))).ToString()
          }
        }
      }
    }
  }
  $productType = Get-GreenloopInfoValue $basic 'ProductType'
  $deviceColor = Get-GreenloopInfoValue $basic 'DeviceColor'
  $enclosureColor = Get-GreenloopInfoValue $basic 'DeviceEnclosureColor'
  $capacity = Get-GreenloopInfoValue $basic 'TotalDiskCapacity'
  if (-not $capacity) { $capacity = Get-GreenloopInfoValue $disk 'TotalDiskCapacity' }
  if (-not $capacity) { $capacity = Get-GreenloopInfoValue $disk 'TotalDataCapacity' }
  return @{
    imei = Get-GreenloopInfoValue $basic 'InternationalMobileEquipmentIdentity'
    model = Get-GreenloopFriendlyModel $productType
    productType = $productType
    modelNumber = Get-GreenloopInfoValue $basic 'ModelNumber'
    storageGb = Get-NearestStorageGb $capacity
    color = Get-IPhoneColorName $productType $enclosureColor $deviceColor
    batteryHealth = $batteryHealth
    serialNumber = Get-GreenloopInfoValue $basic 'SerialNumber'
    activationState = Get-GreenloopInfoValue $basic 'ActivationState'
  }
}

function Get-IPhoneColorName([string]$ProductType, [string]$EnclosureColor, [string]$DeviceColor) {
  $rawColor = if (-not [string]::IsNullOrWhiteSpace($EnclosureColor)) { $EnclosureColor.Trim() } else { ([string]$DeviceColor).Trim() }
  if ($rawColor -and $rawColor -notmatch '^(?:#|\d+$)') {
    return (Get-Culture).TextInfo.ToTitleCase(($rawColor -replace '[-_]', ' ').ToLowerInvariant())
  }

  if ($null -eq $script:GreenloopColorTable) {
    $script:GreenloopColorTable = @()
    $tablePaths = @((Join-Path $PSScriptRoot 'devices_table.txt'))
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

function Invoke-GreenloopCommand([string]$Executable, [string]$Arguments, [int]$TimeoutSeconds = 120) {
  if (-not (Test-Path -LiteralPath $Executable)) {
    throw 'The Greenloop activation engine is not installed. Run Install-Greenloop-Cable-Reader.cmd once.'
  }

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $Executable
  $startInfo.Arguments = $Arguments
  $startInfo.WorkingDirectory = $activationToolFolder
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.EnvironmentVariables['PATH'] = "$activationToolFolder;$appleSupportPath;$env:PATH"

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  [void]$process.Start()
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    try { $process.Kill() } catch {}
    throw 'Apple activation did not finish in time. Check the internet connection and reconnect the iPhone.'
  }
  $stdout = $stdoutTask.Result.Trim()
  $stderr = $stderrTask.Result.Trim()
  $outputLines = @($stdout, $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
  return @{ ExitCode = $process.ExitCode; Output = (($outputLines -join "`n").Trim()) }
}

function Invoke-GreenloopActivationTool([string]$Command, [int]$TimeoutSeconds = 120) {
  return Invoke-GreenloopCommand $activationTool "$Command --batch" $TimeoutSeconds
}

function Confirm-GreenloopPairing {
  $validation = Invoke-GreenloopCommand $pairTool 'validate' 20
  if ($validation.ExitCode -eq 0 -and $validation.Output -match '(?i)success|validated|paired') { return }

  $pairing = Invoke-GreenloopCommand $pairTool 'pair' 45
  if ($pairing.ExitCode -ne 0 -or $pairing.Output -notmatch '(?i)success|paired') {
    throw 'Trust Required: unlock the iPhone and tap Trust This Computer. Greenloop will retry automatically.'
  }
}

function Test-ActivatedState([string]$Value) {
  return ([string]$Value) -match '(?i)\bactivated\b' -and ([string]$Value) -notmatch '(?i)\bunactivated\b'
}

function Get-GreenloopSecurityState {
  $information = Invoke-GreenloopCommand $deviceInfoTool '' 35
  if ($information.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$information.Output)) {
    throw 'Greenloop could not verify this iPhone security state. Setup Assistant was not changed.'
  }
  $output = [string]$information.Output
  $activationState = if ($output -match '(?im)^ActivationState:\s*(.+)$') { $matches[1].Trim() } else { '' }
  $encodedLock = if ($output -match '(?im)^\s*fm-activation-locked:\s*(\S+)\s*$') { $matches[1].Trim() } else { '' }
  $activationLocked = $false
  if ($encodedLock) {
    try {
      $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedLock)).Trim()
      $activationLocked = $decoded -match '^(?i:yes|true|1)$'
    } catch {
      throw 'Greenloop could not verify Apple ownership protection. Setup Assistant was not changed.'
    }
  }
  if ($activationLocked) {
    throw 'Apple Activation Lock is enabled. Greenloop will not complete Setup Assistant. The legitimate owner or supplier must remove the lock.'
  }
  if (-not (Test-ActivatedState $activationState)) {
    throw 'This iPhone is not activated through Apple services. Setup Assistant was not changed.'
  }
  return @{ ActivationState = $activationState; ActivationLocked = $activationLocked }
}

function Test-GreenloopSetupAssistantFinished {
  $result = Invoke-GreenloopCommand $deviceInfoTool '-q com.apple.purplebuddy' 35
  if ($result.ExitCode -ne 0) { return $false }
  $output = [string]$result.Output
  $setupDone = $output -match '(?im)^SetupDone:\s*true\s*$'
  $allStepsDone = $output -match '(?im)^SetupFinishedAllSteps:\s*true\s*$'
  return ($setupDone -and $allStepsDone)
}

function Get-GreenloopConnectedUdid {
  $deviceList = Invoke-GreenloopCommand $deviceIdTool '-l' 20
  if ($deviceList.ExitCode -ne 0) {
    throw 'Greenloop could not identify the connected iPhone. Reconnect the cable and try again.'
  }
  $udids = @(([string]$deviceList.Output -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[A-Za-z0-9-]{12,}$' })
  if ($udids.Count -eq 0) { throw 'No iPhone is connected.' }
  if ($udids.Count -gt 1) { throw 'More than one iPhone is connected. Keep only the phone being activated connected, then try again.' }
  return [string]$udids[0]
}

function Get-GreenloopConnectionProbe {
  try {
    $udid = Get-GreenloopConnectedUdid
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
      $bytes = [Text.Encoding]::UTF8.GetBytes($udid)
      $deviceKey = ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').Substring(0, 16)
    } finally {
      $sha256.Dispose()
    }
    return @{ ok = $true; connected = $true; deviceKey = $deviceKey }
  } catch {
    if ($_.Exception.Message -match '(?i)no iphone is connected') {
      return @{ ok = $true; connected = $false; deviceKey = '' }
    }
    throw
  }
}

function Invoke-GreenloopSetupRestore([string]$Udid) {
  throw 'Backup restore is permanently disabled in Greenloop Cable Reader 4.0.'
}

function Invoke-GreenloopCompleteSetup {
  Confirm-GreenloopPairing
  $security = Get-GreenloopSecurityState
  # IMPORTANT: this route must never erase, restore, reboot, or restart the
  # connected phone. It writes only Apple's Setup Assistant completion flags.
  # The browser calls this route once for each physical connection.
  $nativeResult = [GreenloopAppleDeviceReader]::CompleteSetupAssistant()
  if (-not $nativeResult -or [string]$nativeResult['ok'] -ne 'true') {
    $detail = if ($nativeResult -and $nativeResult.ContainsKey('message')) { [string]$nativeResult['message'] } else { 'Apple did not accept the Setup Assistant completion request.' }
    throw $detail
  }

  Start-Sleep -Milliseconds 1200
  if (-not (Test-GreenloopSetupAssistantFinished)) {
    throw 'Apple did not confirm Setup Assistant completion. Greenloop stopped safely without resetting or restarting the phone.'
  }

  return @{
    ok = $true
    activationState = [string]$security.ActivationState
    setupAssistantCompleted = $true
    homeScreenReady = $true
    restarting = $false
    message = 'Setup Assistant completion was accepted. No reset, restore, or restart was performed.'
  }
}

function Invoke-GreenloopActivation {
  Confirm-GreenloopPairing
  $state = Invoke-GreenloopActivationTool 'state' 20
  if (Test-ActivatedState $state.Output) {
    $result = Invoke-GreenloopCompleteSetup
    $result.alreadyActivated = $true
    return $result
  }

  $activation = Invoke-GreenloopActivationTool 'activate' 120
  if ($activation.ExitCode -ne 0) {
    $detail = [string]$activation.Output
    if ($detail -match '(?i)lost mode') {
      throw 'Lost Mode is enabled. Greenloop will not activate this phone. The legitimate owner must remove Lost Mode first.'
    }
    if ($detail -match '(?i)activation lock|locked to owner|apple id|owner account') {
      throw 'Apple Activation Lock is enabled. The legitimate owner or supplier must remove the lock before Greenloop can continue.'
    }
    if ($detail -match '(?i)sim not supported|carrier lock|carrier restriction|unsupported carrier') {
      throw 'Carrier Restriction: this iPhone cannot be activated with its current carrier status. The legitimate carrier or supplier must resolve it.'
    }
    if ($detail -match '(?i)sim|required sim|imsi|baseband') {
      throw 'Apple requires a valid SIM or baseband response for this phone. Insert a supported SIM, reconnect the phone, and try again.'
    }
    if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'Apple did not accept the activation request.' }
    throw "Activation failed: $detail"
  }

  $verified = Invoke-GreenloopActivationTool 'state' 25
  if (-not (Test-ActivatedState $verified.Output)) {
    throw 'Apple activation finished without a confirmed Activated state. Reconnect the phone and try once more.'
  }
  $result = Invoke-GreenloopCompleteSetup
  $result.alreadyActivated = $false
  return $result
}

function Get-GreenloopActivationError([string]$Message) {
  $detail = [string]$Message
  if ($detail -match '(?i)lost mode') {
    return @{ ok = $false; securityBlocked = $true; blockCode = 'lost_mode'; title = 'Lost Mode'; message = 'This iPhone is in Lost Mode and cannot be activated by Greenloop. The legitimate owner must remove Lost Mode first.' }
  }
  if ($detail -match '(?i)activation lock|locked to owner|apple id|owner account') {
    return @{ ok = $false; securityBlocked = $true; blockCode = 'activation_lock'; title = 'Activation Lock'; message = 'This iPhone is protected by Activation Lock or Apple ID ownership and cannot be activated by Greenloop. The legitimate owner or supplier must remove the lock.' }
  }
  if ($detail -match '(?i)carrier restriction|carrier lock|sim not supported|unsupported carrier') {
    return @{ ok = $false; securityBlocked = $true; blockCode = 'carrier_restriction'; title = 'Carrier Restriction'; message = 'This iPhone has a carrier restriction and cannot be activated in its current state. The legitimate carrier or supplier must resolve it.' }
  }
  if ($detail -match '(?i)trust required|not trusted|lockdownd|invalid hostid|pair') {
    return @{ ok = $false; securityBlocked = $false; blockCode = 'trust_required'; title = 'Trust Required'; message = 'Unlock the iPhone and tap Trust This Computer. Greenloop will retry automatically.' }
  }
  if ($detail -match '(?i)valid sim|required sim|imsi|baseband') {
    return @{ ok = $false; securityBlocked = $false; blockCode = 'sim_required'; title = 'SIM Required'; message = 'Apple requires a supported SIM or baseband response for this iPhone. Insert a supported SIM, reconnect it, and try again.' }
  }
  return @{ ok = $false; securityBlocked = $false; blockCode = 'activation_error'; title = 'Activation Needs Attention'; message = $detail }
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
try {
  $listener.Start()
} catch {
  Write-Host "Could not start the local scanner on port $Port. $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

Write-Host "Greenloop iPhone Scanner is ready on http://127.0.0.1:$Port" -ForegroundColor Green
Write-Host 'Automatic detection is on. Connect one iPhone; Greenloop will start without a button.' -ForegroundColor Yellow

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
      '/health' { Send-Json $tcpClient 200 @{ ok = $true; service = 'Greenloop iPhone Cable Reader'; version = '4.0'; appleMobileDeviceSupport = $true; activationEngine = ((Test-Path -LiteralPath $activationTool) -and (Test-Path -LiteralPath $pairTool)); setupAssistantEngine = ((Test-Path -LiteralPath $deviceInfoTool) -and (Test-Path -LiteralPath $deviceIdTool)) } }
      '/v1/probe' {
        try { Send-Json $tcpClient 200 (Get-GreenloopConnectionProbe) }
        catch { Send-Json $tcpClient 422 @{ ok = $false; connected = $false; message = $_.Exception.Message } }
      }
      '/v1/activate' {
        try { Send-Json $tcpClient 200 (Invoke-GreenloopActivation) }
        catch { Send-Json $tcpClient 422 (Get-GreenloopActivationError $_.Exception.Message) }
      }
      '/v1/complete-setup' {
        try { Send-Json $tcpClient 200 (Invoke-GreenloopCompleteSetup) }
        catch { Send-Json $tcpClient 422 (Get-GreenloopActivationError $_.Exception.Message) }
      }
      '/v1/device' {
        $result = [GreenloopAppleDeviceReader]::ReadConnectedDevice()
        if ($result['ok'] -eq 'true' -and -not [string]::IsNullOrWhiteSpace([string]$result['imei'])) {
          $resolvedColor = Get-IPhoneColorName $result['productType'] $result['enclosureColor'] $result['deviceColor']
          Send-Json $tcpClient 200 @{ ok = $true; device = @{ imei = $result['imei']; model = $result['model']; productType = $result['productType']; modelNumber = $result['modelNumber']; storageGb = (Get-NearestStorageGb $result['totalDiskCapacity']); color = $resolvedColor; batteryHealth = $result['batteryHealth']; serialNumber = $result['serialNumber']; activationState = $result['activationState'] } }
          continue
        }
        try {
          $fallback = Get-GreenloopCliDevice
          if ([string]::IsNullOrWhiteSpace([string]$fallback.imei)) { throw 'Apple did not return an IMEI for this phone.' }
          Send-Json $tcpClient 200 @{ ok = $true; device = $fallback }
        } catch {
          $nativeMessage = [string]$result['message']
          $message = if ($nativeMessage) { "$nativeMessage $($_.Exception.Message)" } else { $_.Exception.Message }
          Send-Json $tcpClient 422 @{ ok = $false; message = $message }
        }
      }
      default { Send-Json $tcpClient 404 @{ ok = $false; message = 'Endpoint not found.' } }
    }
  } catch {
    Write-Host "Request error: $($_.Exception.Message)" -ForegroundColor Red
  } finally {
    if ($null -ne $tcpClient) { $tcpClient.Close() }
  }
}
