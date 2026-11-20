using System;
using System.IO;
using System.Reflection;
using System.ServiceProcess;
using System.Threading;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

// Hosts the embedded NetRefresh.ps1 in-process: no powershell.exe, no console window.
//   NetRefresh.exe             the window (one per PC)
//   NetRefresh.exe --service   the Windows service: the headless watchdog
static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        if (Array.IndexOf(args, "--service") >= 0) { ServiceBase.Run(new WatchService()); return; }
        bool created;
        using (Mutex one = new Mutex(true, "Global\\NetRefreshWindow", out created))
        {
            if (!created) return;   // the window is already open
            RunScript(args, null, false);
        }
    }

    public static void RunScript(string[] args, ManualResetEvent stop, bool service)
    {
        string script;
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("NetRefresh.ps1"))
        using (StreamReader r = new StreamReader(s)) script = r.ReadToEnd();

        string exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        string crashDir = service ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "NetRefresh") : exeDir;
        InitialSessionState iss = InitialSessionState.CreateDefault();
        iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;   // lets the NetAdapter/ScheduledTasks modules load
        iss.ApartmentState = service ? ApartmentState.MTA : ApartmentState.STA;
        iss.ThreadOptions = PSThreadOptions.UseCurrentThread;

        using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
        {
            rs.Open();
            rs.SessionStateProxy.SetVariable("ExeDir", exeDir);
            rs.SessionStateProxy.SetVariable("ExePath", Application.ExecutablePath);
            rs.SessionStateProxy.SetVariable("StopEvent", stop);
            using (PowerShell ps = PowerShell.Create())
            {
                ps.Runspace = rs;
                ps.AddScript(script);
                if (service) ps.AddParameter("Service");
                else foreach (string a in args) if (a.StartsWith("-")) ps.AddParameter(a.TrimStart('-'));   // -Boot, -Preview
                // A script that runs for weeks must not keep every error and warning: keep only the last few.
                ps.Streams.Error.DataAdded += (o, e) => { var c = (PSDataCollection<ErrorRecord>)o; while (c.Count > 20) c.RemoveAt(0); };
                ps.Streams.Warning.DataAdded += (o, e) => { var c = (PSDataCollection<WarningRecord>)o; while (c.Count > 20) c.RemoveAt(0); };
                try { ps.Invoke(); } catch (Exception e) { Fail(crashDir, e.ToString(), service); return; }
                if (ps.HadErrors && ps.Streams.Error.Count > 0 && !service)
                {
                    string all = "";
                    foreach (ErrorRecord er in ps.Streams.Error) all += er.ToString() + "\r\n" + er.ScriptStackTrace + "\r\n\r\n";
                    Fail(crashDir, all, service);
                }
            }
        }
    }

    static void Fail(string dir, string text, bool service)
    {
        try { Directory.CreateDirectory(dir); File.WriteAllText(Path.Combine(dir, "crash.log"), text); } catch { }
        if (!service) MessageBox.Show("NetRefresh stopped:\r\n\r\n" + text.Substring(0, Math.Min(text.Length, 800)) + "\r\n\r\n(saved to crash.log)", "NetRefresh");
    }
}

// The watchdog as a Windows service: runs without anyone logged in, and Windows restarts it if it ever stops.
class WatchService : ServiceBase
{
    readonly ManualResetEvent stop = new ManualResetEvent(false);
    Thread worker;

    public WatchService() { ServiceName = "NetRefresh"; CanStop = true; CanShutdown = true; }

    protected override void OnStart(string[] args)
    {
        worker = new Thread(() => Program.RunScript(new string[0], stop, true));
        worker.IsBackground = true;
        worker.Start();
    }

    protected override void OnStop() { stop.Set(); if (worker != null) worker.Join(20000); }

    protected override void OnShutdown() { OnStop(); }
}
