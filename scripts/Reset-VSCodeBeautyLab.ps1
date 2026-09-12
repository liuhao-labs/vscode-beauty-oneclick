[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$PayloadPath = "",
    [string]$FontsPath = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:ResetWarnings = 0
. (Join-Path $PSScriptRoot 'VSCodeBeauty.Safety.ps1')

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-WarnLine {
    param([string]$Message)
    $script:ResetWarnings++
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Ensure-FontNativeMethods {
    if ("Win32.BeautyResetFontNativeMethods" -as [type]) {
        return
    }

    Add-Type -Namespace Win32 -Name BeautyResetFontNativeMethods -MemberDefinition @"
[DllImport("gdi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
public static extern bool RemoveFontResourceW(string lpFileName);

[DllImport("user32.dll", SetLastError=true)]
public static extern int SendMessageTimeout(
    System.IntPtr hWnd,
    int Msg,
    System.IntPtr wParam,
    System.IntPtr lParam,
    int fuFlags,
    int uTimeout,
    out System.IntPtr lpdwResult);
"@
}

function Send-FontChangeBroadcast {
    try {
        Ensure-FontNativeMethods
        $result = [IntPtr]::Zero
        if ([Win32.BeautyResetFontNativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 1000, [ref]$result) -eq 0) {
            throw 'Font-change broadcast timed out or failed.'
        }
    }
    catch {
        Write-WarnLine "Font-change broadcast failed; log off/on or restart Windows if an app cannot see font changes."
    }
}

function Resolve-ExistingPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if (Test-Path -LiteralPath $Path) {
        return (Resolve-Path -LiteralPath $Path).Path
    }
    return $null
}

function Get-RepositoryFontsRoot {
    $candidates = @(
        (Join-Path $PSScriptRoot "fonts"),
        (Join-Path (Split-Path -Parent $PSScriptRoot) "fonts")
    )

    foreach ($candidate in $candidates) {
        $resolved = Resolve-ExistingPath -Path $candidate
        if ($resolved) {
            return $resolved
        }
    }

    return $null
}

function Get-FontsRoot {
    if ($FontsPath -and -not (Test-Path -LiteralPath $FontsPath -PathType Container)) {
        throw "FontsPath is not a directory: $FontsPath"
    }
    $resolved = Resolve-ExistingPath -Path $FontsPath
    if ($resolved) {
        return $resolved
    }

    $resolvedPayload = Resolve-ExistingPath -Path $PayloadPath
    if ($resolvedPayload) {
        $candidate = Join-Path $resolvedPayload "fonts"
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $repoFonts = Get-RepositoryFontsRoot
    if ($repoFonts) {
        return $repoFonts
    }

    throw "Pass -FontsPath, pass -PayloadPath, or place this script in a repository with a fonts folder."
}

function Get-BeautyFontInventory {
    $fontRoot = Get-FontsRoot
    if (-not (Test-Path -LiteralPath $fontRoot)) {
        throw "Font source not found: $fontRoot"
    }

    $fontFiles = @(Get-ChildItem -LiteralPath $fontRoot -Recurse -File |
        Where-Object { $_.Extension -in @(".ttf", ".ttc", ".otf") })
    if ($fontFiles.Count -eq 0) {
        throw "No font files found in payload: $fontRoot"
    }

    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($font in $fontFiles) {
        [void]$names.Add($font.Name)
    }

    [pscustomobject]@{
        Files = $fontFiles
        FileNames = $names
    }
}

function Test-BeautyFontRegistryValue {
    param(
        [System.Management.Automation.PSPropertyInfo]$Property,
        [object]$Inventory
    )

    $value = [string]$Property.Value
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        $fileName = Split-Path -Leaf $value
        if ($Inventory.FileNames.Contains($fileName)) {
            $expected = Join-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts') $fileName
            return [IO.Path]::IsPathRooted($value) -and
                ([IO.Path]::GetFullPath($value) -ieq [IO.Path]::GetFullPath($expected))
        }
    }

    return $false
}

function Remove-BeautyFontRegistryValues {
    param([object]$Inventory)

    Write-Step "Removing beauty font registry values"
    foreach ($regPath in @(
        "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
    )) {
        if (-not (Test-Path -LiteralPath $regPath)) {
            continue
        }

        $props = (Get-ItemProperty -Path $regPath).PSObject.Properties |
            Where-Object { $_.MemberType -eq "NoteProperty" -and (Test-BeautyFontRegistryValue -Property $_ -Inventory $Inventory) }

        foreach ($prop in $props) {
            try {
                $fontFile = Join-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts') (Split-Path -Leaf ([string]$prop.Value))
                if (Test-Path -LiteralPath $fontFile) {
                    Write-WarnLine "Font file still exists; keeping registry value: $($prop.Name)"
                    continue
                }
                Write-Host "Remove registry: $regPath -> $($prop.Name)"
                Remove-ItemProperty -Path $regPath -Name $prop.Name -Force
            }
            catch {
                Write-WarnLine "Could not remove registry value: $regPath -> $($prop.Name)"
                Write-WarnLine $_.Exception.Message
            }
        }
    }
}

function Remove-BeautyFontFiles {
    param(
        [object]$Inventory,
        [string]$BackupRoot
    )

    Write-Step "Removing beauty font files"
    Ensure-FontNativeMethods

    foreach ($base in @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts")
    )) {
        foreach ($fileName in $Inventory.FileNames) {
            $path = Join-Path $base $fileName
            if (-not (Test-Path -LiteralPath $path)) {
                continue
            }

            try {
                $backupDir = Join-Path $BackupRoot ("fonts-" + (($base -replace "[:\\]+", "_").Trim("_")))
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
                Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir $fileName) -Force
                for ($i = 0; $i -lt 10; $i++) {
                    if (-not [Win32.BeautyResetFontNativeMethods]::RemoveFontResourceW($path)) { break }
                }
                Remove-Item -LiteralPath $path -Force
                Write-Host "Removed font file: $path"
            }
            catch {
                Write-WarnLine "Could not remove font file: $path"
                Write-WarnLine $_.Exception.Message
            }
        }
    }

    Send-FontChangeBroadcast
}

function Stop-VSCode {
    $processes = @(Get-Process Code -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) {
        return
    }

    throw 'VS Code is running. Save your work and close all VS Code windows before resetting.'
}

function Move-KnownPath {
    param(
        [string]$Path,
        [string]$BackupRoot
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "Missing: $Path"
        return
    }

    $full = [System.IO.Path]::GetFullPath($Path)
    Assert-NoLinkedPath -Path $full -Recurse
    $allowed = @(
        [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code")),
        [System.IO.Path]::GetFullPath((Join-Path $env:APPDATA "Code")),
        [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "Code")),
        [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE ".vscode\extensions"))
    )

    if (-not ($allowed | Where-Object { $_ -ieq $full })) {
        throw "Refusing to move unexpected path: $full"
    }

    $name = ($full -replace "[:\\]+", "_").Trim("_")
    $destination = Join-Path $BackupRoot $name
    if (Test-Path -LiteralPath $destination) {
        $destination = "$destination-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    }

    Write-Host "Move: $full"
    Write-Host "  To: $destination"
    Move-Item -LiteralPath $full -Destination $destination -Force
}

function Uninstall-VSCode {
    Write-Step "Uninstalling VS Code"
    Stop-VSCode

    $uninstallers = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\unins000.exe")
    )

    $uninstaller = $uninstallers | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($uninstaller) {
        Write-Host "Run: $uninstaller"
        $process = Start-Process -FilePath $uninstaller -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART" -Wait -PassThru -WindowStyle Hidden
        Write-Host "Exit code: $($process.ExitCode)"
        if ($process.ExitCode -ne 0) { throw "Uninstaller failed with exit code $($process.ExitCode)." }
        Start-Sleep -Seconds 3
    }
    else {
        Write-Host "VS Code uninstaller not found."
    }
}

