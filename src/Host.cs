using System;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

// Hosts the embedded NetRefresh.ps1 in-process: no powershell.exe, no console window, no self-relaunch.
static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        bool created;
        using (Mutex one = new Mutex(true, "Global\\NetRefreshSingleInstance", out created))
        {
            if (!created) return;   // already running

            string script;
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("NetRefresh.ps1"))
            using (StreamReader r = new StreamReader(s)) script = r.ReadToEnd();

            string dir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;   // lets the NetAdapter/ScheduledTasks modules load
            iss.ApartmentState = ApartmentState.STA;
            iss.ThreadOptions = PSThreadOptions.UseCurrentThread;

            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.Open();
                rs.SessionStateProxy.SetVariable("ExeDir", dir);
                rs.SessionStateProxy.SetVariable("ExePath", Application.ExecutablePath);
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddScript(script);
                    foreach (string a in args) if (a.StartsWith("-")) ps.AddParameter(a.TrimStart('-'));   // -Boot, -Preview
                    try { ps.Invoke(); } catch (Exception e) { Fail(dir, e.ToString()); return; }
                    if (ps.Streams.Error.Count > 0)
                    {
                        string all = "";
                        foreach (ErrorRecord er in ps.Streams.Error) all += er.ToString() + "\r\n" + er.ScriptStackTrace + "\r\n\r\n";
                        Fail(dir, all);
                    }
                }
            }
        }
    }

    static void Fail(string dir, string text)
    {
        try { File.WriteAllText(Path.Combine(dir, "crash.log"), text); } catch { }
        MessageBox.Show("NetRefresh stopped:\r\n\r\n" + text.Substring(0, Math.Min(text.Length, 800)) + "\r\n\r\n(saved to crash.log)", "NetRefresh");
    }
}
