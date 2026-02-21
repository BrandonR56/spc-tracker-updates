param(
    [string]$InstallDir = "$env:USERPROFILE\SPC_Tracker_Installed"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step([string]$Message) {
    Write-Host "[SPC-USB-INSTALL] $Message"
}

function Stop-PortProcess([int]$Port) {
    $listening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    foreach ($conn in $listening) {
        $procId = [int]$conn.OwningProcess
        if ($procId -gt 0) {
            try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch {}
        }
    }
}

function Stop-InstallProcesses([string]$InstallDirPath) {
    $currentProcessId = $PID
    $needle = "$InstallDirPath".Trim().ToLower()
    try {
        $resolved = Resolve-Path $InstallDirPath -ErrorAction SilentlyContinue
        if ($resolved) {
            $needle = "$($resolved.Path)".Trim().ToLower()
        }
    } catch {}

    $procNames = @("SPC_Tracker_App", "uvicorn")
    foreach ($name in $procNames) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {}
        }
    }

    $candidates = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    foreach ($p in $candidates) {
        $cmd = "$($p.CommandLine)".ToLower()
        $nm = "$($p.Name)".ToLower()
        $procId = 0
        try { $procId = [int]$p.ProcessId } catch { $procId = 0 }
        if ($procId -le 0) {
            continue
        }
        if ($procId -eq $currentProcessId) {
            continue
        }
        $matchInstall = (-not [string]::IsNullOrWhiteSpace($needle)) -and ($cmd -like "*$needle*")
        $matchSpcCmd = ($cmd -like "*app:app*--port 8010*") -or ($cmd -like "*start_spc*") -or ($cmd -like "*spc_tracker_app.exe*")
        $matchName = $nm -eq "spc_tracker_app.exe"
        if ($matchInstall -or $matchSpcCmd -or $matchName) {
            try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch {}
        }
    }
}

function Rename-ItemRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$NewName,
        [int]$Attempts = 20,
        [int]$DelayMs = 600
    )
    $lastErr = $null
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            Rename-Item -Path $Path -NewName $NewName -ErrorAction Stop
            return
        } catch {
            $lastErr = $_
            Start-Sleep -Milliseconds $DelayMs
        }
    }
    $msg = ""
    if ($lastErr) {
        $msg = "$lastErr"
    }
    throw "Could not move existing install out of the way after retries. Close SPC app windows and file explorers using install folder, then retry. Details: $msg"
}

function Wait-AppReady([int]$Port, [int]$TimeoutSeconds = 45) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/login" -f $Port) -UseBasicParsing -TimeoutSec 4
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) {
                return $true
            }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Invoke-RobocopySafe {
    param(
        [Parameter(Mandatory = $true)][string]$From,
        [Parameter(Mandatory = $true)][string]$To
    )
    & robocopy $From $To /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "Robocopy failed with exit code $LASTEXITCODE"
    }
}

function Test-VenvReady([string]$VenvPython) {
    if (!(Test-Path $VenvPython)) {
        return $false
    }
    try {
        & $VenvPython -c "import fastapi,uvicorn,reportlab,matplotlib,httpx; print('ok')" | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Get-PythonBootstrapCommand {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        return @("py", "-3")
    }
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        return @($python.Path)
    }
    return @()
}

function Ensure-LocalRuntime([string]$InstallDirPath, [switch]$ForceRebuild) {
    $venvDir = Join-Path $InstallDirPath ".venv"
    $venvPython = Join-Path $venvDir "Scripts\python.exe"
    if ((-not $ForceRebuild) -and (Test-VenvReady -VenvPython $venvPython)) {
        Write-Step "Bundled runtime is ready."
        return
    }

    Write-Step "Rebuilding local runtime."
    if (Test-Path $venvDir) {
        Remove-Item -Recurse -Force $venvDir
    }

    $bootstrap = Get-PythonBootstrapCommand
    if ($bootstrap.Count -eq 0) {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Step "Installing Python 3 with winget (one-time setup)."
            & winget install -e --id Python.Python.3.13 --scope user --accept-source-agreements --accept-package-agreements
            $bootstrap = Get-PythonBootstrapCommand
        }
    }
    if ($bootstrap.Count -eq 0) {
        throw "Python is not installed on this PC. Install Python 3.x, then rerun this installer."
    }

    Write-Step "Creating virtual environment."
    if ($bootstrap.Count -eq 2) {
        & $bootstrap[0] $bootstrap[1] -m venv $venvDir
    } else {
        & $bootstrap[0] -m venv $venvDir
    }
    if (!(Test-Path $venvPython)) {
        throw "Failed to create virtual environment at $venvDir"
    }

    Write-Step "Installing dependencies (requires internet for first install)."
    & $venvPython -m pip install --disable-pip-version-check -r (Join-Path $InstallDirPath "requirements.txt")

    if (-not (Test-VenvReady -VenvPython $venvPython)) {
        throw "Runtime setup completed, but dependency import check failed."
    }
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