function Clear-VSCodeActivePaths {
    param([string]$BackupRoot)

    Write-Step "Moving VS Code active paths out of the profile"
    foreach ($path in @(
        (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code"),
        (Join-Path $env:APPDATA "Code"),
        (Join-Path $env:LOCALAPPDATA "Code"),
        (Join-Path $env:USERPROFILE ".vscode\extensions")
    )) {
        Move-KnownPath -Path $path -BackupRoot $BackupRoot
    }
}

function Show-ResetVerification {
    param([object]$Inventory)

    Write-Step "Reset verification"
    foreach ($path in @(
        (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code"),
        (Join-Path $env:APPDATA "Code"),
        (Join-Path $env:LOCALAPPDATA "Code"),
        (Join-Path $env:USERPROFILE ".vscode\extensions")
    )) {
        Write-Host ("VSCodePath|{0}|{1}" -f (Test-Path -LiteralPath $path), $path)
        if (Test-Path -LiteralPath $path) { Write-WarnLine "VS Code path remains: $path" }
    }

    foreach ($base in @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts")
    )) {
        $left = @()
        foreach ($fileName in $Inventory.FileNames) {
            $path = Join-Path $base $fileName
            if (Test-Path -LiteralPath $path) {
                $left += $path
            }
        }
        Write-Host ("FontFilesLeft|{0}|{1}" -f $left.Count, $base)
        if ($left.Count) { Write-WarnLine 'Some current-user font files remain.' }
        foreach ($item in $left) {
            Write-Host "  $item"
        }
    }

    foreach ($regPath in @(
        "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
    )) {
        if (-not (Test-Path -LiteralPath $regPath)) {
            Write-Host "FontRegLeft|0|$regPath"
            continue
        }
        $props = (Get-ItemProperty -Path $regPath).PSObject.Properties |
            Where-Object { $_.MemberType -eq "NoteProperty" -and (Test-BeautyFontRegistryValue -Property $_ -Inventory $Inventory) }
        Write-Host ("FontRegLeft|{0}|{1}" -f @($props).Count, $regPath)
        if (@($props).Count) { Write-WarnLine 'Some current-user font registry values remain.' }
        foreach ($prop in $props) {
            Write-Host "  $($prop.Name)=$($prop.Value)"
        }
    }
}

function Backup-ResetFonts {
    param([object]$Inventory, [string]$BackupRoot)
    $fontRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $fileBackup = Join-Path $BackupRoot 'fonts-before'
    New-Item -ItemType Directory -Path $fileBackup | Out-Null
    foreach ($fileName in $Inventory.FileNames) {
        $path = Join-Path $fontRoot $fileName
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $fileBackup $fileName) -ErrorAction Stop }
    }
    $regPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    $values = @()
    if (Test-Path -LiteralPath $regPath) {
        $key = Get-Item -LiteralPath $regPath
        $values = @((Get-ItemProperty -LiteralPath $regPath).PSObject.Properties |
            Where-Object { $_.MemberType -eq 'NoteProperty' -and (Test-BeautyFontRegistryValue $_ $Inventory) } |
            ForEach-Object { [pscustomobject]@{ Path = $regPath; Name = $_.Name; Value = $_.Value; Kind = $key.GetValueKind($_.Name).ToString() } })
    }
    Export-Clixml -InputObject $values -LiteralPath (Join-Path $BackupRoot 'fonts-registry-before.xml') -Encoding UTF8
}

