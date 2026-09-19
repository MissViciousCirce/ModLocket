// Windows-only owned worker. No process-name matching and no breakaway permission.
using System;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
namespace ModLocket {
 public sealed class OwnedWorker : IDisposable {
  [StructLayout(LayoutKind.Sequential)] struct BasicLimit {
   public long ProcessTime, JobTime; public uint Flags;
   public UIntPtr MinWorkingSet, MaxWorkingSet; public uint ActiveLimit;
   public UIntPtr Affinity; public uint Priority, Scheduling;
  }
  [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong A,B,C,D,E,F; }
  [StructLayout(LayoutKind.Sequential)] struct ExtendedLimit {
   public BasicLimit Basic; public IoCounters Io;
   public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob;
  }
  [StructLayout(LayoutKind.Sequential)] struct Accounting {
   public long A,B,C,D; public uint Faults,Total,Active,Terminated;
  }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes,string name);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref ExtendedLimit info,uint size);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int kind,out Accounting info,uint size,IntPtr length);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint code);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  IntPtr job;
  Process process;
  EventWaitHandle gate;
  readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();
  volatile bool outputEnded, errorEnded;
  public bool Cancelled {get; private set;}
  public int ProcessId {get {return process.Id;}}
  public uint ActiveCount { get {
   if(job==IntPtr.Zero) return 0;
   Accounting value;
   if(!QueryInformationJobObject(job,1,out value,(uint)Marshal.SizeOf(typeof(Accounting)),IntPtr.Zero)) throw new Win32Exception();
   return value.Active;
  }}
  public bool Finished {get {return process.HasExited && ActiveCount==0 && outputEnded && errorEnded;}}
  public int ExitCode {get {return process.ExitCode;}}
  public string[] Drain() {
   var result = new System.Collections.Generic.List<string>(); string line;
   while(lines.TryDequeue(out line)) result.Add(line);
   return result.ToArray();
  }
  public static OwnedWorker Start(string executable,string command,string bootstrapPath) {
   var worker=new OwnedWorker();
   try {
    worker.job=CreateJobObject(IntPtr.Zero,null);
    if(worker.job==IntPtr.Zero) throw new Win32Exception();
    var limit=new ExtendedLimit(); limit.Basic.Flags=0x2000; // KILL_ON_JOB_CLOSE
    if(!SetInformationJobObject(worker.job,9,ref limit,(uint)Marshal.SizeOf(typeof(ExtendedLimit)))) throw new Win32Exception();
    string gateName="Local\\ModLocket-"+Guid.NewGuid().ToString("N");
    worker.gate=new EventWaitHandle(false,EventResetMode.ManualReset,gateName);
    {
     // No user work can run until assignment succeeds. A lost parent means timeout,
     // or kernel job termination after assignment. No inherited job handles.
     if(string.IsNullOrEmpty(bootstrapPath) || bootstrapPath.IndexOf('"')>=0 || !System.IO.File.Exists(bootstrapPath))
      throw new ArgumentException("Worker bootstrap script is missing or invalid.");
     string arguments="-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -File \""+System.IO.Path.GetFullPath(bootstrapPath)+"\" -GateName \""+gateName+"\" -CommandBase64 "+Convert.ToBase64String(Encoding.Unicode.GetBytes(command));
     var start=new ProcessStartInfo(executable,arguments);
     start.UseShellExecute=false; start.CreateNoWindow=true;
     start.RedirectStandardOutput=true; start.RedirectStandardError=true;
     worker.process=new Process(); worker.process.StartInfo=start;
     worker.process.OutputDataReceived+=(s,e)=>{if(e.Data==null) worker.outputEnded=true; else worker.lines.Enqueue(e.Data);};
     worker.process.ErrorDataReceived+=(s,e)=>{if(e.Data==null) worker.errorEnded=true; else worker.lines.Enqueue("[ERROR] "+e.Data);};
     if(!worker.process.Start()) throw new InvalidOperationException("Could not start the worker.");
     if(!AssignProcessToJobObject(worker.job,worker.process.Handle)) {
      int code=Marshal.GetLastWin32Error();
      try {worker.process.Kill();} catch(InvalidOperationException) {}
      throw new Win32Exception(code,"Could not contain the worker; the operation was not started.");
     }
     worker.process.BeginOutputReadLine(); worker.process.BeginErrorReadLine();
     worker.gate.Set();
    }
    return worker;
   } catch {worker.Dispose(); throw;}
  }
  public void Stop() {
   Cancelled=true;
   if(job!=IntPtr.Zero && !TerminateJobObject(job,1223)) throw new Win32Exception();
  }
  public void Dispose() {
   if(job!=IntPtr.Zero) {CloseHandle(job); job=IntPtr.Zero;}
   if(process!=null) {process.Dispose(); process=null;}
   if(gate!=null) {gate.Dispose(); gate=null;}
  }
 }
}