$sourceStandaloneDir = Get-ChildItem -Path $scriptRoot -Directory -Filter "SPC_Tracker_v*_windows_standalone" -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object -First 1
$zipStandalone = Get-ChildItem -Path $scriptRoot -File -Filter "SPC_Tracker_v*_windows_standalone.zip" -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object -First 1
$sourcePortableDir = Get-ChildItem -Path $scriptRoot -Directory -Filter "SPC_Tracker_v*_windows_portable" -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object -First 1
$zipPortable = Get-ChildItem -Path $scriptRoot -File -Filter "SPC_Tracker_v*_windows_portable.zip" -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object -First 1

$packageKind = ""
$sourceDir = $null
$zipFile = $null
if ($sourceStandaloneDir -or $zipStandalone) {
    $packageKind = "standalone"
    $sourceDir = $sourceStandaloneDir
    $zipFile = $zipStandalone
} elseif ($sourcePortableDir -or $zipPortable) {
    $packageKind = "portable"
    $sourceDir = $sourcePortableDir
    $zipFile = $zipPortable
}

if ([string]::IsNullOrWhiteSpace($packageKind)) {
    throw "No supported release folder or zip found in: $scriptRoot"
}

$installParent = Split-Path -Parent $InstallDir
if (-not (Test-Path $installParent)) {
    New-Item -Path $installParent -ItemType Directory | Out-Null
}

$installDirExists = Test-Path $InstallDir
if ($installDirExists) {
    Write-Step "Stopping running SPC processes before install."
    Stop-PortProcess -Port 8010
    Stop-PortProcess -Port 8011
    Stop-InstallProcesses -InstallDirPath $InstallDir
    Start-Sleep -Milliseconds 700
}

$previousInstallBackup = $null
if (Test-Path $InstallDir) {
    $backupDir = "$InstallDir`_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Write-Step "Existing install found. Backing up to: $backupDir"
    Rename-ItemRetry -Path $InstallDir -NewName (Split-Path -Leaf $backupDir)
    $previousInstallBackup = $backupDir
}

New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null

