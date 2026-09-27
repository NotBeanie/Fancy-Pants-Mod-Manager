Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class FancyNative {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@


Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.IO.Compression;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Collections.Generic;

public static class FancyArtSwf {
    private static ushort U16(byte[] b, int p) {
        return (ushort)(b[p] | (b[p + 1] << 8));
    }

    private static int I32(byte[] b, int p) {
        return b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24);
    }

    private static void W32(byte[] b, int p, int v) {
        b[p] = (byte)(v & 255);
        b[p + 1] = (byte)((v >> 8) & 255);
        b[p + 2] = (byte)((v >> 16) & 255);
        b[p + 3] = (byte)((v >> 24) & 255);
    }

    private static int TagStart(byte[] swf) {
        if (swf.Length < 16 || swf[0] != (byte)'F' || swf[1] != (byte)'W' || swf[2] != (byte)'S')
            throw new InvalidDataException("Build 11 art template must be an uncompressed FWS file.");
        int nbits = swf[8] >> 3;
        int rectBytes = (5 + 4 * nbits + 7) / 8;
        return 8 + rectBytes + 4;
    }

    private static uint Adler32(byte[] data) {
        const uint MOD = 65521;
        uint a = 1, b = 0;
        for (int i = 0; i < data.Length; i++) {
            a = (a + data[i]) % MOD;
            b = (b + a) % MOD;
        }
        return (b << 16) | a;
    }

    private static byte[] Zlib(byte[] data) {
        byte[] deflated;
        using (MemoryStream ms = new MemoryStream()) {
            using (DeflateStream ds = new DeflateStream(ms, CompressionLevel.Optimal, true)) {
                ds.Write(data, 0, data.Length);
            }
            deflated = ms.ToArray();
        }

        uint adler = Adler32(data);
        using (MemoryStream ms = new MemoryStream()) {
            ms.WriteByte(0x78);
            ms.WriteByte(0x9C);
            ms.Write(deflated, 0, deflated.Length);
            ms.WriteByte((byte)((adler >> 24) & 255));
            ms.WriteByte((byte)((adler >> 16) & 255));
            ms.WriteByte((byte)((adler >> 8) & 255));
            ms.WriteByte((byte)(adler & 255));
            return ms.ToArray();
        }
    }

    private static Bitmap LoadScaled(string path, int width, int height) {
        Bitmap dst = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(dst)) {
            g.Clear(Color.Transparent);
            if (!String.IsNullOrEmpty(path) && File.Exists(path)) {
                using (Bitmap src = new Bitmap(path)) {
                    g.InterpolationMode = InterpolationMode.NearestNeighbor;
                    g.PixelOffsetMode = PixelOffsetMode.Half;
                    g.CompositingMode = CompositingMode.SourceCopy;
                    g.DrawImage(src, new Rectangle(0, 0, width, height),
                        new Rectangle(0, 0, src.Width, src.Height), GraphicsUnit.Pixel);
                }
            }
        }
        return dst;
    }

    private static byte[] BitmapPayload(ushort id, string path, int width, int height) {
        byte[] raw = new byte[width * height * 4];
        using (Bitmap bmp = LoadScaled(path, width, height)) {
            int k = 0;
            for (int y = 0; y < height; y++) {
                for (int x = 0; x < width; x++) {
                    Color c = bmp.GetPixel(x, y);
                    int a = c.A;
                    raw[k++] = (byte)a;
                    raw[k++] = (byte)((c.R * a + 127) / 255);
                    raw[k++] = (byte)((c.G * a + 127) / 255);
                    raw[k++] = (byte)((c.B * a + 127) / 255);
                }
            }
        }
        byte[] z = Zlib(raw);
        byte[] p = new byte[7 + z.Length];
        p[0] = (byte)(id & 255);
        p[1] = (byte)(id >> 8);
        p[2] = 5;
        p[3] = (byte)(width & 255);
        p[4] = (byte)(width >> 8);
        p[5] = (byte)(height & 255);
        p[6] = (byte)(height >> 8);
        Buffer.BlockCopy(z, 0, p, 7, z.Length);
        return p;
    }

    private static void WriteTag(Stream s, int code, byte[] payload) {
        int len = payload.Length;
        if (len < 63) {
            ushort h = (ushort)((code << 6) | len);
            s.WriteByte((byte)(h & 255));
            s.WriteByte((byte)(h >> 8));
        } else {
            ushort h = (ushort)((code << 6) | 63);
            s.WriteByte((byte)(h & 255));
            s.WriteByte((byte)(h >> 8));
            s.WriteByte((byte)(len & 255));
            s.WriteByte((byte)((len >> 8) & 255));
            s.WriteByte((byte)((len >> 16) & 255));
            s.WriteByte((byte)((len >> 24) & 255));
        }
        s.Write(payload, 0, payload.Length);
    }

    public static void PatchArt(string templatePath, string outputPath, string hatPath, string pantsPath) {
        byte[] src = File.ReadAllBytes(templatePath);
        int p = TagStart(src);
        byte[] hatPayload = BitmapPayload(11866, hatPath, 32, 20);
        byte[] pantsPayload = BitmapPayload(11868, pantsPath, 48, 67);

        using (MemoryStream ms = new MemoryStream(src.Length + 32768)) {
            ms.Write(src, 0, p);
            while (p < src.Length) {
                int tagStart = p;
                if (p + 2 > src.Length) throw new InvalidDataException("Truncated SWF tag header.");
                ushort rec = U16(src, p); p += 2;
                int code = rec >> 6;
                int len = rec & 63;
                if (len == 63) {
                    if (p + 4 > src.Length) throw new InvalidDataException("Truncated long SWF tag header.");
                    len = I32(src, p); p += 4;
                }
                int payloadStart = p;
                int tagEnd = payloadStart + len;
                if (len < 0 || tagEnd > src.Length) throw new InvalidDataException("Invalid SWF tag length.");

                bool replaced = false;
                if (code == 36 && len >= 2) {
                    ushort cid = U16(src, payloadStart);
                    if (cid == 11866) {
                        WriteTag(ms, 36, hatPayload);
                        replaced = true;
                    } else if (cid == 11868) {
                        WriteTag(ms, 36, pantsPayload);
                        replaced = true;
                    }
                }

                if (!replaced) ms.Write(src, tagStart, tagEnd - tagStart);
                p = tagEnd;
                if (code == 0) break;
            }

            byte[] dst = ms.ToArray();
            W32(dst, 4, dst.Length);
            string dir = Path.GetDirectoryName(outputPath);
            if (!String.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.WriteAllBytes(outputPath, dst);
        }
    }

    public static bool IsBuild8(string path) {
        try {
            byte[] src = File.ReadAllBytes(path);
            int p = TagStart(src);
            bool b1 = false, s1 = false, b2 = false, s2 = false;
            while (p < src.Length) {
                ushort rec = U16(src, p); p += 2;
                int code = rec >> 6;
                int len = rec & 63;
                if (len == 63) { len = I32(src, p); p += 4; }
                int ps = p;
                int pe = ps + len;
                if (pe > src.Length) return false;
                if ((code == 36 || code == 32) && len >= 2) {
                    ushort cid = U16(src, ps);
                    if (code == 36 && cid == 11866) b1 = true;
                    if (code == 32 && cid == 11867) s1 = true;
                    if (code == 36 && cid == 11868) b2 = true;
                    if (code == 32 && cid == 11869) s2 = true;
                }
                p = pe;
                if (code == 0) break;
            }
            return b1 && s1 && b2 && s2;
        } catch { return false; }
    }
}
"@ -ReferencedAssemblies @("System.Drawing.dll","System.IO.Compression.dll")

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ModTemplate = Join-Path $script:Root "ModFiles\SFPA_modded_base.swf"
$script:ModSwf = Join-Path $script:Root "ModFiles\SFPA_modded.swf"
$script:ArtDir = Join-Path $script:Root "CustomArt"
$script:HatArtPath = Join-Path $script:ArtDir "custom_hat.png"
$script:PantsArtPath = Join-Path $script:ArtDir "custom_pants.png"
$script:CustomArtEnabledPath = Join-Path $script:ArtDir "custom_art_enabled.txt"
$script:CustomArtEnabled = Test-Path $script:CustomArtEnabledPath
$script:ConfigPath = Join-Path $script:Root "gamefolder.txt"
$script:GameDir = $null
$script:GameProcess = $null
$script:OverlayVisible = $false
$script:PrevTab = $false
$script:PrevTick = $false
$script:MenuPauseSent = $false
$script:OverlayScaleFactor = 1.0
$script:OverlayScalePct = 90
$script:ExpectedOriginalHash = "a0b2d1a134fd543b098a73222a70eb08feadbd1e4f3833a400c892f888bc3abb"
$script:TemplateHash = "e7af056f4d01c54b34c7ebb465f7d3d5d78ee232aafd436affb999e465c92809"
$script:GeneratedModHash = $null
$script:KnownOlderModHashes = @(
    "cca9b310bb55b2055c8675b556f832f358126b98595ba3eb18c5d0c1f871ce4d",
    "cbe731ae0ff9283cce8a0b6c6bbdf7f7a0f736c548291f9cd2de345f72be9470",
    "78c503649724393174443f4a16446ce8253436f55857321ea814957e3adc6764",
    "942e7b95fb5ba5577b39c4c47684f2a1d05d2cc92809308705e3012692cb5572",
    "38d03414eca6d236ce4be8029a532ed1dd907ac0236110c6bd6956b5fa729e01",
    "25a74123b14ef233f98597d750332860fdd002fde6d324471684ed25fe09a31a",
    "dd3ee3c3f4ad38d15e7e89757afa5e2167ec1a786be015bd9c4c7f342ccda8ae",
    "c35ec80a9ba9d7e2bf1ae45b8a3dd987e0e600309604934b0a3bcba7c51a10ac",
    "5e3c0c946fef23998f3eecd920a9b7f507fd62a9ac3a23f215c107633eb0504d",
    "f0196133e69399b4eab1fa725ee0c8a0dbacc0ead8943aa3c39fbd911431e514"
)
$script:BaseBounds = @{}
$script:BaseFontSizes = @{}
$script:BaseScrollMin = @{}
$script:OverlayBaseClientSize = New-Object System.Drawing.Size(1080,600)

$script:Ink = [System.Drawing.Color]::FromArgb(239,241,247)
$script:Paper = [System.Drawing.Color]::FromArgb(16,17,23)
$script:Card = [System.Drawing.Color]::FromArgb(27,29,38)
$script:CardOff = [System.Drawing.Color]::FromArgb(35,37,48)
$script:CardOn = [System.Drawing.Color]::FromArgb(112,92,255)
$script:Wood = [System.Drawing.Color]::FromArgb(12,13,18)
$script:Pink = [System.Drawing.Color]::FromArgb(126,105,255)
$script:White = [System.Drawing.Color]::FromArgb(246,247,251)
$script:Gold = [System.Drawing.Color]::FromArgb(245,190,69)
$script:Sky = [System.Drawing.Color]::FromArgb(43,46,60)
$script:Pencil = [System.Drawing.Color]::FromArgb(61,64,80)
$script:SoftPink = [System.Drawing.Color]::FromArgb(49,43,76)
$script:Green = [System.Drawing.Color]::FromArgb(74,207,137)
$script:Muted = [System.Drawing.Color]::FromArgb(155,161,178)
$script:Accent2 = [System.Drawing.Color]::FromArgb(75,169,255)

function New-FancyFont([float]$size, [System.Drawing.FontStyle]$style = [System.Drawing.FontStyle]::Regular) {
    try { return New-Object System.Drawing.Font("Segoe UI", $size, $style) }
    catch { return New-Object System.Drawing.Font("Arial", $size, $style) }
}

function New-FancyButton([string]$text, [int]$x, [int]$y, [int]$w, [int]$h) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x,$y)
    $b.Size = New-Object System.Drawing.Size($w,$h)
    $b.Font = New-FancyFont 10.0 ([System.Drawing.FontStyle]::Bold)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = $script:Pencil
    $b.BackColor = $script:Card
    $b.ForeColor = $script:White
    $b.FlatAppearance.MouseOverBackColor = $script:SoftPink
    $b.FlatAppearance.MouseDownBackColor = $script:Pink
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}

function New-FancyLabel([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [float]$size = 11, [bool]$bold = $false) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x,$y)
    $l.Size = New-Object System.Drawing.Size($w,$h)
    $style = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font = New-FancyFont $size $style
    $l.ForeColor = $script:Ink
    $l.BackColor = [System.Drawing.Color]::Transparent
    return $l
}

function New-CardPanel([int]$x,[int]$y,[int]$w,[int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($x,$y)
    $p.Size = New-Object System.Drawing.Size($w,$h)
    $p.BackColor = $script:Card
    $p.Add_Paint({
        $g = $_.Graphics
        $outer = New-Object System.Drawing.Pen($script:Pencil,1)
        $accent = New-Object System.Drawing.Pen($script:Pink,2)
        $g.DrawRectangle($outer,0,0,($this.ClientSize.Width-1),($this.ClientSize.Height-1))
        $g.DrawLine($accent,0,0,42,0)
        $outer.Dispose(); $accent.Dispose()
    })
    return $p
}

function Apply-ProControlStyle($root) {
    foreach ($c in $root.Controls) {
        if ($c -is [System.Windows.Forms.TextBox]) {
            $c.BackColor = $script:CardOff; $c.ForeColor = $script:White; $c.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        } elseif ($c -is [System.Windows.Forms.NumericUpDown]) {
            $c.BackColor = $script:CardOff; $c.ForeColor = $script:White; $c.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        } elseif ($c -is [System.Windows.Forms.ComboBox]) {
            $c.BackColor = $script:CardOff; $c.ForeColor = $script:White; $c.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        }
        if ($c.Controls.Count -gt 0) { Apply-ProControlStyle $c }
    }
}

function Get-ConfiguredGameDir {
    if ($script:GameDir -and (Test-Path (Join-Path $script:GameDir "SFPA.exe"))) { return $script:GameDir }
    if (Test-Path (Join-Path $script:Root "SFPA.exe")) {
        $script:GameDir = $script:Root
        return $script:GameDir
    }
    if (Test-Path $script:ConfigPath) {
        $saved = (Get-Content $script:ConfigPath -Raw).Trim().Trim([char]34)
        if ($saved -and (Test-Path (Join-Path $saved "SFPA.exe"))) {
            $script:GameDir = $saved
            return $script:GameDir
        }
    }
    return $null
}

function Choose-GameFolder {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Choose SFPA.exe"
    $dialog.Filter = "Super Fancy Pants Adventure|SFPA.exe"
    $dialog.FileName = "SFPA.exe"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:GameDir = Split-Path -Parent $dialog.FileName
        Set-Content -Path $script:ConfigPath -Value $script:GameDir -Encoding UTF8
        return $script:GameDir
    }
    return $null
}

function Ensure-GameDir {
    $d = Get-ConfiguredGameDir
    if (-not $d) { $d = Choose-GameFolder }
    return $d
}

function Set-Status([string]$text) {
    if ($script:StatusLabel) { $script:StatusLabel.Text = $text }
}

function Get-Sha256([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLowerInvariant() }
    catch { return $null }
}


function Set-CustomArtEnabled([bool]$enabled) {
    if (-not (Test-Path $script:ArtDir)) { New-Item -ItemType Directory -Path $script:ArtDir | Out-Null }
    $script:CustomArtEnabled=$enabled
    if ($enabled) { Set-Content -Path $script:CustomArtEnabledPath -Value 'enabled' -Encoding ASCII }
    elseif (Test-Path $script:CustomArtEnabledPath) { Remove-Item $script:CustomArtEnabledPath -Force -ErrorAction SilentlyContinue }
    if ($script:CustomArtToggleButton) {
        $script:CustomArtToggleButton.Text = if ($enabled) { 'CUSTOM ART  ON' } else { 'CUSTOM ART  OFF' }
        $script:CustomArtToggleButton.BackColor = if ($enabled) { $script:CardOn } else { $script:CardOff }
    }
}

function Build-CustomizedModSwf {
    if (-not (Test-Path $script:ModTemplate)) {
        [System.Windows.Forms.MessageBox]::Show("Build 11 base mod file is missing. Extract Build 11 again.","Fancy Mod Manager") | Out-Null
        return $false
    }
    if ((Get-Sha256 $script:ModTemplate) -ne $script:TemplateHash) {
        [System.Windows.Forms.MessageBox]::Show("Build 11 base mod file failed its integrity check. Extract Build 11 again.","Fancy Mod Manager") | Out-Null
        return $false
    }
    try {
        if (-not (Test-Path $script:ArtDir)) { New-Item -ItemType Directory -Path $script:ArtDir | Out-Null }
        if ($script:CustomArtEnabled) {
            [FancyArtSwf]::PatchArt($script:ModTemplate,$script:ModSwf,$script:HatArtPath,$script:PantsArtPath)
            if (-not [FancyArtSwf]::IsBuild8($script:ModSwf)) { throw "Generated SWF failed the Build 11 structure check." }
        } else {
            Copy-Item $script:ModTemplate $script:ModSwf -Force
        }
        $script:GeneratedModHash = Get-Sha256 $script:ModSwf
        return $true
    } catch {
        # Fail safe: a bad custom image should never stop the stable game from launching.
        try {
            Copy-Item $script:ModTemplate $script:ModSwf -Force
            $script:GeneratedModHash = Get-Sha256 $script:ModSwf
            Set-CustomArtEnabled $false
            Set-Status "Custom art failed validation, so Build 11 switched back to the stable base art."
            return $true
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Could not build the custom art version of Build 11.`r`n`r`n$($_.Exception.Message)","Fancy Mod Manager") | Out-Null
            return $false
        }
    }
}

function Install-Mod {
    if (-not (Build-CustomizedModSwf)) { return $false }
    $d = Ensure-GameDir
    if (-not $d) { return $false }
    $gameSwf = Join-Path $d "SFPA.swf"
    $backup = Join-Path $d "SFPA.original.swf"
    $temp = Join-Path $d "SFPA.fancy.install.tmp"
    $swapBackup = Join-Path $d "SFPA.fancy.previous.tmp"

    if (-not (Test-Path $gameSwf)) {
        [System.Windows.Forms.MessageBox]::Show("SFPA.swf was not found in that folder.","Fancy Mod Manager") | Out-Null
        return $false
    }
    if (-not (Test-Path $script:ModSwf)) {
        [System.Windows.Forms.MessageBox]::Show("The generated Build 11 SWF is missing.","Fancy Mod Manager") | Out-Null
        return $false
    }

    $currentHash = Get-Sha256 $gameSwf
    if ($currentHash -eq $script:GeneratedModHash) {
        Set-Status "Build 11 is already installed with the current custom art."
        return $true
    }

    $backupHash = Get-Sha256 $backup
    if ($currentHash -eq $script:ExpectedOriginalHash) {
        try {
            Copy-Item $gameSwf $backup -Force
            $backupHash = Get-Sha256 $backup
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Could not create the original game backup.`r`n`r`n$($_.Exception.Message)","Fancy Mod Manager") | Out-Null
            return $false
        }
    } elseif (($script:KnownOlderModHashes -contains $currentHash) -or [FancyArtSwf]::IsBuild8($gameSwf)) {
        if ($backupHash -ne $script:ExpectedOriginalHash) {
            [System.Windows.Forms.MessageBox]::Show("A Fancy Mod build is installed, but a verified original backup was not found. Restore or verify the game in Steam first so the manager does not risk overwriting the wrong version.","Fancy Mod Manager") | Out-Null
            return $false
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show("This SFPA.swf does not match the game version Build 11 was made for. The manager stopped before changing anything. If Steam updated the game, verify the files and use a mod build made for that version.","Fancy Mod Manager") | Out-Null
        return $false
    }

    try {
        if (Test-Path $temp) { Remove-Item $temp -Force -ErrorAction SilentlyContinue }
        if (Test-Path $swapBackup) { Remove-Item $swapBackup -Force -ErrorAction SilentlyContinue }
        Copy-Item $script:ModSwf $temp -Force
        if ((Get-Sha256 $temp) -ne $script:GeneratedModHash) { throw "Temporary install file failed verification." }

        [System.IO.File]::Replace($temp,$gameSwf,$swapBackup,$true)

        if ((Get-Sha256 $gameSwf) -ne $script:GeneratedModHash) { throw "Installed file failed verification." }
        if (Test-Path $swapBackup) { Remove-Item $swapBackup -Force -ErrorAction SilentlyContinue }
        Set-Status "Build 11 installed and verified with the current custom art."
        return $true
    } catch {
        if (Test-Path $temp) { Remove-Item $temp -Force -ErrorAction SilentlyContinue }
        if (Test-Path $swapBackup) { Remove-Item $swapBackup -Force -ErrorAction SilentlyContinue }
        [System.Windows.Forms.MessageBox]::Show("Could not install Build 11. Close the game and try again.`r`n`r`n$($_.Exception.Message)","Fancy Mod Manager") | Out-Null
        return $false
    }
}

function Restore-Original {
    $d = Ensure-GameDir
    if (-not $d) { return }
    $gameSwf = Join-Path $d "SFPA.swf"
    $backup = Join-Path $d "SFPA.original.swf"
    if (-not (Test-Path $backup)) {
        [System.Windows.Forms.MessageBox]::Show("No original backup was found. Use Steam Verify Integrity of Game Files if you need a clean copy.","Fancy Mod Manager") | Out-Null
        return
    }
    if ((Get-Sha256 $backup) -ne $script:ExpectedOriginalHash) {
        [System.Windows.Forms.MessageBox]::Show("The backup does not match the original game version used to build this mod, so it was not restored automatically.","Fancy Mod Manager") | Out-Null
        return
    }
    try {
        Copy-Item $backup $gameSwf -Force
        if ((Get-Sha256 $gameSwf) -ne $script:ExpectedOriginalHash) { throw "Restored file failed verification." }
        Set-Status "Original game restored and verified."
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not restore the original while the game is open. Close the game and try again.`r`n`r`n$($_.Exception.Message)","Fancy Mod Manager") | Out-Null
    }
}
function Find-GameProcess {
    try {
        if ($script:GameProcess -and -not $script:GameProcess.HasExited) {
            $script:GameProcess.Refresh()
            return $script:GameProcess
        }
    } catch { $script:GameProcess = $null }
    $p = Get-Process -Name "SFPA" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { $script:GameProcess = $p; return $p }
    $script:GameProcess = $null
    return $null
}

function Launch-Game {
    if (-not (Install-Mod)) { return }
    $d = Ensure-GameDir
    try {
        $script:GameProcess = Start-Process -FilePath (Join-Path $d "SFPA.exe") -WorkingDirectory $d -PassThru
    } catch {
        [System.Windows.Forms.MessageBox]::Show("The game could not be started.`r`n`r`n$($_.Exception.Message)","Fancy Mod Manager") | Out-Null
        return
    }
    Start-Sleep -Milliseconds 800
    try {
        Reset-UiState
    } catch {
        Set-Status "Game started. UI reset warning: $($_.Exception.Message)"
    }
    Set-Status "Game running. Press Tab or the grave key to open the mod book."
    $script:MainForm.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
}

function Send-ModKey([int]$vk) {
    $p = Find-GameProcess
    if (-not $p) {
        [System.Windows.Forms.MessageBox]::Show("Start the game from Fancy Mod Manager first.","Fancy Mod Manager") | Out-Null
        return $false
    }
    $p.Refresh()
    $h = $p.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) {
        Start-Sleep -Milliseconds 250
        $p.Refresh(); $h = $p.MainWindowHandle
    }
    if ($h -eq [IntPtr]::Zero) { return $false }
    [FancyNative]::PostMessage($h,0x0100,[IntPtr]$vk,[IntPtr]0) | Out-Null
    Start-Sleep -Milliseconds 35
    [FancyNative]::PostMessage($h,0x0101,[IntPtr]$vk,[IntPtr]0) | Out-Null
    Start-Sleep -Milliseconds 15
    return $true
}

