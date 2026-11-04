using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using System.Text.Json;

namespace EyeDrowsinessControl;

public sealed class MainForm : Form
{
    private readonly ComboBox portBox = new();
    private readonly NumericUpDown slotBox = new();
    private readonly NumericUpDown frameBox = new();
    private readonly TextBox imagePathBox = new();
    private readonly PictureBox preview = new();
    private readonly Label resultLabel = new();
    private readonly TextBox logBox = new();
    private readonly ListBox capturedImages = new();
    private readonly Button uploadButton = new();
    private readonly Button runSlotButton = new();
    private readonly Button liveButton = new();
    private readonly Button captureButton = new();
    private readonly System.Windows.Forms.Timer captureRefreshTimer = new() { Interval = 500 };
    private readonly string? repositoryRoot;
    private CancellationTokenSource? operationCancellation;
    private Image? previewImage;
    private Process? captureProcess;
    private Process? liveProcess;
    private readonly NumericUpDown cameraBox = new() { Minimum = 0, Maximum = 10, Width = 80 };
    private readonly Button resumeLiveButton = new() { Text = "Resume live", AutoSize = true };
    private bool liveStopping;
    private bool closingAfterLive;
    private bool cliBusy;
    private Task? liveTask;
    private string cameraStatus = "Camera: waiting";
    private string fpgaStatus = "FPGA: waiting";