if ($MyInvocation.InvocationName -eq '.') { return }
Write-Host 'VS Code Beauty Lab Reset (current user only)' -ForegroundColor Magenta
try {
    if ($PayloadPath -and -not (Test-Path -LiteralPath $PayloadPath -PathType Container)) { throw "Invalid PayloadPath: $PayloadPath" }
    $inventory = Get-BeautyFontInventory
    $targets = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code'),
        (Join-Path $env:APPDATA 'Code'),
        (Join-Path $env:LOCALAPPDATA 'Code'),
        (Join-Path $env:USERPROFILE '.vscode\extensions'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts')
    )
    foreach ($path in $targets) { Assert-NoLinkedPath -Path $path -Recurse }
    foreach ($font in $inventory.Files) {
        foreach ($path in $targets) {
            if (Test-PathsOverlap $font.FullName $path) { throw 'Reset font inventory must be outside active targets.' }
        }
    }
    $backupBase = Join-Path $env:LOCALAPPDATA 'VSCodeBeauty\Backups'
    Assert-NoLinkedPath -Path $backupBase
    if (-not $PSCmdlet.ShouldProcess(($targets -join ', '), 'Back up and reset current-user VS Code and matching user fonts')) { return }
    Stop-VSCode
    $backupRoot = Join-Path $backupBase ('reset-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $backupRoot | Out-Null
    Write-Host "Backup: $backupRoot"
    Backup-ResetFonts -Inventory $inventory -BackupRoot $backupRoot
    Uninstall-VSCode
    Clear-VSCodeActivePaths -BackupRoot $backupRoot
    Remove-BeautyFontFiles -Inventory $inventory -BackupRoot $backupRoot
    Remove-BeautyFontRegistryValues -Inventory $inventory
    Send-FontChangeBroadcast
    Show-ResetVerification -Inventory $inventory
}
catch {
    Write-Host "Reset failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
if ($script:ResetWarnings) {
    Write-WarnLine 'Reset completed with warnings. Some items may remain; review the output and backup.'
    exit 2
}
Write-Ok 'Current-user reset completed.'
exit 0
