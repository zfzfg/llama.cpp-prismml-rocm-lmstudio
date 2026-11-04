<#
.SYNOPSIS
    Diagnostic report for LM Studio PrismML backends.
.DESCRIPTION
    Packaging fork by Collin Lerche (zfzfg) | STERRA (MIT).
    Inspects GPU detection, installed backends, LM Studio internal engine cache,
    and manifest compatibility. Writes an English report and copies it to the clipboard.
    Does not change LM Studio files unless -ClearIndexCache is set.
#>

[CmdletBinding()]
param (
    [switch]$ClearIndexCache
)

$report = [System.Collections.Generic.List[string]]::new()
function Log-Line([string]$str) {
    Write-Host $str
    $report.Add($str)
}

Log-Line "=========================================================="
Log-Line "         LM Studio PrismML Diagnostic Tool               "
Log-Line "=========================================================="
Log-Line "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Log-Line "This report can contain local paths and log excerpts. Review it before sharing it."

# 1. GPU Information
Log-Line "`n--- [1] GPU Hardware Detection ---"
$gpus = @()
try {
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    foreach ($gpu in $gpus) {
        Log-Line "GPU: $($gpu.Caption)"
        Log-Line "  Driver Version: $($gpu.DriverVersion)"
        Log-Line "  PNP Device ID:  $($gpu.PNPDeviceID)"
        Log-Line "  Video Processor: $($gpu.VideoProcessor)"
    }
} catch {
    Log-Line "Error querying GPUs: $($_.Exception.Message)"
}

# 2. Environment Variables
Log-Line "`n--- [2] ROCm / HIP Environment Variables ---"
$hsaOverride = [Environment]::GetEnvironmentVariable('HSA_OVERRIDE_GFX_VERSION', 'User')
$hsaProcess = $env:HSA_OVERRIDE_GFX_VERSION
$hsaOverrideStr = if ($hsaOverride) { $hsaOverride } else { '<Not Set>' }
$hsaProcessStr = if ($hsaProcess) { $hsaProcess } else { '<Not Set>' }
Log-Line "User HSA_OVERRIDE_GFX_VERSION:    $hsaOverrideStr"
Log-Line "Process HSA_OVERRIDE_GFX_VERSION: $hsaProcessStr"
$rdna4 = @($gpus | Where-Object { $_.Caption -match "9070|9000" })
if ($hsaOverride -eq "12.0.1" -and $rdna4.Count -eq 0) {
    Log-Line "  [!] HSA_OVERRIDE_GFX_VERSION=12.0.1 is set, but no RX 9070 / 9000 GPU was detected. That override is for gfx1201 only."
}

# 3. Installed Backends in .lmstudio
Log-Line "`n--- [3] Installed Backend Folders ---"
$lmStudioPath = Join-Path $env:USERPROFILE ".lmstudio"
$backendsPath = Join-Path $lmStudioPath "extensions\backends"