if ($sourceDir) {
    Write-Step "Installing $packageKind package from folder: $($sourceDir.FullName)"
    Invoke-RobocopySafe -From $sourceDir.FullName -To $InstallDir
} else {
    Write-Step "Installing $packageKind package from zip: $($zipFile.FullName)"
    $tmp = Join-Path $env:TEMP ("spc_usb_install_" + [guid]::NewGuid().ToString("N"))
    New-Item -Path $tmp -ItemType Directory | Out-Null
    try {
        Expand-Archive -Path $zipFile.FullName -DestinationPath $tmp -Force
        Invoke-RobocopySafe -From $tmp -To $InstallDir
    } finally {
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$dbPatterns = @("spc*.db", "*.db-wal", "*.db-shm", "*.db-journal")
$preserveFiles = @("spc_update_channel.json")
if ($previousInstallBackup -and (Test-Path $previousInstallBackup)) {
    Write-Step "Preserving existing local database from previous install."
    foreach ($pat in $dbPatterns) {
        Get-ChildItem -Path $previousInstallBackup -Filter $pat -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                Copy-Item -Path $_.FullName -Destination (Join-Path $InstallDir $_.Name) -Force
            }
    }
    foreach ($fileName in $preserveFiles) {
        $candidate = Join-Path $previousInstallBackup $fileName
        if (Test-Path $candidate -PathType Leaf) {
            Copy-Item -Path $candidate -Destination (Join-Path $InstallDir $fileName) -Force
        }
    }
}

$startBat = Join-Path $InstallDir "start_spc.bat"
$startVbs = Join-Path $InstallDir "start_spc_hidden.vbs"
$standaloneExe = Join-Path $InstallDir "SPC_Tracker_App.exe"
$startStandaloneBat = Join-Path $InstallDir "start_spc_standalone.bat"

if ($packageKind -eq "standalone") {
    if (-not (Test-Path $standaloneExe)) {
        throw "Install incomplete: missing $standaloneExe"
    }
} else {
    if (-not (Test-Path $startBat)) {
        throw "Install incomplete: missing $startBat"
    }
    Ensure-LocalRuntime -InstallDirPath $InstallDir
}

$desktop = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktop "SPC Tracker.lnk"
$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)
if ($packageKind -eq "standalone" -and (Test-Path $startVbs)) {
    $shortcut.TargetPath = $startVbs
} elseif ($packageKind -eq "standalone" -and (Test-Path $startStandaloneBat)) {
    $shortcut.TargetPath = $startStandaloneBat
} elseif ($packageKind -eq "standalone") {
    $shortcut.TargetPath = $standaloneExe
} elseif (Test-Path $startVbs) {
    $shortcut.TargetPath = $startVbs
} else {
    $shortcut.TargetPath = $startBat
}
$shortcut.WorkingDirectory = $InstallDir
$shortcut.Description = "SPC Tracker"
$iconStandalone = Join-Path $InstallDir "spc_icon.ico"
$iconAssets = Join-Path $InstallDir "assets\spc_icon.ico"
if (Test-Path $iconStandalone) {
    $shortcut.IconLocation = "$iconStandalone,0"
} elseif (Test-Path $iconAssets) {
    $shortcut.IconLocation = "$iconAssets,0"
} else {
    $shortcut.IconLocation = "$env:SystemRoot\System32\SHELL32.dll,13"
}
$shortcut.Save()

Write-Step "Desktop shortcut created: $shortcutPath"
Write-Step "Starting SPC Tracker and verifying startup..."
Stop-PortProcess -Port 8010
if ($packageKind -eq "standalone" -and (Test-Path $startVbs)) {
    Start-Process -FilePath $startVbs -WorkingDirectory $InstallDir | Out-Null
} elseif ($packageKind -eq "standalone" -and (Test-Path $startStandaloneBat)) {
    Start-Process -FilePath $startStandaloneBat -WorkingDirectory $InstallDir | Out-Null
} elseif ($packageKind -eq "standalone") {
    Start-Process -FilePath $standaloneExe -WorkingDirectory $InstallDir | Out-Null
} elseif (Test-Path $startVbs) {
    Start-Process -FilePath $startVbs -WorkingDirectory $InstallDir | Out-Null
} else {
    Start-Process -FilePath $startBat -WorkingDirectory $InstallDir | Out-Null
}
if (-not (Wait-AppReady -Port 8010 -TimeoutSeconds 45)) {
    if ($packageKind -eq "portable") {
        Write-Step "First startup failed. Rebuilding runtime and retrying."
        Ensure-LocalRuntime -InstallDirPath $InstallDir -ForceRebuild
        Stop-PortProcess -Port 8010
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $startBat -WorkingDirectory $InstallDir -WindowStyle Hidden | Out-Null
        if (-not (Wait-AppReady -Port 8010 -TimeoutSeconds 60)) {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/k", $startBat -WorkingDirectory $InstallDir | Out-Null
            throw "App installation completed, but startup failed. A console window was opened for diagnostics."
        }
    } else {
        Start-Process -FilePath "cmd.exe" -ArgumentList "/k", ("cd /d `"{0}`" && {1}" -f $InstallDir, "SPC_Tracker_App.exe") -WorkingDirectory $InstallDir | Out-Null
        throw "Standalone app installation completed, but startup failed. A console window was opened for diagnostics."
    }
}
Write-Step "Install complete. Open http://127.0.0.1:8010/login"