function Send-NumericSetting([int]$startKey,[int]$value) {
    $value = [Math]::Max(0,[Math]::Min(9999,$value))
    if (-not (Send-ModKey $startKey)) { return $false }
    foreach ($ch in $value.ToString().ToCharArray()) {
        $vk = [int][char]$ch
        if (-not (Send-ModKey $vk)) { return $false }
    }
    return (Send-ModKey 13)
}

function Release-GameMovementKeys {
    $p = Find-GameProcess
    if (-not $p) { return }
    $p.Refresh(); $h = $p.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { return }
    foreach ($vk in @(0x25,0x26,0x27,0x28,0x20,0x41,0x44,0x53,0x57,0x10)) {
        [FancyNative]::PostMessage($h,0x0101,[IntPtr]$vk,[IntPtr]0) | Out-Null
    }
}

function Set-MenuPause([bool]$pause) {
    if ($pause -eq $script:MenuPauseSent) { return }
    if (Send-ModKey 133) { $script:MenuPauseSent = $pause }
}

$script:Flags = @{
    Invincible = $false
    Friendly = $false
    Fly = $false
    NoClip = $false
    InfiniteJumps = $false
    InfiniteAmmo = $false
    InfiniteLives = $false
    InfiniteSquiggles = $false
    FreezeEnemies = $false
    OneHit = $false
    NoPitDeath = $false
    NoSquish = $false
    NoScreenShake = $false
    AllTools = $false
    AllMoves = $false
    NoKnockback = $false
    MaxPower = $false
    HatTint = $false
}
$script:Levels = @()
for ($i = 1; $i -le 20; $i++) { $script:Levels += ($i * 0.25) }
$script:LevelIndex = @{ Speed=3; Jump=3; Strength=3; GameSpeed=3 }
$script:ToggleButtons = @{}
$script:ValueLabels = @{}
$script:LevelKeys = @{
    Speed = @{ Up=114; Down=125 }
    Jump = @{ Up=115; Down=126 }
    Strength = @{ Up=116; Down=127 }
    GameSpeed = @{ Up=117; Down=128 }
}

function Update-ToggleButton([string]$name) {
    $b = $script:ToggleButtons[$name]
    if (-not $b) { return }
    if ($script:Flags[$name]) {
        $b.Text = "ON"
        $b.BackColor = $script:CardOn
        $b.ForeColor = $script:White
    } else {
        $b.Text = "OFF"
        $b.BackColor = $script:CardOff
        $b.ForeColor = $script:Ink
    }
}

function Toggle-Flag([string]$name, [int]$vk) {
    if ($name -eq "NoClip" -and -not $script:Flags.Fly) { return }
    if ($name -eq "Fly" -and $script:Flags.Fly -and $script:Flags.NoClip) {
        if (Send-ModKey 119) {
            $script:Flags.NoClip = $false
            Update-ToggleButton "NoClip"
        }
    }
    if (Send-ModKey $vk) {
        $script:Flags[$name] = -not $script:Flags[$name]
        Update-ToggleButton $name
        if ($name -eq "Fly") { $script:ToggleButtons.NoClip.Enabled = $script:Flags.Fly }
    }
}

function Send-ExtendedCommand([int]$command) {
    return (Send-NumericSetting 135 $command)
}

function Toggle-ExtendedFlag([string]$name, [int]$command) {
    if (Send-ExtendedCommand $command) {
        $script:Flags[$name] = -not $script:Flags[$name]
        Update-ToggleButton $name
    }
}

function Send-OneShot([int]$command, [string]$message) {
    if (Send-ExtendedCommand $command) { Set-Status $message }
}

function Summon-SelectedEnemy {
    if (-not $script:SummonEnemyBox) { return }
    $idx = [int]$script:SummonEnemyBox.SelectedIndex
    if ($idx -lt 0) { return }
    if (-not (Find-GameProcess)) { Set-Status "Launch the game before using Summon."; return }

    # Build 11 uses Pattern 18 only as an internal summon sentinel.  The enemy
    # selector rides through the existing hat tint index channel so no new save
    # fields are created and ordinary outfit values stay untouched.
    $wasPaused = [bool]$script:MenuPauseSent
    if ($wasPaused) { Set-MenuPause $false }
    try {
        if (-not (Send-ExtendedCommand (14000 + $idx))) { return }
        if (-not (Send-ExtendedCommand 12018)) { return }
        if (-not (Send-ExtendedCommand 25)) { return }
        Start-Sleep -Milliseconds 80
        Set-Status ("Spawned " + $script:SummonEnemyBox.SelectedItem + ". Click SPAWN again for another one.")
    } finally {
        if ($wasPaused) { Set-MenuPause $true }
    }
}

function Update-LevelLabel([string]$name) {
    $v = $script:Levels[$script:LevelIndex[$name]]
    $script:ValueLabels[$name].Text = ("{0:0.00}x" -f $v)
}

function Change-Level([string]$name, [int]$delta) {
    $count = $script:Levels.Count
    $vk = if ($delta -gt 0) { $script:LevelKeys[$name].Up } else { $script:LevelKeys[$name].Down }
    if (Send-ModKey $vk) {
        if ($delta -gt 0) { $script:LevelIndex[$name] = ($script:LevelIndex[$name] + 1) % $count }
        else { $script:LevelIndex[$name] = ($script:LevelIndex[$name] - 1 + $count) % $count }
        Update-LevelLabel $name
        if ($name -eq "GameSpeed") { Apply-SmoothGameSpeedFps }
    }
}

function Apply-SmoothGameSpeedFps {
    if (-not $script:ExtraFlags -or -not $script:ExtraFlags.SmoothGameSpeed) { return }
    $v = [double]$script:Levels[$script:LevelIndex.GameSpeed]
    $script:SmoothFpsTarget = [int][Math]::Round(60.0 * [Math]::Max(1.0,$v))
    $script:SmoothFpsTarget = [Math]::Max(60,[Math]::Min(480,$script:SmoothFpsTarget))
}
function Update-SmoothFpsRamp {
    if (-not $script:ExtraFlags.SmoothGameSpeed -or -not (Find-GameProcess)) { return }
    $target=[int]$script:SmoothFpsTarget; $cur=[int]$script:SmoothFpsCurrent
    if ($cur -eq $target) { return }
    $step=30
    if ($cur -lt $target) { $cur=[Math]::Min($target,$cur+$step) } else { $cur=[Math]::Max($target,$cur-$step) }
    if (Send-NumericSetting 134 $cur) {
        $script:SmoothFpsCurrent=$cur
        if ($script:FpsActualLabel) { $script:FpsActualLabel.Text = "SMOOTH $cur FPS" }
    }
}

function Apply-FPS {
    if ($script:ExtraFlags.SmoothGameSpeed) { $script:ExtraFlags.SmoothGameSpeed=$false; Update-ExtraButton 'SmoothGameSpeed' }
    $requested = [int]$script:FpsInput.Value
    $effective = if ($requested -eq 0) { 1000 } else { [Math]::Min(1000,$requested) }
    if (Send-NumericSetting 134 $effective) {
        $script:FpsActualLabel.Text = if ($requested -eq 0) { "AIR TARGET 1000" } elseif ($requested -gt 1000) { "AIR CAP 1000" } else { "TARGET $requested" }
        if ($requested -gt 1000) { Set-Status "FPS request saved. Adobe AIR limits Stage.frameRate to 1000, so $requested requests 1000 in the engine." }
        elseif ($requested -eq 0) { Set-Status "FPS set to the AIR maximum target of 1000." }
        else { Set-Status "FPS target set to $requested." }
    }
}

function Reset-UiState {
    foreach ($k in @($script:Flags.Keys)) {
        $script:Flags[$k] = $false
        Update-ToggleButton $k
    }
    foreach ($k in @("Speed","Jump","Strength","GameSpeed")) {
        $script:LevelIndex[$k] = 3
        Update-LevelLabel $k
    }
    if ($script:ToggleButtons.ContainsKey("NoClip")) { $script:ToggleButtons.NoClip.Enabled = $false }
    if ($script:FpsInput) { $script:FpsInput.Value = 0 }
    if ($script:FpsActualLabel) { $script:FpsActualLabel.Text = "GAME 60" }
}

function Reset-Mods {
    if (-not (Send-ModKey 122)) { return }
    Send-ExtendedCommand 30 | Out-Null
    foreach ($k in @("Invincible","Friendly","Fly","NoClip","InfiniteJumps","InfiniteAmmo","InfiniteLives","InfiniteSquiggles","FreezeEnemies","OneHit","NoPitDeath","NoSquish","NoScreenShake","AllTools","AllMoves","NoKnockback","MaxPower","HatTint")) {
        $script:Flags[$k] = $false
        Update-ToggleButton $k
    }
    foreach ($k in @("Speed","Jump","Strength","GameSpeed")) {
        $script:LevelIndex[$k] = 3
        Update-LevelLabel $k
    }
    if ($script:ToggleButtons.ContainsKey("NoClip")) { $script:ToggleButtons.NoClip.Enabled = $false }
    Reset-ExtraMods
    Set-Status "Gameplay and Build 11 automation mods reset to normal values."
}

function Reset-Performance {
    if ($script:FpsInput) { $script:FpsInput.Value = 0 }
    if (Send-NumericSetting 134 0) {
        if ($script:FpsActualLabel) { $script:FpsActualLabel.Text = "GAME 60" }
        Set-Status "FPS restored to the game's original 60 FPS. TPS and interpolation are disabled in the crash safe build."
    }
}

function Set-LevelExact([string]$name, [double]$value) {
    $target = [int][Math]::Round(($value / 0.25) - 1)
    $target = [Math]::Max(0,[Math]::Min($script:Levels.Count - 1,$target))
    while ($script:LevelIndex[$name] -lt $target) { Change-Level $name 1 }
    while ($script:LevelIndex[$name] -gt $target) { Change-Level $name -1 }
}

function Ensure-Flag([string]$name,[bool]$desired) {
    if ($script:Flags[$name] -eq $desired) { return }
    switch ($name) {
        "Invincible"       { Toggle-Flag $name 112 }
        "Friendly"         { Toggle-Flag $name 113 }
        "Fly"              { Toggle-Flag $name 118 }
        "NoClip"           { if ($desired -and -not $script:Flags.Fly) { Ensure-Flag "Fly" $true }; Toggle-Flag $name 119 }
        "InfiniteJumps"    { Toggle-Flag $name 120 }
        "InfiniteAmmo"     { Toggle-Flag $name 121 }
        "InfiniteLives"    { Toggle-Flag $name 129 }
        "InfiniteSquiggles"{ Toggle-Flag $name 130 }
        "FreezeEnemies"    { Toggle-Flag $name 131 }
        "OneHit"           { Toggle-Flag $name 132 }
        "NoPitDeath"       { Toggle-ExtendedFlag $name 1 }
        "NoSquish"         { Toggle-ExtendedFlag $name 2 }
        "NoScreenShake"    { Toggle-ExtendedFlag $name 3 }
        "AllTools"         { Toggle-ExtendedFlag $name 4 }
        "AllMoves"         { Toggle-ExtendedFlag $name 5 }
        "NoKnockback"      { Toggle-ExtendedFlag $name 6 }
        "MaxPower"         { Toggle-ExtendedFlag $name 7 }
    }
}

function Apply-ModPack($pack) {
    if (-not (Find-GameProcess)) {
        [System.Windows.Forms.MessageBox]::Show("Launch the game first, then open the Mod Book and choose a pack.","Fancy Mod Manager") | Out-Null
        return
    }
    Reset-Mods
    if ($null -ne $pack.Speed) { Set-LevelExact "Speed" ([double]$pack.Speed) }
    if ($null -ne $pack.Jump) { Set-LevelExact "Jump" ([double]$pack.Jump) }
    if ($null -ne $pack.Strength) { Set-LevelExact "Strength" ([double]$pack.Strength) }
    if ($null -ne $pack.GameSpeed) { Set-LevelExact "GameSpeed" ([double]$pack.GameSpeed) }
    foreach ($f in @($pack.Flags)) { if ($f) { Ensure-Flag ([string]$f) $true } }
    foreach ($cmd in @($pack.Actions)) { if ($cmd) { Send-ExtendedCommand ([int]$cmd) | Out-Null } }
    Set-Status "Applied mod pack: $($pack.Name)"
}

