@echo off
rem Rebuilds NetRefresh.exe from NetRefresh.ps1 (embedded) using the C# compiler that ships with Windows.
cd /d "%~dp0"
"C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /out:NetRefresh.exe /win32manifest:src\app.manifest /win32icon:src\app.ico ^
 /reference:"C:\Windows\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation\v4.0_3.0.0.0__31bf3856ad364e35\System.Management.Automation.dll" ^
 /reference:System.Windows.Forms.dll /reference:System.ServiceProcess.dll /resource:NetRefresh.ps1,NetRefresh.ps1 src\Host.cs
if errorlevel 1 (echo BUILD FAILED) else (echo Built NetRefresh.exe)
pause
