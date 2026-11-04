using System.Reflection;
using System.Text.Json;
using EyeDrowsinessControl;

// No camera/board access: this executable also acts as a controlled child backend.
internal static class Program
{
    static readonly BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    static string Evidence => Path.Combine(Directory.GetCurrentDirectory(), "build", "gui_integration");
    static object? Call(object form, string name, params object[] args) =>
        form.GetType().GetMethod(name, Private)!.Invoke(form, args);
    static T Field<T>(object form, string name) => (T)form.GetType().GetField(name, Private)!.GetValue(form)!;
    static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    static void Emit(object value) => Console.WriteLine("LIVE_EVENT " + JsonSerializer.Serialize(value));

    [STAThread]
    static void Main(string[] args)
    {
        Directory.CreateDirectory(Evidence);
        if (args.FirstOrDefault() == "-u") { Backend(args); return; }
        ApplicationConfiguration.Initialize();
        using var form = new MainForm();
        form.Opacity = 0;
        form.ShowInTaskbar = false;
        form.Shown += async (_, _) =>
        {
            try
            {
                // Allow initial read-only COM discovery to finish.
                await Task.Delay(1500);
                var task = (Task)Call(form, "RunLiveProcessAsync", Environment.ProcessPath!, "FAKE", 12000, 0)!;
                form.GetType().GetField("liveTask", Private)!.SetValue(form, task);
                for (var n = 0; n < 100 && Field<NumericUpDown>(form,"frameBox").Value != 12001; n++) await Task.Delay(50);
                Check(Field<NumericUpDown>(form,"frameBox").Value == 12001, "Frame ID not propagated");
                Check(Field<Label>(form,"resultLabel").Text.Contains("CLOSED"), "FPGA class missing");
                Check(Field<PictureBox>(form,"preview").Image?.Width == 24, "Exact input preview missing");
                using (var bitmap = new Bitmap(form.Width,form.Height))
                {
                    form.DrawToBitmap(bitmap, new Rectangle(Point.Empty,form.Size));
                    bitmap.Save(Path.Combine(Evidence,"gui-smoke.png"));
                }
                using var gap = JsonDocument.Parse("{\"event\":\"live_state\",\"running\":false,\"stale\":true,\"face_available\":false,\"busy\":false,\"status\":\"Gap: reset then Resume live\"}");
                Call(form,"HandleLiveEvent",gap.RootElement);
                Check(Field<Label>(form,"resultLabel").Text.Contains("no fresh"),"Stale label not cleared");
                Check(Field<Button>(form,"resumeLiveButton").Enabled,"Resume not enabled after idle gap");
                await (Task)Call(form,"StopLiveAsync")!;
                Check(task.IsCompleted,"Child did not exit after STOP");
                var commands = File.ReadAllLines(Path.Combine(Evidence,"commands.txt"));
                Check(commands.SequenceEqual(new[]{"START","STOP"}),"Unexpected control commands");
                File.WriteAllText(Path.Combine(Evidence,"smoke-result.txt"),"PASS: GUI event/result/raw-preview/stale-resume/START-STOP process lifecycle; mock backend, no physical board/camera.");
                Console.WriteLine("PASS GUI bridge smoke");
            }
            catch (Exception ex) { Console.Error.WriteLine(ex); Environment.ExitCode=1; }
            finally
            {
                form.GetType().GetField("liveTask",Private)!.SetValue(form,null);
                form.Close();
            }
        };
        Application.Run(form);
    }

    static void Backend(string[] args)
    {
        Check(args.Contains("--gui-control") && args.Contains("reyn") && args.Contains("0.10"),"Wrong backend arguments");
        var raw = Path.Combine(Evidence,"mock-input.raw");
        File.WriteAllBytes(raw,Enumerable.Range(0,576).Select(n=>(byte)(60+n%176)).ToArray());
        using var commands = new StreamWriter(Path.Combine(Evidence,"commands.txt")) { AutoFlush=true };
        string? line;
        while ((line=Console.ReadLine()) is not null)
        {
            commands.WriteLine(line);
            if (line=="STOP") break;
            if (line!="START") continue;
            Emit(new { @event="result", result=new {frame_id=12000,eye_class="CLOSED",warning="MICROSLEEP"},
                golden_match=true,input_raw=raw,roundtrip_ms=94.0 });
        }
        Emit(new { @event="session_end",exit_code=0 });
    }
}