if (Test-Path $backendsPath) {
    $dirs = Get-ChildItem -Path $backendsPath -Directory -ErrorAction SilentlyContinue
    foreach ($d in $dirs) {
        $manifestPath = Join-Path $d.FullName "backend-manifest.json"
        $serverPath = Join-Path $d.FullName "llama-server.exe"
        $hasManifest = Test-Path $manifestPath
        $hasServer = Test-Path $serverPath
        
        Log-Line "`nFolder: $($d.Name)"
        Log-Line "  llama-server.exe: $(if ($hasServer) { 'PRESENT' } else { 'MISSING' })"
        Log-Line "  backend-manifest.json: $(if ($hasManifest) { 'PRESENT' } else { 'MISSING' })"
        
        if ($hasManifest) {
            try {
                $rawJson = [System.IO.File]::ReadAllText($manifestPath)
                $manifest = ConvertFrom-Json $rawJson
                Log-Line "    name: $($manifest.name)"
                Log-Line "    version: $($manifest.version)"
                Log-Line "    gpu.framework: $($manifest.gpu.framework)"
                if ($manifest.vendor_lib_package_names) {
                    Log-Line "    vendor_lib_package_names: $($manifest.vendor_lib_package_names -join ', ')"
                }
                if ($manifest.target_libraries) {
                    $tl = $manifest.target_libraries | ForEach-Object { "$($_.name) ($($_.type))" }
                    Log-Line "    target_libraries: $($tl -join ', ')"
                }
                $hipDll = Test-Path (Join-Path $d.FullName "ggml-hip.dll")
                $vkDll = Test-Path (Join-Path $d.FullName "ggml-vulkan.dll")
                Log-Line "    ggml-hip.dll: $(if ($hipDll) { 'PRESENT' } else { 'MISSING' })"
                Log-Line "    ggml-vulkan.dll: $(if ($vkDll) { 'PRESENT' } else { 'MISSING' })"
                if ($manifest.name -match "rocm" -and -not $hipDll) {
                    Log-Line "    [!] ROCm engine name is set but ggml-hip.dll is missing."
                }
                if ($manifest.name -match "vulkan" -and -not $vkDll) {
                    Log-Line "    [!] Vulkan engine name is set but ggml-vulkan.dll is missing."
                }
            } catch {
                Log-Line "    [!] Error parsing manifest: $($_.Exception.Message)"
            }
        }
        
        if ($hasServer) {
            try {
                $ver = & $serverPath --version 2>&1 | Select-Object -First 1
                Log-Line "  llama-server --version: $ver (exit $LASTEXITCODE). This is not a model-inference test."
            } catch {
                Log-Line "  llama-server --version: FAILED ($($_.Exception.Message))"
            }
        }

        # Check node files in folder
        $nodeFiles = Get-ChildItem -Path $d.FullName -Filter "*.node" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        if ($nodeFiles) {
            Log-Line "  .node files: $($nodeFiles -join ', ')"
        } else {
            Log-Line "  .node files: NONE"
        }
    }
} else {
    Log-Line "Extensions directory not found at $backendsPath"
}

# 3b. GGUF runtime preferences
Log-Line "`n--- [3b] GGUF Runtime Preferences ---"
$prefFiles = @(
    (Join-Path $lmStudioPath ".internal\backend-preferences-v1.json"),
    (Join-Path $lmStudioPath "apps\bionic\.internal\backend-preferences-v1.json"),
    (Join-Path $lmStudioPath "apps\bionic\.internal\backend-preferences-v2.json")
)
foreach ($pf in $prefFiles) {
    if (-not (Test-Path -LiteralPath $pf)) { continue }
    Log-Line "Preference file: $pf"
    try {
        $prefs = @(Get-Content -LiteralPath $pf -Raw | ConvertFrom-Json)
        $gguf = @($prefs | Where-Object { $_.model_format -eq "gguf" })
        foreach ($row in $prefs) {
            Log-Line "  $($row.model_format): $($row.name)@$($row.version)"
        }
        if ($prefs.Count -gt 0 -and $gguf.Count -eq $prefs.Count -and ($gguf | Where-Object { $_.name -match "prism" })) {
            Log-Line "  [!] This file contains only Prism GGUF rows. Other formats are absent; that is expected if LM Studio only stored GGUF here."
        }
    } catch {
        Log-Line "  [!] Error parsing preferences: $($_.Exception.Message)"
    }
}

# 4. LM Studio Cached Engine Index
Log-Line "`n--- [4] LM Studio Internal Engine Index Cache ---"
$indexFiles = @(
    (Join-Path $lmStudioPath ".internal\internal-engine-index.json"),
    (Join-Path $lmStudioPath "apps\bionic\.internal\internal-engine-index.json")
)

foreach ($idxFile in $indexFiles) {
    if (Test-Path $idxFile) {
        Log-Line "`nIndex File: $idxFile"
        try {
            $raw = [System.IO.File]::ReadAllText($idxFile)
            $data = ConvertFrom-Json $raw
            $entries = if ($data.json -is [array]) { $data.json } else { @($data.json) }
            
            foreach ($entry in $entries) {
                $mName = $entry.manifest.name
                $mVer = $entry.manifest.version
                $status = $entry.backendCompatibility.status
                $msg = $entry.backendCompatibility.message
                if ($mName -match "prism|rocm|vulkan") {
                    Log-Line "  -> Engine: $mName@$mVer"
                    Log-Line "     Index status: $status"
                    Log-Line "     This index flag is not a runtime test and does not show that a model was loaded."
                    if ($msg) { Log-Line "     Message: $msg" }
                }
            }
        } catch {
            Log-Line "  [!] Error parsing index: $($_.Exception.Message)"
        }
    } else {
        Log-Line "Index file not found: $idxFile"
    }
}