    public MainForm()
    {
        repositoryRoot = FindRepositoryRoot();
        Text = "Eye Drowsiness  |  Basys 3 Control";
        MinimumSize = new Size(1040, 760);
        Size = new Size(1180, 820);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(245, 247, 250);
        Font = new Font("Segoe UI", 9F);

        BuildLayout();
        FormClosing += async (_, e) =>
        {
            if (liveProcess is not null && !closingAfterLive)
            {
                e.Cancel = true;
                await StopLiveAsync();
                closingAfterLive = true;
                Close();
            }
        };
        captureRefreshTimer.Tick += (_, _) => LoadCapturedImages();
        LoadPorts();
        UpdateActionState();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            operationCancellation?.Cancel();
            if (liveProcess is { HasExited: false }) liveProcess.Kill(entireProcessTree: true);
            StopCaptureProcess();
            captureRefreshTimer.Stop();
            previewImage?.Dispose();
        }
        base.Dispose(disposing);
    }

    private void BuildLayout()
    {
        var header = new Panel { Dock = DockStyle.Top, Height = 82, BackColor = Color.FromArgb(20, 35, 55) };
        var title = new Label
        {
            Text = "EYE DROWSINESS",
            ForeColor = Color.White,
            Font = new Font("Segoe UI Semibold", 18F),
            Location = new Point(28, 14),
            AutoSize = true
        };
        var subtitle = new Label
        {
            Text = "Basys 3 FPGA control center",
            ForeColor = Color.FromArgb(185, 202, 220),
            Location = new Point(31, 49),
            AutoSize = true
        };
        header.Controls.AddRange([title, subtitle]);

        var main = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(24, 20, 24, 18),
            ColumnCount = 2,
            RowCount = 2,
            BackColor = BackColor
        };
        main.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 57));
        main.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 43));
        main.RowStyles.Add(new RowStyle(SizeType.Percent, 58));
        main.RowStyles.Add(new RowStyle(SizeType.Percent, 42));

        var setup = CreateCard("CONNECTION & IMAGE", out var setupContent);
        var setupGrid = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            Height = 226,
            Padding = new Padding(4, 2, 4, 0),
            ColumnCount = 3,
            RowCount = 6
        };
        setupGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 115));
        setupGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        setupGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 105));
        for (var row = 0; row < setupGrid.RowCount; row++)
            setupGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        setupGrid.Controls.Add(FieldLabel("Serial port"), 0, 0);
        portBox.DropDownStyle = ComboBoxStyle.DropDownList;
        portBox.Dock = DockStyle.Fill;
        portBox.SelectedIndexChanged += (_, _) => UpdateActionState();
        setupGrid.Controls.Add(portBox, 1, 0);
        var refresh = SecondaryButton("Refresh");
        refresh.Click += (_, _) => LoadPorts();
        setupGrid.Controls.Add(refresh, 2, 0);

        setupGrid.Controls.Add(FieldLabel("Frame ID"), 0, 1);
        frameBox.Minimum = 0;
        frameBox.Maximum = 65535;
        frameBox.Value = 12000;
        frameBox.Dock = DockStyle.Left;
        frameBox.Width = 130;
        setupGrid.Controls.Add(frameBox, 1, 1);
        setupGrid.Controls.Add(FieldLabel("0–65535"), 2, 1);

        setupGrid.Controls.Add(FieldLabel("Eye crop"), 0, 2);
        imagePathBox.ReadOnly = true;
        imagePathBox.Dock = DockStyle.Fill;
        setupGrid.Controls.Add(imagePathBox, 1, 2);
        var browse = SecondaryButton("Choose...");
        browse.Click += (_, _) => ChooseImage();
        setupGrid.Controls.Add(browse, 2, 2);

        setupGrid.Controls.Add(FieldLabel("ROM slot"), 0, 3);
        slotBox.Minimum = 0;
        slotBox.Maximum = 15;
        slotBox.Dock = DockStyle.Left;
        slotBox.Width = 130;
        setupGrid.Controls.Add(slotBox, 1, 3);
        setupGrid.Controls.Add(FieldLabel("0–15"), 2, 3);

        captureButton.Text = "Start camera capture";
        captureButton.Width = 170;
        captureButton.Height = 30;
        captureButton.Click += async (_, _) => await ToggleCaptureAsync();
        setupGrid.Controls.Add(captureButton, 1, 4);
        resumeLiveButton.Enabled = false;
        resumeLiveButton.Click += async (_, _) => await SendLiveCommandAsync("START");
        setupGrid.Controls.Add(resumeLiveButton, 2, 4);
        setupGrid.Controls.Add(FieldLabel("Camera index"), 0, 5);
        setupGrid.Controls.Add(cameraBox, 1, 5);

        var actions = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            Height = 54,
            Padding = new Padding(4, 8, 0, 0),
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false
        };
        uploadButton.Text = "Upload & classify";
        uploadButton.Width = 170;
        uploadButton.Height = 36;
        uploadButton.Click += async (_, _) => await UploadAsync();
        runSlotButton.Text = "Run ROM slot";
        runSlotButton.Width = 140;
        runSlotButton.Height = 36;
        runSlotButton.Click += async (_, _) => await RunSlotAsync();
        liveButton.Text = "Start live 10 FPS";
        liveButton.Width = 150;
        liveButton.Height = 36;
        liveButton.Click += async (_, _) => await ToggleLiveAsync();
        actions.Controls.AddRange([uploadButton, runSlotButton, liveButton]);
        setupContent.Controls.Add(setupGrid);
        setupContent.Controls.Add(actions);
        main.Controls.Add(setup, 0, 0);

        var imageCard = CreateCard("EYE INPUT / CAPTURED IMAGES", out var previewContent);
        preview.Dock = DockStyle.Fill;
        preview.BackColor = Color.FromArgb(232, 236, 241);
        preview.SizeMode = PictureBoxSizeMode.Zoom;
        preview.BorderStyle = BorderStyle.FixedSingle;
        capturedImages.Dock = DockStyle.Bottom;
        capturedImages.Height = 84;
        capturedImages.SelectionMode = SelectionMode.MultiExtended;
        capturedImages.SelectedIndexChanged += (_, _) => SelectCapturedImage();
        previewContent.Controls.Add(capturedImages);
        previewContent.Controls.Add(preview);
        main.Controls.Add(imageCard, 1, 0);

        var resultCard = CreateCard("LATEST RESULT", out var resultContent);
        resultLabel.Text = "Ready — connect the Basys 3 and choose an action.";
        resultLabel.Dock = DockStyle.Fill;
        resultLabel.Font = new Font("Segoe UI Semibold", 12F);
        resultLabel.ForeColor = Color.FromArgb(20, 35, 55);
        resultLabel.Padding = new Padding(8, 4, 8, 4);
        resultLabel.AutoEllipsis = true;
        resultContent.Controls.Add(resultLabel);
        main.Controls.Add(resultCard, 0, 1);

        var logCard = CreateCard("ACTIVITY", out var logContent);
        logBox.Multiline = true;
        logBox.ReadOnly = true;
        logBox.ScrollBars = ScrollBars.Vertical;
        logBox.Dock = DockStyle.Fill;
        logBox.BorderStyle = BorderStyle.FixedSingle;
        logBox.BackColor = Color.FromArgb(30, 37, 46);
        logBox.ForeColor = Color.FromArgb(218, 228, 238);
        logBox.Font = new Font("Consolas", 9F);
        logContent.Controls.Add(logBox);
        main.Controls.Add(logCard, 1, 1);

        Controls.Add(main);
        Controls.Add(header);
    }

    private static Panel CreateCard(string caption, out Panel content)
    {
        var card = new Panel
        {
            Dock = DockStyle.Fill,
            BackColor = Color.White,
            Padding = new Padding(16, 12, 16, 14),
            Margin = new Padding(8)
        };
        var label = new Label
        {
            Text = caption,
            Dock = DockStyle.Top,
            Height = 30,
            ForeColor = Color.FromArgb(85, 100, 116),
            Font = new Font("Segoe UI Semibold", 9F),
            TextAlign = ContentAlignment.MiddleLeft
        };
        content = new Panel { Dock = DockStyle.Fill, Padding = new Padding(0, 4, 0, 0) };
        card.Controls.Add(content);
        card.Controls.Add(label);
        return card;
    }

    private static Label FieldLabel(string text) => new()
    {
        Text = text,
        AutoSize = true,
        Anchor = AnchorStyles.Left,
        Padding = new Padding(0, 0, 0, 0),
        TextAlign = ContentAlignment.MiddleLeft
    };

    private static Button SecondaryButton(string text) => new() { Text = text, AutoSize = true, Height = 30, FlatStyle = FlatStyle.Flat };

    private void LoadPorts()
    {
        if (liveTask is not null) return;
        portBox.Items.Clear();
        if (repositoryRoot is null)
        {
            AppendLog("Repository root not found. Run the app from this repository.");
            return;
        }

        _ = RunCliAsync(["ports"], updateResult: false, onOutput: line =>
        {
            var port = line.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries)[0];
            if (port.StartsWith("COM", StringComparison.OrdinalIgnoreCase) && !portBox.Items.Contains(port))
                portBox.Items.Add(port);
        });
    }

    private void ChooseImage()
    {
        using var dialog = new OpenFileDialog
        {
            Title = "Choose a 24 x 24 eye crop",
            Filter = "Eye images|*.png;*.jpg;*.jpeg;*.bmp;*.raw;*.bin|All files|*.*"
        };
        if (dialog.ShowDialog(this) != DialogResult.OK)
            return;

        capturedImages.ClearSelected();
        imagePathBox.Text = dialog.FileName;
        try
        {
            using var loaded = Image.FromFile(dialog.FileName);
            previewImage?.Dispose();
            previewImage = new Bitmap(loaded);
            preview.Image = previewImage;
            resultLabel.Text = "Image selected. Ready to upload.";
        }
        catch (Exception ex) when (ex is ArgumentException or OutOfMemoryException)
        {
            resultLabel.Text = "Selected file is not a previewable image.";
            AppendLog(ex.Message);
        }
        UpdateActionState();
    }

    private async Task ToggleCaptureAsync()
    {
        if (captureProcess is not null && !captureProcess.HasExited)
        {
            StopCaptureProcess();
            return;
        }

        if (repositoryRoot is null || liveTask is not null)
            return;

        var outputDirectory = Path.Combine(repositoryRoot, "eye_dataset");
        if (Directory.Exists(outputDirectory))
            Directory.Delete(outputDirectory, recursive: true);
        capturedImages.Items.Clear();
        imagePathBox.Clear();
        resultLabel.Text = "Camera is ready. Press SPACE in the camera window to capture, Q or Close to stop.";
        captureButton.Text = "Stop camera capture";
        captureRefreshTimer.Start();
        try
        {
            await RunProcessAsync(
                GetPythonExecutable(),
                ["eye_capture.py", "--out-dir", "eye_dataset"],
                CancellationToken.None,
                UpdateCameraStatus);
        }
        finally
        {
            captureRefreshTimer.Stop();
            captureButton.Text = "Start camera capture";
            LoadCapturedImages();
        }
    }

    private async Task ToggleLiveAsync()
    {
        if (liveTask is not null)
        {
            await StopLiveAsync();
            return;
        }
        if (repositoryRoot is null || portBox.SelectedItem is null) return;
        if (captureProcess is { HasExited: false })
        {
            resultLabel.Text = "Stop camera capture before starting live.";
            return;
        }
        var python = Path.Combine(repositoryRoot, ".venv-camera", "Scripts", "python.exe");
        if (!File.Exists(python))
        {
            resultLabel.Text = "Prepare .venv-camera using tools/requirements-live.txt first.";
            return;
        }
        cameraStatus = "Live: starting | Reyn | Y +0.10 | diagnostics saves eye crops";
        fpgaStatus = "FPGA: waiting (reset btnU first, SW9 up / SW13 down)";
        RefreshResultText();
        liveButton.Text = "Stop live detection";
        captureButton.Enabled = portBox.Enabled = frameBox.Enabled = cameraBox.Enabled = false;
        uploadButton.Enabled = runSlotButton.Enabled = false;
        liveTask = RunLiveProcessAsync(python, portBox.SelectedItem.ToString()!, (int)frameBox.Value, (int)cameraBox.Value);
        try { await liveTask; }
        finally
        {
            liveTask = null;
            liveButton.Text = "Start live 10 FPS";
            captureButton.Enabled = portBox.Enabled = frameBox.Enabled = cameraBox.Enabled = true;
            resumeLiveButton.Enabled = false;
            cameraStatus = "Live stopped; reset btnU before the next session";
            fpgaStatus = "FPGA: no current live result; board warning may persist until reset";
            RefreshResultText();
            UpdateActionState();
        }
    }

    private async Task RunLiveProcessAsync(string python, string port, int frameId, int camera)
    {
        var info = new ProcessStartInfo(python)
        {
            WorkingDirectory = repositoryRoot!, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        string[] arguments = ["-u", "tools/live_webcam.py", "--camera", camera.ToString(), "--port", port,
            "--eye", "left", "--fps", "10", "--frame-id", frameId.ToString(), "--roi-style", "reyn",
            "--crop-offset-y", "0.10", "--diagnostics", "--gui-control"];
        foreach (var arg in arguments) info.ArgumentList.Add(arg);
        AppendLog("$ " + python + " " + string.Join(" ", arguments));
        using var process = new Process { StartInfo = info };
        try
        {
            process.Start();
            liveProcess = process;
            var stdout = ReadLiveOutputAsync(process.StandardOutput, true);
            var stderr = ReadLiveOutputAsync(process.StandardError, false);
            await SendLiveCommandAsync("START");
            await process.WaitForExitAsync();
            await Task.WhenAll(stdout, stderr);
            AppendLog($"Live client exited: {process.ExitCode}");
        }
        catch (Exception ex) { AppendLog("Live error: " + ex.Message); }
        finally { liveProcess = null; }
    }

    private async Task ReadLiveOutputAsync(StreamReader reader, bool events)
    {
        while (await reader.ReadLineAsync() is { } line)
        {
            if (IsDisposed) return;
            if (events && line.StartsWith("LIVE_EVENT ", StringComparison.Ordinal))
            {
                try
                {
                    using var document = JsonDocument.Parse(line[11..]);
                    HandleLiveEvent(document.RootElement);
                }
                catch (Exception ex) when (ex is JsonException or IOException or ArgumentException)
                { AppendLog("Live event error: " + ex.Message); }
            }
            else if (!events || line.StartsWith("Session log:") || line.StartsWith("Eye crop:")) AppendLog(line);
        }
    }

    private void HandleLiveEvent(JsonElement data)
    {
        var kind = data.GetProperty("event").GetString();
        if (kind == "result")
        {
            var result = data.GetProperty("result");
            var id = result.GetProperty("frame_id").GetInt32();
            frameBox.Value = Math.Min(id + 1, 65535);
            fpgaStatus = $"FPGA #{id}: {result.GetProperty("eye_class").GetString()} | {result.GetProperty("warning").GetString()} | {data.GetProperty("roundtrip_ms").GetDouble():F1} ms";
            cameraStatus = "Live: Reyn | Y +0.10 | " + (data.GetProperty("golden_match").GetBoolean() ? "Golden MATCH" : "Golden MISMATCH");
            var raw = File.ReadAllBytes(data.GetProperty("input_raw").GetString()!);
            if (raw.Length != 576) throw new IOException("Expected 576 crop bytes");
            var bitmap = new Bitmap(24, 24);
            for (var y = 0; y < 24; y++)
                for (var x = 0; x < 24; x++)
                {
                    var value = raw[y * 24 + x];
                    bitmap.SetPixel(x, y, Color.FromArgb(value, value, value));
                }
            preview.Image = bitmap;
            previewImage?.Dispose();
            previewImage = bitmap;
            AppendLog(fpgaStatus + " | " + cameraStatus);
        }
        else if (kind == "live_state")
        {
            var running = data.GetProperty("running").GetBoolean();
            var stale = data.GetProperty("stale").GetBoolean();
            var busy = data.GetProperty("busy").GetBoolean();
            resumeLiveButton.Enabled = !running && !busy && !liveStopping;
            cameraStatus = running ? "Live: " + (busy ? "UART busy" : "UART idle") : data.GetProperty("status").GetString()!;
            if (stale) fpgaStatus = "FPGA: no fresh live result";
        }
        else if (kind == "gap_pause" || kind == "error")
        {
            fpgaStatus = "FPGA: no current live result";
            cameraStatus = kind == "error" ? data.GetProperty("message").GetString()! : "Gap: wait UART idle, reset btnU, then Resume live";
            AppendLog(cameraStatus);
        }
        else if (kind == "session_end") AppendLog("Session ended. Reset btnU before restarting.");
        RefreshResultText();
    }

    private async Task SendLiveCommandAsync(string command)
    {
        try
        {
            if (liveProcess is { HasExited: false })
            {
                await liveProcess.StandardInput.WriteLineAsync(command);
                await liveProcess.StandardInput.FlushAsync();
            }
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException)
        { AppendLog("Live command: " + ex.Message); }
    }

    private async Task StopLiveAsync()
    {
        if (liveTask is null) return;
        if (liveStopping) { await liveTask; return; }
        liveStopping = true;
        liveButton.Enabled = resumeLiveButton.Enabled = false;
        try
        {
            await SendLiveCommandAsync("STOP");
            try { await liveTask.WaitAsync(TimeSpan.FromSeconds(10)); }
            catch (TimeoutException)
            {
                AppendLog("Live client did not drain in 10s; terminating. Reset board before reconnecting.");
                if (liveProcess is { HasExited: false }) liveProcess.Kill(entireProcessTree: true);
                if (liveTask is not null) await liveTask;
            }
        }
        finally { liveStopping = false; UpdateActionState(); }
    }

    private void StopCaptureProcess()
    {
        if (captureProcess is null || captureProcess.HasExited)
            return;
        try
        {
            captureProcess.Kill(entireProcessTree: true);
            captureProcess.WaitForExit(1000);
        }
        catch (InvalidOperationException)
        {
        }
        captureProcess = null;
        captureButton.Text = "Start camera capture";
    }

    private void LoadCapturedImages()
    {
        if (repositoryRoot is null)
            return;
        var outputDirectory = Path.Combine(repositoryRoot, "eye_dataset");
        if (!Directory.Exists(outputDirectory))
            return;
        var before = capturedImages.Items.Count;
        var files = Directory.EnumerateFiles(outputDirectory, "*.png", SearchOption.AllDirectories)
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase);
        foreach (var file in files)
        {
            if (!capturedImages.Items.Contains(file))
                capturedImages.Items.Add(file);
        }
        if (capturedImages.Items.Count > 0 && capturedImages.SelectedItems.Count == 0)
            capturedImages.SetSelected(0, true);
        if (capturedImages.Items.Count != before)
            AppendLog($"Loaded {capturedImages.Items.Count} captured eye crop(s). Select one or more.");
    }

    private void SelectCapturedImage()
    {
        if (capturedImages.SelectedItems.Count == 0)
            return;
        imagePathBox.Text = capturedImages.SelectedItems[0]?.ToString() ?? string.Empty;
        try
        {
            using var loaded = Image.FromFile(imagePathBox.Text);
            previewImage?.Dispose();
            previewImage = new Bitmap(loaded);
            preview.Image = previewImage;
        }
        catch (Exception ex) when (ex is ArgumentException or OutOfMemoryException)
        {
            AppendLog("Could not preview selected image: " + ex.Message);
        }
        UpdateActionState();
    }

    private async Task UploadAsync()
    {
        if (capturedImages.SelectedItems.Count == 0 && string.IsNullOrWhiteSpace(imagePathBox.Text))
            return;
        var images = capturedImages.SelectedItems.Count > 0
            ? capturedImages.SelectedItems.Cast<string>().ToArray()
            : [imagePathBox.Text];
        foreach (var image in images)
        {
            await RunCliAsync(["upload", "--image", image, "--frame-id", frameBox.Value.ToString()], true, null);
            if (frameBox.Value < frameBox.Maximum)
                frameBox.Value++;
        }
    }

    private async Task RunSlotAsync()
    {
        await RunCliAsync(["run", "--slot", slotBox.Value.ToString()], true, null);
    }

    private async Task RunCliAsync(string[] arguments, bool updateResult, Action<string>? onOutput)
    {
        if (repositoryRoot is null || liveTask is not null)
            return;

        var isPortDiscovery = arguments.Length == 1 && arguments[0] == "ports";
        if (!isPortDiscovery && portBox.SelectedItem is null)
        {
            resultLabel.Text = "Select a serial port first.";
            return;
        }

        SetBusy(true);
        operationCancellation = new CancellationTokenSource();
        var cliArguments = new List<string>();
        if (!isPortDiscovery)
            cliArguments.AddRange(["--port", portBox.SelectedItem!.ToString()!, "--baud", "115200", "--timeout", "2", "--quiet"]);
        cliArguments.AddRange(arguments);
        var exitCode = await RunProcessAsync(GetPythonExecutable(), ["tools\\uart_cli.py", .. cliArguments], operationCancellation.Token, onOutput);
        if (updateResult && exitCode == 0 && liveTask is null)
            fpgaStatus = "FPGA: classification completed";
        else if (updateResult && exitCode != 0)
            resultLabel.Text = "Operation failed. Check the activity log.";
        SetBusy(false);
        UpdateActionState();
    }

    private async Task<int> RunProcessAsync(string executable, IEnumerable<string> arguments, CancellationToken cancellationToken, Action<string>? onOutput = null)
    {
        var info = new ProcessStartInfo(executable)
        {
            WorkingDirectory = repositoryRoot ?? AppContext.BaseDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        foreach (var argument in arguments)
            info.ArgumentList.Add(argument);

        AppendLog("$ " + executable + " " + string.Join(" ", arguments));
        using var process = new Process { StartInfo = info, EnableRaisingEvents = true };
        var isCapture = arguments.FirstOrDefault() == "eye_capture.py";
        if (isCapture)
            captureProcess = process;
        process.OutputDataReceived += (_, e) => DispatchProcessOutput(e.Data, onOutput);
        process.ErrorDataReceived += (_, e) => AppendLog(e.Data);
        try
        {
            if (!process.Start())
                throw new InvalidOperationException("Could not start the host command.");
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            await process.WaitForExitAsync(cancellationToken);
            return process.ExitCode;
        }
        catch (OperationCanceledException)
        {
            AppendLog("Operation cancelled.");
            return -1;
        }
        catch (Exception ex)
        {
            AppendLog("ERROR: " + ex.Message);
            return -1;
        }
        finally
        {
            if (isCapture && ReferenceEquals(captureProcess, process))
                captureProcess = null;
        }
    }

    private void DispatchProcessOutput(string? line, Action<string>? onOutput)
    {
        if (string.IsNullOrWhiteSpace(line))
            return;

        if (onOutput is null)
        {
            AppendLog(line);
            return;
        }

        if (InvokeRequired)
        {
            if (!IsDisposed)
                BeginInvoke(() => onOutput(line));
            return;
        }

        onOutput(line);
    }

    private void UpdateCameraStatus(string line)
    {
        if (!line.StartsWith("CAMERA ", StringComparison.Ordinal))
        {
            if (line.StartsWith("ERROR", StringComparison.Ordinal) ||
                line.StartsWith("Traceback", StringComparison.Ordinal))
                AppendLog(line);
            return;
        }

        var match = Regex.Match(line, @"^CAMERA left=(OPEN|CLOSED) right=(OPEN|CLOSED) state=(AWAKE|DROWSY|SLEEPING|NO FACE)$");
        if (match.Success)
        {
            cameraStatus =
                $"Camera  L:{match.Groups[1].Value}  R:{match.Groups[2].Value}  " +
                $"State: {match.Groups[3].Value}";
            RefreshResultText();
        }
    }

    private void RefreshResultText()
    {
        resultLabel.Text = cameraStatus + Environment.NewLine + fpgaStatus;
    }

    private string GetPythonExecutable()
    {
        var camera = Path.Combine(repositoryRoot ?? string.Empty, ".venv-camera", "Scripts", "python.exe");
        if (File.Exists(camera)) return camera;
        var local = Path.Combine(repositoryRoot ?? string.Empty, ".venv", "Scripts", "python.exe");
        return File.Exists(local) ? local : "python";
    }

    private void AppendLog(string? line)
    {
        if (string.IsNullOrWhiteSpace(line))
            return;
        if (InvokeRequired)
        {
            BeginInvoke(() => AppendLog(line));
            return;
        }
        logBox.AppendText($"[{DateTime.Now:HH:mm:ss}] {line}{Environment.NewLine}");
        var match = Regex.Match(line, @"RESULT source=.* class=(OPEN|CLOSED) warning=(AWAKE|DROWSY|MICROSLEEP).*");
        if (match.Success)
        {
            var warning = match.Groups[2].Value switch
            {
                "MICROSLEEP" => "SLEEP",
                "DROWSY" => "TIRED",
                var value => value
            };
            fpgaStatus = $"FPGA: {match.Groups[1].Value}  |  {warning}";
            RefreshResultText();
        }
    }

    private void SetBusy(bool busy)
    {
        cliBusy = busy;
        uploadButton.Enabled = !busy;
        runSlotButton.Enabled = !busy;
        portBox.Enabled = !busy;
        liveButton.Enabled = !busy;
        if (liveTask is not null && !liveTask.IsCompleted)
            liveButton.Enabled = true;
        Cursor = busy ? Cursors.WaitCursor : Cursors.Default;
    }

    private static async Task WaitForStableFileAsync(string path, CancellationToken cancellationToken)
    {
        long previous = -1;
        for (var attempt = 0; attempt < 10; attempt++)
        {
            var current = new FileInfo(path).Length;
            if (current == previous && current > 0)
                return;
            previous = current;
            await Task.Delay(10, cancellationToken);
        }
    }

    private void UpdateActionState()
    {
        var liveActive = liveTask is not null;
        uploadButton.Enabled = !cliBusy && portBox.SelectedItem is not null &&
            !liveActive &&
            (capturedImages.SelectedItems.Count > 0 || !string.IsNullOrWhiteSpace(imagePathBox.Text));
        runSlotButton.Enabled = !cliBusy && portBox.SelectedItem is not null && !liveActive;
        liveButton.Enabled = !cliBusy && !liveStopping && (liveActive ||
            (portBox.SelectedItem is not null && captureProcess is null));
    }

    private string? FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "tools", "uart_cli.py")))
                return directory.FullName;
            directory = directory.Parent;
        }
        return null;
    }
}
