param(
    [string]$Python = "",
    [switch]$SkipInstall
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$PreviousLocation = Get-Location
$PreviousPythonUtf8 = $env:PYTHONUTF8
$env:PYTHONUTF8 = "1"
Set-Location -LiteralPath $RepoRoot

function Invoke-Python {
    param([string[]]$Arguments)
    & $script:BuildPython @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Python command failed with exit code $LASTEXITCODE" }
}

function Test-FrozenApp {
    param([string]$Executable, [string[]]$Arguments)
    $Process = Start-Process -FilePath $Executable -ArgumentList $Arguments -PassThru -WindowStyle Hidden
    if (-not $Process.WaitForExit(240000)) {
        # A missing frozen import can show a native error dialog on Windows.
        # Bound the smoke check instead of waiting indefinitely for that dialog.
        $Process.Kill($true)
        $Process.WaitForExit()
        throw "Packaged application did not finish its verification within four minutes."
    }
    if ($Process.ExitCode -ne 0) { throw "Packaged application failed with exit code $($Process.ExitCode)" }
}

try {
    if (-not $IsWindows -and $env:OS -ne "Windows_NT") { throw "Build this EXE on Windows x64." }
    if ($Python) {
        $script:BuildPython = (Resolve-Path -LiteralPath $Python).Path
    } else {
        $VenvPython = Join-Path $RepoRoot "desktop\.venv\Scripts\python.exe"
        if (-not (Test-Path -LiteralPath $VenvPython)) {
            & python -m venv desktop/.venv
            if ($LASTEXITCODE -ne 0) { throw "Cannot create the isolated Python environment." }
        }
        $script:BuildPython = $VenvPython
    }
    Invoke-Python -Arguments @("-c", "import sys,struct; assert sys.version_info[:2] == (3,12), 'Use Python 3.12'; assert struct.calcsize('P') == 8, 'Use x64 Python'")
    if (-not $SkipInstall) {
        Invoke-Python -Arguments @("-m", "pip", "install", "--require-hashes", "-r", "desktop/requirements-build.txt")
    }
    Invoke-Python -Arguments @("-m", "pip", "check")
    Invoke-Python -Arguments @("-m", "pytest", "-c", "desktop/pytest.ini", "desktop/tests", "-q")
    Invoke-Python -Arguments @("desktop/build/collect_licenses.py", "desktop/.build/licenses")
    Invoke-Python -Arguments @("-m", "PyInstaller", "--noconfirm", "--clean", "--distpath", "desktop/dist", "--workpath", "desktop/.build/pyinstaller", "desktop/build/ScanPDF-Desktop.spec")

    $Executable = Join-Path $RepoRoot "desktop\dist\ScanPDF-Desktop\ScanPDF-Desktop.exe"
    Test-FrozenApp -Executable $Executable -Arguments @("--self-test")
    $Screenshot = Join-Path $RepoRoot "desktop\dist\ScanPDF-Desktop-Preview.png"
    $ScreenshotData = Join-Path $RepoRoot "desktop\.build\preview-data"
    Test-FrozenApp -Executable $Executable -Arguments @("--screenshot", "`"$Screenshot`"", "--data-dir", "`"$ScreenshotData`"")
    if (-not (Test-Path -LiteralPath $Screenshot)) { throw "GUI verification did not create a screenshot." }
    Invoke-Python -Arguments @("desktop/build/package_release.py")
} finally {
    $env:PYTHONUTF8 = $PreviousPythonUtf8
    Set-Location -LiteralPath $PreviousLocation.Path
}