# 5. Recent Logs from main.log
Log-Line "`n--- [5] Recent LM Studio Error / Warning Logs ---"
$logPath = Join-Path $env:APPDATA "LM Studio\logs\main.log"
if (Test-Path $logPath) {
    try {
        $recentLines = Get-Content -Path $logPath -Tail 200 -ErrorAction SilentlyContinue | 
            Where-Object { $_ -match "error|warn|backend|rocm|vulkan|incompatible|Missing" } | 
            Select-Object -Last 15
        if ($recentLines) {
            foreach ($l in $recentLines) { Log-Line "  $l" }
        } else {
            Log-Line "  (No recent backend errors found in main.log)"
        }
    } catch {
        Log-Line "  Error reading log: $($_.Exception.Message)"
    }
} else {
    Log-Line "Log file not found at $logPath"
}

# 5b. Flag contract between LM Studio and installed PrismML servers
Log-Line "`n--- [5b] LM Studio Flag Contract ---"
$serverLogs = Join-Path $env:USERPROFILE ".lmstudio\server-logs"
if (Test-Path -LiteralPath $serverLogs) {
    $flagErrors = Get-ChildItem -LiteralPath $serverLogs -Recurse -Filter "*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 3 |
        Select-String -Pattern "invalid argument: " -SimpleMatch | Select-Object -Last 5
    foreach ($hit in $flagErrors) { Log-Line "  $($hit.Line)" }
    if (-not $flagErrors) { Log-Line "  (No 'invalid argument' lines in the 3 newest server logs)" }
}
$backendsRoot = Join-Path $env:USERPROFILE ".lmstudio\extensions\backends"
foreach ($dir in @(Get-ChildItem -LiteralPath $backendsRoot -Directory -Filter "llama.cpp-prism-*" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch "\.bak-" })) {
    $manifestFile = Join-Path $dir.FullName "backend-manifest.json"
    $commonDll = Join-Path $dir.FullName "llama-common.dll"
    if (-not (Test-Path -LiteralPath $manifestFile) -or -not (Test-Path -LiteralPath $commonDll)) { continue }
    try {
        $manifestVersion = (Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json).version
        $receivesFlag = [version]$manifestVersion -ge [version]"2.32.0"
        $acceptsFlag = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($commonDll)).Contains("--lazy-mode")
        $state = if ($receivesFlag -and -not $acceptsFlag) { "MISMATCH: LLM models cannot load in LM Studio 0.4.28" } else { "ok" }
        Log-Line "  $($dir.Name): manifest $manifestVersion, receives --lazy-mode=$receivesFlag, server has it=$acceptsFlag -> $state"
    } catch {
        Log-Line "  $($dir.Name): could not check: $($_.Exception.Message)"
    }
}

# Optional Cache Clearing
if ($ClearIndexCache) {
    Log-Line "`n--- [6] Clearing Cached Engine Index ---"
    foreach ($idxFile in $indexFiles) {
        if (Test-Path $idxFile) {
            Remove-Item $idxFile -Force -ErrorAction SilentlyContinue
            Log-Line "  Removed cached index: $idxFile"
        }
    }
    Log-Line "  -> Done! Restart LM Studio to trigger a clean re-scan."
}

Log-Line "`n=========================================================="
Log-Line "                 End of Diagnostic Report                 "
Log-Line "=========================================================="

# Save to file and copy to clipboard
$outText = $report -join "`r`n"
$tempDiag = Join-Path $env:TEMP "lmstudio-diagnostic.txt"
[System.IO.File]::WriteAllText($tempDiag, $outText)

try {
    Set-Clipboard -Value $outText -ErrorAction SilentlyContinue
    Write-Host "`n[OK] Diagnostic report copied to clipboard!" -ForegroundColor Green
    Write-Host "     (You can simply press Ctrl + V to paste it here)." -ForegroundColor Green
} catch {
    Write-Host "`n[INFO] Report saved to: $tempDiag" -ForegroundColor Cyan
}
