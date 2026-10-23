using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Collections.Generic;
using System.Windows.Forms;

// No service privileges, phone writes or system-wide security changes.
internal sealed class SetupForm : Form {
  private readonly TextBox log = new TextBox();
  private readonly Button install = new Button(), test = new Button();
  private bool running;
  private readonly string stage;
  private const string PayloadSha256 = "PAYLOAD_SHA256";
  internal SetupForm() {
    Text = "Greenloop · Cable Reader Setup";
    Size = new Size(780, 650); MinimumSize = new Size(650, 580);
    StartPosition = FormStartPosition.CenterScreen;
    Font = new Font("Segoe UI", 10); BackColor = Color.FromArgb(235, 243, 246);
    var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(22), ColumnCount = 1, RowCount = 6 };
    layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
    layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 66));
    layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
    layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
    layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
    layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 50));
    layout.Controls.Add(new Label { Text = "iPhone + Android Cable Reader", Font = new Font("Segoe UI", 19, FontStyle.Bold), Dock = DockStyle.Fill, ForeColor = Color.FromArgb(8, 106, 78) });
    layout.Controls.Add(new Label { Text = "1. Install reader   2. Finish USB driver setup   3. Connect and test a phone\r\nWindows 10/11 x64 · One-time setup for this Windows user. Internet is needed for Android tools. Windows/phone approvals remain yours.", Dock = DockStyle.Fill });
    var actions = new FlowLayoutPanel { Dock = DockStyle.Fill };
    install.Text = "Install / Check reader"; install.AutoSize = true; install.Height = 38;
    install.Click += async (s,e) => await Install(); actions.Controls.Add(install);
    test.Text = "Test connected phone"; test.AutoSize = true; test.Click += async (s,e) => await TestPhone(); actions.Controls.Add(test);
    layout.Controls.Add(actions);
    var drivers = new FlowLayoutPanel { Dock = DockStyle.Fill };
    AddLink(drivers, "Apple Devices / driver", "https://apps.microsoft.com/detail/9np83lwlpz9k");
    AddLink(drivers, "Android USB drivers", "https://developer.android.com/studio/run/oem-usb");
    AddLink(drivers, "Sources & licenses", "https://greenloopfzc.github.io/downloads/reader-sources.zip");
    layout.Controls.Add(drivers);
    log.Multiline = true; log.ReadOnly = true; log.ScrollBars = ScrollBars.Vertical; log.Dock = DockStyle.Fill;
    log.BackColor = Color.White; log.Font = new Font("Consolas", 10);
    log.Text = "Click Install / Check reader. Existing custom reader functions are preserved when compatible.\r\n\r\niPhone: unlock, connect by a data cable, and tap Trust.\r\nAndroid: enable USB debugging and tap Allow. Manufacturer USB drivers may be needed.\r\n\r\nSetup never changes Greenloop records or saves a phone entry.\r\n";
    layout.Controls.Add(log);
    var end = new FlowLayoutPanel { Dock = DockStyle.Fill };
    AddLink(end, "Open Greenloop", "https://greenloopfzc.github.io/imei-entry.html");
    var close = new Button { Text = "Close", AutoSize = true }; close.Click += (s,e) => Close(); end.Controls.Add(close);
    layout.Controls.Add(end); Controls.Add(layout);
    stage = Path.Combine(Path.GetTempPath(), "GreenloopCableSetup", Guid.NewGuid().ToString("N"));
    FormClosing += (s,e) => { if (running) { e.Cancel = true; MessageBox.Show(this, "Setup is still running. Wait for the result before closing."); } };
  }
  private static void AddLink(Control panel, string title, string url) {
    var b = new Button { Text = title, AutoSize = true, Height = 34 };
    b.Click += (s,e) => { try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch (Exception ex) { MessageBox.Show(ex.Message); } };
    panel.Controls.Add(b);
  }
  private void Append(string line) { if (IsDisposed) return; if (InvokeRequired) { BeginInvoke(new Action<string>(Append), line); return; } log.AppendText(line + Environment.NewLine); }
  private void Busy(bool value) { running=value; install.Enabled=!value; test.Enabled=!value; }
  private async Task Install() {
    Busy(true);
    try {
      if (!Environment.Is64BitOperatingSystem || (Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE") ?? "").Equals("ARM64", StringComparison.OrdinalIgnoreCase) || (Environment.GetEnvironmentVariable("PROCESSOR_ARCHITEW6432") ?? "").Equals("ARM64", StringComparison.OrdinalIgnoreCase)) throw new Exception("This installer requires Windows 10/11 x64.");
      await Task.Run(() => {
        Directory.CreateDirectory(stage);
        using (var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip")) {
          if(resource==null) throw new Exception("Setup payload is missing.");
          using(var ms=new MemoryStream()) {
            resource.CopyTo(ms); var bytes=ms.ToArray();
            using(var sha=SHA256.Create()) { if(BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-","").ToLowerInvariant()!=PayloadSha256) throw new Exception("Setup payload integrity check failed."); }
            ms.Position=0;
            using(var zip=new ZipArchive(ms,ZipArchiveMode.Read)) foreach(var entry in zip.Entries) {
              string target=Path.GetFullPath(Path.Combine(stage,entry.FullName));
              if(!target.StartsWith(Path.GetFullPath(stage)+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase)) throw new Exception("Unsafe setup payload path.");
              Directory.CreateDirectory(Path.GetDirectoryName(target));
              if(!entry.FullName.EndsWith("/")) using(var input=entry.Open()) using(var output=new FileStream(target,FileMode.Create,FileAccess.Write)) input.CopyTo(output);
            }
          }
        }
        var info=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),@"System32\WindowsPowerShell\v1.0\powershell.exe"));
        info.Arguments="-NoProfile -ExecutionPolicy Bypass -File \""+Path.Combine(stage,"Install-Cable-Reader.ps1")+"\"";
        info.UseShellExecute=false; info.CreateNoWindow=true; info.RedirectStandardOutput=true; info.RedirectStandardError=true;
        info.EnvironmentVariables["PSModulePath"]=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),@"System32\WindowsPowerShell\v1.0\Modules")+";"+Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),@"WindowsPowerShell\Modules");
        using(var p=new Process()) {
          p.StartInfo=info; p.OutputDataReceived+=(s,e)=>{if(e.Data!=null)Append(e.Data);}; p.ErrorDataReceived+=(s,e)=>{if(e.Data!=null)Append(e.Data);};
          p.Start();p.BeginOutputReadLine();p.BeginErrorReadLine();p.WaitForExit();
          if(p.ExitCode!=0)throw new Exception("Installation is incomplete. The log above shows the reason. You can copy this log to support and rerun setup.");
        }
      });
      Append("Reader is ready. Finish any required Apple/OEM driver step, then click Test connected phone. This has not yet verified a phone.");
    } catch(Exception ex) { Append(ex.Message); }
    finally { Busy(false); }
  }
  private async Task TestPhone() {
    Busy(true);Append("Checking one connected phone...");
    try {
      string result=await Task.Run(()=>{
        var req=WebRequest.CreateHttp("http://127.0.0.1:51892/v1/device");req.Proxy=null;req.Timeout=25000;
        using(var response=req.GetResponse()) using(var stream=response.GetResponseStream()) using(var reader=new StreamReader(stream)) return reader.ReadToEnd();
      });
      var json=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(result);
      object ok;object raw;
      if(json.TryGetValue("ok",out ok) && ok is bool && (bool)ok && json.TryGetValue("device",out raw) && raw is Dictionary<string,object>){
        var device=(Dictionary<string,object>)raw;object imei;
        if(device.TryGetValue("imei",out imei) && System.Text.RegularExpressions.Regex.IsMatch(Convert.ToString(imei),@"^\d{15}$")){
          Append("PHONE COMMUNICATION VERIFIED. Available details can now appear in Greenloop. Review before Save. No identifiers were added to this log.");return;
        }
      }
      Append("Phone details are not ready. Unlock one phone, check the data cable, finish its driver setup and accept Trust / USB debugging. Some Android phones do not expose IMEI by cable; use manual entry for unavailable fields.");
    } catch(Exception){Append("Phone could not be read. Install/start the reader first, then check the cable, USB driver and Trust / Allow prompt. A running reader alone does not confirm a phone connection.");}
    finally {Busy(false);}
  }
  [STAThread] private static void Main(){Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);Application.Run(new SetupForm());}
}
