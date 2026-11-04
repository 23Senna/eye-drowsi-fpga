using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

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
    private CancellationTokenSource? liveCancellation;
    private Task? liveTask;
    private string cameraStatus = "Camera: waiting";
    private string fpgaStatus = "FPGA: waiting";

    public MainForm()
    {
        repositoryRoot = FindRepositoryRoot();
        Text = "Eye Drowsiness  |  Basys 3 Control";
        MinimumSize = new Size(920, 620);
        Size = new Size(1060, 700);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(245, 247, 250);
        Font = new Font("Segoe UI", 9F);

        BuildLayout();
        captureRefreshTimer.Tick += (_, _) => LoadCapturedImages();
        LoadPorts();
        UpdateActionState();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            operationCancellation?.Cancel();
            liveCancellation?.Cancel();
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
            Height = 190,
            Padding = new Padding(4, 2, 4, 0),
            ColumnCount = 3,
            RowCount = 5
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
        frameBox.Value = 1;
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

        var imageCard = CreateCard("CAPTURED IMAGES", out var previewContent);
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

        if (repositoryRoot is null)
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
        if (liveTask is not null && !liveTask.IsCompleted)
        {
            await StopLiveAsync();
            return;
        }

        if (repositoryRoot is null || portBox.SelectedItem is null)
        {
            resultLabel.Text = "Select a serial port before starting live detection.";
            return;
        }

        var outputDirectory = Path.Combine(repositoryRoot, "eye_dataset");
        if (Directory.Exists(outputDirectory))
            Directory.Delete(outputDirectory, recursive: true);
        Directory.CreateDirectory(Path.Combine(outputDirectory, "left"));
        capturedImages.Items.Clear();
        imagePathBox.Clear();

        liveCancellation = new CancellationTokenSource();
        liveButton.Text = "Stop live detection";
        captureButton.Enabled = false;
        uploadButton.Enabled = false;
        runSlotButton.Enabled = false;
        resultLabel.Text = "Live detection running at 10 FPS.";

        _ = RunProcessAsync(
            GetPythonExecutable(),
            ["eye_capture.py", "--out-dir", "eye_dataset", "--record"],
            liveCancellation.Token,
            UpdateCameraStatus);
        liveTask = LiveUploadLoopAsync(outputDirectory, liveCancellation.Token);
        try
        {
            try
            {
                await liveTask;
            }
            catch (OperationCanceledException)
            {
            }
        }
        finally
        {
            await StopLiveAsync();
        }
    }

    private async Task LiveUploadLoopAsync(string outputDirectory, CancellationToken cancellationToken)
    {
        var sent = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var nextFrameId = (int)frameBox.Value;
        while (!cancellationToken.IsCancellationRequested)
        {
            if (captureProcess is null)
            {
                await Task.Delay(50, cancellationToken);
                continue;
            }
            if (captureProcess.HasExited)
                return;

            var files = Directory.EnumerateFiles(
                    Path.Combine(outputDirectory, "left"), "*.png", SearchOption.TopDirectoryOnly)
                .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
                .ToArray();

            foreach (var image in files)
            {
                if (!sent.Add(image))
                    continue;

                await WaitForStableFileAsync(image, cancellationToken);
                await RunCliAsync(
                    ["upload", "--image", image, "--frame-id", nextFrameId.ToString()],
                    updateResult: true,
                    onOutput: null);
                nextFrameId = (nextFrameId + 1) & 0xFFFF;
                if (frameBox.Value < frameBox.Maximum)
                    frameBox.Value++;

                if (cancellationToken.IsCancellationRequested)
                    break;
            }

            await Task.Delay(50, cancellationToken);
        }
    }

    private async Task StopLiveAsync()
    {
        liveCancellation?.Cancel();
        operationCancellation?.Cancel();
        StopCaptureProcess();
        if (liveTask is not null && !liveTask.IsCompleted)
        {
            try
            {
                await liveTask;
            }
            catch (OperationCanceledException)
            {
            }
        }

        liveTask = null;
        liveCancellation?.Dispose();
        liveCancellation = null;
        liveButton.Text = "Start live 10 FPS";
        captureButton.Enabled = true;
        UpdateActionState();
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
        if (repositoryRoot is null)
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
        var liveActive = liveTask is not null && !liveTask.IsCompleted;
        uploadButton.Enabled = portBox.SelectedItem is not null &&
            !liveActive &&
            (capturedImages.SelectedItems.Count > 0 || !string.IsNullOrWhiteSpace(imagePathBox.Text));
        runSlotButton.Enabled = portBox.SelectedItem is not null && !liveActive;
        liveButton.Enabled = liveActive || portBox.SelectedItem is not null;
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
