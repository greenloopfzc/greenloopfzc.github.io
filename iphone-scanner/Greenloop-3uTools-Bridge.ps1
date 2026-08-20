# Greenloop 3uTools Bridge
# Reads the visible 3uTools iDevice screen locally and exposes the result only on 127.0.0.1.
[CmdletBinding()]
param([int]$Port = 51894)

$ErrorActionPreference = 'Stop'
$BridgeVersion = '2.0'
$ThreeUToolsPath = 'C:\Program Files (x86)\3uToolsV3\3uTools.exe'

$captureCode = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class Greenloop3uToolsWindow
{
    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    private delegate bool EnumWindowsCallback(IntPtr handle, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr handle);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr handle, out RECT rectangle);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool PrintWindow(IntPtr handle, IntPtr deviceContext, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr handle, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr handle);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr handle, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr handle);

    private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    private static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOMOVE = 0x0002;
    private const uint SWP_SHOWWINDOW = 0x0040;
    private const int SW_RESTORE = 9;

    private static IntPtr FindWindow(int processId)
    {
        IntPtr found = IntPtr.Zero;
        int largestArea = 0;
        EnumWindows((handle, parameter) => {
            uint owner;
            GetWindowThreadProcessId(handle, out owner);
            if (owner == processId && IsWindowVisible(handle))
            {
                RECT rectangle;
                if (GetWindowRect(handle, out rectangle))
                {
                    int area = Math.Max(0, rectangle.Right - rectangle.Left) * Math.Max(0, rectangle.Bottom - rectangle.Top);
                    if (area > largestArea) { largestArea = area; found = handle; }
                }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static string Capture(string outputPath)
    {
        Process[] processes = Process.GetProcessesByName("3uTools");
        if (processes.Length == 0) throw new InvalidOperationException("3uTools is not running. Open 3uTools and connect the iPhone first.");
        IntPtr handle = IntPtr.Zero;
        foreach (Process process in processes)
        {
            // MainWindowHandle can point to 3uTools' small notification/tray window.
            // Always prefer the largest visible top-level window of the process.
            handle = FindWindow(process.Id);
            if (handle == IntPtr.Zero) handle = process.MainWindowHandle;
            if (handle != IntPtr.Zero) break;
        }
        if (handle == IntPtr.Zero) throw new InvalidOperationException("3uTools is open but its iDevice window is not visible. Restore it and keep the iDevice screen on display.");
        RECT rectangle;
        if (!GetWindowRect(handle, out rectangle)) throw new InvalidOperationException("Could not capture the 3uTools window.");
        int width = rectangle.Right - rectangle.Left;
        int height = rectangle.Bottom - rectangle.Top;
        if (width < 400 || height < 300) throw new InvalidOperationException("3uTools window is too small. Open its iDevice screen before reading it.");
        using (var image = new Bitmap(width, height))
        using (var graphics = Graphics.FromImage(image))
        {
            IntPtr deviceContext = graphics.GetHdc();
            bool printed;
            try
            {
                // PrintWindow reads the 3uTools window directly. Unlike CopyFromScreen,
                // it still works while Greenloop is the front window.
                printed = PrintWindow(handle, deviceContext, 2); // PW_RENDERFULLCONTENT
                if (!printed) printed = PrintWindow(handle, deviceContext, 0);
            }
            finally { graphics.ReleaseHdc(deviceContext); }
            if (!printed)
            {
                // Some 3uTools builds do not permit PrintWindow. Make it topmost only
                // long enough to copy its visible pixels, then restore Greenloop.
                IntPtr previousForegroundWindow = GetForegroundWindow();
                try
                {
                    SetWindowPos(handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
                    BringWindowToTop(handle);
                    System.Threading.Thread.Sleep(850);
                    graphics.CopyFromScreen(rectangle.Left, rectangle.Top, 0, 0, new Size(width, height), CopyPixelOperation.SourceCopy);
                }
                finally
                {
                    SetWindowPos(handle, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
                    if (previousForegroundWindow != IntPtr.Zero)
                    {
                        SetWindowPos(previousForegroundWindow, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
                        SetWindowPos(previousForegroundWindow, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
                    }
                }
            }
            image.Save(outputPath, ImageFormat.Png);
        }
        return outputPath;
    }

    public static bool Show()
    {
        Process[] processes = Process.GetProcessesByName("3uTools");
        foreach (Process process in processes)
        {
            IntPtr handle = FindWindow(process.Id);
            if (handle == IntPtr.Zero) handle = process.MainWindowHandle;
            if (handle == IntPtr.Zero) continue;
            ShowWindow(handle, SW_RESTORE);
            BringWindowToTop(handle);
            SetForegroundWindow(handle);
            return true;
        }
        return false;
    }
}
'@

if (-not ('Greenloop3uToolsWindow' -as [type])) { Add-Type -TypeDefinition $captureCode -ReferencedAssemblies System.Drawing }

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]
$null = [Windows.Storage.Streams.RandomAccessStreamReference, Windows.Storage.Streams, ContentType=WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType=WindowsRuntime]
$null = [Windows.Media.Ocr.OcrResult, Windows.Media.Ocr, ContentType=WindowsRuntime]

function Await-WinRt($operation, [Type]$resultType) {
  $method = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 } | Select-Object -First 1
  $task = $method.MakeGenericMethod($resultType).Invoke($null, @($operation))
  $task.Wait()
  return $task.Result
}

function Invoke-WinRtOneArgument($type, [string]$name, $argument) {
  $method = $type.GetMethods() | Where-Object { $_.Name -eq $name -and $_.GetParameters().Count -eq 1 } | Select-Object -First 1
  return $method.Invoke($null, @($argument))
}

function Get-OcrText([string]$imagePath) {
  $file = Await-WinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($imagePath)) ([Windows.Storage.StorageFile])
  $stream = Await-WinRt ([Windows.Storage.Streams.RandomAccessStreamReference]::CreateFromFile($file).OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
  $decoder = Await-WinRt (Invoke-WinRtOneArgument ([Windows.Graphics.Imaging.BitmapDecoder]) 'CreateAsync' $stream) ([Windows.Graphics.Imaging.BitmapDecoder])
  $bitmap = Await-WinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  if ($null -eq $engine) { throw 'Windows OCR is not available on this PC.' }
  $recognise = $engine.GetType().GetMethods() | Where-Object { $_.Name -eq 'RecognizeAsync' -and $_.GetParameters().Count -eq 1 } | Select-Object -First 1
  return (Await-WinRt ($recognise.Invoke($engine, @($bitmap))) ([Windows.Media.Ocr.OcrResult])).Text
}

function Get-NearestStorageGb([double]$observedGb) {
  if ($observedGb -le 0) { return $null }
  $sizes = 16, 32, 64, 128, 256, 512, 1024, 2048
  return $sizes | Sort-Object { [math]::Abs($_ - $observedGb) } | Select-Object -First 1
}

function Get-ModelFromProductType([string]$productType) {
  $models = @{
    'iPhone10,1' = '8'; 'iPhone10,4' = '8';
    'iPhone10,2' = '8 Plus'; 'iPhone10,5' = '8 Plus';
    'iPhone10,3' = 'X'; 'iPhone10,6' = 'X';
    'iPhone11,2' = 'XS'; 'iPhone11,4' = 'XS Max'; 'iPhone11,6' = 'XS Max'; 'iPhone11,8' = 'XR';
    'iPhone12,1' = '11'; 'iPhone12,3' = '11 Pro'; 'iPhone12,5' = '11 Pro Max'; 'iPhone12,8' = 'SE 2';
    'iPhone13,1' = '12 mini'; 'iPhone13,2' = '12'; 'iPhone13,3' = '12 Pro'; 'iPhone13,4' = '12 Pro Max';
    'iPhone14,4' = '13 mini'; 'iPhone14,5' = '13'; 'iPhone14,2' = '13 Pro'; 'iPhone14,3' = '13 Pro Max'; 'iPhone14,6' = 'SE 3'; 'iPhone14,7' = '14'; 'iPhone14,8' = '14 Plus';
    'iPhone15,2' = '14 Pro'; 'iPhone15,3' = '14 Pro Max'; 'iPhone15,4' = '15'; 'iPhone15,5' = '15 Plus';
    'iPhone16,1' = '15 Pro'; 'iPhone16,2' = '15 Pro Max'; 'iPhone17,3' = '16'; 'iPhone17,4' = '16 Plus'; 'iPhone17,1' = '16 Pro'; 'iPhone17,2' = '16 Pro Max'
  }
  if ($models.ContainsKey($productType)) { return $models[$productType] }
  return ''
}

function Get-3uToolsProcess {
  return Get-Process -Name '3uTools' -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Open-3uTools {
  if (-not (Test-Path -LiteralPath $ThreeUToolsPath)) {
    throw '3uTools is not installed. Install 3uTools on this Windows PC first.'
  }
  $process = Get-3uToolsProcess
  if ($null -eq $process) {
    Start-Process -FilePath $ThreeUToolsPath -WorkingDirectory (Split-Path -Parent $ThreeUToolsPath) | Out-Null
    for ($attempt = 0; $attempt -lt 20; $attempt += 1) {
      Start-Sleep -Milliseconds 250
      $process = Get-3uToolsProcess
      if ($null -ne $process) { break }
    }
  }
  if ($null -eq $process) { throw '3uTools could not be started. Open it manually once, then try again.' }
  $shown = $false
  for ($attempt = 0; $attempt -lt 12; $attempt += 1) {
    if ([Greenloop3uToolsWindow]::Show()) { $shown = $true; break }
    Start-Sleep -Milliseconds 250
  }
  return @{ ok = $true; installed = $true; running = $true; windowShown = $shown }
}

function Get-3uToolsCacheDevice {
  $cacheRoot = 'C:\Program Files (x86)\3uToolsV3\cache'
  if (-not (Test-Path -LiteralPath $cacheRoot)) { return $null }
  $file = Get-ChildItem -LiteralPath $cacheRoot -Filter '*_info.txt' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($null -eq $file) { return $null }
  $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  $readValue = {
    param([string]$name)
    $match = [regex]::Match($raw, "(?m)^" + [regex]::Escape($name) + "\s+(.+?)\s*$")
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return ''
  }
  $cacheImei = & $readValue 'InternationalMobileEquipmentIdentity'
  if ($cacheImei -notmatch '^\d{15}$') { return $null }
  $productType = & $readValue 'ProductType'
  return @{
    imei = $cacheImei
    model = (Get-ModelFromProductType $productType)
    storageGb = $null
    color = ''
    batteryHealth = $null
    activationState = (& $readValue 'ActivationState')
    serialNumber = (& $readValue 'SerialNumber')
    productType = $productType
    hostAttached = (& $readValue 'HostAttached')
    cacheUpdatedAt = $file.LastWriteTimeUtc.ToString('o')
  }
}

function Get-3uToolsDevice {
  if ($null -eq (Get-3uToolsProcess)) { throw '3uTools is not running. Greenloop can open it automatically.' }
  $snapshot = Join-Path $env:TEMP ('greenloop-3utools-' + [guid]::NewGuid().ToString() + '.png')
  try {
    # 3uTools records the connected phone's IMEI and ProductType in this local cache.
    # Read it first, so window OCR cannot block the most important device identity.
    $cacheDevice = Get-3uToolsCacheDevice
    if ($null -ne $cacheDevice) {
      $text = ''
      $storageGb = $null
      $color = ''
      $batteryHealth = $null
      try {
        [void][Greenloop3uToolsWindow]::Capture($snapshot)
        $text = Get-OcrText $snapshot
        $colors = 'Black','White','Blue','Green','Red','Pink','Purple','Yellow','Gold','Silver','Starlight','Midnight','Graphite','Sierra Blue','Alpine Green','Space Black','Deep Purple','Natural Titanium','Blue Titanium','White Titanium','Desert Titanium'
        foreach ($candidate in $colors) { if ($text -match ('(?i)\b' + [regex]::Escape($candidate) + '\b')) { $color = $candidate; break } }
        $gbMatches = [regex]::Matches($text, '(?i)(?<!\d)(\d{2,4}(?:\.\d+)?)\s*(?:GB|G8)\b')
        $observedGb = @($gbMatches | ForEach-Object { [double]$_.Groups[1].Value } | Where-Object { $_ -ge 14 }) | Measure-Object -Maximum
        if ($null -ne $observedGb.Maximum) { $storageGb = Get-NearestStorageGb ([double]$observedGb.Maximum) }
        $batteryMatch = [regex]::Match($text, '(?is)Battery\s*Life.{0,60}?(\d{1,3})\s*%')
        if ($batteryMatch.Success -and [int]$batteryMatch.Groups[1].Value -ge 1 -and [int]$batteryMatch.Groups[1].Value -le 100) { $batteryHealth = [int]$batteryMatch.Groups[1].Value }
      } catch { $text = '' }
      return @{ ok = $true; device = @{ imei = $cacheDevice.imei; model = $cacheDevice.model; storageGb = $storageGb; color = $color; batteryHealth = $batteryHealth; activationState = $cacheDevice.activationState; serialNumber = $cacheDevice.serialNumber; productType = $cacheDevice.productType }; ocr = $text; source = '3uTools cache and iDevice screen' }
    }
    [void][Greenloop3uToolsWindow]::Capture($snapshot)
    $text = Get-OcrText $snapshot
    $imei = [regex]::Match($text, '(?<!\d)\d{15}(?!\d)').Value
    $modelMatch = [regex]::Match($text, '(?i)\biPhone\s+((?:\d{1,2}|SE)(?:\s+(?:mini|Plus|Pro(?:\s+Max)?|e))?)')
    $model = if ($modelMatch.Success) { $modelMatch.Groups[1].Value.Trim() } else { '' }
    $colors = 'Black','White','Blue','Green','Red','Pink','Purple','Yellow','Gold','Silver','Starlight','Midnight','Graphite','Sierra Blue','Alpine Green','Space Black','Deep Purple','Natural Titanium','Blue Titanium','White Titanium','Desert Titanium'
    $color = ''
    foreach ($candidate in $colors) { if ($text -match ('(?i)\b' + [regex]::Escape($candidate) + '\b')) { $color = $candidate; break } }
    $gbMatches = [regex]::Matches($text, '(?i)(?<!\d)(\d{2,4}(?:\.\d+)?)\s*(?:GB|G8)\b')
    $observedGb = @($gbMatches | ForEach-Object { [double]$_.Groups[1].Value } | Where-Object { $_ -ge 14 }) | Measure-Object -Maximum
    $storageGb = if ($null -ne $observedGb.Maximum) { Get-NearestStorageGb ([double]$observedGb.Maximum) } else { $null }
    $batteryMatch = [regex]::Match($text, '(?is)Battery\s*Life.{0,60}?(\d{1,3})\s*%')
    $batteryHealth = if ($batteryMatch.Success -and [int]$batteryMatch.Groups[1].Value -ge 1 -and [int]$batteryMatch.Groups[1].Value -le 100) { [int]$batteryMatch.Groups[1].Value } else { $null }
    if (-not $imei) { throw '3uTools screen was captured, but no 15-digit IMEI was found. Keep the 3uTools iDevice page open and press Refresh once.' }
    return @{ ok = $true; device = @{ imei = $imei; model = $model; storageGb = $storageGb; color = $color; batteryHealth = $batteryHealth }; ocr = $text; source = '3uTools iDevice screen' }
  } finally {
    if (Test-Path -LiteralPath $snapshot) { Remove-Item -LiteralPath $snapshot -Force -ErrorAction SilentlyContinue }
  }
}

function Send-Json($client, [int]$statusCode, $body) {
  $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 6 -Compress))
  $statusText = if ($statusCode -eq 200) { 'OK' } elseif ($statusCode -eq 204) { 'No Content' } elseif ($statusCode -eq 404) { 'Not Found' } elseif ($statusCode -eq 422) { 'Unprocessable Entity' } else { 'Error' }
  $stream = $client.GetStream()
  $header = "HTTP/1.1 $statusCode $statusText`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET, OPTIONS`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
  $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
  $stream.Write($headerBytes, 0, $headerBytes.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
}

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
try { $listener.Start() } catch { Write-Host "Could not start the 3uTools bridge on port $Port. $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
Write-Host "Greenloop 3uTools Bridge is ready on http://127.0.0.1:$Port" -ForegroundColor Green
Write-Host 'Keep 3uTools open, maximized, and on the iDevice screen while Greenloop reads a phone.' -ForegroundColor Yellow

while ($true) {
  $client = $null
  try {
    $client = $listener.AcceptTcpClient(); $stream = $client.GetStream(); $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 4096, $true)
    $request = $reader.ReadLine(); while ($true) { $line = $reader.ReadLine(); if ($null -eq $line -or $line.Length -eq 0) { break } }
    $path = if ([string]::IsNullOrWhiteSpace($request)) { '/' } else { $request.Split(' ')[1].Split('?')[0] }
    if ($request -like 'OPTIONS *') { Send-Json $client 200 @{ ok = $true }; continue }
    if ($path -eq '/health') { Send-Json $client 200 @{ ok = $true; service = 'Greenloop 3uTools Bridge'; version = $BridgeVersion; threeUToolsInstalled = (Test-Path -LiteralPath $ThreeUToolsPath); threeUToolsRunning = ($null -ne (Get-3uToolsProcess)) }; continue }
    if ($path -eq '/v1/status') { Send-Json $client 200 @{ ok = $true; installed = (Test-Path -LiteralPath $ThreeUToolsPath); running = ($null -ne (Get-3uToolsProcess)); cacheDevice = (Get-3uToolsCacheDevice) }; continue }
    if ($path -eq '/v1/open') { try { Send-Json $client 200 (Open-3uTools) } catch { Send-Json $client 422 @{ ok = $false; message = $_.Exception.Message } }; continue }
    if ($path -eq '/v1/device') { try { Send-Json $client 200 (Get-3uToolsDevice) } catch { Send-Json $client 422 @{ ok = $false; message = $_.Exception.Message } }; continue }
    Send-Json $client 404 @{ ok = $false; message = 'Endpoint not found.' }
  } catch { Write-Host "Bridge request error: $($_.Exception.Message)" -ForegroundColor Red } finally { if ($null -ne $client) { $client.Close() } }
}