$script:ModPacks = @(
    [PSCustomObject]@{Category="MOVEMENT";Name="Moon Jump";Desc="3x jump height with unlimited air jumps.";Speed=1.0;Jump=3.0;Strength=1.0;GameSpeed=1.0;Flags=@("InfiniteJumps");Actions=@()},
    [PSCustomObject]@{Category="MOVEMENT";Name="Mega Jump";Desc="Maximum 5x jumps with unlimited air jumps.";Speed=1.0;Jump=5.0;Strength=1.0;GameSpeed=1.0;Flags=@("InfiniteJumps");Actions=@()},
    [PSCustomObject]@{Category="MOVEMENT";Name="Feather Feet";Desc="Floaty 2.5x jumps with a small speed boost.";Speed=1.25;Jump=2.5;Strength=1.0;GameSpeed=1.0;Flags=@();Actions=@()},
    [PSCustomObject]@{Category="MOVEMENT";Name="Heavy Boots";Desc="Short jumps, slower steps, stronger hits.";Speed=0.75;Jump=0.5;Strength=2.0;GameSpeed=1.0;Flags=@();Actions=@()},
    [PSCustomObject]@{Category="MOVEMENT";Name="Speedster";Desc="Maximum 5x movement speed.";Speed=5.0;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@();Actions=@()},
    [PSCustomObject]@{Category="MOVEMENT";Name="Turbo Runner";Desc="3x speed with slightly higher jumps.";Speed=3.0;Jump=1.25;Strength=1.0;GameSpeed=1.0;Flags=@();Actions=@()},
    [PSCustomObject]@{Category="MOVEMENT";Name="Slow Walk";Desc="Quarter speed movement for precision.";Speed=0.25;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@();Actions=@()},
    [PSCustomObject]@{Category="MOVEMENT";Name="Parkour";Desc="2x speed and jump plus air jumps and pit safety.";Speed=2.0;Jump=2.0;Strength=1.0;GameSpeed=1.0;Flags=@("InfiniteJumps","NoPitDeath");Actions=@()},
    [PSCustomObject]@{Category="MOVEMENT";Name="Air Acrobat";Desc="High jumps, air jumps, and no knockback.";Speed=1.25;Jump=2.5;Strength=1.0;GameSpeed=1.0;Flags=@("InfiniteJumps","NoKnockback");Actions=@()},
    [PSCustomObject]@{Category="MOVEMENT";Name="Ghost Flight";Desc="Fly through walls with Friendly enabled.";Speed=1.5;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@("Fly","NoClip","Friendly");Actions=@()},
    [PSCustomObject]@{Category="MOVEMENT";Name="Safe Flight";Desc="Fly with invincibility and a follow camera.";Speed=1.5;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@("Fly","Invincible");Actions=@()},
    [PSCustomObject]@{Category="MOVEMENT";Name="Super Hero";Desc="Fly, invincibility, maximum strength, and all tools.";Speed=2.0;Jump=2.0;Strength=5.0;GameSpeed=1.0;Flags=@("Fly","Invincible","AllTools","MaxPower");Actions=@()},

    [PSCustomObject]@{Category="COMBAT";Name="Tank";Desc="Invincible, no knockback, and 2x strength.";Speed=0.75;Jump=1.0;Strength=2.0;GameSpeed=1.0;Flags=@("Invincible","NoKnockback");Actions=@()},
    [PSCustomObject]@{Category="COMBAT";Name="Glass Cannon";Desc="5x strength and one hit enemy defeats.";Speed=1.0;Jump=1.0;Strength=5.0;GameSpeed=1.0;Flags=@("OneHit");Actions=@()},
    [PSCustomObject]@{Category="COMBAT";Name="Pacifist";Desc="Nothing hurts you and knockback is disabled.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@("Friendly","NoKnockback");Actions=@()},
    [PSCustomObject]@{Category="COMBAT";Name="Pencil Master";Desc="All tools, every pencil move, and max power.";Speed=1.0;Jump=1.0;Strength=2.0;GameSpeed=1.0;Flags=@("AllTools","AllMoves","MaxPower");Actions=@()},
    [PSCustomObject]@{Category="COMBAT";Name="Ammo God";Desc="All tools with infinite pen gun ink.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@("AllTools","InfiniteAmmo");Actions=@()},
    [PSCustomObject]@{Category="COMBAT";Name="Boss Melter";Desc="Invincible with 5x strength and one hit mode.";Speed=1.0;Jump=1.0;Strength=5.0;GameSpeed=1.0;Flags=@("Invincible","OneHit","AllTools","AllMoves");Actions=@()},
    [PSCustomObject]@{Category="COMBAT";Name="Training Mode";Desc="Infinite lives, invincibility, and no knockback.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@("Invincible","InfiniteLives","NoKnockback");Actions=@()},
    [PSCustomObject]@{Category="COMBAT";Name="Berserker";Desc="2x speed with 5x strength and one hit mode.";Speed=2.0;Jump=1.25;Strength=5.0;GameSpeed=1.0;Flags=@("OneHit");Actions=@()},
    [PSCustomObject]@{Category="COMBAT";Name="Combat Slowmo";Desc="Half speed combat with 2x strength and infinite ammo.";Speed=1.0;Jump=1.0;Strength=2.0;GameSpeed=0.5;Flags=@("InfiniteAmmo");Actions=@()},
    [PSCustomObject]@{Category="COMBAT";Name="Untouchable";Desc="Friendly, invincible, no squish, and no pit death.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@("Friendly","Invincible","NoSquish","NoPitDeath");Actions=@()},
    [PSCustomObject]@{Category="COMBAT";Name="Resource God";Desc="Infinite ammo, squiggle spending, and lives.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@("InfiniteAmmo","InfiniteSquiggles","InfiniteLives");Actions=@(24)},
    [PSCustomObject]@{Category="COMBAT";Name="Maxed Hero";Desc="All tools, all moves, max power, ammo, and 3x strength.";Speed=1.0;Jump=1.0;Strength=3.0;GameSpeed=1.0;Flags=@("AllTools","AllMoves","MaxPower","InfiniteAmmo");Actions=@()},

    [PSCustomObject]@{Category="WORLD";Name="Enemy Statue";Desc="Freezes standard enemy and most boss updates.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@("FreezeEnemies");Actions=@()},
    [PSCustomObject]@{Category="WORLD";Name="Frozen Adventure";Desc="Frozen enemies plus Friendly mode.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@("FreezeEnemies","Friendly");Actions=@()},
    [PSCustomObject]@{Category="WORLD";Name="No Hazards";Desc="Friendly mode plus pit and squish protection.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@("Friendly","NoPitDeath","NoSquish");Actions=@()},
    [PSCustomObject]@{Category="WORLD";Name="Smooth Screen";Desc="Disables screen shake while leaving gameplay normal.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@("NoScreenShake");Actions=@()},
    [PSCustomObject]@{Category="WORLD";Name="Cinematic";Desc="Half speed gameplay without screen shake.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=0.5;Flags=@("NoScreenShake");Actions=@()},
    [PSCustomObject]@{Category="WORLD";Name="Bullet Time";Desc="Quarter speed world with slightly faster movement.";Speed=1.5;Jump=1.0;Strength=1.0;GameSpeed=0.25;Flags=@("NoScreenShake");Actions=@()},
    [PSCustomObject]@{Category="WORLD";Name="Fast Forward";Desc="Maximum 5x simulation speed.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=5.0;Flags=@();Actions=@()},
    [PSCustomObject]@{Category="WORLD";Name="Double Time";Desc="2x simulation speed.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=2.0;Flags=@();Actions=@()},
    [PSCustomObject]@{Category="WORLD";Name="Half Time";Desc="0.5x simulation speed.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=0.5;Flags=@();Actions=@()},
    [PSCustomObject]@{Category="WORLD";Name="Quarter Time";Desc="0.25x simulation speed.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=0.25;Flags=@();Actions=@()},
    [PSCustomObject]@{Category="WORLD";Name="Speedrun";Desc="3x movement, 1.5x jump, and 1.25x world speed.";Speed=3.0;Jump=1.5;Strength=1.0;GameSpeed=1.25;Flags=@("NoScreenShake");Actions=@()},
    [PSCustomObject]@{Category="WORLD";Name="Explorer";Desc="Friendly exploration with pit safety and all moves.";Speed=1.25;Jump=1.25;Strength=1.0;GameSpeed=1.0;Flags=@("Friendly","NoPitDeath","NoSquish","AllMoves");Actions=@()},

    [PSCustomObject]@{Category="FUN";Name="God Mode";Desc="Nearly every safety and resource mod at once.";Speed=2.0;Jump=2.0;Strength=5.0;GameSpeed=1.0;Flags=@("Invincible","InfiniteLives","InfiniteAmmo","InfiniteSquiggles","NoPitDeath","NoSquish","NoKnockback","AllTools","AllMoves","MaxPower");Actions=@(24)},
    [PSCustomObject]@{Category="FUN";Name="Creative Mode";Desc="Fly, noclip, Friendly, unlimited ammo, and all tools.";Speed=2.0;Jump=2.0;Strength=1.0;GameSpeed=1.0;Flags=@("Fly","NoClip","Friendly","InfiniteAmmo","InfiniteSquiggles","AllTools","AllMoves");Actions=@()},
    [PSCustomObject]@{Category="FUN";Name="Chaos Runner";Desc="5x speed, 5x jump, 2x time, and unlimited air jumps.";Speed=5.0;Jump=5.0;Strength=1.0;GameSpeed=2.0;Flags=@("InfiniteJumps");Actions=@()},
    [PSCustomObject]@{Category="FUN";Name="Stunt School";Desc="Unlimited air jumps with pit, squish, and knockback safety.";Speed=1.5;Jump=2.0;Strength=1.0;GameSpeed=1.0;Flags=@("InfiniteJumps","NoPitDeath","NoSquish","NoKnockback");Actions=@()},
    [PSCustomObject]@{Category="FUN";Name="Shopping Spree";Desc="Unlimited spending and an instant 9999 squiggles refill.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@("InfiniteSquiggles");Actions=@(24)},
    [PSCustomObject]@{Category="FUN";Name="Ink Party";Desc="All tools with infinite pen gun ink.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@("AllTools","InfiniteAmmo");Actions=@()},
    [PSCustomObject]@{Category="FUN";Name="Enemy Museum";Desc="Freeze enemies and freely fly through the level.";Speed=1.25;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@("FreezeEnemies","Fly","NoClip");Actions=@()},
    [PSCustomObject]@{Category="FUN";Name="Zero Risk";Desc="Friendly mode with pit, squish, and life protection.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@("Friendly","NoPitDeath","NoSquish","InfiniteLives");Actions=@()},
    [PSCustomObject]@{Category="FUN";Name="No Death Practice";Desc="Invincible with infinite lives and hazard protection.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=1.0;Flags=@("Invincible","InfiniteLives","NoPitDeath","NoSquish");Actions=@()},
    [PSCustomObject]@{Category="FUN";Name="Boss Practice";Desc="Invincible maxed tools and moves with 2x strength.";Speed=1.0;Jump=1.0;Strength=2.0;GameSpeed=1.0;Flags=@("Invincible","InfiniteLives","AllTools","AllMoves","MaxPower","InfiniteAmmo");Actions=@()},
    [PSCustomObject]@{Category="FUN";Name="Rush Hour";Desc="5x movement and 5x world speed with 2x jumps.";Speed=5.0;Jump=2.0;Strength=1.0;GameSpeed=5.0;Flags=@();Actions=@()},
    [PSCustomObject]@{Category="FUN";Name="Dream Mode";Desc="Half speed, Friendly flight, and no screen shake.";Speed=1.0;Jump=1.0;Strength=1.0;GameSpeed=0.5;Flags=@("Friendly","Fly","NoScreenShake");Actions=@()}
)

function Unlock-AllCosmetics {
    if (Send-ModKey 124) {
        Set-Status "Unlock command sent for every hat and pants style."
        $script:CosmeticsButton.Text = "HATS + PANTS UNLOCKED"
        $script:CosmeticsButton.BackColor = $script:CardOn
    }
}

function Unlock-AllAchievements {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $script:Overlay,
        "This sends all 16 achievement unlock commands to the game. Continue?",
        "Unlock All Achievements",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    if (Send-ModKey 123) {
        Set-Status "Unlock command sent for all 16 achievements."
        $script:AchievementsButton.Text = "ALL 16 ACHIEVEMENTS SENT"
        $script:AchievementsButton.BackColor = $script:CardOn
    }
}

$script:OutfitPresetPath = Join-Path $script:Root "outfit_presets.json"
$script:OutfitPresets = @{}
if (Test-Path $script:OutfitPresetPath) {
    try {
        $loaded = Get-Content $script:OutfitPresetPath -Raw | ConvertFrom-Json
        foreach ($prop in $loaded.PSObject.Properties) { $script:OutfitPresets[$prop.Name] = $prop.Value }
    } catch { $script:OutfitPresets = @{} }
}

function Apply-Outfit {
    $hat = [int]$script:HatInput.Value
    $pants = [int]$script:PantsInput.Value
    $pattern = [int]$script:PatternInput.Value
    $color = [int]$script:ColorInput.Value
    if (-not (Send-ExtendedCommand (10000 + $hat))) { return }
    if (-not (Send-ExtendedCommand (11000 + $pants))) { return }
    if (-not (Send-ExtendedCommand (12000 + $pattern))) { return }
    $hatTintColor = [int]$script:HatTintColorInput.Value
    if (-not (Send-ExtendedCommand (13000 + $color))) { return }
    if (-not (Send-ExtendedCommand (14000 + $hatTintColor))) { return }
    if (Send-ExtendedCommand 25) {
        Set-Status "Outfit queued: Hat $hat, Pants $pants, Pattern $pattern, Color $color. It applies as soon as the mod book closes."
    }
}

function Randomize-Outfit {
    $script:HatInput.Value = Get-Random -Minimum 0 -Maximum 31
    $script:PantsInput.Value = Get-Random -Minimum 0 -Maximum 13
    $script:PatternInput.Value = Get-Random -Minimum 0 -Maximum 18
    $script:ColorInput.Value = Get-Random -Minimum 0 -Maximum 13
    $script:HatTintColorInput.Value = Get-Random -Minimum 0 -Maximum 13
    $script:StylePreview.Invalidate()
}

function Refresh-PresetList {
    if (-not $script:PresetCombo) { return }
    $script:PresetCombo.Items.Clear()
    foreach ($name in @($script:OutfitPresets.Keys | Sort-Object)) { [void]$script:PresetCombo.Items.Add($name) }
    if ($script:PresetCombo.Items.Count -gt 0 -and $script:PresetCombo.SelectedIndex -lt 0) { $script:PresetCombo.SelectedIndex = 0 }
}

function Save-OutfitPreset {
    $name = $script:PresetName.Text.Trim()
    if (-not $name) { $name = "Outfit $($script:OutfitPresets.Count + 1)" }
    $script:OutfitPresets[$name] = [PSCustomObject]@{
        Hat=[int]$script:HatInput.Value; Pants=[int]$script:PantsInput.Value; Pattern=[int]$script:PatternInput.Value; Color=[int]$script:ColorInput.Value; HatTint=[bool]$script:Flags.HatTint; HatTintColor=[int]$script:HatTintColorInput.Value
    }
    $obj = [ordered]@{}
    foreach ($k in @($script:OutfitPresets.Keys | Sort-Object)) { $obj[$k] = $script:OutfitPresets[$k] }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -Path $script:OutfitPresetPath -Encoding UTF8
    Refresh-PresetList
    $script:PresetCombo.SelectedItem = $name
    Set-Status "Saved outfit preset: $name"
}

function Load-OutfitPreset {
    if (-not $script:PresetCombo.SelectedItem) { return }
    $p = $script:OutfitPresets[[string]$script:PresetCombo.SelectedItem]
    if (-not $p) { return }
    $script:HatInput.Value = [int]$p.Hat
    $script:PantsInput.Value = [int]$p.Pants
    $script:PatternInput.Value = [int]$p.Pattern
    $script:ColorInput.Value = [int]$p.Color
    if ($null -ne $p.HatTintColor) { $script:HatTintColorInput.Value = [int]$p.HatTintColor }
    if ($null -ne $p.HatTint -and ([bool]$p.HatTint) -ne $script:Flags.HatTint) { Toggle-ExtendedFlag "HatTint" 8 }
    $script:StylePreview.Invalidate()
    Set-Status "Loaded outfit preset: $($script:PresetCombo.SelectedItem)"
}


function Ensure-BlankArt([string]$path,[int]$w,[int]$h) {
    if (Test-Path $path) { return }
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $bmp = New-Object System.Drawing.Bitmap($w,$h,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try { $bmp.Save($path,[System.Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
}

function Open-CustomArtEditor([string]$kind) {
    $isHat = ($kind -eq "Hat")
    $w = if ($isHat) { 32 } else { 48 }
    $h = if ($isHat) { 20 } else { 67 }
    $path = if ($isHat) { $script:HatArtPath } else { $script:PantsArtPath }
    Ensure-BlankArt $path $w $h

    $bmp = New-Object System.Drawing.Bitmap($w,$h,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    if (Test-Path $path) {
        $src = New-Object System.Drawing.Bitmap($path)
        try {
            $gg = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $gg.Clear([System.Drawing.Color]::Transparent)
                $gg.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
                $gg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
                $gg.DrawImage($src,(New-Object System.Drawing.Rectangle(0,0,$w,$h)))
            } finally { $gg.Dispose() }
        } finally { $src.Dispose() }
    }

    $state = [PSCustomObject]@{
        Bitmap=$bmp
        Undo=$null
        Drawing=$false
        Erase=$false
        Fill=$false
        Mirror=$false
        Color=[System.Drawing.Color]::FromArgb(255,244,72,184)
        Brush=1
    }

    $canvasW = if ($isHat) { 640 } else { 384 }
    $canvasH = if ($isHat) { 400 } else { 536 }
    $toolX = $canvasW + 40
    $formW = $canvasW + 255
    $formH = [Math]::Max($canvasH + 125,690)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = if ($isHat) { "Build 11 Custom Hat Maker" } else { "Build 11 Custom Pants Maker" }
    $form.ClientSize = New-Object System.Drawing.Size($formW,$formH)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor = $script:Paper
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true

    $titleText = if ($isHat) { "DRAW YOUR CUSTOM HAT" } else { "DRAW YOUR CUSTOM PANTS PATTERN" }
    $title = New-FancyLabel $titleText 18 12 ($formW-36) 40 16 $true
    $title.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $form.Controls.Add($title)

    $canvas = New-Object System.Windows.Forms.PictureBox
    $canvas.Location = New-Object System.Drawing.Point(20,62)
    $canvas.Size = New-Object System.Drawing.Size($canvasW,$canvasH)
    $canvas.BackColor = [System.Drawing.Color]::White
    $canvas.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $canvas.Cursor = [System.Windows.Forms.Cursors]::Cross
    $form.Controls.Add($canvas)

    $paintPoint = {
        param([int]$px,[int]$py)
        if ($px -lt 0 -or $py -lt 0 -or $px -ge $w -or $py -ge $h) { return }
        $radius = [Math]::Max(0,[int]$state.Brush - 1)
        for ($yy=$py-$radius; $yy -le $py+$radius; $yy++) {
            for ($xx=$px-$radius; $xx -le $px+$radius; $xx++) {
                if ($xx -lt 0 -or $yy -lt 0 -or $xx -ge $w -or $yy -ge $h) { continue }
                $c = if ($state.Erase) { [System.Drawing.Color]::Transparent } else { $state.Color }
                $state.Bitmap.SetPixel($xx,$yy,$c)
                if ($state.Mirror) {
                    $mx = $w - 1 - $xx
                    if ($mx -ge 0 -and $mx -lt $w) { $state.Bitmap.SetPixel($mx,$yy,$c) }
                }
            }
        }
    }.GetNewClosure()

    $flood = {
        param([int]$sx,[int]$sy)
        if ($sx -lt 0 -or $sy -lt 0 -or $sx -ge $w -or $sy -ge $h) { return }
        $target = $state.Bitmap.GetPixel($sx,$sy).ToArgb()
        $replaceColor = if ($state.Erase) { [System.Drawing.Color]::Transparent } else { $state.Color }
        $replace = $replaceColor.ToArgb()
        if ($target -eq $replace) { return }
        $q = New-Object System.Collections.Queue
        $q.Enqueue((New-Object System.Drawing.Point($sx,$sy)))
        while ($q.Count -gt 0) {
            $p = $q.Dequeue()
            if ($p.X -lt 0 -or $p.Y -lt 0 -or $p.X -ge $w -or $p.Y -ge $h) { continue }
            if ($state.Bitmap.GetPixel($p.X,$p.Y).ToArgb() -ne $target) { continue }
            $state.Bitmap.SetPixel($p.X,$p.Y,[System.Drawing.Color]::FromArgb($replace))
            $q.Enqueue((New-Object System.Drawing.Point($p.X+1,$p.Y)))
            $q.Enqueue((New-Object System.Drawing.Point($p.X-1,$p.Y)))
            $q.Enqueue((New-Object System.Drawing.Point($p.X,$p.Y+1)))
            $q.Enqueue((New-Object System.Drawing.Point($p.X,$p.Y-1)))
        }
    }.GetNewClosure()

    $canvas.Add_Paint({
        $g=$_.Graphics
        $g.Clear([System.Drawing.Color]::White)
        $g.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $g.PixelOffsetMode=[System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $g.DrawImage($state.Bitmap,(New-Object System.Drawing.Rectangle(0,0,$canvas.ClientSize.Width,$canvas.ClientSize.Height)))
        $cellX=$canvas.ClientSize.Width / [double]$w
        $cellY=$canvas.ClientSize.Height / [double]$h
        if ($cellX -ge 5 -and $cellY -ge 5) {
            $gp=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(45,20,20,20),1)
            for ($i=1;$i -lt $w;$i++) { $xx=[int][Math]::Round($i*$cellX); $g.DrawLine($gp,$xx,0,$xx,$canvas.ClientSize.Height) }
            for ($i=1;$i -lt $h;$i++) { $yy=[int][Math]::Round($i*$cellY); $g.DrawLine($gp,0,$yy,$canvas.ClientSize.Width,$yy) }
            $gp.Dispose()
        }
    }.GetNewClosure())

    $mousePoint = {
        param($e)
        $px=[int][Math]::Floor($e.X * $w / [double]$canvas.ClientSize.Width)
        $py=[int][Math]::Floor($e.Y * $h / [double]$canvas.ClientSize.Height)
        return (New-Object System.Drawing.Point($px,$py))
    }.GetNewClosure()

    $canvas.Add_MouseDown({
        param($sender,$e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        if ($state.Undo) { $state.Undo.Dispose() }
        $state.Undo = $state.Bitmap.Clone()
        $p=& $mousePoint $e
        if ($state.Fill) {
            & $flood $p.X $p.Y
            $state.Fill=$false
        } else {
            $state.Drawing=$true
            & $paintPoint $p.X $p.Y
        }
        $canvas.Invalidate()
    }.GetNewClosure())
    $canvas.Add_MouseMove({
        param($sender,$e)
        if (-not $state.Drawing) { return }
        $p=& $mousePoint $e
        & $paintPoint $p.X $p.Y
        $canvas.Invalidate()
    }.GetNewClosure())
    $canvas.Add_MouseUp({ $state.Drawing=$false }.GetNewClosure())
    $canvas.Add_MouseLeave({ $state.Drawing=$false }.GetNewClosure())

    $colorBtn = New-FancyButton "COLOR" $toolX 70 180 42
    $colorBtn.BackColor=$state.Color
    $colorBtn.Add_Click({
        $dlg=New-Object System.Windows.Forms.ColorDialog
        $dlg.FullOpen=$true
        $dlg.Color=$state.Color
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $state.Color=$dlg.Color
            $state.Erase=$false
            $state.Fill=$false
            $colorBtn.BackColor=$state.Color
        }
        $dlg.Dispose()
    }.GetNewClosure())
    $form.Controls.Add($colorBtn)

    $pencilBtn=New-FancyButton "PENCIL" $toolX 122 86 40
    $eraserBtn=New-FancyButton "ERASER" ($toolX+94) 122 86 40
    $fillBtn=New-FancyButton "FILL ONCE" $toolX 170 180 40
    $pencilBtn.BackColor=$script:Pink
    $pencilBtn.Add_Click({ $state.Erase=$false; $state.Fill=$false; $pencilBtn.BackColor=$script:Pink; $eraserBtn.BackColor=$script:Card; $fillBtn.BackColor=$script:Card }.GetNewClosure())
    $eraserBtn.Add_Click({ $state.Erase=$true; $state.Fill=$false; $eraserBtn.BackColor=$script:Pink; $pencilBtn.BackColor=$script:Card; $fillBtn.BackColor=$script:Card }.GetNewClosure())
    $fillBtn.Add_Click({ $state.Fill=$true; $fillBtn.BackColor=$script:Pink; $pencilBtn.BackColor=$script:Card; $eraserBtn.BackColor=$script:Card }.GetNewClosure())
    $form.Controls.Add($pencilBtn); $form.Controls.Add($eraserBtn); $form.Controls.Add($fillBtn)

    $mirror=New-Object System.Windows.Forms.CheckBox
    $mirror.Text="Mirror drawing"
    $mirror.Location=New-Object System.Drawing.Point($toolX,220)
    $mirror.Size=New-Object System.Drawing.Size(180,30)
    $mirror.Font=New-FancyFont 8.5 ([System.Drawing.FontStyle]::Bold)
    $mirror.Add_CheckedChanged({ $state.Mirror=$mirror.Checked }.GetNewClosure())
    $form.Controls.Add($mirror)

    $brushLabel=New-FancyLabel "Brush size" $toolX 255 105 26 8.5 $true
    $brush=New-Object System.Windows.Forms.NumericUpDown
    $brush.Location=New-Object System.Drawing.Point(($toolX+110),252)
    $brush.Size=New-Object System.Drawing.Size(70,30)
    $brush.Minimum=1; $brush.Maximum=5; $brush.Value=1
    $brush.Add_ValueChanged({ $state.Brush=[int]$brush.Value }.GetNewClosure())
    $form.Controls.Add($brushLabel); $form.Controls.Add($brush)

    $undoBtn=New-FancyButton "UNDO" $toolX 295 86 40
    $clearBtn=New-FancyButton "CLEAR" ($toolX+94) 295 86 40
    $undoBtn.Add_Click({
        if ($state.Undo) {
            $old=$state.Bitmap
            $state.Bitmap=$state.Undo
            $state.Undo=$old
            $canvas.Invalidate()
        }
    }.GetNewClosure())
    $clearBtn.Add_Click({
        if ($state.Undo) { $state.Undo.Dispose() }
        $state.Undo=$state.Bitmap.Clone()
        $gg=[System.Drawing.Graphics]::FromImage($state.Bitmap)
        try { $gg.Clear([System.Drawing.Color]::Transparent) } finally { $gg.Dispose() }
        $canvas.Invalidate()
    }.GetNewClosure())
    $form.Controls.Add($undoBtn); $form.Controls.Add($clearBtn)

    $importBtn=New-FancyButton "IMPORT PNG" $toolX 345 180 40
    $importBtn.Add_Click({
        $dlg=New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter="Images|*.png;*.bmp;*.jpg;*.jpeg"
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $src=New-Object System.Drawing.Bitmap($dlg.FileName)
            try {
                if ($state.Undo) { $state.Undo.Dispose() }
                $state.Undo=$state.Bitmap.Clone()
                $gg=[System.Drawing.Graphics]::FromImage($state.Bitmap)
                try {
                    $gg.Clear([System.Drawing.Color]::Transparent)
                    $gg.CompositingMode=[System.Drawing.Drawing2D.CompositingMode]::SourceCopy
                    $gg.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
                    $gg.DrawImage($src,(New-Object System.Drawing.Rectangle(0,0,$w,$h)))
                } finally { $gg.Dispose() }
            } finally { $src.Dispose() }
            $canvas.Invalidate()
        }
        $dlg.Dispose()
    }.GetNewClosure())
    $form.Controls.Add($importBtn)

    $exportBtn=New-FancyButton "EXPORT PNG" $toolX 395 180 40
    $exportBtn.Add_Click({
        $dlg=New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter="PNG image|*.png"
        $dlg.FileName=if ($isHat) { "custom_hat.png" } else { "custom_pants.png" }
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $state.Bitmap.Save($dlg.FileName,[System.Drawing.Imaging.ImageFormat]::Png)
        }
        $dlg.Dispose()
    }.GetNewClosure())
    $form.Controls.Add($exportBtn)

    $saveBtn=New-FancyButton "SAVE DESIGN" $toolX 455 180 46
    $saveBtn.BackColor=$script:Sky
    $saveBtn.Add_Click({
        $state.Bitmap.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)
        Build-CustomizedModSwf | Out-Null
        Set-Status "$kind design saved. Turn Custom Art on when you want to load it in game."
    }.GetNewClosure())
    $form.Controls.Add($saveBtn)

    $useBtn=New-FancyButton "SAVE + USE SLOT" $toolX 510 180 50
    $useBtn.BackColor=$script:Pink
    $useBtn.Add_Click({
        $state.Bitmap.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)
        Set-CustomArtEnabled $true
        Build-CustomizedModSwf | Out-Null
        if ($isHat) {
            if ($script:HatInput) { $script:HatInput.Value=30 }
        } else {
            if ($script:PatternInput) { $script:PatternInput.Value=17 }
            if ($script:ColorInput) { $script:ColorInput.Value=9 }
        }
        if (Find-GameProcess) {
            [System.Windows.Forms.MessageBox]::Show($form,"Design saved. Restart SFPA through Build 11 to load the new artwork. After restart, use the custom slot from the ART page.","Fancy Mod Manager") | Out-Null
        } else {
            Set-Status "$kind design saved and Build 11 rebuilt. It will load on the next launch."
        }
    }.GetNewClosure())
    $form.Controls.Add($useBtn)

    $noteText = if ($isHat) { "Hat canvas: 32 x 20 pixels. Transparent areas show nothing. Custom Hat uses safe hat index 30." } else { "Pants canvas: 48 x 67 pixels. It becomes custom pattern index 17. White pattern color is selected when you use it." }
    $note=New-FancyLabel $noteText $toolX 575 185 72 7.6 $false
    $form.Controls.Add($note)

    $closeBtn=New-FancyButton "CLOSE" 20 ($canvasH+78) 170 40
    $closeBtn.Add_Click({ $form.Close() }.GetNewClosure())
    $form.Controls.Add($closeBtn)

    $form.Add_FormClosed({
        if ($state.Undo) { $state.Undo.Dispose() }
        if ($state.Bitmap) { $state.Bitmap.Dispose() }
    }.GetNewClosure())
    [void]$form.ShowDialog()
}

function Use-CustomHat {
    if ($script:Flags.HatTint) { Toggle-ExtendedFlag "HatTint" 8 }
    $script:HatInput.Value=30
    Apply-Outfit
    Set-Status "Custom Hat index 30 selected with tint disabled so your drawn colors stay intact."
}

function Use-CustomPants {
    $script:PatternInput.Value=17
    $script:ColorInput.Value=9
    Apply-Outfit
    Set-Status "Custom Pants pattern index 17 selected."
}



# ---------------- BUILD 11 INDIVIDUAL MOD ENGINE ----------------
$script:ExtraFlags = @{
    AutoHeal=$false; AutoInk=$false; AutoSquiggles=$false; AutoSavePos=$false;
    RainbowHat=$false; SlowRainbow=$false; FastRainbow=$false; CycleHat=$false; CyclePants=$false; CyclePattern=$false;
    CyclePatternColor=$false; RandomOutfit=$false; RandomHat=$false; RandomPants=$false; RandomPattern=$false; RandomPatternColor=$false; RandomTint=$false;
    OutfitLock=$false; SmoothGameSpeed=$true; FlyBoost=$false; FlyPrecision=$false;
    HoldSlowmo=$false; HoldFastForward=$false; AutoUnlockCosmetics=$false;
    QuickHealKeys=$false; QuickInkKeys=$false; QuickSaveKeys=$false; QuickTeleportKeys=$false; QuickSquiggleKeys=$false;
    QuickFlyKeys=$false; QuickNoClipKeys=$false; QuickInvincibleKeys=$false; QuickFriendlyKeys=$false; QuickFreezeKeys=$false; QuickOneHitKeys=$false;
    RandomSpeed=$false; CycleSpeed=$false; PulseSpeed=$false;
    RandomJump=$false; CycleJump=$false; PulseJump=$false;
    RandomStrength=$false; CycleStrength=$false; PulseStrength=$false;
    RandomTime=$false; CycleTime=$false; PulseTime=$false;
    RandomFps=$false; CycleFps=$false; PulseFps=$false
}
$script:ExtraButtons = @{}
$script:ExtraButtonLabels = @{}
$script:AutomationLast = @{}
$script:CycleState = @{ Rainbow=0; Hat=0; Pants=0; Pattern=0; PatternColor=0; Speed=3; Jump=3; Strength=3; Time=3; Fps=1; PulseSpeed=0; PulseJump=0; PulseStrength=0; PulseTime=0; PulseFps=0 }
$script:FpsCycleValues = @(30,60,75,90,120,144,165,240,360,500,1000)
$script:TempSpeedActive = $false
$script:TempSpeedSavedIndex = 3
$script:TempSpeedTarget = -1
$script:TempTimeActive = $false
$script:TempTimeSavedIndex = 3
$script:TempTimeTarget = -1
$script:AutoUnlockProcessId = -1
$script:AutoUnlockStart = $null
$script:SearchModItems = New-Object System.Collections.ArrayList
$script:SmoothFpsTarget = 60
$script:SmoothFpsCurrent = 60
$script:HotkeyEdges = @{}

function Update-ExtraButton([string]$name) {
    if (-not $script:ExtraButtons.ContainsKey($name)) { return }
    $b=$script:ExtraButtons[$name]
    $label=$script:ExtraButtonLabels[$name]
    if ($script:ExtraFlags[$name]) {
        $b.Text="$label  [ON]"; $b.BackColor=$script:CardOn; $b.ForeColor=$script:White
    } else {
        $b.Text=$label; $b.BackColor=$script:Card; $b.ForeColor=$script:Ink
    }
}
function Toggle-ExtraFlag([string]$name) {
    $script:ExtraFlags[$name] = -not [bool]$script:ExtraFlags[$name]
    if ($script:ExtraFlags[$name] -and $name -in @('RainbowHat','SlowRainbow','FastRainbow')) {
        foreach($other in @('RainbowHat','SlowRainbow','FastRainbow')) {
            if ($other -ne $name) { $script:ExtraFlags[$other]=$false; Update-ExtraButton $other }
        }
    }
    # Dynamic variants in the same family are exclusive so they never fight over one value.
    $dynamicGroups=@(
        @('RandomSpeed','CycleSpeed','PulseSpeed'),
        @('RandomJump','CycleJump','PulseJump'),
        @('RandomStrength','CycleStrength','PulseStrength'),
        @('RandomTime','CycleTime','PulseTime'),
        @('RandomFps','CycleFps','PulseFps')
    )
    if ($script:ExtraFlags[$name]) {
        foreach($group in $dynamicGroups) {
            if ($name -in $group) {
                foreach($other in $group) { if ($other -ne $name) { $script:ExtraFlags[$other]=$false; Update-ExtraButton $other } }
            }
        }
    }
    Update-ExtraButton $name
    if ($name -eq 'SmoothGameSpeed') {
        if ($script:ExtraFlags[$name]) { Apply-SmoothGameSpeedFps }
        else { $script:SmoothFpsTarget=60; $script:SmoothFpsCurrent=60; Send-NumericSetting 134 60 | Out-Null; if ($script:FpsActualLabel) { $script:FpsActualLabel.Text='GAME 60' } }
    }
    $prefix = if ($script:ExtraFlags[$name]) { 'Enabled: ' } else { 'Disabled: ' }
    Set-Status ($prefix + $script:ExtraButtonLabels[$name])
}
function Test-AutoDue([string]$name,[int]$ms) {
    $now=[DateTime]::UtcNow
    if (-not $script:AutomationLast.ContainsKey($name) -or (($now-$script:AutomationLast[$name]).TotalMilliseconds -ge $ms)) {
        $script:AutomationLast[$name]=$now; return $true
    }
    return $false
}
function Apply-OutfitQuiet {
    if (-not $script:HatInput) { return }
    Send-ExtendedCommand (10000 + [int]$script:HatInput.Value) | Out-Null
    Send-ExtendedCommand (11000 + [int]$script:PantsInput.Value) | Out-Null
    Send-ExtendedCommand (12000 + [int]$script:PatternInput.Value) | Out-Null
    Send-ExtendedCommand (13000 + [int]$script:ColorInput.Value) | Out-Null
    Send-ExtendedCommand (14000 + [int]$script:HatTintColorInput.Value) | Out-Null
    Send-ExtendedCommand 25 | Out-Null
}
function Set-FpsQuick([int]$fps) {
    if ($script:ExtraFlags.SmoothGameSpeed) { $script:ExtraFlags.SmoothGameSpeed=$false; Update-ExtraButton 'SmoothGameSpeed' }
    if (Send-NumericSetting 134 $fps) {
        if ($script:FpsInput) { $script:FpsInput.Value=$fps }
        if ($script:FpsActualLabel) { $script:FpsActualLabel.Text="TARGET $fps" }
        Set-Status "FPS target set to $fps."
    }
}
function Set-QuickLevel([string]$name,[double]$value) {
    if (-not (Find-GameProcess)) { Set-Status 'Launch the game first.'; return }
    Set-LevelExact $name $value
    Set-Status "$name set to $([string]::Format('{0:0.00}x',$value))."
}
function Restore-TempSpeed {
    if ($script:TempSpeedActive) {
        $target=[double]$script:Levels[$script:TempSpeedSavedIndex]
        Set-LevelExact 'Speed' $target
        $script:TempSpeedActive=$false; $script:TempSpeedTarget=-1
    }
}
function Restore-TempTime {
    if ($script:TempTimeActive) {
        $target=[double]$script:Levels[$script:TempTimeSavedIndex]
        Set-LevelExact 'GameSpeed' $target
        $script:TempTimeActive=$false; $script:TempTimeTarget=-1
    }
}
function Update-HoldMods {
    if ($script:OverlayVisible -or -not (Find-GameProcess)) { Restore-TempSpeed; Restore-TempTime; return }
    $p=Find-GameProcess; $p.Refresh()
    if ([FancyNative]::GetForegroundWindow() -ne $p.MainWindowHandle) { Restore-TempSpeed; Restore-TempTime; return }

    # Fly precision has priority over fly boost if both keys are held.
    $speedTarget=$null
    if ($script:Flags.Fly -and $script:ExtraFlags.FlyPrecision -and (([FancyNative]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0)) { $speedTarget=0.5 }
    elseif ($script:Flags.Fly -and $script:ExtraFlags.FlyBoost -and (([FancyNative]::GetAsyncKeyState(0x10) -band 0x8000) -ne 0)) { $speedTarget=5.0 }
    if ($null -ne $speedTarget) {
        $ti=[int][Math]::Round(([double]$speedTarget/0.25)-1)
        if (-not $script:TempSpeedActive) { $script:TempSpeedSavedIndex=$script:LevelIndex.Speed; $script:TempSpeedActive=$true }
        if ($script:TempSpeedTarget -ne $ti) { Set-LevelExact 'Speed' ([double]$speedTarget); $script:TempSpeedTarget=$ti }
    } else { Restore-TempSpeed }

    $timeTarget=$null
    if ($script:ExtraFlags.HoldSlowmo -and (([FancyNative]::GetAsyncKeyState(0x22) -band 0x8000) -ne 0)) { $timeTarget=0.25 }
    elseif ($script:ExtraFlags.HoldFastForward -and (([FancyNative]::GetAsyncKeyState(0x21) -band 0x8000) -ne 0)) { $timeTarget=5.0 }
    if ($null -ne $timeTarget) {
        $ti=[int][Math]::Round(([double]$timeTarget/0.25)-1)
        if (-not $script:TempTimeActive) { $script:TempTimeSavedIndex=$script:LevelIndex.GameSpeed; $script:TempTimeActive=$true }
        if ($script:TempTimeTarget -ne $ti) { Set-LevelExact 'GameSpeed' ([double]$timeTarget); $script:TempTimeTarget=$ti }
    } else { Restore-TempTime }
}
function Test-HotkeyEdge([string]$name,[int]$vk) {
    $ctrl=((([FancyNative]::GetAsyncKeyState(0x11)) -band 0x8000) -ne 0)
    $shift=((([FancyNative]::GetAsyncKeyState(0x10)) -band 0x8000) -ne 0)
    $down=((([FancyNative]::GetAsyncKeyState($vk)) -band 0x8000) -ne 0) -and $ctrl -and $shift
    $prev=$false; if ($script:HotkeyEdges.ContainsKey($name)) { $prev=[bool]$script:HotkeyEdges[$name] }
    $script:HotkeyEdges[$name]=$down
    return ($down -and -not $prev)
}
function Run-QuickHotkeys {
    if ($script:OverlayVisible) { return }
    $p=Find-GameProcess; if (-not $p) { return }; $p.Refresh()
    if ([FancyNative]::GetForegroundWindow() -ne $p.MainWindowHandle) { return }
    if ($script:ExtraFlags.QuickHealKeys -and (Test-HotkeyEdge 'Heal' 0x48)) { Send-ExtendedCommand 22 | Out-Null }
    if ($script:ExtraFlags.QuickInkKeys -and (Test-HotkeyEdge 'Ink' 0x49)) { Send-ExtendedCommand 23 | Out-Null }
    if ($script:ExtraFlags.QuickSaveKeys -and (Test-HotkeyEdge 'Save' 0x4B)) { Send-ExtendedCommand 20 | Out-Null }
    if ($script:ExtraFlags.QuickTeleportKeys -and (Test-HotkeyEdge 'Teleport' 0x4C)) { Send-ExtendedCommand 21 | Out-Null }
    if ($script:ExtraFlags.QuickSquiggleKeys -and (Test-HotkeyEdge 'Squiggle' 0x47)) { Send-ExtendedCommand 24 | Out-Null }
    if ($script:ExtraFlags.QuickFlyKeys -and (Test-HotkeyEdge 'Fly' 0x46)) { Ensure-Flag 'Fly' (-not $script:Flags.Fly) }
    if ($script:ExtraFlags.QuickNoClipKeys -and (Test-HotkeyEdge 'NoClip' 0x4E)) { Ensure-Flag 'NoClip' (-not $script:Flags.NoClip) }
    if ($script:ExtraFlags.QuickInvincibleKeys -and (Test-HotkeyEdge 'Invincible' 0x56)) { Ensure-Flag 'Invincible' (-not $script:Flags.Invincible) }
    if ($script:ExtraFlags.QuickFriendlyKeys -and (Test-HotkeyEdge 'Friendly' 0x52)) { Ensure-Flag 'Friendly' (-not $script:Flags.Friendly) }
    if ($script:ExtraFlags.QuickFreezeKeys -and (Test-HotkeyEdge 'Freeze' 0x45)) { Ensure-Flag 'FreezeEnemies' (-not $script:Flags.FreezeEnemies) }
    if ($script:ExtraFlags.QuickOneHitKeys -and (Test-HotkeyEdge 'OneHit' 0x4F)) { Ensure-Flag 'OneHit' (-not $script:Flags.OneHit) }
}

function Run-AutomationMods {
    $p=Find-GameProcess
    if (-not $p) { Restore-TempSpeed; Restore-TempTime; $script:AutoUnlockProcessId=-1; $script:AutoUnlockStart=$null; return }
    Update-HoldMods
    Update-SmoothFpsRamp
    Run-QuickHotkeys
    if ($script:ExtraFlags.AutoHeal -and (Test-AutoDue 'AutoHeal' 900)) { Send-ExtendedCommand 22 | Out-Null }
    if ($script:ExtraFlags.AutoInk -and (Test-AutoDue 'AutoInk' 900)) { Send-ExtendedCommand 23 | Out-Null }
    if ($script:ExtraFlags.AutoSquiggles -and (Test-AutoDue 'AutoSquiggles' 4500)) { Send-ExtendedCommand 24 | Out-Null }
    if ($script:ExtraFlags.AutoSavePos -and (Test-AutoDue 'AutoSavePos' 5000)) { Send-ExtendedCommand 20 | Out-Null }
    if ($script:ExtraFlags.OutfitLock -and (Test-AutoDue 'OutfitLock' 4500)) { Apply-OutfitQuiet }
    if ($script:ExtraFlags.RainbowHat -and (Test-AutoDue 'RainbowHat' 650)) {
        if (-not $script:Flags.HatTint) { Toggle-ExtendedFlag 'HatTint' 8 }
        $script:CycleState.Rainbow=($script:CycleState.Rainbow+1)%13
        $script:HatTintColorInput.Value=$script:CycleState.Rainbow
        Send-ExtendedCommand (14000+$script:CycleState.Rainbow) | Out-Null; Send-ExtendedCommand 25 | Out-Null
    }
    if ($script:ExtraFlags.CycleHat -and (Test-AutoDue 'CycleHat' 2500)) {
        $script:HatInput.Value=([int]$script:HatInput.Value+1)%31; Apply-OutfitQuiet
    }
    if ($script:ExtraFlags.CyclePants -and (Test-AutoDue 'CyclePants' 2500)) {
        $script:PantsInput.Value=([int]$script:PantsInput.Value+1)%13; Apply-OutfitQuiet
    }
    if ($script:ExtraFlags.CyclePattern -and (Test-AutoDue 'CyclePattern' 2500)) {
        $script:PatternInput.Value=([int]$script:PatternInput.Value+1)%18; Apply-OutfitQuiet
    }
    if ($script:ExtraFlags.CyclePatternColor -and (Test-AutoDue 'CyclePatternColor' 1500)) {
        $script:ColorInput.Value=([int]$script:ColorInput.Value+1)%13; Apply-OutfitQuiet
    }
    if ($script:ExtraFlags.RandomOutfit -and (Test-AutoDue 'RandomOutfit' 4000)) { Randomize-Outfit; Apply-OutfitQuiet }
    if ($script:ExtraFlags.RandomHat -and (Test-AutoDue 'RandomHat' 3000)) { $script:HatInput.Value=Get-Random -Minimum 0 -Maximum 31; Apply-OutfitQuiet }
    if ($script:ExtraFlags.RandomPattern -and (Test-AutoDue 'RandomPattern' 3000)) { $script:PatternInput.Value=Get-Random -Minimum 0 -Maximum 18; Apply-OutfitQuiet }

    if ($script:ExtraFlags.SlowRainbow -and (Test-AutoDue 'SlowRainbow' 1800)) {
        if (-not $script:Flags.HatTint) { Toggle-ExtendedFlag 'HatTint' 8 }
        $script:CycleState.Rainbow=($script:CycleState.Rainbow+1)%13
        $script:HatTintColorInput.Value=$script:CycleState.Rainbow
        Send-ExtendedCommand (14000+$script:CycleState.Rainbow) | Out-Null; Send-ExtendedCommand 25 | Out-Null
    }
    if ($script:ExtraFlags.FastRainbow -and (Test-AutoDue 'FastRainbow' 180)) {
        if (-not $script:Flags.HatTint) { Toggle-ExtendedFlag 'HatTint' 8 }
        $script:CycleState.Rainbow=($script:CycleState.Rainbow+1)%13
        $script:HatTintColorInput.Value=$script:CycleState.Rainbow
        Send-ExtendedCommand (14000+$script:CycleState.Rainbow) | Out-Null; Send-ExtendedCommand 25 | Out-Null
    }
    if ($script:ExtraFlags.RandomPants -and (Test-AutoDue 'RandomPants' 3000)) { $script:PantsInput.Value=Get-Random -Minimum 0 -Maximum 13; Apply-OutfitQuiet }
    if ($script:ExtraFlags.RandomPatternColor -and (Test-AutoDue 'RandomPatternColor' 2200)) { $script:ColorInput.Value=Get-Random -Minimum 0 -Maximum 13; Apply-OutfitQuiet }
    if ($script:ExtraFlags.RandomTint -and (Test-AutoDue 'RandomTint' 1800)) {
        if (-not $script:Flags.HatTint) { Toggle-ExtendedFlag 'HatTint' 8 }
        $script:HatTintColorInput.Value=Get-Random -Minimum 0 -Maximum 13; Apply-OutfitQuiet
    }

    # Build 11 dynamic individual mods. These use the existing safe numeric command path.
    if ($script:ExtraFlags.RandomSpeed -and (Test-AutoDue 'RandomSpeed' 1800)) { Set-LevelExact 'Speed' ([double]$script:Levels[(Get-Random -Minimum 0 -Maximum $script:Levels.Count)]) }
    if ($script:ExtraFlags.CycleSpeed -and (Test-AutoDue 'CycleSpeed' 800)) { $script:CycleState.Speed=($script:CycleState.Speed+1)%$script:Levels.Count; Set-LevelExact 'Speed' ([double]$script:Levels[$script:CycleState.Speed]) }
    if ($script:ExtraFlags.PulseSpeed -and (Test-AutoDue 'PulseSpeed' 700)) { $script:CycleState.PulseSpeed=1-$script:CycleState.PulseSpeed; Set-LevelExact 'Speed' $(if($script:CycleState.PulseSpeed){3.0}else{0.5}) }

    if ($script:ExtraFlags.RandomJump -and (Test-AutoDue 'RandomJump' 2000)) { Set-LevelExact 'Jump' ([double]$script:Levels[(Get-Random -Minimum 0 -Maximum $script:Levels.Count)]) }
    if ($script:ExtraFlags.CycleJump -and (Test-AutoDue 'CycleJump' 900)) { $script:CycleState.Jump=($script:CycleState.Jump+1)%$script:Levels.Count; Set-LevelExact 'Jump' ([double]$script:Levels[$script:CycleState.Jump]) }
    if ($script:ExtraFlags.PulseJump -and (Test-AutoDue 'PulseJump' 900)) { $script:CycleState.PulseJump=1-$script:CycleState.PulseJump; Set-LevelExact 'Jump' $(if($script:CycleState.PulseJump){4.0}else{0.5}) }

    if ($script:ExtraFlags.RandomStrength -and (Test-AutoDue 'RandomStrength' 2200)) { Set-LevelExact 'Strength' ([double]$script:Levels[(Get-Random -Minimum 0 -Maximum $script:Levels.Count)]) }
    if ($script:ExtraFlags.CycleStrength -and (Test-AutoDue 'CycleStrength' 1000)) { $script:CycleState.Strength=($script:CycleState.Strength+1)%$script:Levels.Count; Set-LevelExact 'Strength' ([double]$script:Levels[$script:CycleState.Strength]) }
    if ($script:ExtraFlags.PulseStrength -and (Test-AutoDue 'PulseStrength' 850)) { $script:CycleState.PulseStrength=1-$script:CycleState.PulseStrength; Set-LevelExact 'Strength' $(if($script:CycleState.PulseStrength){5.0}else{0.5}) }

    if ($script:ExtraFlags.RandomTime -and (Test-AutoDue 'RandomTime' 2400)) { Set-LevelExact 'GameSpeed' ([double]$script:Levels[(Get-Random -Minimum 0 -Maximum $script:Levels.Count)]) }
    if ($script:ExtraFlags.CycleTime -and (Test-AutoDue 'CycleTime' 1100)) { $script:CycleState.Time=($script:CycleState.Time+1)%$script:Levels.Count; Set-LevelExact 'GameSpeed' ([double]$script:Levels[$script:CycleState.Time]) }
    if ($script:ExtraFlags.PulseTime -and (Test-AutoDue 'PulseTime' 1000)) { $script:CycleState.PulseTime=1-$script:CycleState.PulseTime; Set-LevelExact 'GameSpeed' $(if($script:CycleState.PulseTime){2.5}else{0.5}) }

    if ($script:ExtraFlags.RandomFps -and (Test-AutoDue 'RandomFps' 2600)) { Set-FpsQuick ([int]$script:FpsCycleValues[(Get-Random -Minimum 0 -Maximum $script:FpsCycleValues.Count)]) }
    if ($script:ExtraFlags.CycleFps -and (Test-AutoDue 'CycleFps' 1500)) { $script:CycleState.Fps=($script:CycleState.Fps+1)%$script:FpsCycleValues.Count; Set-FpsQuick ([int]$script:FpsCycleValues[$script:CycleState.Fps]) }
    if ($script:ExtraFlags.PulseFps -and (Test-AutoDue 'PulseFps' 1200)) { $script:CycleState.PulseFps=1-$script:CycleState.PulseFps; Set-FpsQuick $(if($script:CycleState.PulseFps){240}else{60}) }

    if ($script:ExtraFlags.AutoUnlockCosmetics) {
        if ($script:AutoUnlockProcessId -ne $p.Id) { $script:AutoUnlockProcessId=$p.Id; $script:AutoUnlockStart=[DateTime]::UtcNow }
        elseif ($script:AutoUnlockStart -and (([DateTime]::UtcNow-$script:AutoUnlockStart).TotalSeconds -ge 6)) {
            Send-ModKey 124 | Out-Null; $script:AutoUnlockStart=$null
        }
    }
}
function Reset-ExtraMods {
    Restore-TempSpeed; Restore-TempTime
    foreach($k in @($script:ExtraFlags.Keys)) { $script:ExtraFlags[$k]=$false; Update-ExtraButton $k }
    # Smoother game-speed rendering is the useful default for Build 11.
    $script:ExtraFlags.SmoothGameSpeed=$true; Update-ExtraButton 'SmoothGameSpeed'
    $script:SmoothFpsTarget=60; $script:SmoothFpsCurrent=60
    $script:AutomationLast=@{}; $script:HotkeyEdges=@{}; $script:AutoUnlockProcessId=-1; $script:AutoUnlockStart=$null
}
function Register-SearchItem($control,[string]$name,[string]$desc,[string]$category) {
    $item=[PSCustomObject]@{Control=$control;Name=$name;Desc=$desc;Category=$category}
    [void]$script:SearchModItems.Add($item)
}
function Filter-ModSearch {
    if (-not $script:ModsPage) { return }
    $q=''; if ($script:ModSearchBox) { $q=$script:ModSearchBox.Text.Trim().ToLowerInvariant() }
    $cat='ALL'; if ($script:CategoryFilter -and $script:CategoryFilter.SelectedItem) { $cat=[string]$script:CategoryFilter.SelectedItem }
    $visible=New-Object System.Collections.ArrayList
    foreach($item in $script:SearchModItems) {
        $hay=("$($item.Name) $($item.Desc) $($item.Category)").ToLowerInvariant()
        $matchText=([string]::IsNullOrWhiteSpace($q) -or $hay.Contains($q))
        $matchCat=($cat -eq 'ALL' -or $item.Category -eq $cat)
        $show=($matchText -and $matchCat)
        $item.Control.Visible=$show
        if ($show) { [void]$visible.Add($item) }
    }
    for($i=0;$i -lt $visible.Count;$i++) {
        $col=$i%2; $row=[int][Math]::Floor($i/2)
        $x=if($col -eq 0){12}else{311}; $y=112+($row*62)
        $visible[$i].Control.Location=New-Object System.Drawing.Point($x,$y)
    }
    $script:ModsPage.AutoScrollMinSize=New-Object System.Drawing.Size(0,(135+[Math]::Ceiling($visible.Count/2.0)*62))
    if ($script:SearchCountLabel) { $script:SearchCountLabel.Text="$($visible.Count) shown" }
}
function Add-SearchToggle([string]$name,[string]$label,[string]$desc,[string]$category) {
    $b=New-FancyButton $label 12 112 286 52
    $b.Font=New-FancyFont 7.5 ([System.Drawing.FontStyle]::Bold); $b.TextAlign=[System.Drawing.ContentAlignment]::MiddleCenter
    $b.Add_Click({ Toggle-ExtraFlag $name }.GetNewClosure())
    $script:ExtraButtons[$name]=$b; $script:ExtraButtonLabels[$name]=$label; Update-ExtraButton $name
    $script:ModsTip.SetToolTip($b,$desc); $script:ModsPage.Controls.Add($b); Register-SearchItem $b $label $desc $category
}
function Add-SearchAction([string]$label,[string]$desc,[string]$category,[scriptblock]$action) {
    $b=New-FancyButton $label 12 112 286 52
    $b.Font=New-FancyFont 7.5 ([System.Drawing.FontStyle]::Bold); $b.TextAlign=[System.Drawing.ContentAlignment]::MiddleCenter
    $b.Add_Click($action); $script:ModsTip.SetToolTip($b,$desc); $script:ModsPage.Controls.Add($b); Register-SearchItem $b $label $desc $category
}
# ---------------- END BUILD 11 INDIVIDUAL MOD ENGINE ----------------

function Add-ExtendedToggleRow($panel, [string]$title, [string]$description, [string]$name, [int]$command, [int]$y) {
    $row = New-CardPanel 8 $y 600 58
    $row.Controls.Add((New-FancyLabel $title 13 5 300 22 10.5 $true))
    $row.Controls.Add((New-FancyLabel $description 13 27 420 24 7.4 $false))
    $b = New-FancyButton "OFF" 466 8 116 40
    $b.BackColor = $script:CardOff
    $b.Add_Click({ Toggle-ExtendedFlag $name $command }.GetNewClosure())
    $row.Controls.Add($b)
    $panel.Controls.Add($row)
    $script:ToggleButtons[$name] = $b
    return ($y + 64)
}

function Add-ToggleRow($panel, [string]$title, [string]$description, [string]$name, [int]$vk, [int]$y) {
    $row = New-CardPanel 8 $y 600 58
    $row.Controls.Add((New-FancyLabel $title 13 5 300 22 10.5 $true))
    $row.Controls.Add((New-FancyLabel $description 13 27 420 24 7.4 $false))
    $b = New-FancyButton "OFF" 466 8 116 40
    $b.BackColor = $script:CardOff
    $b.Add_Click({ Toggle-Flag $name $vk }.GetNewClosure())
    $row.Controls.Add($b)
    $panel.Controls.Add($row)
    $script:ToggleButtons[$name] = $b
    return ($y + 64)
}

function Add-LevelRow($panel, [string]$title, [string]$description, [string]$name, [int]$y) {
    $row = New-CardPanel 8 $y 600 58
    $row.Controls.Add((New-FancyLabel $title 13 5 270 22 10.5 $true))
    $row.Controls.Add((New-FancyLabel $description 13 27 330 24 7.4 $false))
    $minus = New-FancyButton "<" 365 8 48 40
    $value = New-FancyLabel "1.00x" 414 10 78 36 10.2 $true
    $value.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $plus = New-FancyButton ">" 495 8 48 40
    $minus.BackColor = $script:Sky
    $plus.BackColor = $script:Sky
    $minus.Add_Click({ Change-Level $name -1 }.GetNewClosure())
    $plus.Add_Click({ Change-Level $name 1 }.GetNewClosure())
    $row.Controls.Add($minus); $row.Controls.Add($value); $row.Controls.Add($plus)
    $panel.Controls.Add($row)
    $script:ValueLabels[$name] = $value
    return ($y + 64)
}

function New-Page {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point(0,0)
    $p.Size = New-Object System.Drawing.Size(620,482)
    $p.BackColor = $script:Paper
    $p.AutoScroll = $true
    $p.Visible = $false
    return $p
}

function Show-Page([string]$name) {
    foreach ($k in $script:Pages.Keys) { $script:Pages[$k].Visible = $false }
    foreach ($k in $script:TabButtons.Keys) { $script:TabButtons[$k].BackColor = $script:Card }
    $script:Pages[$name].Visible = $true
    $script:Pages[$name].BringToFront()
    $script:TabButtons[$name].BackColor = $script:Pink
}

function Center-Overlay {
    $screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    $script:Overlay.Left = $screen.Left + [Math]::Max(0,[int](($screen.Width - $script:Overlay.Width) / 2))
    $script:Overlay.Top = $screen.Top + [Math]::Max(0,[int](($screen.Height - $script:Overlay.Height) / 2))
}

function Capture-BaseLayout($control) {
    foreach ($child in $control.Controls) {
        $script:BaseBounds[$child] = $child.Bounds
        if ($child.Font) { $script:BaseFontSizes[$child] = [double]$child.Font.Size }
        if ($child -is [System.Windows.Forms.ScrollableControl]) {
            $script:BaseScrollMin[$child] = $child.AutoScrollMinSize
        }
        if ($child.Controls.Count -gt 0) { Capture-BaseLayout $child }
    }
}

function Apply-ExactScaleToChildren($control,[double]$factor) {
    foreach ($child in $control.Controls) {
        if ($script:BaseBounds.ContainsKey($child)) {
            $r = $script:BaseBounds[$child]
            $child.Bounds = New-Object System.Drawing.Rectangle(
                [int][Math]::Round($r.X*$factor),
                [int][Math]::Round($r.Y*$factor),
                [int][Math]::Round($r.Width*$factor),
                [int][Math]::Round($r.Height*$factor)
            )
        }
        if ($script:BaseFontSizes.ContainsKey($child) -and $child.Font) {
            $newSize = [Math]::Max(5.0,[double]$script:BaseFontSizes[$child] * $factor)
            try { $child.Font = New-Object System.Drawing.Font($child.Font.FontFamily,$newSize,$child.Font.Style) } catch { }
        }
        if ($script:BaseScrollMin.ContainsKey($child)) {
            $sz = $script:BaseScrollMin[$child]
            $child.AutoScrollMinSize = New-Object System.Drawing.Size(
                [int][Math]::Round($sz.Width*$factor),
                [int][Math]::Round($sz.Height*$factor)
            )
        }
        if ($child.Controls.Count -gt 0) { Apply-ExactScaleToChildren $child $factor }
    }
}

function Set-OverlayScale([int]$pct) {
    $pct = [Math]::Max(50,[Math]::Min(110,$pct))
    $factor = $pct / 100.0
    $script:Overlay.SuspendLayout()
    $script:Overlay.ClientSize = New-Object System.Drawing.Size(
        [int][Math]::Round($script:OverlayBaseClientSize.Width*$factor),
        [int][Math]::Round($script:OverlayBaseClientSize.Height*$factor)
    )
    Apply-ExactScaleToChildren $script:Overlay $factor
    $script:OverlayScaleFactor = $factor
    $script:OverlayScalePct = $pct
    if ($script:ScaleValueLabel) { $script:ScaleValueLabel.Text = "$pct%" }
    if ($script:ScaleValueLabel2) { $script:ScaleValueLabel2.Text = "$pct%" }
    $script:Overlay.ResumeLayout($true)
    $script:Overlay.Invalidate($true)
    Center-Overlay
}

function Change-OverlayScale([int]$delta) {
    Set-OverlayScale ($script:OverlayScalePct + $delta)
}

# Main launcher
$main = New-Object System.Windows.Forms.Form
$script:MainForm = $main
$main.Text = "Fancy Mod Manager Build 11 Pro"
$main.ClientSize = New-Object System.Drawing.Size(680,600)
$main.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$main.BackColor = $script:Paper
$main.MaximizeBox = $false
$main.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$main.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$main.Font = New-FancyFont 10

$title = New-FancyLabel "SUPER FANCY PANTS" 24 18 632 50 23 $true
$title.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$main.Controls.Add($title)
$sub = New-FancyLabel "MOD MANAGER   BUILD 11 PRO" 24 68 632 32 13 $true
$sub.ForeColor = $script:Pink
$sub.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$main.Controls.Add($sub)

$launch = New-FancyButton "LAUNCH GAME" 80 130 520 60
$launch.Font = New-FancyFont 14 ([System.Drawing.FontStyle]::Bold)
$launch.BackColor = $script:CardOn
$launch.Add_Click({ Launch-Game })
$main.Controls.Add($launch)

$install = New-FancyButton "INSTALL BUILD 11" 80 212 250 52
$restore = New-FancyButton "RESTORE ORIGINAL" 350 212 250 52
$install.Add_Click({ Install-Mod | Out-Null })
$restore.Add_Click({ Restore-Original })
$main.Controls.Add($install); $main.Controls.Add($restore)

$choose = New-FancyButton "CHOOSE GAME FOLDER" 80 282 520 48
$choose.Add_Click({ if (Choose-GameFolder) { Set-Status "Game folder selected: $script:GameDir" } })
$main.Controls.Add($choose)

$info = New-FancyLabel "Build 11 Pro uses a compact Mega Hack inspired runtime panel, a rebuilt Noclip camera path, full enemy movement freeze, repeatable enemy summoning, searchable controls, and the stable save loading core." 66 350 548 84 9.1 $false
$info.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$info.ForeColor = $script:Muted
$main.Controls.Add($info)

$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Location = New-Object System.Drawing.Point(36,470)
$statusPanel.Size = New-Object System.Drawing.Size(608,82)
$statusPanel.BackColor = $script:Wood
$statusPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$main.Controls.Add($statusPanel)
$script:StatusLabel = New-FancyLabel "Ready." 12 8 580 62 8.8 $true
$script:StatusLabel.ForeColor = $script:White
$script:StatusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$statusPanel.Controls.Add($script:StatusLabel)

$main.Add_Paint({
    $g = $_.Graphics
    $line = New-Object System.Drawing.Pen($script:Pink,2)
    $dim = New-Object System.Drawing.Pen($script:Pencil,1)
    $g.DrawLine($line,44,108,636,108)
    $g.DrawLine($dim,44,447,636,447)
    $line.Dispose(); $dim.Dispose()
})

# Runtime mod book
$overlay = New-Object System.Windows.Forms.Form
$script:Overlay = $overlay
$overlay.ClientSize = New-Object System.Drawing.Size(700,790)
$overlay.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$overlay.BackColor = $script:Paper
$overlay.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$overlay.TopMost = $true
$overlay.ShowInTaskbar = $false
$overlay.Opacity = 0.98
$overlay.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None

$ovTitle = New-FancyLabel "SFPA  //  MOD MENU" 55 11 590 42 19 $true
$ovTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$overlay.Controls.Add($ovTitle)
$ovSub = New-FancyLabel 'BUILD 11 PRO   •   GAME PAUSED   •   Tab or ` closes' 80 51 540 24 8.8 $true
$ovSub.ForeColor = $script:Pink
$ovSub.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$overlay.Controls.Add($ovSub)

$scaleMinus = New-FancyButton "UI <" 22 80 70 34
$scaleMinus.Font = New-FancyFont 8.2 ([System.Drawing.FontStyle]::Bold)
$scaleMinus.BackColor = $script:Sky
$scaleMinus.Add_Click({ Change-OverlayScale -10 })
$overlay.Controls.Add($scaleMinus)
$scaleValue = New-FancyLabel "90%" 94 82 55 30 8.5 $true
$scaleValue.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$overlay.Controls.Add($scaleValue)
$script:ScaleValueLabel = $scaleValue
$scalePlus = New-FancyButton "UI >" 151 80 70 34
$scalePlus.Font = New-FancyFont 8.2 ([System.Drawing.FontStyle]::Bold)
$scalePlus.BackColor = $script:Sky
$scalePlus.Add_Click({ Change-OverlayScale 10 })
$overlay.Controls.Add($scalePlus)

$globalSearchLabel = New-FancyLabel "SEARCH" 354 82 72 28 8.2 $true
$overlay.Controls.Add($globalSearchLabel)
$globalSearch = New-Object System.Windows.Forms.TextBox
$globalSearch.Location = New-Object System.Drawing.Point(426,82)
$globalSearch.Size = New-Object System.Drawing.Size(220,30)
$globalSearch.Font = New-FancyFont 9
$globalSearch.Add_TextChanged({
    if ($script:ModSearchBox -and $script:ModSearchBox.Text -ne $globalSearch.Text) { $script:ModSearchBox.Text=$globalSearch.Text }
    if ($script:Pages.ContainsKey('MODS')) { Show-Page 'MODS'; Filter-ModSearch }
})
$overlay.Controls.Add($globalSearch)
$script:GlobalSearchBox=$globalSearch

$pagesHost = New-Object System.Windows.Forms.Panel
$pagesHost.Location = New-Object System.Drawing.Point(38,196)
$pagesHost.Size = New-Object System.Drawing.Size(624,486)
$pagesHost.BackColor = $script:Paper
$pagesHost.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$overlay.Controls.Add($pagesHost)

$script:Pages = @{}
$script:TabButtons = @{}

$row1 = @("PLAYER","MOVE","WORLD","FUN","MODS")
for ($i=0; $i -lt $row1.Count; $i++) {
    $tabName = $row1[$i]
    $b = New-FancyButton $tabName (24 + ($i * 130)) 118 118 34
    $b.Font = New-FancyFont 7.5 ([System.Drawing.FontStyle]::Bold)
    $b.FlatAppearance.BorderSize = 2
    $b.Add_Click({ Show-Page $tabName }.GetNewClosure())
    $overlay.Controls.Add($b)
    $script:TabButtons[$tabName] = $b
}
$row2 = @("ART","STYLE","DISPLAY","UNLOCKS")
for ($i=0; $i -lt $row2.Count; $i++) {
    $tabName = $row2[$i]
    $b = New-FancyButton $tabName (73 + ($i * 146)) 156 136 34
    $b.Font = New-FancyFont 7.5 ([System.Drawing.FontStyle]::Bold)
    $b.FlatAppearance.BorderSize = 2
    $b.Add_Click({ Show-Page $tabName }.GetNewClosure())
    $overlay.Controls.Add($b)
    $script:TabButtons[$tabName] = $b
}

# Player page
$playerPage = New-Page
$pagesHost.Controls.Add($playerPage)
$script:Pages.PLAYER = $playerPage
$y = 8
$y = Add-ToggleRow $playerPage "Invincible" "You react to hits, but health is restored to full." "Invincible" 112 $y
$y = Add-ToggleRow $playerPage "Friendly" "Enemy and hazard hurt calls are ignored." "Friendly" 113 $y
$y = Add-LevelRow $playerPage "Speed" "Horizontal movement multiplier." "Speed" $y
$y = Add-LevelRow $playerPage "Jump Height" "Normal and air jump multiplier." "Jump" $y
$y = Add-LevelRow $playerPage "Strength" "Attack power multiplier." "Strength" $y
$y = Add-ToggleRow $playerPage "Infinite Jumps" "Jump again in the air as many times as you want." "InfiniteJumps" 120 $y
$y = Add-ToggleRow $playerPage "Infinite Ammo" "Keeps the pen gun ink reserve full." "InfiniteAmmo" 121 $y
$y = Add-ToggleRow $playerPage "Infinite Lives" "Keeps the current character at 99 lives." "InfiniteLives" 129 $y
$y = Add-ToggleRow $playerPage "Infinite Squiggles" "Purchases succeed without spending squiggles." "InfiniteSquiggles" 130 $y
$playerPage.AutoScrollMinSize = New-Object System.Drawing.Size(0,($y+8))

# Movement page
$movePage = New-Page
$pagesHost.Controls.Add($movePage)
$script:Pages.MOVE = $movePage
$y = 18
$y = Add-ToggleRow $movePage "Fly" "Free movement with a direct player locked camera." "Fly" 118 $y
$y = Add-ToggleRow $movePage "Noclip" "Pass through walls and floors. Requires Fly." "NoClip" 119 $y
$script:ToggleButtons.NoClip.Enabled = $false
$moveInfo = New-CardPanel 8 ($y+14) 600 138
$moveInfo.Controls.Add((New-FancyLabel "FLY CONTROLS" 18 12 560 28 12 $true))
$moveInfo.Controls.Add((New-FancyLabel "Use your normal left and right controls. Use Up and Down to move vertically. Noclip stays locked until Fly is enabled. The camera is forced to Fancy Pants every Fly frame, including while Noclip is active." 18 44 555 78 8.4 $false))
$movePage.Controls.Add($moveInfo)

# World page
$worldPage = New-Page
$pagesHost.Controls.Add($worldPage)
$script:Pages.WORLD = $worldPage
$y = 18
$y = Add-LevelRow $worldPage "Game Speed" "Simulation speed from 0.25x through 5.00x." "GameSpeed" $y
$y = Add-ToggleRow $worldPage "Freeze Enemies" "Stops standard enemy and most boss updates." "FreezeEnemies" 131 $y
$y = Add-ToggleRow $worldPage "One Hit KO" "A damaging hit defeats standard enemies instantly." "OneHit" 132 $y

# Fun page
$funPage = New-Page
$pagesHost.Controls.Add($funPage)
$script:Pages.FUN = $funPage
$y = 8
$y = Add-ExtendedToggleRow $funPage "No Pit Death" "Falling out of the world no longer triggers the pit death routine." "NoPitDeath" 1 $y
$y = Add-ExtendedToggleRow $funPage "No Squish" "Crushers and squish checks cannot squish Fancy Pants." "NoSquish" 2 $y
$y = Add-ExtendedToggleRow $funPage "No Knockback" "Hits can still happen, but smash knockback is suppressed." "NoKnockback" 6 $y
$y = Add-ExtendedToggleRow $funPage "No Screen Shake" "Disables the game's screen shake calls." "NoScreenShake" 3 $y
$y = Add-ExtendedToggleRow $funPage "All Tools" "Keeps pencil, pen gun, shooting, advanced pencil, and zip enabled." "AllTools" 4 $y
$y = Add-ExtendedToggleRow $funPage "All Pencil Moves" "Keeps Buzz Saw, Poke Down, and Rising unlocked." "AllMoves" 5 $y
$y = Add-ExtendedToggleRow $funPage "Max Power" "Keeps the player's power upgrade level at the game's max value." "MaxPower" 7 $y
$quick = New-CardPanel 8 $y 600 170
$quick.Controls.Add((New-FancyLabel "QUICK ACTIONS" 14 8 570 26 11.5 $true))
$savePos = New-FancyButton "SAVE POSITION" 16 42 175 46
$warpPos = New-FancyButton "TELEPORT BACK" 207 42 175 46
$healNow = New-FancyButton "HEAL NOW" 398 42 175 46
$inkNow = New-FancyButton "REFILL INK" 16 102 175 46
$squigNow = New-FancyButton "9999 SQUIGGLES" 207 102 175 46
$savePos.Add_Click({ Send-OneShot 20 "Position will be saved as soon as the mod book closes." })
$warpPos.Add_Click({ Send-OneShot 21 "Teleport queued. Close the mod book to warp to the saved position." })
$healNow.Add_Click({ Send-OneShot 22 "Full heal queued." })
$inkNow.Add_Click({ Send-OneShot 23 "Ink refill queued." })
$squigNow.Add_Click({ Send-OneShot 24 "9999 squiggles queued." })
foreach ($b in @($savePos,$warpPos,$healNow,$inkNow,$squigNow)) { $b.BackColor = $script:Sky; $quick.Controls.Add($b) }
$funPage.Controls.Add($quick)
$funPage.AutoScrollMinSize = New-Object System.Drawing.Size(0,($y+188))


# Individual searchable mods page
$modsPage = New-Page
$pagesHost.Controls.Add($modsPage)
$script:Pages.MODS = $modsPage
$script:ModsPage = $modsPage
$modsTitle = New-FancyLabel "MOD LIBRARY" 18 8 575 30 13.5 $true
$modsTitle.TextAlign=[System.Drawing.ContentAlignment]::MiddleCenter
$modsPage.Controls.Add($modsTitle)
$modSearch = New-Object System.Windows.Forms.TextBox
$modSearch.Location=New-Object System.Drawing.Point(18,44); $modSearch.Size=New-Object System.Drawing.Size(270,30); $modSearch.Font=New-FancyFont 9
$modSearch.Add_TextChanged({ if($script:GlobalSearchBox -and $script:GlobalSearchBox.Text -ne $modSearch.Text){$script:GlobalSearchBox.Text=$modSearch.Text}; Filter-ModSearch })
$modsPage.Controls.Add($modSearch); $script:ModSearchBox=$modSearch
$category = New-Object System.Windows.Forms.ComboBox
$category.Location=New-Object System.Drawing.Point(298,44); $category.Size=New-Object System.Drawing.Size(150,30); $category.DropDownStyle=[System.Windows.Forms.ComboBoxStyle]::DropDownList; $category.Font=New-FancyFont 8.2
[void]$category.Items.AddRange(@('ALL','AUTOMATION','UTILITY','COSMETIC','DISPLAY','MOVEMENT','COMBAT','WORLD','UNLOCK'))
$category.SelectedIndex=0; $category.Add_SelectedIndexChanged({ Filter-ModSearch })
$modsPage.Controls.Add($category); $script:CategoryFilter=$category
$clearSearch=New-FancyButton 'CLEAR' 458 44 72 30; $clearSearch.Font=New-FancyFont 7.4 ([System.Drawing.FontStyle]::Bold)
$clearSearch.Add_Click({ $script:ModSearchBox.Text=''; $script:CategoryFilter.SelectedIndex=0; Filter-ModSearch })
$modsPage.Controls.Add($clearSearch)
$searchCount=New-FancyLabel "" 532 47 66 24 7.0 $true; $searchCount.TextAlign=[System.Drawing.ContentAlignment]::MiddleRight
$modsPage.Controls.Add($searchCount); $script:SearchCountLabel=$searchCount
$script:ModsTip=New-Object System.Windows.Forms.ToolTip

# 19 new automation / live modifier mods.
Add-SearchToggle 'AutoHeal' 'AUTO HEAL' 'Refresh health about once per second without removing normal hit reactions.' 'AUTOMATION'
Add-SearchToggle 'AutoInk' 'AUTO INK REFILL' 'Refills pen gun ink automatically.' 'AUTOMATION'
Add-SearchToggle 'AutoSquiggles' 'AUTO 9999 SQUIGGLES' 'Refreshes your squiggle total to 9999 every few seconds.' 'AUTOMATION'
Add-SearchToggle 'AutoSavePos' 'AUTO SAVE POSITION' 'Updates the teleport anchor every five seconds.' 'UTILITY'
Add-SearchToggle 'RainbowHat' 'RAINBOW HAT' 'Cycles the custom hat tint through the game color palette.' 'COSMETIC'
Add-SearchToggle 'CycleHat' 'AUTO CYCLE HATS' 'Moves to the next hat every few seconds.' 'COSMETIC'
Add-SearchToggle 'CyclePants' 'AUTO CYCLE PANTS COLORS' 'Cycles through pants colors automatically.' 'COSMETIC'
Add-SearchToggle 'CyclePattern' 'AUTO CYCLE PATTERNS' 'Cycles through pants patterns automatically.' 'COSMETIC'
Add-SearchToggle 'CyclePatternColor' 'AUTO PATTERN COLORS' 'Cycles the pants pattern color automatically.' 'COSMETIC'
Add-SearchToggle 'RandomOutfit' 'RANDOM OUTFIT LOOP' 'Chooses a completely random outfit every four seconds.' 'COSMETIC'
Add-SearchToggle 'RandomHat' 'RANDOM HAT LOOP' 'Chooses a random hat every three seconds.' 'COSMETIC'
Add-SearchToggle 'RandomPattern' 'RANDOM PATTERN LOOP' 'Chooses a random pants pattern every three seconds.' 'COSMETIC'
Add-SearchToggle 'OutfitLock' 'OUTFIT LOCK' 'Reapplies the selected STYLE outfit so level scripts cannot keep changing it.' 'COSMETIC'
Add-SearchToggle 'SmoothGameSpeed' 'SMOOTH GAME SPEED' 'Raises render FPS with fast game speed so 2x through 5x motion has more visual steps.' 'DISPLAY'
Add-SearchToggle 'FlyBoost' 'FLY BOOST  [SHIFT]' 'While Fly is on, hold Shift for temporary 5x flight movement.' 'MOVEMENT'
Add-SearchToggle 'FlyPrecision' 'FLY PRECISION  [CTRL]' 'While Fly is on, hold Ctrl for precise 0.5x flight movement.' 'MOVEMENT'
Add-SearchToggle 'HoldSlowmo' 'HOLD SLOWMO  [PGDN]' 'Hold Page Down in gameplay for temporary 0.25x game speed.' 'WORLD'
Add-SearchToggle 'HoldFastForward' 'HOLD FAST FORWARD  [PGUP]' 'Hold Page Up in gameplay for temporary 5x game speed.' 'WORLD'
Add-SearchToggle 'AutoUnlockCosmetics' 'AUTO UNLOCK COSMETICS' 'Sends the hat and pants unlock command a few seconds after each game launch.' 'UNLOCK'
Add-SearchToggle 'SlowRainbow' 'RAINBOW HAT  SLOW' 'Cycles the hat tint slowly for a softer color animation.' 'COSMETIC'
Add-SearchToggle 'FastRainbow' 'RAINBOW HAT  FAST' 'Cycles the hat tint rapidly.' 'COSMETIC'
Add-SearchToggle 'RandomPants' 'RANDOM PANTS LOOP' 'Randomizes only the pants color every few seconds.' 'COSMETIC'
Add-SearchToggle 'RandomPatternColor' 'RANDOM PATTERN COLOR' 'Randomizes only the pants pattern color.' 'COSMETIC'
Add-SearchToggle 'RandomTint' 'RANDOM HAT TINT' 'Randomizes the hat tint while keeping the selected hat.' 'COSMETIC'
Add-SearchToggle 'QuickHealKeys' 'HOTKEY  HEAL' 'Ctrl + Shift + H heals immediately during gameplay.' 'UTILITY'
Add-SearchToggle 'QuickInkKeys' 'HOTKEY  REFILL INK' 'Ctrl + Shift + I refills ink.' 'UTILITY'
Add-SearchToggle 'QuickSaveKeys' 'HOTKEY  SAVE POSITION' 'Ctrl + Shift + K stores your current position.' 'UTILITY'
Add-SearchToggle 'QuickTeleportKeys' 'HOTKEY  TELEPORT' 'Ctrl + Shift + L teleports to the saved position.' 'UTILITY'
Add-SearchToggle 'QuickSquiggleKeys' 'HOTKEY  9999 SQUIGGLES' 'Ctrl + Shift + G gives 9999 squiggles.' 'UTILITY'
Add-SearchToggle 'QuickFlyKeys' 'HOTKEY  FLY' 'Ctrl + Shift + F toggles Fly.' 'MOVEMENT'
Add-SearchToggle 'QuickNoClipKeys' 'HOTKEY  NOCLIP' 'Ctrl + Shift + N toggles Noclip and enables Fly when needed.' 'MOVEMENT'
Add-SearchToggle 'QuickInvincibleKeys' 'HOTKEY  INVINCIBLE' 'Ctrl + Shift + V toggles Invincible.' 'COMBAT'
Add-SearchToggle 'QuickFriendlyKeys' 'HOTKEY  FRIENDLY' 'Ctrl + Shift + R toggles Friendly mode.' 'COMBAT'
Add-SearchToggle 'QuickFreezeKeys' 'HOTKEY  FREEZE ENEMIES' 'Ctrl + Shift + E toggles Freeze Enemies.' 'WORLD'
Add-SearchToggle 'QuickOneHitKeys' 'HOTKEY  ONE HIT' 'Ctrl + Shift + O toggles One Hit KO.' 'COMBAT'

# Single-setting movement modifiers. These are not packs: every button changes only one value.
Add-SearchAction 'MOVEMENT 0.25x' 'Set only player movement speed to 0.25x.' 'MOVEMENT' { Set-QuickLevel 'Speed' 0.25 }
Add-SearchAction 'MOVEMENT 0.50x' 'Set only player movement speed to 0.50x.' 'MOVEMENT' { Set-QuickLevel 'Speed' 0.50 }
Add-SearchAction 'MOVEMENT 2.00x' 'Set only player movement speed to 2x.' 'MOVEMENT' { Set-QuickLevel 'Speed' 2.00 }
Add-SearchAction 'MOVEMENT 3.00x' 'Set only player movement speed to 3x.' 'MOVEMENT' { Set-QuickLevel 'Speed' 3.00 }
Add-SearchAction 'MOVEMENT 5.00x' 'Set only player movement speed to 5x.' 'MOVEMENT' { Set-QuickLevel 'Speed' 5.00 }
Add-SearchAction 'JUMP 0.25x' 'Set only jump height to 0.25x.' 'MOVEMENT' { Set-QuickLevel 'Jump' 0.25 }
Add-SearchAction 'JUMP 0.50x' 'Set only jump height to 0.50x.' 'MOVEMENT' { Set-QuickLevel 'Jump' 0.50 }
Add-SearchAction 'JUMP 2.00x' 'Set only jump height to 2x.' 'MOVEMENT' { Set-QuickLevel 'Jump' 2.00 }
Add-SearchAction 'JUMP 3.00x' 'Set only jump height to 3x.' 'MOVEMENT' { Set-QuickLevel 'Jump' 3.00 }
Add-SearchAction 'JUMP 5.00x' 'Set only jump height to 5x.' 'MOVEMENT' { Set-QuickLevel 'Jump' 5.00 }
Add-SearchAction 'STRENGTH 0.25x' 'Set only attack strength to 0.25x.' 'COMBAT' { Set-QuickLevel 'Strength' 0.25 }
Add-SearchAction 'STRENGTH 0.50x' 'Set only attack strength to 0.50x.' 'COMBAT' { Set-QuickLevel 'Strength' 0.50 }
Add-SearchAction 'STRENGTH 2.00x' 'Set only attack strength to 2x.' 'COMBAT' { Set-QuickLevel 'Strength' 2.00 }
Add-SearchAction 'STRENGTH 3.00x' 'Set only attack strength to 3x.' 'COMBAT' { Set-QuickLevel 'Strength' 3.00 }
Add-SearchAction 'STRENGTH 5.00x' 'Set only attack strength to 5x.' 'COMBAT' { Set-QuickLevel 'Strength' 5.00 }
Add-SearchAction 'GAME SPEED 0.25x' 'Set only simulation speed to 0.25x.' 'WORLD' { Set-QuickLevel 'GameSpeed' 0.25 }
Add-SearchAction 'GAME SPEED 0.50x' 'Set only simulation speed to 0.50x.' 'WORLD' { Set-QuickLevel 'GameSpeed' 0.50 }
Add-SearchAction 'GAME SPEED 1.50x' 'Set only simulation speed to 1.50x.' 'WORLD' { Set-QuickLevel 'GameSpeed' 1.50 }
Add-SearchAction 'GAME SPEED 2.00x' 'Set only simulation speed to 2x.' 'WORLD' { Set-QuickLevel 'GameSpeed' 2.00 }
Add-SearchAction 'GAME SPEED 3.00x' 'Set only simulation speed to 3x.' 'WORLD' { Set-QuickLevel 'GameSpeed' 3.00 }
Add-SearchAction 'GAME SPEED 5.00x' 'Set only simulation speed to 5x.' 'WORLD' { Set-QuickLevel 'GameSpeed' 5.00 }

# Four useful single FPS target mods. Total new individual controls on this page: 44.
Add-SearchAction 'FPS 60' 'Set only the render target to 60 FPS.' 'DISPLAY' { Set-FpsQuick 60 }
Add-SearchAction 'FPS 120' 'Set only the render target to 120 FPS.' 'DISPLAY' { Set-FpsQuick 120 }
Add-SearchAction 'FPS 144' 'Set only the render target to 144 FPS.' 'DISPLAY' { Set-FpsQuick 144 }
Add-SearchAction 'FPS 240' 'Set only the render target to 240 FPS.' 'DISPLAY' { Set-FpsQuick 240 }
Add-SearchAction 'MOVEMENT 0.75x' 'Set only player movement speed to 0.75x.' 'MOVEMENT' { Set-QuickLevel 'Speed' 0.75 }
Add-SearchAction 'MOVEMENT 1.00x' 'Reset only player movement speed to 1x.' 'MOVEMENT' { Set-QuickLevel 'Speed' 1.00 }
Add-SearchAction 'MOVEMENT 1.25x' 'Set only player movement speed to 1.25x.' 'MOVEMENT' { Set-QuickLevel 'Speed' 1.25 }
Add-SearchAction 'MOVEMENT 1.50x' 'Set only player movement speed to 1.50x.' 'MOVEMENT' { Set-QuickLevel 'Speed' 1.50 }
Add-SearchAction 'MOVEMENT 1.75x' 'Set only player movement speed to 1.75x.' 'MOVEMENT' { Set-QuickLevel 'Speed' 1.75 }
Add-SearchAction 'MOVEMENT 2.50x' 'Set only player movement speed to 2.50x.' 'MOVEMENT' { Set-QuickLevel 'Speed' 2.50 }
Add-SearchAction 'MOVEMENT 4.00x' 'Set only player movement speed to 4x.' 'MOVEMENT' { Set-QuickLevel 'Speed' 4.00 }
Add-SearchAction 'JUMP 0.75x' 'Set only jump height to 0.75x.' 'MOVEMENT' { Set-QuickLevel 'Jump' 0.75 }
Add-SearchAction 'JUMP 1.00x' 'Reset only jump height to 1x.' 'MOVEMENT' { Set-QuickLevel 'Jump' 1.00 }
Add-SearchAction 'JUMP 1.25x' 'Set only jump height to 1.25x.' 'MOVEMENT' { Set-QuickLevel 'Jump' 1.25 }
Add-SearchAction 'JUMP 1.50x' 'Set only jump height to 1.50x.' 'MOVEMENT' { Set-QuickLevel 'Jump' 1.50 }
Add-SearchAction 'JUMP 1.75x' 'Set only jump height to 1.75x.' 'MOVEMENT' { Set-QuickLevel 'Jump' 1.75 }
Add-SearchAction 'JUMP 2.50x' 'Set only jump height to 2.50x.' 'MOVEMENT' { Set-QuickLevel 'Jump' 2.50 }
Add-SearchAction 'JUMP 4.00x' 'Set only jump height to 4x.' 'MOVEMENT' { Set-QuickLevel 'Jump' 4.00 }
Add-SearchAction 'STRENGTH 0.75x' 'Set only attack strength to 0.75x.' 'COMBAT' { Set-QuickLevel 'Strength' 0.75 }
Add-SearchAction 'STRENGTH 1.00x' 'Reset only attack strength to 1x.' 'COMBAT' { Set-QuickLevel 'Strength' 1.00 }
Add-SearchAction 'STRENGTH 1.25x' 'Set only attack strength to 1.25x.' 'COMBAT' { Set-QuickLevel 'Strength' 1.25 }
Add-SearchAction 'STRENGTH 1.50x' 'Set only attack strength to 1.50x.' 'COMBAT' { Set-QuickLevel 'Strength' 1.50 }
Add-SearchAction 'STRENGTH 1.75x' 'Set only attack strength to 1.75x.' 'COMBAT' { Set-QuickLevel 'Strength' 1.75 }
Add-SearchAction 'STRENGTH 2.50x' 'Set only attack strength to 2.50x.' 'COMBAT' { Set-QuickLevel 'Strength' 2.50 }
Add-SearchAction 'STRENGTH 4.00x' 'Set only attack strength to 4x.' 'COMBAT' { Set-QuickLevel 'Strength' 4.00 }
Add-SearchAction 'GAME SPEED 0.75x' 'Set only simulation speed to 0.75x.' 'WORLD' { Set-QuickLevel 'GameSpeed' 0.75 }
Add-SearchAction 'GAME SPEED 1.00x' 'Reset only simulation speed to 1x.' 'WORLD' { Set-QuickLevel 'GameSpeed' 1.00 }
Add-SearchAction 'GAME SPEED 1.25x' 'Set only simulation speed to 1.25x.' 'WORLD' { Set-QuickLevel 'GameSpeed' 1.25 }
Add-SearchAction 'GAME SPEED 1.75x' 'Set only simulation speed to 1.75x.' 'WORLD' { Set-QuickLevel 'GameSpeed' 1.75 }
Add-SearchAction 'GAME SPEED 2.50x' 'Set only simulation speed to 2.50x.' 'WORLD' { Set-QuickLevel 'GameSpeed' 2.50 }
Add-SearchAction 'GAME SPEED 4.00x' 'Set only simulation speed to 4x.' 'WORLD' { Set-QuickLevel 'GameSpeed' 4.00 }
Add-SearchAction 'FPS 30' 'Set render target to 30 FPS.' 'DISPLAY' { Set-FpsQuick 30 }
Add-SearchAction 'FPS 75' 'Set render target to 75 FPS.' 'DISPLAY' { Set-FpsQuick 75 }
Add-SearchAction 'FPS 90' 'Set render target to 90 FPS.' 'DISPLAY' { Set-FpsQuick 90 }
Add-SearchAction 'FPS 165' 'Set render target to 165 FPS.' 'DISPLAY' { Set-FpsQuick 165 }
Add-SearchAction 'FPS 360' 'Set render target to 360 FPS.' 'DISPLAY' { Set-FpsQuick 360 }
Add-SearchAction 'FPS 500' 'Set render target to 500 FPS.' 'DISPLAY' { Set-FpsQuick 500 }
Add-SearchAction 'FPS 1000' 'Set render target to the Adobe AIR maximum of 1000 FPS.' 'DISPLAY' { Set-FpsQuick 1000 }
Filter-ModSearch

# True custom art page
$artPage = New-Page
$pagesHost.Controls.Add($artPage)
$script:Pages.ART = $artPage

$artTitle = New-FancyLabel "CUSTOM HAT + PANTS DRAWING" 20 12 575 36 14 $true
$artTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$artPage.Controls.Add($artTitle)
$artIntro = New-CardPanel 12 55 588 95
$artIntro.Controls.Add((New-FancyLabel "DRAW IT YOURSELF" 14 8 555 24 10.5 $true))
$artIntro.Controls.Add((New-FancyLabel "Paint actual pixels, then turn Custom Art on when you want the drawings baked into the game. If an image fails validation, Build 11 automatically falls back to the stable base art." 14 34 555 50 7.6 $false))
$artPage.Controls.Add($artIntro)

$drawHat = New-FancyButton "DRAW CUSTOM HAT" 28 170 255 55
$drawHat.BackColor = $script:Pink
$drawHat.Font = New-FancyFont 10 ([System.Drawing.FontStyle]::Bold)
$drawHat.Add_Click({ Open-CustomArtEditor "Hat"; if ($script:ArtHatPreview) { $script:ArtHatPreview.Invalidate() } })
$artPage.Controls.Add($drawHat)

$drawPants = New-FancyButton "DRAW CUSTOM PANTS" 316 170 255 55
$drawPants.BackColor = $script:Sky
$drawPants.Font = New-FancyFont 10 ([System.Drawing.FontStyle]::Bold)
$drawPants.Add_Click({ Open-CustomArtEditor "Pants"; if ($script:ArtPantsPreview) { $script:ArtPantsPreview.Invalidate() } })
$artPage.Controls.Add($drawPants)

$hatCard = New-CardPanel 28 244 255 150
$hatCard.Controls.Add((New-FancyLabel "CUSTOM HAT  INDEX 30" 12 8 230 24 9.5 $true))
$hatPreview = New-Object System.Windows.Forms.Panel
$hatPreview.Location = New-Object System.Drawing.Point(14,38)
$hatPreview.Size = New-Object System.Drawing.Size(226,64)
$hatPreview.BackColor = [System.Drawing.Color]::White
$hatPreview.Add_Paint({
    $g=$_.Graphics
    $g.Clear([System.Drawing.Color]::White)
    if (Test-Path $script:HatArtPath) {
        $img=New-Object System.Drawing.Bitmap($script:HatArtPath)
        try {
            $g.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
            $g.PixelOffsetMode=[System.Drawing.Drawing2D.PixelOffsetMode]::Half
            $g.DrawImage($img,(New-Object System.Drawing.Rectangle(61,2,102,60)))
        } finally { $img.Dispose() }
    }
})
$hatCard.Controls.Add($hatPreview)
$script:ArtHatPreview=$hatPreview
$useHat = New-FancyButton "USE CUSTOM HAT" 35 108 185 32
$useHat.Font = New-FancyFont 7.3 ([System.Drawing.FontStyle]::Bold)
$useHat.Add_Click({ Use-CustomHat })
$hatCard.Controls.Add($useHat)
$artPage.Controls.Add($hatCard)

$pantsCard = New-CardPanel 316 244 255 150
$pantsCard.Controls.Add((New-FancyLabel "CUSTOM PANTS  PATTERN 17" 12 8 230 24 9.5 $true))
$pantsPreview = New-Object System.Windows.Forms.Panel
$pantsPreview.Location = New-Object System.Drawing.Point(14,38)
$pantsPreview.Size = New-Object System.Drawing.Size(226,64)
$pantsPreview.BackColor = [System.Drawing.Color]::White
$pantsPreview.Add_Paint({
    $g=$_.Graphics
    $g.Clear([System.Drawing.Color]::White)
    if (Test-Path $script:PantsArtPath) {
        $img=New-Object System.Drawing.Bitmap($script:PantsArtPath)
        try {
            $g.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
            $g.PixelOffsetMode=[System.Drawing.Drawing2D.PixelOffsetMode]::Half
            $g.DrawImage($img,(New-Object System.Drawing.Rectangle(90,2,46,60)))
        } finally { $img.Dispose() }
    }
})
$pantsCard.Controls.Add($pantsPreview)
$script:ArtPantsPreview=$pantsPreview
$usePants = New-FancyButton "USE CUSTOM PANTS" 35 108 185 32
$usePants.Font = New-FancyFont 7.3 ([System.Drawing.FontStyle]::Bold)
$usePants.Add_Click({ Use-CustomPants })
$pantsCard.Controls.Add($usePants)
$artPage.Controls.Add($pantsCard)

$customArtToggle = New-FancyButton "CUSTOM ART  OFF" 28 414 255 48
$customArtToggle.BackColor = $script:CardOff
$customArtToggle.Add_Click({ Set-CustomArtEnabled (-not $script:CustomArtEnabled); if ($script:CustomArtEnabled) { Set-Status "Custom art enabled. Restart through Build 11 to load your drawings." } else { Set-Status "Custom art disabled. The stable base cosmetic slots will be used on next launch." } })
$artPage.Controls.Add($customArtToggle); $script:CustomArtToggleButton=$customArtToggle
Set-CustomArtEnabled $script:CustomArtEnabled
$rebuildArt = New-FancyButton "REBUILD ART" 316 414 255 48
$rebuildArt.BackColor = $script:Gold
$rebuildArt.Add_Click({
    if (Build-CustomizedModSwf) {
        if (Find-GameProcess) { Set-Status "Custom art rebuilt. Restart SFPA through Build 11 to load it." }
        else { Set-Status "Custom art rebuilt and ready for the next launch." }
    }
})
$artPage.Controls.Add($rebuildArt)

$artHelp = New-CardPanel 28 480 543 118
$artHelp.Controls.Add((New-FancyLabel "HOW THE CUSTOM SLOTS WORK" 14 8 510 24 10 $true))
$artHelp.Controls.Add((New-FancyLabel "Custom Hat uses hat index 30 and Custom Pants uses pattern index 17. Custom Art is optional and can be disabled instantly. New drawings appear after a restart, and a failed art build falls back to the stable base instead of blocking launch." 14 34 510 72 7.5 $false))
$artPage.Controls.Add($artHelp)
$artPage.AutoScrollMinSize = New-Object System.Drawing.Size(0,620)


# Style page / Hat + Pants Maker
$stylePage = New-Page
$pagesHost.Controls.Add($stylePage)
$script:Pages.STYLE = $stylePage
$maker = New-CardPanel 8 10 600 320
$maker.Controls.Add((New-FancyLabel "OUTFIT MIXER" 16 8 560 30 13 $true))
$maker.Controls.Add((New-FancyLabel "Mix the normal cosmetics here, or choose the special custom slots made on the ART page. Hat 30 is custom. Pattern 17 is custom." 16 38 560 42 7.6 $false))
$maker.Controls.Add((New-FancyLabel "Hat  0 to 30" 16 88 125 24 8.5 $true))
$hatInput = New-Object System.Windows.Forms.NumericUpDown
$hatInput.Location = New-Object System.Drawing.Point(144,86); $hatInput.Size = New-Object System.Drawing.Size(74,28); $hatInput.Minimum=0; $hatInput.Maximum=30; $hatInput.Value=0
$maker.Controls.Add($hatInput); $script:HatInput=$hatInput
$maker.Controls.Add((New-FancyLabel "Pants Color  0 to 12" 245 88 135 24 8.5 $true))
$pantsInput = New-Object System.Windows.Forms.NumericUpDown
$pantsInput.Location = New-Object System.Drawing.Point(386,86); $pantsInput.Size = New-Object System.Drawing.Size(74,28); $pantsInput.Minimum=0; $pantsInput.Maximum=12; $pantsInput.Value=0
$maker.Controls.Add($pantsInput); $script:PantsInput=$pantsInput
$maker.Controls.Add((New-FancyLabel "Pattern  0 to 17" 16 128 135 24 8.5 $true))
$patternInput = New-Object System.Windows.Forms.NumericUpDown
$patternInput.Location = New-Object System.Drawing.Point(154,126); $patternInput.Size = New-Object System.Drawing.Size(74,28); $patternInput.Minimum=0; $patternInput.Maximum=17; $patternInput.Value=0
$maker.Controls.Add($patternInput); $script:PatternInput=$patternInput
$maker.Controls.Add((New-FancyLabel "Pattern Color  0 to 12" 245 128 135 24 8.5 $true))
$colorInput = New-Object System.Windows.Forms.NumericUpDown
$colorInput.Location = New-Object System.Drawing.Point(386,126); $colorInput.Size = New-Object System.Drawing.Size(74,28); $colorInput.Minimum=0; $colorInput.Maximum=12; $colorInput.Value=0
$maker.Controls.Add($colorInput); $script:ColorInput=$colorInput
$maker.Controls.Add((New-FancyLabel "Hat Tint  0 to 12" 16 164 135 24 8.5 $true))
$hatTintColorInput = New-Object System.Windows.Forms.NumericUpDown
$hatTintColorInput.Location = New-Object System.Drawing.Point(154,162); $hatTintColorInput.Size = New-Object System.Drawing.Size(74,28); $hatTintColorInput.Minimum=0; $hatTintColorInput.Maximum=12; $hatTintColorInput.Value=0
$maker.Controls.Add($hatTintColorInput); $script:HatTintColorInput=$hatTintColorInput
$hatTintToggle = New-FancyButton "HAT TINT OFF" 294 158 260 40
$hatTintToggle.BackColor = $script:CardOff
$hatTintToggle.Add_Click({
    Toggle-ExtendedFlag "HatTint" 8
    $this.Text = if ($script:Flags.HatTint) { "HAT TINT ON" } else { "HAT TINT OFF" }
    $script:StylePreview.Invalidate()
})
$maker.Controls.Add($hatTintToggle); $script:ToggleButtons.HatTint=$hatTintToggle
$applyOutfit = New-FancyButton "APPLY OUTFIT" 16 228 260 52
$applyOutfit.BackColor = $script:Pink
$applyOutfit.Add_Click({ Apply-Outfit })
$randomOutfit = New-FancyButton "RANDOMIZE" 294 228 260 52
$randomOutfit.BackColor = $script:Sky
$randomOutfit.Add_Click({ Randomize-Outfit })
$maker.Controls.Add($applyOutfit); $maker.Controls.Add($randomOutfit)
$stylePage.Controls.Add($maker)

$preset = New-CardPanel 8 342 600 154
$preset.Controls.Add((New-FancyLabel "OUTFIT PRESETS" 16 8 560 26 11 $true))
$presetName = New-Object System.Windows.Forms.TextBox
$presetName.Location = New-Object System.Drawing.Point(16,42); $presetName.Size = New-Object System.Drawing.Size(220,30); $presetName.Font = New-FancyFont 9
$preset.Controls.Add($presetName); $script:PresetName=$presetName
$savePreset = New-FancyButton "SAVE" 246 39 95 38
$savePreset.Add_Click({ Save-OutfitPreset })
$preset.Controls.Add($savePreset)
$presetCombo = New-Object System.Windows.Forms.ComboBox
$presetCombo.Location = New-Object System.Drawing.Point(16,92); $presetCombo.Size = New-Object System.Drawing.Size(325,30); $presetCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$presetCombo.Font = New-FancyFont 8.5
$preset.Controls.Add($presetCombo); $script:PresetCombo=$presetCombo
$loadPreset = New-FancyButton "LOAD" 356 88 95 40
$loadPreset.Add_Click({ Load-OutfitPreset })
$applyPreset = New-FancyButton "LOAD + APPLY" 462 88 120 40
$applyPreset.Add_Click({ Load-OutfitPreset; Apply-Outfit })
$preset.Controls.Add($loadPreset); $preset.Controls.Add($applyPreset)
$stylePage.Controls.Add($preset)

$preview = New-CardPanel 8 508 600 160
$preview.Controls.Add((New-FancyLabel "SKETCH PREVIEW" 16 8 180 24 10.5 $true))
$previewNote = New-FancyLabel "The sketch shows your selected palette and tint. The actual game keeps the real Fancy Pants hat art and animation." 250 18 330 48 7.2 $false
$preview.Controls.Add($previewNote)
$draw = New-Object System.Windows.Forms.Panel
$draw.Location = New-Object System.Drawing.Point(18,36); $draw.Size = New-Object System.Drawing.Size(210,108); $draw.BackColor = $script:Card
$script:PreviewColors = @(
    [System.Drawing.Color]::FromArgb(35,35,35), [System.Drawing.Color]::FromArgb(232,62,177), [System.Drawing.Color]::FromArgb(48,160,221),
    [System.Drawing.Color]::FromArgb(235,70,70), [System.Drawing.Color]::FromArgb(80,200,100), [System.Drawing.Color]::FromArgb(245,210,70),
    [System.Drawing.Color]::FromArgb(155,95,210), [System.Drawing.Color]::FromArgb(245,130,55), [System.Drawing.Color]::FromArgb(70,210,195),
    [System.Drawing.Color]::FromArgb(235,235,235), [System.Drawing.Color]::FromArgb(115,80,55), [System.Drawing.Color]::FromArgb(85,110,230),
    [System.Drawing.Color]::FromArgb(250,120,190)
)
$draw.Add_Paint({
    $g=$_.Graphics; $g.SmoothingMode=[System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $pen=New-Object System.Drawing.Pen($script:Ink,4)
    $pantsColor=$script:PreviewColors[[int]$script:PantsInput.Value % $script:PreviewColors.Count]
    $patternColor=$script:PreviewColors[[int]$script:ColorInput.Value % $script:PreviewColors.Count]
    $hatColor=if ($script:Flags.HatTint) { $script:PreviewColors[[int]$script:HatTintColorInput.Value % $script:PreviewColors.Count] } else { $script:Pink }
    $pantsBrush=New-Object System.Drawing.SolidBrush($pantsColor); $patternBrush=New-Object System.Drawing.SolidBrush($patternColor); $hatBrush=New-Object System.Drawing.SolidBrush($hatColor)
    $g.DrawEllipse($pen,82,10,42,38); $g.DrawLine($pen,103,48,103,76); $g.DrawLine($pen,103,55,78,70); $g.DrawLine($pen,103,55,128,70)
    $g.FillPolygon($pantsBrush,@((New-Object System.Drawing.Point(90,74)),(New-Object System.Drawing.Point(116,74)),(New-Object System.Drawing.Point(128,104)),(New-Object System.Drawing.Point(108,104)),(New-Object System.Drawing.Point(103,86)),(New-Object System.Drawing.Point(98,104)),(New-Object System.Drawing.Point(78,104))))
    $g.DrawPolygon($pen,@((New-Object System.Drawing.Point(90,74)),(New-Object System.Drawing.Point(116,74)),(New-Object System.Drawing.Point(128,104)),(New-Object System.Drawing.Point(108,104)),(New-Object System.Drawing.Point(103,86)),(New-Object System.Drawing.Point(98,104)),(New-Object System.Drawing.Point(78,104))))
    if ([int]$script:PatternInput.Value -gt 0) { $g.FillEllipse($patternBrush,92,80,9,9); $g.FillEllipse($patternBrush,108,91,9,9); $g.FillEllipse($patternBrush,84,94,7,7) }
    $g.FillRectangle($hatBrush,76,4,54,13); $g.DrawRectangle($pen,76,4,54,13)
    $f=New-FancyFont 7 ([System.Drawing.FontStyle]::Bold); $b=New-Object System.Drawing.SolidBrush($script:Ink)
    $g.DrawString("H$([int]$script:HatInput.Value)   P$([int]$script:PatternInput.Value)",$f,$b,132,78)
    $f.Dispose(); $b.Dispose(); $pantsBrush.Dispose(); $patternBrush.Dispose(); $hatBrush.Dispose(); $pen.Dispose()
})
$preview.Controls.Add($draw); $stylePage.Controls.Add($preview); $script:StylePreview=$draw
foreach ($c in @($hatInput,$pantsInput,$patternInput,$colorInput,$hatTintColorInput)) { $c.Add_ValueChanged({ $script:StylePreview.Invalidate() }) }
$stylePage.AutoScrollMinSize = New-Object System.Drawing.Size(0,686)
Refresh-PresetList

# Display page
$displayPage = New-Page
$pagesHost.Controls.Add($displayPage)
$script:Pages.DISPLAY = $displayPage

$safeCard = New-CardPanel 8 14 600 94
$safeCard.Controls.Add((New-FancyLabel "CRASH SAFE DISPLAY MODE" 14 9 560 25 11.5 $true))
$safeCard.Controls.Add((New-FancyLabel "TPS and interpolation remain disabled in the crash safe core. Smooth Game Speed can raise render FPS during fast simulation without restoring the old save loading hooks." 14 35 560 48 7.5 $false))
$displayPage.Controls.Add($safeCard)

$fpsCard = New-CardPanel 8 120 600 112
$fpsCard.Controls.Add((New-FancyLabel "FPS TARGET" 14 9 230 25 11.5 $true))
$fpsCard.Controls.Add((New-FancyLabel "Type 0 through 9999. 0 requests the AIR maximum. Values above 1000 are accepted here, but Adobe AIR caps Stage.frameRate at 1000." 14 35 350 62 7.3 $false))
$fpsInput = New-Object System.Windows.Forms.NumericUpDown
$fpsInput.Location = New-Object System.Drawing.Point(382,18)
$fpsInput.Size = New-Object System.Drawing.Size(92,34)
$fpsInput.Minimum = 0; $fpsInput.Maximum = 9999; $fpsInput.Value = 0
$fpsInput.Font = New-FancyFont 11 ([System.Drawing.FontStyle]::Bold)
$fpsInput.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
$fpsCard.Controls.Add($fpsInput)
$script:FpsInput = $fpsInput
$fpsApply = New-FancyButton "APPLY" 482 16 100 38
$fpsApply.BackColor = $script:Sky
$fpsApply.Add_Click({ Apply-FPS })
$fpsCard.Controls.Add($fpsApply)
$fpsActual = New-FancyLabel "GAME 60" 382 61 200 30 8.5 $true
$fpsActual.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$fpsCard.Controls.Add($fpsActual)
$script:FpsActualLabel = $fpsActual
$displayPage.Controls.Add($fpsCard)

$scaleCard = New-CardPanel 8 244 600 74
$scaleCard.Controls.Add((New-FancyLabel "Mod Book Scale" 14 8 260 24 10.5 $true))
$scaleCard.Controls.Add((New-FancyLabel "Resize this menu from 50% through 110%." 14 35 320 24 7.5 $false))
$scaleDown = New-FancyButton "<" 380 14 52 42
$scaleDown.BackColor = $script:Sky
$scaleDown.Add_Click({ Change-OverlayScale -10 })
$scaleCard.Controls.Add($scaleDown)
$scaleRead = New-FancyLabel "70%" 435 16 72 38 10 $true
$scaleRead.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$scaleCard.Controls.Add($scaleRead)
$script:ScaleValueLabel2 = $scaleRead
$scaleUp = New-FancyButton ">" 510 14 52 42
$scaleUp.BackColor = $script:Sky
$scaleUp.Add_Click({ Change-OverlayScale 10 })
$scaleCard.Controls.Add($scaleUp)
$displayPage.Controls.Add($scaleCard)
$resetPerf = New-FancyButton "RESET FPS TO 60" 155 334 300 46
$resetPerf.BackColor = $script:Gold
$resetPerf.Add_Click({ Reset-Performance })
$displayPage.Controls.Add($resetPerf)

# Unlock page
$unlockPage = New-Page
$pagesHost.Controls.Add($unlockPage)
$script:Pages.UNLOCKS = $unlockPage
$unlockTitle = New-FancyLabel "ONE CLICK UNLOCKS" 25 25 570 42 17 $true
$unlockTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$unlockPage.Controls.Add($unlockTitle)
$cosmetics = New-FancyButton "UNLOCK ALL HATS + PANTS" 58 98 500 64
$cosmetics.Font = New-FancyFont 12 ([System.Drawing.FontStyle]::Bold)
$cosmetics.Add_Click({ Unlock-AllCosmetics })
$unlockPage.Controls.Add($cosmetics)
$script:CosmeticsButton = $cosmetics
$achievements = New-FancyButton "UNLOCK ALL 16 ACHIEVEMENTS" 58 184 500 64
$achievements.Font = New-FancyFont 12 ([System.Drawing.FontStyle]::Bold)
$achievements.BackColor = $script:Pink
$achievements.Add_Click({ Unlock-AllAchievements })
$unlockPage.Controls.Add($achievements)
$script:AchievementsButton = $achievements
$unlockNote = New-CardPanel 58 278 500 135
$unlockNote.Controls.Add((New-FancyLabel "TIP" 18 12 460 26 11 $true))
$unlockNote.Controls.Add((New-FancyLabel "Enter a level before using the cosmetic unlock so the game can save immediately. Achievement unlocks are permanent on the connected Steam account, so that button asks for confirmation first." 18 43 455 76 8.2 $false))
$unlockPage.Controls.Add($unlockNote)

$reset = New-FancyButton "RESET GAMEPLAY MODS" 52 714 280 48
$reset.BackColor = $script:Gold
$reset.Add_Click({ Reset-Mods })
$overlay.Controls.Add($reset)
$hide = New-FancyButton "CLOSE MOD BOOK" 368 714 280 48
$hide.Add_Click({ Toggle-Overlay })
$overlay.Controls.Add($hide)

$overlay.Add_Paint({
    $g = $_.Graphics
    $sx = $this.ClientSize.Width / 700.0
    $sy = $this.ClientSize.Height / 790.0
    $sm = [Math]::Min($sx,$sy)
    $inkPen = New-Object System.Drawing.Pen($script:Ink,[single]([Math]::Max(2,5*$sm)))
    $thinPen = New-Object System.Drawing.Pen($script:Pencil,[single]([Math]::Max(1,2*$sm)))
    $pinkPen = New-Object System.Drawing.Pen($script:Pink,[single]([Math]::Max(2,6*$sm)))
    $skyPen = New-Object System.Drawing.Pen($script:Sky,[single]([Math]::Max(1,3*$sm)))
    $g.DrawRectangle($inkPen,[int](3*$sx),[int](3*$sy),[int](693*$sx),[int](783*$sy))
    $g.DrawRectangle($thinPen,[int](8*$sx),[int](7*$sy),[int](682*$sx),[int](772*$sy))
    $g.DrawLine($pinkPen,[int](25*$sx),[int](76*$sy),[int](675*$sx),[int](76*$sy))
    $g.DrawLine($skyPen,[int](32*$sx),[int](700*$sy),[int](668*$sx),[int](700*$sy))

    # Pink pants doodle
    $g.DrawLine($pinkPen,[int](20*$sx),[int](21*$sy),[int](40*$sx),[int](21*$sy))
    $g.DrawLine($pinkPen,[int](22*$sx),[int](21*$sy),[int](23*$sx),[int](48*$sy))
    $g.DrawLine($pinkPen,[int](38*$sx),[int](21*$sy),[int](37*$sx),[int](48*$sy))
    $g.DrawLine($pinkPen,[int](23*$sx),[int](48*$sy),[int](15*$sx),[int](64*$sy))
    $g.DrawLine($pinkPen,[int](37*$sx),[int](48*$sy),[int](45*$sx),[int](64*$sy))
    $g.DrawLine($pinkPen,[int](30*$sx),[int](34*$sy),[int](30*$sx),[int](57*$sy))

    # Loose pencil marks and little squiggle
    $g.DrawArc($thinPen,[int](647*$sx),[int](16*$sy),[int](27*$sx),[int](23*$sy),190,130)
    $g.DrawArc($thinPen,[int](642*$sx),[int](38*$sy),[int](32*$sx),[int](24*$sy),210,120)
    $g.DrawArc($pinkPen,[int](624*$sx),[int](86*$sy),[int](28*$sx),[int](18*$sy),0,180)
    $g.DrawArc($pinkPen,[int](642*$sx),[int](86*$sy),[int](28*$sx),[int](18*$sy),180,180)

    $inkPen.Dispose(); $thinPen.Dispose(); $pinkPen.Dispose(); $skyPen.Dispose()
})


# ---------------- BUILD 11 COMPACT RUNTIME PANEL ----------------
$mega = New-Object System.Windows.Forms.Form
$mega.ClientSize = New-Object System.Drawing.Size(1080,600)
$mega.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$mega.BackColor = [System.Drawing.Color]::FromArgb(24,24,30)
$mega.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$mega.TopMost = $true
$mega.ShowInTaskbar = $false
$mega.Opacity = 0.97
$mega.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$mega.KeyPreview = $true
$mega.Add_Paint({
    $g=$_.Graphics
    $edge=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(94,96,110),1)
    $top=New-Object System.Drawing.Pen($script:Pink,2)
    $g.DrawRectangle($edge,0,0,$this.ClientSize.Width-1,$this.ClientSize.Height-1)
    $g.DrawLine($top,0,39,$this.ClientSize.Width,39)
    $edge.Dispose();$top.Dispose()
})

$megaTitle=New-FancyLabel 'FANCY HACK 11' 12 7 160 28 11.5 $true
$megaTitle.ForeColor=$script:White
$mega.Controls.Add($megaTitle)
$megaBuild=New-FancyLabel 'SFPA  •  PRO' 168 9 105 24 7.5 $true
$megaBuild.ForeColor=$script:Pink
$mega.Controls.Add($megaBuild)
$megaSearch=New-Object System.Windows.Forms.TextBox
$megaSearch.Location=New-Object System.Drawing.Point(285,8)
$megaSearch.Size=New-Object System.Drawing.Size(270,25)
$megaSearch.Font=New-FancyFont 8.0
$megaSearch.BackColor=[System.Drawing.Color]::FromArgb(38,39,47)
$megaSearch.ForeColor=$script:White
$megaSearch.BorderStyle=[System.Windows.Forms.BorderStyle]::FixedSingle
$mega.Controls.Add($megaSearch)
$megaCount=New-FancyLabel '' 562 10 92 22 7.0 $true
$megaCount.ForeColor=$script:Muted
$mega.Controls.Add($megaCount)
$megaScaleMinus=New-FancyButton 'UI  −' 735 6 62 28
$megaScaleMinus.Font=New-FancyFont 7.0 ([System.Drawing.FontStyle]::Bold)
$megaScaleMinus.Add_Click({ Change-OverlayScale -10 })
$mega.Controls.Add($megaScaleMinus)
$megaScaleValue=New-FancyLabel '90%' 800 8 48 24 7.4 $true
$megaScaleValue.TextAlign=[System.Drawing.ContentAlignment]::MiddleCenter
$mega.Controls.Add($megaScaleValue)
$script:ScaleValueLabel=$megaScaleValue
$megaScalePlus=New-FancyButton 'UI  +' 851 6 62 28
$megaScalePlus.Font=New-FancyFont 7.0 ([System.Drawing.FontStyle]::Bold)
$megaScalePlus.Add_Click({ Change-OverlayScale 10 })
$mega.Controls.Add($megaScalePlus)
$megaClose=New-FancyButton 'CLOSE' 946 6 120 28
$megaClose.Font=New-FancyFont 7.2 ([System.Drawing.FontStyle]::Bold)
$megaClose.BackColor=[System.Drawing.Color]::FromArgb(54,55,65)
$megaClose.Add_Click({ Toggle-Overlay })
$mega.Controls.Add($megaClose)

$script:MegaItems=New-Object System.Collections.ArrayList
$script:MegaTip=New-Object System.Windows.Forms.ToolTip
$script:MegaTip.AutoPopDelay=8000
$script:MegaTip.InitialDelay=250
$script:MegaTip.ReshowDelay=100

function New-MegaColumn([string]$title,[int]$x) {
    $box=New-Object System.Windows.Forms.Panel
    $box.Location=New-Object System.Drawing.Point($x,47)
    $box.Size=New-Object System.Drawing.Size(146,541)
    $box.BackColor=[System.Drawing.Color]::FromArgb(31,32,39)
    $box.BorderStyle=[System.Windows.Forms.BorderStyle]::FixedSingle
    $head=New-Object System.Windows.Forms.Label
    $head.Text=$title.ToUpperInvariant()
    $head.Location=New-Object System.Drawing.Point(0,0)
    $head.Size=New-Object System.Drawing.Size(144,25)
    $head.TextAlign=[System.Drawing.ContentAlignment]::MiddleCenter
    $head.Font=New-FancyFont 7.3 ([System.Drawing.FontStyle]::Bold)
    $head.BackColor=[System.Drawing.Color]::FromArgb(53,41,73)
    $head.ForeColor=[System.Drawing.Color]::FromArgb(255,126,211)
    $box.Controls.Add($head)
    $flow=New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Location=New-Object System.Drawing.Point(1,26)
    $flow.Size=New-Object System.Drawing.Size(143,513)
    $flow.FlowDirection=[System.Windows.Forms.FlowDirection]::TopDown
    $flow.WrapContents=$false
    $flow.AutoScroll=$true
    $flow.BackColor=[System.Drawing.Color]::FromArgb(31,32,39)
    $box.Controls.Add($flow)
    $mega.Controls.Add($box)
    return $flow
}

function Register-MegaItem($control,[string]$text,[string]$category) {
    [void]$script:MegaItems.Add([PSCustomObject]@{Control=$control;Text=$text.ToLowerInvariant();Category=$category})
}

function New-MegaRow([string]$label,[string]$tip) {
    $row=New-Object System.Windows.Forms.Panel
    $row.Size=New-Object System.Drawing.Size(126,25)
    $row.Margin=New-Object System.Windows.Forms.Padding(2,1,2,1)
    $row.BackColor=[System.Drawing.Color]::FromArgb(37,38,46)
    $l=New-Object System.Windows.Forms.Label
    $l.Text=$label
    $l.Location=New-Object System.Drawing.Point(4,2)
    $l.Size=New-Object System.Drawing.Size(78,21)
    $l.Font=New-FancyFont 6.6
    $l.ForeColor=$script:White
    $l.TextAlign=[System.Drawing.ContentAlignment]::MiddleLeft
    $row.Controls.Add($l)
    if ($tip) { $script:MegaTip.SetToolTip($row,$tip);$script:MegaTip.SetToolTip($l,$tip) }
    return $row
}

function Add-MegaCoreToggle($flow,[string]$label,[string]$tip,[string]$name,[int]$vk,[string]$cat) {
    $row=New-MegaRow $label $tip
    $b=New-FancyButton 'OFF' 84 3 38 19
    $b.Font=New-FancyFont 5.8 ([System.Drawing.FontStyle]::Bold)
    $b.FlatAppearance.BorderSize=1
    $b.Add_Click({ Toggle-Flag $name $vk }.GetNewClosure())
    $row.Controls.Add($b);$flow.Controls.Add($row)
    $script:ToggleButtons[$name]=$b;Update-ToggleButton $name
    Register-MegaItem $row ($label+' '+$tip) $cat
}
function Add-MegaExtendedToggle($flow,[string]$label,[string]$tip,[string]$name,[int]$cmd,[string]$cat) {
    $row=New-MegaRow $label $tip
    $b=New-FancyButton 'OFF' 84 3 38 19
    $b.Font=New-FancyFont 5.8 ([System.Drawing.FontStyle]::Bold)
    $b.FlatAppearance.BorderSize=1
    $b.Add_Click({ Toggle-ExtendedFlag $name $cmd }.GetNewClosure())
    $row.Controls.Add($b);$flow.Controls.Add($row)
    $script:ToggleButtons[$name]=$b;Update-ToggleButton $name
    Register-MegaItem $row ($label+' '+$tip) $cat
}
function Add-MegaExtraToggle($flow,[string]$label,[string]$tip,[string]$name,[string]$cat) {
    $row=New-MegaRow $label $tip
    $b=New-FancyButton 'OFF' 84 3 38 19
    $b.Font=New-FancyFont 5.8 ([System.Drawing.FontStyle]::Bold)
    $b.FlatAppearance.BorderSize=1
    $b.Add_Click({ Toggle-ExtraFlag $name }.GetNewClosure())
    $row.Controls.Add($b);$flow.Controls.Add($row)
    $script:ExtraButtons[$name]=$b;$script:ExtraButtonLabels[$name]=$label;Update-ExtraButton $name
    Register-MegaItem $row ($label+' '+$tip) $cat
}
function Add-MegaAction($flow,[string]$label,[string]$tip,[scriptblock]$action,[string]$cat) {
    $b=New-FancyButton $label 0 0 126 25
    $b.Margin=New-Object System.Windows.Forms.Padding(2,1,2,1)
    $b.Font=New-FancyFont 6.3
    $b.TextAlign=[System.Drawing.ContentAlignment]::MiddleLeft
    $b.FlatAppearance.BorderSize=1
    $b.BackColor=[System.Drawing.Color]::FromArgb(37,38,46)
    $b.Add_Click($action);$script:MegaTip.SetToolTip($b,$tip)
    $flow.Controls.Add($b);Register-MegaItem $b ($label+' '+$tip) $cat
}
function Add-MegaLevel($flow,[string]$label,[string]$name,[string]$tip,[string]$cat) {
    $row=New-Object System.Windows.Forms.Panel
    $row.Size=New-Object System.Drawing.Size(126,29);$row.Margin=New-Object System.Windows.Forms.Padding(2,1,2,1);$row.BackColor=[System.Drawing.Color]::FromArgb(37,38,46)
    $l=New-Object System.Windows.Forms.Label;$l.Text=$label;$l.Location=New-Object System.Drawing.Point(3,2);$l.Size=New-Object System.Drawing.Size(50,24);$l.Font=New-FancyFont 6.0;$l.ForeColor=$script:White;$l.TextAlign=[System.Drawing.ContentAlignment]::MiddleLeft
    $m=New-FancyButton '‹' 54 4 19 21;$m.Font=New-FancyFont 6.0 ([System.Drawing.FontStyle]::Bold);$m.FlatAppearance.BorderSize=1
    $v=New-FancyLabel '1.00x' 74 4 32 21 5.8 $true;$v.TextAlign=[System.Drawing.ContentAlignment]::MiddleCenter
    $p=New-FancyButton '›' 106 4 18 21;$p.Font=New-FancyFont 6.0 ([System.Drawing.FontStyle]::Bold);$p.FlatAppearance.BorderSize=1
    $m.Add_Click({ Change-Level $name -1 }.GetNewClosure());$p.Add_Click({ Change-Level $name 1 }.GetNewClosure())
    $row.Controls.Add($l);$row.Controls.Add($m);$row.Controls.Add($v);$row.Controls.Add($p);$flow.Controls.Add($row)
    $script:ValueLabels[$name]=$v;Update-LevelLabel $name;$script:MegaTip.SetToolTip($row,$tip);Register-MegaItem $row ($label+' '+$tip) $cat
}

$playerFlow=New-MegaColumn 'Player' 8
$moveFlow=New-MegaColumn 'Movement' 160
$combatFlow=New-MegaColumn 'Combat' 312
$worldFlow=New-MegaColumn 'World' 464
$utilFlow=New-MegaColumn 'Utility' 616
$cosFlow=New-MegaColumn 'Cosmetic' 768
$displayFlow=New-MegaColumn 'Display' 920

# PLAYER
Add-MegaCoreToggle $playerFlow 'Invincible' 'Take the normal hit reaction without losing health.' 'Invincible' 112 'PLAYER'
Add-MegaCoreToggle $playerFlow 'Friendly' 'Ignore ordinary enemy and hazard hurt calls.' 'Friendly' 113 'PLAYER'
Add-MegaCoreToggle $playerFlow 'Inf Lives' 'Keep lives at 99.' 'InfiniteLives' 129 'PLAYER'
Add-MegaCoreToggle $playerFlow 'Inf Squiggles' 'Purchases do not consume squiggles.' 'InfiniteSquiggles' 130 'PLAYER'
Add-MegaExtendedToggle $playerFlow 'No Knockback' 'Suppress hit knockback.' 'NoKnockback' 6 'PLAYER'
Add-MegaExtendedToggle $playerFlow 'No Pit Death' 'Disable pit death routine.' 'NoPitDeath' 1 'PLAYER'
Add-MegaExtendedToggle $playerFlow 'No Squish' 'Disable crusher squish death.' 'NoSquish' 2 'PLAYER'
Add-MegaExtendedToggle $playerFlow 'Max Power' 'Keep max power level.' 'MaxPower' 7 'PLAYER'
Add-MegaExtraToggle $playerFlow 'Auto Heal' 'Repeatedly refill health.' 'AutoHeal' 'PLAYER'
Add-MegaExtraToggle $playerFlow 'Auto Ink' 'Repeatedly refill pen ink.' 'AutoInk' 'PLAYER'
Add-MegaExtraToggle $playerFlow 'Auto 9999' 'Repeatedly restore 9999 squiggles.' 'AutoSquiggles' 'PLAYER'
Add-MegaAction $playerFlow 'Heal Now' 'Immediately queue a full heal.' { Send-OneShot 22 'Full heal queued.' } 'PLAYER'
Add-MegaAction $playerFlow 'Refill Ink' 'Immediately refill pen ink.' { Send-OneShot 23 'Ink refill queued.' } 'PLAYER'
Add-MegaAction $playerFlow 'Give 9999' 'Give 9999 squiggles.' { Send-OneShot 24 '9999 squiggles queued.' } 'PLAYER'

# MOVEMENT
Add-MegaCoreToggle $moveFlow 'Fly' 'Free movement with player follow camera.' 'Fly' 118 'MOVEMENT'
Add-MegaCoreToggle $moveFlow 'Noclip' 'Pass through collision while camera continues through the shared camera tail.' 'NoClip' 119 'MOVEMENT'
$script:ToggleButtons.NoClip.Enabled=$script:Flags.Fly
Add-MegaCoreToggle $moveFlow 'Inf Jumps' 'Jump repeatedly in the air.' 'InfiniteJumps' 120 'MOVEMENT'
Add-MegaExtraToggle $moveFlow 'Fly Boost' 'Hold Shift while flying for faster movement.' 'FlyBoost' 'MOVEMENT'
Add-MegaExtraToggle $moveFlow 'Fly Precision' 'Hold Ctrl while flying for slower precision movement.' 'FlyPrecision' 'MOVEMENT'
Add-MegaExtraToggle $moveFlow 'Hold Slowmo' 'Hold Page Down for temporary slow motion.' 'HoldSlowmo' 'MOVEMENT'
Add-MegaExtraToggle $moveFlow 'Hold Fast' 'Hold Page Up for temporary fast motion.' 'HoldFastForward' 'MOVEMENT'
Add-MegaLevel $moveFlow 'Speed' 'Speed' 'Player horizontal speed multiplier.' 'MOVEMENT'
Add-MegaLevel $moveFlow 'Jump' 'Jump' 'Jump height multiplier.' 'MOVEMENT'
Add-MegaAction $moveFlow 'Save Position' 'Save Fancy Pants current position.' { Send-OneShot 20 'Position save queued.' } 'MOVEMENT'
Add-MegaAction $moveFlow 'Teleport Back' 'Return to the saved position.' { Send-OneShot 21 'Teleport queued.' } 'MOVEMENT'
Add-MegaExtraToggle $moveFlow 'Auto Save Pos' 'Refresh saved position on an interval.' 'AutoSavePos' 'MOVEMENT'

# COMBAT
Add-MegaCoreToggle $combatFlow 'Inf Ammo' 'Keep pen gun ink full.' 'InfiniteAmmo' 121 'COMBAT'
Add-MegaCoreToggle $combatFlow 'One Hit KO' 'Normal damaging hits defeat standard enemies.' 'OneHit' 132 'COMBAT'
Add-MegaExtendedToggle $combatFlow 'All Tools' 'Keep all tools enabled.' 'AllTools' 4 'COMBAT'
Add-MegaExtendedToggle $combatFlow 'All Moves' 'Keep pencil special moves enabled.' 'AllMoves' 5 'COMBAT'
Add-MegaLevel $combatFlow 'Strength' 'Strength' 'Attack power multiplier.' 'COMBAT'
Add-MegaExtraToggle $combatFlow 'Hotkey Fly' 'Ctrl Shift F toggles Fly.' 'QuickFlyKeys' 'COMBAT'
Add-MegaExtraToggle $combatFlow 'Hotkey Noclip' 'Ctrl Shift N toggles Noclip.' 'QuickNoClipKeys' 'COMBAT'
Add-MegaExtraToggle $combatFlow 'Hotkey Invinc' 'Ctrl Shift I toggles Invincible.' 'QuickInvincibleKeys' 'COMBAT'
Add-MegaExtraToggle $combatFlow 'Hotkey Friendly' 'Ctrl Shift R toggles Friendly.' 'QuickFriendlyKeys' 'COMBAT'
Add-MegaExtraToggle $combatFlow 'Hotkey Freeze' 'Ctrl Shift E toggles Freeze Enemies.' 'QuickFreezeKeys' 'COMBAT'
Add-MegaExtraToggle $combatFlow 'Hotkey One Hit' 'Ctrl Shift O toggles One Hit KO.' 'QuickOneHitKeys' 'COMBAT'

# WORLD
Add-MegaCoreToggle $worldFlow 'Freeze Enemies' 'Build 11 freezes enemy AI, movement physics, and after move processing.' 'FreezeEnemies' 131 'WORLD'
Add-MegaExtendedToggle $worldFlow 'No Shake' 'Suppress screen shake.' 'NoScreenShake' 3 'WORLD'
Add-MegaLevel $worldFlow 'Game Speed' 'GameSpeed' 'Simulation speed multiplier.' 'WORLD'
Add-MegaExtraToggle $worldFlow 'Smooth Speed' 'Ramp render FPS with higher game speed.' 'SmoothGameSpeed' 'WORLD'
$sumRow=New-Object System.Windows.Forms.Panel;$sumRow.Size=New-Object System.Drawing.Size(126,66);$sumRow.Margin=New-Object System.Windows.Forms.Padding(2,2,2,2);$sumRow.BackColor=[System.Drawing.Color]::FromArgb(46,37,57)
$sumLabel=New-Object System.Windows.Forms.Label;$sumLabel.Text='SUMMON ENEMY';$sumLabel.Location=New-Object System.Drawing.Point(4,2);$sumLabel.Size=New-Object System.Drawing.Size(118,18);$sumLabel.Font=New-FancyFont 6.4 ([System.Drawing.FontStyle]::Bold);$sumLabel.ForeColor=[System.Drawing.Color]::FromArgb(255,126,211);$sumRow.Controls.Add($sumLabel)
$sumBox=New-Object System.Windows.Forms.ComboBox;$sumBox.Location=New-Object System.Drawing.Point(4,22);$sumBox.Size=New-Object System.Drawing.Size(82,23);$sumBox.DropDownStyle=[System.Windows.Forms.ComboBoxStyle]::DropDownList;$sumBox.Font=New-FancyFont 6.2
[void]$sumBox.Items.AddRange(@('Baddie1','Spider','Bat','Bird','Mouse','Ninja','InkFly','InkBall','InkFloat','SnailShell','Volleyball','Bowling Ball'))
$sumBox.SelectedIndex=0;$sumRow.Controls.Add($sumBox);$script:SummonEnemyBox=$sumBox
$sumBtn=New-FancyButton 'SPAWN' 88 22 34 23;$sumBtn.Font=New-FancyFont 5.1 ([System.Drawing.FontStyle]::Bold);$sumBtn.BackColor=$script:Pink;$sumBtn.Add_Click({ Summon-SelectedEnemy });$sumRow.Controls.Add($sumBtn)
$sumHint=New-Object System.Windows.Forms.Label;$sumHint.Text='Click repeatedly to spawn more.';$sumHint.Location=New-Object System.Drawing.Point(4,47);$sumHint.Size=New-Object System.Drawing.Size(118,15);$sumHint.Font=New-FancyFont 5.4;$sumHint.ForeColor=$script:Muted;$sumRow.Controls.Add($sumHint)
$worldFlow.Controls.Add($sumRow);Register-MegaItem $sumRow 'summon enemy spawn baddie spider bat bird mouse ninja ink fly ball snail volleyball' 'WORLD'

# UTILITY
Add-MegaAction $utilFlow 'Unlock Hats Pants' 'Unlock every normal hat and pants option.' { Unlock-AllCosmetics } 'UTILITY'
Add-MegaAction $utilFlow 'Achievements' 'Send all 16 achievement unlocks.' { Unlock-AllAchievements } 'UTILITY'
Add-MegaExtraToggle $utilFlow 'Auto Unlock' 'Keep normal cosmetics unlocked.' 'AutoUnlockCosmetics' 'UTILITY'
Add-MegaExtraToggle $utilFlow 'Outfit Lock' 'Periodically reapply the selected outfit.' 'OutfitLock' 'UTILITY'
Add-MegaExtraToggle $utilFlow 'Hotkey Heal' 'Ctrl Shift H heals.' 'QuickHealKeys' 'UTILITY'
Add-MegaExtraToggle $utilFlow 'Hotkey Ink' 'Ctrl Shift I refills ink when configured.' 'QuickInkKeys' 'UTILITY'
Add-MegaExtraToggle $utilFlow 'Hotkey Save' 'Ctrl Shift K saves position.' 'QuickSaveKeys' 'UTILITY'
Add-MegaExtraToggle $utilFlow 'Hotkey Warp' 'Ctrl Shift L teleports.' 'QuickTeleportKeys' 'UTILITY'
Add-MegaExtraToggle $utilFlow 'Hotkey 9999' 'Ctrl Shift G gives squiggles.' 'QuickSquiggleKeys' 'UTILITY'
Add-MegaAction $utilFlow 'Reset Gameplay' 'Reset gameplay mods to defaults.' { Reset-GameplayMods } 'UTILITY'
Add-MegaAction $utilFlow 'Restore Original' 'Restore the verified original SWF after closing the game.' { Restore-Original } 'UTILITY'

# COSMETIC
Add-MegaExtraToggle $cosFlow 'Rainbow Hat' 'Cycle hat tint.' 'RainbowHat' 'COSMETIC'
Add-MegaExtraToggle $cosFlow 'Slow Rainbow' 'Slower tint cycle.' 'SlowRainbow' 'COSMETIC'
Add-MegaExtraToggle $cosFlow 'Fast Rainbow' 'Faster tint cycle.' 'FastRainbow' 'COSMETIC'
Add-MegaExtraToggle $cosFlow 'Cycle Hat' 'Cycle normal hats.' 'CycleHat' 'COSMETIC'
Add-MegaExtraToggle $cosFlow 'Cycle Pants' 'Cycle pants colors.' 'CyclePants' 'COSMETIC'
Add-MegaExtraToggle $cosFlow 'Cycle Pattern' 'Cycle pants patterns.' 'CyclePattern' 'COSMETIC'
Add-MegaExtraToggle $cosFlow 'Cycle Color' 'Cycle pattern colors.' 'CyclePatternColor' 'COSMETIC'
Add-MegaExtraToggle $cosFlow 'Random Outfit' 'Randomize the whole outfit repeatedly.' 'RandomOutfit' 'COSMETIC'
Add-MegaExtraToggle $cosFlow 'Random Hat' 'Random hat repeatedly.' 'RandomHat' 'COSMETIC'
Add-MegaExtraToggle $cosFlow 'Random Pants' 'Random pants color repeatedly.' 'RandomPants' 'COSMETIC'
Add-MegaExtraToggle $cosFlow 'Random Pattern' 'Random pants pattern repeatedly.' 'RandomPattern' 'COSMETIC'
Add-MegaExtraToggle $cosFlow 'Random Color' 'Random pattern color repeatedly.' 'RandomPatternColor' 'COSMETIC'
Add-MegaExtraToggle $cosFlow 'Random Tint' 'Random hat tint repeatedly.' 'RandomTint' 'COSMETIC'

# DISPLAY and 44 additional individual modifier controls
Add-MegaExtraToggle $displayFlow 'Smooth Speed' 'Smooth render FPS ramp for Game Speed.' 'SmoothGameSpeed' 'DISPLAY'
foreach($fps in @(30,60,75,90,120,144,165,240,360,500,1000)) {
    $f=$fps;Add-MegaAction $displayFlow ("FPS "+$fps) ("Set render target to "+$fps+" FPS.") ({ Set-FpsQuick $f }.GetNewClosure()) 'DISPLAY'
}

# More individual dynamic mods. Each toggle controls one behavior, never a pack.
Add-MegaExtraToggle $moveFlow 'Random Speed' 'Change movement speed to a random value repeatedly.' 'RandomSpeed' 'MOVEMENT'
Add-MegaExtraToggle $moveFlow 'Cycle Speed' 'Continuously step through movement speed values.' 'CycleSpeed' 'MOVEMENT'
Add-MegaExtraToggle $moveFlow 'Pulse Speed' 'Alternate movement speed between slow and fast.' 'PulseSpeed' 'MOVEMENT'
Add-MegaExtraToggle $moveFlow 'Random Jump' 'Change jump height to a random value repeatedly.' 'RandomJump' 'MOVEMENT'
Add-MegaExtraToggle $moveFlow 'Cycle Jump' 'Continuously step through jump height values.' 'CycleJump' 'MOVEMENT'
Add-MegaExtraToggle $moveFlow 'Pulse Jump' 'Alternate jump height between low and high.' 'PulseJump' 'MOVEMENT'
Add-MegaExtraToggle $combatFlow 'Random Power' 'Change attack strength to a random value repeatedly.' 'RandomStrength' 'COMBAT'
Add-MegaExtraToggle $combatFlow 'Cycle Power' 'Continuously step through attack strength values.' 'CycleStrength' 'COMBAT'
Add-MegaExtraToggle $combatFlow 'Pulse Power' 'Alternate attack strength between low and maximum.' 'PulseStrength' 'COMBAT'
Add-MegaExtraToggle $worldFlow 'Random Time' 'Change simulation speed to a random value repeatedly.' 'RandomTime' 'WORLD'
Add-MegaExtraToggle $worldFlow 'Cycle Time' 'Continuously step through simulation speed values.' 'CycleTime' 'WORLD'
Add-MegaExtraToggle $worldFlow 'Pulse Time' 'Alternate simulation speed between slow and fast.' 'PulseTime' 'WORLD'
Add-MegaExtraToggle $displayFlow 'Random FPS' 'Choose a different render FPS target repeatedly.' 'RandomFps' 'DISPLAY'
Add-MegaExtraToggle $displayFlow 'Cycle FPS' 'Cycle through common render FPS targets.' 'CycleFps' 'DISPLAY'
Add-MegaExtraToggle $displayFlow 'Pulse FPS' 'Alternate the render target between 60 and 240 FPS.' 'PulseFps' 'DISPLAY'

# Extra individual values. They are direct settings, never packs.
foreach($v in @(0.25,0.50,0.75,1.00,1.25,1.50,2.00,2.50,3.00,4.00,5.00)) {
    $vv=[double]$v
    Add-MegaAction $moveFlow ("Speed "+('{0:0.00}x' -f $vv)) 'Set only movement speed.' ({ Set-QuickLevel 'Speed' $vv }.GetNewClosure()) 'MOVEMENT'
}
foreach($v in @(0.25,0.50,0.75,1.00,1.25,1.50,2.00,2.50,3.00,4.00,5.00)) {
    $vv=[double]$v
    Add-MegaAction $moveFlow ("Jump "+('{0:0.00}x' -f $vv)) 'Set only jump height.' ({ Set-QuickLevel 'Jump' $vv }.GetNewClosure()) 'MOVEMENT'
}
foreach($v in @(0.25,0.50,0.75,1.00,1.25,1.50,2.00,2.50,3.00,4.00,5.00)) {
    $vv=[double]$v
    Add-MegaAction $combatFlow ("Power "+('{0:0.00}x' -f $vv)) 'Set only attack strength.' ({ Set-QuickLevel 'Strength' $vv }.GetNewClosure()) 'COMBAT'
}
foreach($v in @(0.25,0.50,0.75,1.00,1.25,1.50,2.00,2.50,3.00,4.00,5.00)) {
    $vv=[double]$v
    Add-MegaAction $worldFlow ("Time "+('{0:0.00}x' -f $vv)) 'Set only simulation speed.' ({ Set-QuickLevel 'GameSpeed' $vv }.GetNewClosure()) 'WORLD'
}

function Filter-MegaItems {
    $q=$megaSearch.Text.Trim().ToLowerInvariant();$shown=0
    foreach($item in $script:MegaItems) {
        $show=([string]::IsNullOrWhiteSpace($q) -or $item.Text.Contains($q) -or $item.Category.ToLowerInvariant().Contains($q))
        $item.Control.Visible=$show
        if($show){$shown++}
    }
    $megaCount.Text=("$shown controls")
}
$megaSearch.Add_TextChanged({ Filter-MegaItems })
Filter-MegaItems

# Use the compact form from this point on.
$overlay=$mega
$script:Overlay=$mega
# ---------------- END BUILD 11 COMPACT RUNTIME PANEL ----------------

function Is-ModHotkeyContext {
    $p = Find-GameProcess
    if (-not $p) { return $false }
    $fg = [FancyNative]::GetForegroundWindow()
    if ($script:OverlayVisible) {
        return ($fg -eq $script:Overlay.Handle)
    }
    $p.Refresh()
    return ($p.MainWindowHandle -ne [IntPtr]::Zero -and $fg -eq $p.MainWindowHandle)
}

function Focus-GameWindow {
    $p = Find-GameProcess
    if (-not $p) { return }
    $p.Refresh()
    if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
        [FancyNative]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
    }
}

function Toggle-Overlay {
    if (-not (Find-GameProcess)) { return }
    if ($script:OverlayVisible) {
        Set-MenuPause $false
        Release-GameMovementKeys
        $overlay.Hide()
        $script:OverlayVisible = $false
        Focus-GameWindow
    } else {
        Release-GameMovementKeys
        Set-MenuPause $true
        Center-Overlay
        $overlay.Show()
        $overlay.BringToFront()
        $overlay.Activate()
        $script:OverlayVisible = $true
    }
}

$poll = New-Object System.Windows.Forms.Timer
$poll.Interval = 45
$poll.Add_Tick({
    $p = Find-GameProcess
    if ($p) {
        if (Is-ModHotkeyContext) {
            $tab = (([FancyNative]::GetAsyncKeyState(0x09) -band 0x8000) -ne 0)
            $tick = (([FancyNative]::GetAsyncKeyState(0xC0) -band 0x8000) -ne 0)
            if (($tab -and -not $script:PrevTab) -or ($tick -and -not $script:PrevTick)) { Toggle-Overlay }
            $script:PrevTab = $tab
            $script:PrevTick = $tick
        } else {
            $script:PrevTab = $false
            $script:PrevTick = $false
        }
    } else {
        if ($script:OverlayVisible) { $overlay.Hide(); $script:OverlayVisible = $false }
        $script:PrevTab = $false; $script:PrevTick = $false; $script:MenuPauseSent = $false
    }
})
$poll.Start()

$automationTimer = New-Object System.Windows.Forms.Timer
$automationTimer.Interval = 250
$automationTimer.Add_Tick({ Run-AutomationMods })
$automationTimer.Start()

$main.Add_FormClosing({
    $poll.Stop()
    $automationTimer.Stop()
    if ($script:MenuPauseSent) { Set-MenuPause $false }
    if ($script:OverlayVisible) { $overlay.Hide() }
})

# Initial layout
Show-Page "PLAYER"
Filter-ModSearch
Apply-ProControlStyle $main
Apply-ProControlStyle $overlay
Capture-BaseLayout $overlay
Set-OverlayScale 90
Filter-MegaItems
if ($script:ScaleValueLabel2) { $script:ScaleValueLabel2.Text = "$($script:OverlayScalePct)%" }
$existing = Get-ConfiguredGameDir
if ($existing) { Set-Status "Game folder ready: $existing" }
[System.Windows.Forms.Application]::Run($main)
