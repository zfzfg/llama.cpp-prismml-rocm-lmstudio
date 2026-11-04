<#
.SYNOPSIS
    Install PrismML AMD ROCm/HIP, NVIDIA CUDA, and Vulkan llama.cpp runtimes into LM Studio.
.DESCRIPTION
    Packaging fork by Collin Lerche (zfzfg) | STERRA (MIT).
    The llama.cpp binaries stay under the PrismML / ggml MIT license.
    Installs precompiled PrismML llama.cpp backends into LM Studio's extensions directory.
    Specially tuned for AMD Radeon RX 9070 XT / RX 9000 Series (RDNA 4, gfx1201/gfx1200)
    as well as RX 7000 Series (RDNA 3, gfx1100-gfx1151).
    
    Can be run STANDALONE with a single command without cloning the repository:
    powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/zfzfg/llama.cpp-prismml-rocm-lmstudio/main/setup-rocm-backend.ps1 | iex"
#>

[CmdletBinding()]
param (
    [ValidateSet("all", "rocm", "vulkan", "cuda")]
    [string]$Backend = "all",
    
    [ValidateSet("b10809", "b12128")]
    [string]$PrismBuild = "b10809",

    [switch]$SkipHardwareCheck,
    [switch]$Force,
    [switch]$SetDefaultRuntime,
    [switch]$ClearHsaOverride
)

$ErrorActionPreference = "Stop"
$prismLibPath = $null
if ($PSScriptRoot) {
    $prismLibCandidate = Join-Path $PSScriptRoot "PrismBackendLib.ps1"
    if (Test-Path -LiteralPath $prismLibCandidate) { $prismLibPath = $prismLibCandidate }
}
if (-not $prismLibPath) {
    $prismLibDir = Join-Path $env:TEMP ("prism-lib-" + [guid]::NewGuid().ToString("n"))
    New-Item -ItemType Directory -Path $prismLibDir | Out-Null
    $prismLibPath = Join-Path $prismLibDir "PrismBackendLib.ps1"
    $prismLibUrl = "https://raw.githubusercontent.com/zfzfg/llama.cpp-prismml-rocm-lmstudio/main/PrismBackendLib.ps1"
    Invoke-WebRequest -Uri $prismLibUrl -OutFile $prismLibPath -UseBasicParsing
}
. $prismLibPath
if ($prismLibDir) { Remove-Item -LiteralPath $prismLibDir -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  PrismML LM Studio Extension Setup (ROCm / CUDA / Vulkan)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

# Constants
$buildInfo = Set-PrismBuild -Build $PrismBuild
$PrismTag = $buildInfo.Tag
$HipZipUrl = $buildInfo.HipZipUrl
$VulkanZipUrl = $buildInfo.VulkanZipUrl

$HipDirName = $buildInfo.HipDirName
$VulkanDirName = $buildInfo.VulkanDirName
$lmsExePath = Join-Path $env:LOCALAPPDATA "Programs\LM Studio\resources\app\.webpack\lms.exe"

# 1. Detect LM Studio extensions directory
$lmStudioBackendsPath = Join-Path $env:USERPROFILE ".lmstudio\extensions\backends"
Write-Host "[1/4] Checking LM Studio installation..." -ForegroundColor Yellow
if (-not (Test-Path $lmStudioBackendsPath)) {
    Write-Host "Creating LM Studio extensions directory at: $lmStudioBackendsPath" -ForegroundColor Gray
    New-Item -ItemType Directory -Path $lmStudioBackendsPath -Force | Out-Null
} else {
    Write-Host "Found LM Studio extensions directory: $lmStudioBackendsPath" -ForegroundColor Green
}

$hsaSidecar = Join-Path $env:USERPROFILE ".lmstudio\prism-hsa-override-previous.txt"

function Restore-PrismHsaOverride {
    if (-not (Test-Path -LiteralPath $hsaSidecar)) {
        Write-Host "  [!] No PrismML HSA sidecar was found. The user environment variable was not changed." -ForegroundColor Yellow
        return
    }
    $current = [Environment]::GetEnvironmentVariable('HSA_OVERRIDE_GFX_VERSION', 'User')
    if ($current -ne '12.0.1') {
        Write-Host "  [!] HSA_OVERRIDE_GFX_VERSION is '$current', not the value this installer sets. It was left unchanged." -ForegroundColor Yellow
        return
    }
    $previous = [System.IO.File]::ReadAllText($hsaSidecar).Trim()
    if ($previous -eq "<unset>" -or $previous -eq "") {
        [Environment]::SetEnvironmentVariable('HSA_OVERRIDE_GFX_VERSION', $null, 'User')
        Remove-Item Env:HSA_OVERRIDE_GFX_VERSION -ErrorAction SilentlyContinue
        Write-Host "  [+] Removed user HSA_OVERRIDE_GFX_VERSION. This installer had recorded it as previously unset." -ForegroundColor Green
    } else {
        [Environment]::SetEnvironmentVariable('HSA_OVERRIDE_GFX_VERSION', $previous, 'User')
        $env:HSA_OVERRIDE_GFX_VERSION = $previous
        Write-Host "  [+] Restored user HSA_OVERRIDE_GFX_VERSION to '$previous'." -ForegroundColor Green
    }
}

if ($ClearHsaOverride) {
    Write-Host "`n[HSA] Restoring the user-level HSA_OVERRIDE_GFX_VERSION recorded by this installer..." -ForegroundColor Yellow
    Restore-PrismHsaOverride
}

# 2. Check GPU hardware and the RX 9070 XT HSA override.
# 12.0.1 is the value tested on RX 9070 XT. It is user-wide and only written for a ROCm/HIP install.
$detectedAmd = @()
$detectedNvidia = @()
$applyHsa = ($Backend -eq "all" -or $Backend -eq "rocm")
if (-not $SkipHardwareCheck) {
    Write-Host "`n[2/4] Detecting GPU Hardware..." -ForegroundColor Yellow
    try {
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -Property Caption, DriverVersion, VideoProcessor)
        $amds = @($gpus | Where-Object { $_.Caption -match "AMD|Radeon" })
        $detectedAmd = $amds
        $detectedNvidia = @($gpus | Where-Object { $_.Caption -match "NVIDIA|GeForce|Quadro" })
        foreach ($nvidia in $detectedNvidia) {
            Write-Host "  [+] Found NVIDIA GPU: $($nvidia.Caption) (Driver: $($nvidia.DriverVersion))" -ForegroundColor Green
            Write-Host "      The ROCm/HIP package does not drive this card. PrismML CUDA does." -ForegroundColor Cyan
        }
        
        if ($amds) {
            $rdna4 = @($amds | Where-Object { $_.Caption -match "9070|9000" })
            foreach ($amd in $amds) {
                Write-Host "  [+] Found AMD GPU: $($amd.Caption) (Driver: $($amd.DriverVersion))" -ForegroundColor Green
                if ($amd.Caption -match "9070|9000") {
                    Write-Host "      Detected AMD RDNA 4 architecture (Navi 48 / gfx1201)." -ForegroundColor Cyan
                } elseif ($amd.Caption -match "7900|7800|7700|7600") {
                    Write-Host "      Detected AMD RDNA 3 architecture (gfx1100-gfx1103)." -ForegroundColor Cyan
                    Write-Host "      HSA_OVERRIDE_GFX_VERSION=12.0.1 is for RX 9070 only and will not be set." -ForegroundColor Cyan
                }
            }

            # 12.0.1 matches gfx1201 (RX 9070). Do not apply it to other AMD GPUs or to a Vulkan-only install.
            $hsa = [Environment]::GetEnvironmentVariable('HSA_OVERRIDE_GFX_VERSION', 'User')
            if (-not $applyHsa) {
                Write-Host "  [i] Vulkan-only install. HSA_OVERRIDE_GFX_VERSION was not changed." -ForegroundColor Gray
            } elseif ($rdna4.Count -gt 0) {
                if ([string]::IsNullOrEmpty($hsa)) {
                    Write-Host "  [+] Configuring user environment variable: HSA_OVERRIDE_GFX_VERSION = 12.0.1 (RX 9070 / gfx1201)." -ForegroundColor Green
                    Write-Host "      This value applies to the whole user account, not only to LM Studio. Remove it later with -ClearHsaOverride." -ForegroundColor Gray
                    $sidecarDir = Split-Path -Parent $hsaSidecar
                    if (-not (Test-Path $sidecarDir)) { New-Item -ItemType Directory -Path $sidecarDir -Force | Out-Null }
                    if (-not (Test-Path -LiteralPath $hsaSidecar)) {
                        [System.IO.File]::WriteAllText($hsaSidecar, "<unset>")
                    }
                    [Environment]::SetEnvironmentVariable('HSA_OVERRIDE_GFX_VERSION', '12.0.1', 'User')
                    $env:HSA_OVERRIDE_GFX_VERSION = '12.0.1'
                } elseif ($hsa -eq '12.0.1') {
                    Write-Host "  [+] HSA_OVERRIDE_GFX_VERSION is already 12.0.1." -ForegroundColor Green
                } elseif ($Force) {
                    Write-Host "  [+] -Force: replacing HSA_OVERRIDE_GFX_VERSION '$hsa' with 12.0.1." -ForegroundColor Yellow
                    $sidecarDir = Split-Path -Parent $hsaSidecar
                    if (-not (Test-Path $sidecarDir)) { New-Item -ItemType Directory -Path $sidecarDir -Force | Out-Null }
                    if (-not (Test-Path -LiteralPath $hsaSidecar)) {
                        [System.IO.File]::WriteAllText($hsaSidecar, $hsa)
                    }
                    [Environment]::SetEnvironmentVariable('HSA_OVERRIDE_GFX_VERSION', '12.0.1', 'User')
                    $env:HSA_OVERRIDE_GFX_VERSION = '12.0.1'
                } else {
                    Write-Host "  [!] HSA_OVERRIDE_GFX_VERSION is '$hsa'. Leaving it unchanged. Pass -Force to set 12.0.1." -ForegroundColor Yellow
                }
            } elseif ($hsa -eq '12.0.1') {
                Write-Host "  [!] HSA_OVERRIDE_GFX_VERSION is 12.0.1 but no RX 9070 / 9000 GPU was detected. Leaving the existing value unchanged." -ForegroundColor Yellow
            } else {
                Write-Host "  [i] No RX 9070 / 9000 GPU detected. HSA_OVERRIDE_GFX_VERSION was not changed." -ForegroundColor Gray
            }
        } elseif ($detectedNvidia.Count -eq 0) {
            Write-Host "  [i] No AMD Radeon or NVIDIA GPU detected." -ForegroundColor Gray
        }
    } catch {
        Write-Host "  [!] Could not query GPU info: $($_.Exception.Message)" -ForegroundColor Gray
    }
} else {
    Write-Host "`n[2/4] Skipping hardware check as requested." -ForegroundColor Gray
}

$installBackend = $Backend
$installCuda = ($Backend -eq "cuda")
if (-not $PSBoundParameters.ContainsKey("Backend") -and -not $SkipHardwareCheck) {
    if ($detectedNvidia.Count -gt 0) {
        $installCuda = $true
        Write-Host "  [i] NVIDIA GPU detected, so PrismML CUDA ($($script:PrismCuda.Tag)) will be installed." -ForegroundColor Cyan
    }
    if ($detectedAmd.Count -eq 0) {
        $installBackend = if ($detectedNvidia.Count -gt 0) { "cuda" } else { "vulkan" }
        Write-Host "  [i] No AMD GPU was detected, so the AMD ROCm/HIP package is skipped." -ForegroundColor Cyan
        Write-Host "      Pass -Backend all or -Backend rocm to stage it anyway." -ForegroundColor Cyan
    }
}
if ($installCuda -and $PSBoundParameters.ContainsKey("PrismBuild") -and $PrismBuild -ne "b12128") {
    Write-Host "  [i] The CUDA package is only available as b12128. -PrismBuild applies to ROCm and Vulkan." -ForegroundColor Cyan
}

# Helper: Download file using curl if available or Invoke-WebRequest
function Download-FileWithProgress {
    param([string]$Url, [string]$OutputFile, [string]$Desc)
    Write-Host "     Downloading $Desc..." -ForegroundColor Cyan
    $curlPath = Get-Command "curl.exe" -ErrorAction SilentlyContinue
    if ($curlPath) {
        & curl.exe -L --fail --retry 3 --proto =https --progress-bar "$Url" -o "$OutputFile"
        if ($LASTEXITCODE -ne 0) { throw "Download failed for $Url (exit code $LASTEXITCODE)" }
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        Invoke-WebRequest -Uri $Url -OutFile $OutputFile -UseBasicParsing
    }
}

# Ensure official LM Studio Vulkan runtime and vendor package are present
$vendorVulkan = Join-Path $lmStudioBackendsPath "vendor\win-llama-vulkan-vendor-v3"
$vulkanInstalled = Get-ChildItem -Path $lmStudioBackendsPath -Directory -Filter "llama.cpp-win-x86_64-vulkan*" -ErrorAction SilentlyContinue | Select-Object -First 1

if (($installBackend -ne "cuda") -and ((-not (Test-Path $vendorVulkan)) -or (-not $vulkanInstalled)) -and (Test-Path $lmsExePath)) {
    Write-Host "`n  [*] Ensuring official LM Studio Vulkan runtime package is installed..." -ForegroundColor Cyan
    try {
        & $lmsExePath runtime get -y llama.cpp:vulkan
    } catch {
        Write-Host "      [!] Note: 'lms runtime get' warning: $($_.Exception.Message)" -ForegroundColor Gray
    }
}

# Helper: Find LM Studio adapter files
function Get-LmStudioAdapterFiles {
    param([string]$DestinationDir, [string]$Kind = "vulkan")
    
    $requiredAdapters = @(Get-PrismRequiredAdapterFiles -Kind $Kind)
    $commonFiles = $requiredAdapters + @(
        "libomp.dll",
        "llm_engine.dll", "lmstudiocore.dll", "ggml_llamacpp.dll",
        "MSVCP140.dll", "VCOMP140.dll", "VCRUNTIME140.dll", "VCRUNTIME140_1.dll"
    )

    $adapterName = if ($Kind -eq "cuda") { "CUDA" } else { "Vulkan" }
    $adapterRuntimeFilter = if ($Kind -eq "cuda") { "llama.cpp-win-x86_64-nvidia-cuda12*" } else { "llama.cpp-win-x86_64-vulkan*" }
    $adapterRuntimeId = if ($Kind -eq "cuda") { "llama.cpp:cuda12" } else { "llama.cpp:vulkan" }

    function Test-AdapterSet([string]$Dir) {
        foreach ($name in $requiredAdapters) {
            if (-not (Test-Path -LiteralPath (Join-Path $Dir $name))) { return $false }
        }
        return $true
    }
    
    # Only an official LM Studio runtime of the same GPU framework is a valid adapter source.
    $vulkanDirs = Get-PrismVersionedDirectories -Directories @(Get-ChildItem -Path $lmStudioBackendsPath -Directory -Filter $adapterRuntimeFilter -ErrorAction SilentlyContinue)
    
    $source = $null
    foreach ($vDir in $vulkanDirs) {
        if ((Test-AdapterSet $vDir.FullName) -and ($vDir.FullName -ne $DestinationDir)) {
            $source = $vDir
            break
        }
    }

    if ($source) {
        Write-Host "     $adapterName adapter source: $($source.FullName)" -ForegroundColor Gray
        foreach ($f in $commonFiles) {
            $src = Join-Path $source.FullName $f
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $DestinationDir $f) -Force
            }
        }
        $srcManifestPath = Join-Path $source.FullName "backend-manifest.json"
        $dstManifestPath = Join-Path $DestinationDir "backend-manifest.json"
        if ((Test-Path -LiteralPath $srcManifestPath) -and (Test-Path -LiteralPath $dstManifestPath)) {
            $srcManifest = Get-Content -LiteralPath $srcManifestPath -Raw | ConvertFrom-Json
            $dstManifest = Get-Content -LiteralPath $dstManifestPath -Raw | ConvertFrom-Json
            $srcEngine = @($srcManifest.target_libraries | Where-Object { $_.type -eq "llm_engine" } | Select-Object -First 1)
            $srcBinding = @($srcManifest.target_libraries | Where-Object { $_.type -eq "liblmstudio" } | Select-Object -First 1)
            if ($srcEngine[0] -and $srcBinding[0]) {
                if ($srcEngine[0].version -ne $script:PrismAdapterEngineVersion -or $srcBinding[0].version -ne $script:PrismAdapterBindingVersion) {
                    Write-Host "     [!] Adapter source reports llm_engine $($srcEngine[0].version) and liblmstudio $($srcBinding[0].version)." -ForegroundColor Yellow
                    Write-Host "         The tested RX 9070 XT registration uses $($script:PrismAdapterEngineVersion) and $($script:PrismAdapterBindingVersion). The manifest was updated to the source versions." -ForegroundColor Yellow
                }
                foreach ($lib in @($dstManifest.target_libraries)) {
                    if ($lib.type -eq "llm_engine") { $lib.version = [string]$srcEngine[0].version }
                    if ($lib.type -eq "liblmstudio") { $lib.version = [string]$srcBinding[0].version }
                }
                Write-PrismAtomicText -Path $dstManifestPath -Text ($dstManifest | ConvertTo-Json -Depth 8)
            }
        }
    } elseif (Test-AdapterSet $DestinationDir) {
        Write-Host "     $adapterName adapter source: files already present in the destination." -ForegroundColor Gray
    } else {
        throw "Required LM Studio $adapterName adapter files are missing ($($requiredAdapters -join ', ')). Install the official $adapterName runtime with 'lms runtime get $adapterRuntimeId' and rerun. This installer does not copy adapters from other backends."
    }

    # Ensure aliases for node files exist
    $engineNode = Join-Path $DestinationDir "llm_engine.node"
    $engineVulkanNode = Join-Path $DestinationDir "llm_engine_vulkan.node"
    if ((Test-Path $engineVulkanNode) -and (-not (Test-Path $engineNode))) {
        Copy-Item $engineVulkanNode $engineNode -Force
    } elseif ((Test-Path $engineNode) -and (-not (Test-Path $engineVulkanNode))) {
        Copy-Item $engineNode $engineVulkanNode -Force
    }

    $bindingNode = Join-Path $DestinationDir "liblmstudio_bindings.node"
    $bindingVulkanNode = Join-Path $DestinationDir "liblmstudio_bindings_vulkan.node"
    if ((Test-Path $bindingVulkanNode) -and (-not (Test-Path $bindingNode))) {
        Copy-Item $bindingVulkanNode $bindingNode -Force
    } elseif ((Test-Path $bindingNode) -and (-not (Test-Path $bindingVulkanNode))) {
        Copy-Item $bindingNode $bindingVulkanNode -Force
    }

    $stillMissing = @($requiredAdapters | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $DestinationDir $_))
    })
    if ($stillMissing.Count -gt 0) {
        throw "Adapter copy is incomplete. Missing: $($stillMissing -join ', '). Source: $(if ($source) { $source.FullName } else { $DestinationDir })."
    }
}

# Manifest Generator
function Write-BackendManifests {
    param(
        [string]$TargetDir,
        [string]$Kind # 'rocm', 'vulkan', or 'cuda'
    )

    if ($Kind -eq "cuda") {
        $package = Get-PrismCudaPackageJson
        [System.IO.File]::WriteAllText((Join-Path $TargetDir "backend-manifest.json"), $package.Manifest)
        [System.IO.File]::WriteAllText((Join-Path $TargetDir "display-data.json"), $package.Display)
        [System.IO.File]::WriteAllText((Join-Path $TargetDir "engine-protocol-server-artifacts.json"), $package.Artifacts)
        return
    }
    
    if ($Kind -eq "rocm") {
        $manifestJson = @'
{
  "version": "2.64.0",
  "domains": [
    "llm",
    "embedding"
  ],
  "engine": "llama.cpp",
  "target_libraries": [
    {
      "name": "llm_engine_vulkan.node",
      "type": "llm_engine",
      "version": "0.1.2"
    },
    {
      "name": "liblmstudio_bindings_vulkan.node",
      "type": "liblmstudio",
      "version": "0.2.26"
    }
  ],
  "platform": "win",
  "cpu": {
    "architecture": "x86_64",
    "instruction_set_extensions": [
      "AVX2"
    ]
  },
  "gpu": {
    "framework": "Vulkan"
  },
  "supported_model_formats": [
    "gguf"
  ],
  "manifest_version": "4",
  "extension_type": "engine",
  "vendor_lib_package_names": [
    "win-llama-vulkan-vendor-v3"
  ],
  "minimum_lmstudio_version": "0.4.0+15",
  "minimum_llmster_version": "0.0.1+9",
  "engine_protocol_server": {
    "runtime_kind": "llama-server",
    "executable_relative_path": "llama-server.exe"
  },
  "name": "llama.cpp-win-x86_64-prism-rocm-rx9070"
}
'@
        $displayJson = @'
[["en",{"langKey":"en","displayName":"Prism ML AMD ROCm/HIP llama.cpp (Windows - RX 9070 XT / RDNA 4)","description":"AMD ROCm/HIP accelerated llama.cpp engine with native Prism ML PQ2_0 ternary model support for Radeon RX 7000 / 9000 series","releaseNotes":[{"version":"2.64.0","releaseNotes":"- Native AMD ROCm/HIP support for Windows\n- Full support for Radeon RX 9070 / 9070 XT (RDNA 4, gfx1201 / gfx1200) and RX 7000 series (RDNA 3, gfx1100-gfx1151)\n- Accelerated PrismML Bonsai ternary model inference (*-PQ2_0.gguf, *-Q2_0_g64.gguf)\n"}]}]]
'@
        $artifactsJson = @'
{
  "schema_version": 1,
  "runtime_kind": "llama-server",
  "executable_relative_path": "llama-server.exe",
  "files": [
    { "relative_path": "ggml-base.dll", "executable": false },
    { "relative_path": "ggml-cpu.dll", "executable": false },
    { "relative_path": "ggml-hip.dll", "executable": false },
    { "relative_path": "libhipblas.dll", "executable": false },
    { "relative_path": "libhipblaslt.dll", "executable": false },
    { "relative_path": "rocblas.dll", "executable": false },
    { "relative_path": "llama-common.dll", "executable": false },
    { "relative_path": "llama-server-impl.dll", "executable": false },
    { "relative_path": "llama-server.exe", "executable": true },
    { "relative_path": "llama.dll", "executable": false },
    { "relative_path": "mtmd.dll", "executable": false }
  ]
}
'@
    } else {
        $manifestJson = @'
{
  "version": "2.64.0",
  "domains": [
    "llm",
    "embedding"
  ],
  "engine": "llama.cpp",
  "target_libraries": [
    {
      "name": "llm_engine_vulkan.node",
      "type": "llm_engine",
      "version": "0.1.2"
    },
    {
      "name": "liblmstudio_bindings_vulkan.node",
      "type": "liblmstudio",
      "version": "0.2.26"
    }
  ],
  "platform": "win",
  "cpu": {
    "architecture": "x86_64",
    "instruction_set_extensions": [
      "AVX2"
    ]
  },
  "gpu": {
    "framework": "Vulkan"
  },
  "supported_model_formats": [
    "gguf"
  ],
  "manifest_version": "4",
  "extension_type": "engine",
  "vendor_lib_package_names": [
    "win-llama-vulkan-vendor-v3"
  ],
  "minimum_lmstudio_version": "0.4.0+15",
  "minimum_llmster_version": "0.0.1+9",
  "engine_protocol_server": {
    "runtime_kind": "llama-server",
    "executable_relative_path": "llama-server.exe"
  },
  "name": "llama.cpp-win-x86_64-prism-vulkan"
}
'@
        $displayJson = @'
[["en",{"langKey":"en","displayName":"Prism ML Vulkan llama.cpp (Windows - Universal / AMD Fallback)","description":"Vulkan accelerated llama.cpp engine with native Prism ML PQ2_0 ternary model support for all GPUs including AMD Radeon","releaseNotes":[{"version":"2.64.0","releaseNotes":"- Universal GPU acceleration via Vulkan (AMD, Intel, Nvidia)\n- Zero driver configuration required\n- Accelerated PrismML Bonsai ternary model inference (*-PQ2_0.gguf, *-Q2_0_g64.gguf)\n"}]}]]
'@
        $artifactsJson = @'
{
  "schema_version": 1,
  "runtime_kind": "llama-server",
  "executable_relative_path": "llama-server.exe",
  "files": [
    { "relative_path": "ggml-base.dll", "executable": false },
    { "relative_path": "ggml-cpu.dll", "executable": false },
    { "relative_path": "ggml-vulkan.dll", "executable": false },
    { "relative_path": "llama-common.dll", "executable": false },
    { "relative_path": "llama-server-impl.dll", "executable": false },
    { "relative_path": "llama-server.exe", "executable": true },
    { "relative_path": "llama.dll", "executable": false },
    { "relative_path": "mtmd.dll", "executable": false }
  ]
}
'@
    }
    
    if ($buildInfo.Suffix) {
        $manifestJson = $manifestJson.Replace('"llama.cpp-win-x86_64-prism-rocm-rx9070"', "`"$script:PrismEngineRocm`"").Replace('"llama.cpp-win-x86_64-prism-vulkan"', "`"$script:PrismEngineVulkan`"")
        $displayJson = $displayJson.Replace('"displayName":"Prism ML ', "`"displayName`":`"Prism ML $PrismBuild ")
    }

    [System.IO.File]::WriteAllText((Join-Path $TargetDir "backend-manifest.json"), $manifestJson)
    [System.IO.File]::WriteAllText((Join-Path $TargetDir "display-data.json"), $displayJson)
    [System.IO.File]::WriteAllText((Join-Path $TargetDir "engine-protocol-server-artifacts.json"), $artifactsJson)
}

function Copy-PrismDirectory {
    param([string]$Source, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    & robocopy $Source $Destination /E /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "Robocopy failed with exit code $LASTEXITCODE" }
}

function Complete-PrismStage {
    param([string]$Stage, [string]$Destination, [string]$Kind)
    $missing = @(Get-PrismMissingFiles -Directory $Stage -Kind $Kind)
    if ($missing.Count -gt 0) {
        throw "Staged install is incomplete. Missing: $($missing -join ', '). The existing installation was not replaced."
    }
    $version = Test-PrismServerVersion -ServerPath (Join-Path $Stage "llama-server.exe")
    Write-Host "     Files installed in staging: yes" -ForegroundColor Green
    if (-not $version.ServerStarted -or $version.ExitCode -ne 0) {
        Write-Host "     Server start: failed (exit $($version.ExitCode))" -ForegroundColor Red
        if ($version.Output) { Write-Host "     $([string]$version.Output)" -ForegroundColor Red }
        throw "llama-server.exe --version failed. This does not change the previous installation. Model inference was not tested."
    }
    Write-Host "     Server start: llama-server.exe --version exited 0." -ForegroundColor Green
    Write-Host "     $($version.Output)" -ForegroundColor Gray
    Write-Host "     Model inference tested: no. --version does not load a GGUF model." -ForegroundColor Gray

    $stagedManifest = Get-Content -LiteralPath (Join-Path $Stage "backend-manifest.json") -Raw | ConvertFrom-Json
    $help = Test-PrismServerVersion -ServerPath (Join-Path $Stage "llama-server.exe") -Argument "--help"
    $contract = Test-PrismLazyModeContract -ManifestVersion $stagedManifest.version -HelpText ([string]$help.Output)
    if (-not $contract.Compatible) {
        $script:LazyModeIncompatibleKinds += $Kind
        Write-Host "     [!] LM Studio 0.4.28 passes --lazy-mode to manifest version $($stagedManifest.version), and this server rejects it. LLM models will not load there. Use -PrismBuild b12128." -ForegroundColor Yellow
    }

    $movedAside = $null
    if (Test-Path -LiteralPath $Destination) {
        $original = Get-PrismOriginalBackupPath -Path $Destination
        if (-not (Test-Path -LiteralPath $original)) {
            $movedAside = $original
        } else {
            $movedAside = "$Destination.bak-prism-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
        }
        Move-Item -LiteralPath $Destination -Destination $movedAside
    }
    try {
        Move-Item -LiteralPath $Stage -Destination $Destination
    } catch {
        if ($movedAside -and -not (Test-Path -LiteralPath $Destination) -and (Test-Path -LiteralPath $movedAside)) {
            Move-Item -LiteralPath $movedAside -Destination $Destination
        }
        throw
    }
}

# 3. Installation function
function Install-Backend {
    param(
        [string]$TargetName,
        [string]$ZipUrl,
        [string]$DisplayName,
        [string]$Kind,
        [string]$Sha256,
        [string]$RuntimeZipUrl,
        [string]$RuntimeSha256
    )
    
    $dest = Join-Path $lmStudioBackendsPath $TargetName
    Write-Host "`n  -> Installing $DisplayName..." -ForegroundColor Cyan
    Write-Host "     Destination: $dest" -ForegroundColor Gray
    
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $localSource = Join-Path $scriptDir $TargetName
    $marker = if ($Kind -eq "rocm") { "ggml-hip.dll" } elseif ($Kind -eq "cuda") { "ggml-cuda.dll" } else { "ggml-vulkan.dll" }
    $destHasServer = Test-Path (Join-Path $dest "llama-server.exe")
    $localHasServer = Test-Path (Join-Path $localSource "llama-server.exe")

    $sourceNewer = $false
    if ($localHasServer -and $destHasServer) {
        foreach ($rel in @("llama-server.exe", $marker)) {
            $srcFile = Join-Path $localSource $rel
            $dstFile = Join-Path $dest $rel
            if (-not (Test-Path $srcFile)) { continue }
            if (-not (Test-Path $dstFile)) { $sourceNewer = $true; break }
            $srcItem = Get-Item -LiteralPath $srcFile
            $dstItem = Get-Item -LiteralPath $dstFile
            if ($srcItem.Length -ne $dstItem.Length -or $srcItem.LastWriteTimeUtc -gt $dstItem.LastWriteTimeUtc) {
                $sourceNewer = $true
                break
            }
        }
    }

    $copyLocal = $localHasServer -and (-not $destHasServer -or $sourceNewer -or ($Force -and $destHasServer))
    # Same volume as the backends, so the final move is a rename. LM Studio does not scan this parent.
    $stage = Join-Path (Split-Path -Parent $lmStudioBackendsPath) (".prism-stage-" + [guid]::NewGuid().ToString("n"))

    try {
    if ($destHasServer -and -not $copyLocal) {
        Write-Host "     [Fast Path] Binaries already installed. Refreshing manifests in a staged copy..." -ForegroundColor Green
        Copy-PrismDirectory -Source $dest -Destination $stage
        Write-BackendManifests -TargetDir $stage -Kind $Kind
        Get-LmStudioAdapterFiles -DestinationDir $stage -Kind $Kind
        Complete-PrismStage -Stage $stage -Destination $dest -Kind $Kind
    } elseif ($copyLocal) {
        Write-Host "     [Fast Path] Staging local repository files..." -ForegroundColor Green
        Copy-PrismDirectory -Source $localSource -Destination $stage
        Write-BackendManifests -TargetDir $stage -Kind $Kind
        Get-LmStudioAdapterFiles -DestinationDir $stage -Kind $Kind
        Complete-PrismStage -Stage $stage -Destination $dest -Kind $Kind
    } else {
        # Standalone / Remote Path: Download from GitHub Release directly
        Write-Host "     [Standalone Path] Downloading precompiled release from GitHub CDN..." -ForegroundColor Yellow
        $tempZip = Join-Path $env:TEMP "$TargetName.zip"
        
        try {
            Download-FileWithProgress -Url $ZipUrl -OutputFile $tempZip -Desc $DisplayName
            $zipInfo = Get-Item -LiteralPath $tempZip
            if ($zipInfo.Length -lt 5MB) {
                throw "Downloaded archive is only $($zipInfo.Length) bytes. Refusing to extract '$ZipUrl'."
            }
            
            if ($Sha256) {
                if (-not (Test-PrismFileHash -Path $tempZip -ExpectedSha256 $Sha256)) {
                    throw "SHA-256 of '$ZipUrl' does not match the pinned value. Refusing to extract it."
                }
                Write-Host "     SHA-256 matches the pinned release digest." -ForegroundColor Green
            } else {
                Write-Host "     No published SHA-256 is pinned for this PrismML archive. Size is only a sanity check, not an integrity proof." -ForegroundColor Yellow
            }
            Write-Host "     Extracting archive to a temporary directory..." -ForegroundColor Cyan
            New-Item -ItemType Directory -Path $stage -Force | Out-Null
            
            $tarPath = Get-Command "tar.exe" -ErrorAction SilentlyContinue
            if ($tarPath) {
                & tar.exe -xf "$tempZip" -C "$stage"
                if ($LASTEXITCODE -ne 0) { throw "tar.exe failed with exit code $LASTEXITCODE" }
            } else {
                Expand-Archive -Path $tempZip -DestinationPath $stage -Force
            }
            
            $serverAfterExtract = Join-Path $stage "llama-server.exe"
            if (-not (Test-Path $serverAfterExtract)) {
                $nested = Get-ChildItem -LiteralPath $stage -Recurse -Filter "llama-server.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($nested) {
                    $nestedRoot = $nested.Directory.FullName
                    Write-Host "     Moving extracted files up from $($nested.Directory.Name)..." -ForegroundColor Gray
                    Get-ChildItem -LiteralPath $nestedRoot -Force | ForEach-Object {
                        Move-Item -LiteralPath $_.FullName -Destination $stage -Force
                    }
                    if ($nestedRoot -ne $stage) {
                        Remove-Item -LiteralPath $nestedRoot -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            if (-not (Test-Path (Join-Path $stage "llama-server.exe"))) {
                throw "Archive did not contain llama-server.exe after extract."
            }

            # Keep a dispatched ggml-cpu.dll when the package already has one.
            $cpuDll = Join-Path $stage "ggml-cpu.dll"
            $cpuFallback = Join-Path $stage "ggml-cpu-x64.dll"
            if ((Test-Path $cpuFallback) -and -not (Test-Path $cpuDll)) {
                Copy-Item $cpuFallback $cpuDll
                Write-Host "     Added ggml-cpu.dll from ggml-cpu-x64.dll because it was missing." -ForegroundColor Gray
            }
            
            if ($RuntimeZipUrl) {
                $tempRuntimeZip = Join-Path $env:TEMP "$TargetName-runtime.zip"
                try {
                    Download-FileWithProgress -Url $RuntimeZipUrl -OutputFile $tempRuntimeZip -Desc "CUDA runtime libraries"
                    if (-not (Test-PrismFileHash -Path $tempRuntimeZip -ExpectedSha256 $RuntimeSha256)) {
                        throw "SHA-256 of '$RuntimeZipUrl' does not match the pinned value. Refusing to extract it."
                    }
                    Write-Host "     SHA-256 matches the pinned release digest." -ForegroundColor Green
                    Expand-Archive -LiteralPath $tempRuntimeZip -DestinationPath $stage -Force
                } finally {
                    if (Test-Path -LiteralPath $tempRuntimeZip) { Remove-Item -LiteralPath $tempRuntimeZip -Force -ErrorAction SilentlyContinue }
                }
            }

            # Write Manifests directly
            Write-BackendManifests -TargetDir $stage -Kind $Kind
            Get-LmStudioAdapterFiles -DestinationDir $stage -Kind $Kind
            Complete-PrismStage -Stage $stage -Destination $dest -Kind $Kind
        } finally {
            if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
        }
    }
    return $true
    } catch {
        Write-Host "     [ERROR] $($_.Exception.Message)" -ForegroundColor Red
        return $false
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host "`n[3/4] Installing Backends..." -ForegroundColor Yellow

$installFailed = $false
$script:ConfigFailed = $false
$script:LazyModeIncompatibleKinds = @()
$installedHip = $false
$installedVulkan = $false

if ($installBackend -eq "all" -or $installBackend -eq "rocm") {
    $installedHip = [bool](Install-Backend -TargetName $HipDirName `
        -ZipUrl $HipZipUrl `
        -DisplayName "PrismML AMD ROCm/HIP (Radeon RX 9070 XT / RDNA 4)" `
        -Kind "rocm" `
        -Sha256 $buildInfo.HipSha256)
    if (-not $installedHip) { $installFailed = $true }
}

if ($installBackend -eq "all" -or $installBackend -eq "vulkan") {
    $installedVulkan = [bool](Install-Backend -TargetName $VulkanDirName `
        -ZipUrl $VulkanZipUrl `
        -DisplayName "PrismML Vulkan (Universal Fallback)" `
        -Kind "vulkan" `
        -Sha256 $buildInfo.VulkanSha256)
    if (-not $installedVulkan) { $installFailed = $true }
}

$installedCuda = $false
if ($installCuda) {
    $installedCuda = [bool](Install-Backend -TargetName $script:PrismCuda.DirName `
        -ZipUrl $script:PrismCuda.ZipUrl `
        -DisplayName "PrismML NVIDIA CUDA 13.3" `
        -Kind "cuda" `
        -Sha256 $script:PrismCuda.Sha256 `
        -RuntimeZipUrl $script:PrismCuda.RuntimeZipUrl `
        -RuntimeSha256 $script:PrismCuda.RuntimeSha256)
    if (-not $installedCuda) { $installFailed = $true }
}

$selectedEngine = if ($installBackend -eq "cuda") {
    $script:PrismEngineCuda
} elseif ($installedHip -or $installBackend -eq "rocm") {
    $script:PrismEngineRocm
} else {
    $script:PrismEngineVulkan
}
$selectedKind = if ($selectedEngine -eq $script:PrismEngineCuda) { "cuda" } elseif ($selectedEngine -eq $script:PrismEngineRocm) { "rocm" } else { "vulkan" }
$selectDefault = $SetDefaultRuntime -and (Test-PrismDefaultRuntimeAllowed -Kind $selectedKind -LazyModeIncompatibleKinds $script:LazyModeIncompatibleKinds -Force:$Force)
if ($SetDefaultRuntime -and -not $selectDefault) {
    Write-Host "  [!] $selectedEngine rejects --lazy-mode, so LM Studio 0.4.28 cannot load LLM models with it. It was not selected." -ForegroundColor Yellow
    Write-Host "      Use -PrismBuild b12128, or pass -Force to select it anyway." -ForegroundColor Yellow
}

# 4. Configure LM Studio Engine Index and Runtime Preferences
Write-Host "`n[4/4] Configuring LM Studio Engine Index & Preferences..." -ForegroundColor Yellow

# Helper to inject compatible entries into internal-engine-index.json
$indexFiles = @(
    (Join-Path $env:USERPROFILE ".lmstudio\.internal\internal-engine-index.json"),
    (Join-Path $env:USERPROFILE ".lmstudio\apps\bionic\.internal\internal-engine-index.json")
)

$prefFiles = @(
    (Join-Path $env:USERPROFILE ".lmstudio\.internal\backend-preferences-v1.json"),
    (Join-Path $env:USERPROFILE ".lmstudio\.internal\backend-preferences-v2.json"),
    (Join-Path $env:USERPROFILE ".lmstudio\apps\bionic\.internal\backend-preferences-v1.json"),
    (Join-Path $env:USERPROFILE ".lmstudio\apps\bionic\.internal\backend-preferences-v2.json")
)

$lmStudioRunning = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^LM Studio$|^LM-Studio$|^lms$' })
$skipProfileWrites = ($lmStudioRunning.Count -gt 0) -and (-not $Force)
if ($skipProfileWrites) {
    Write-Host "  [!] LM Studio is running. Skipping preference and engine-index writes." -ForegroundColor Yellow
    Write-Host "      Close LM Studio and rerun, or pass -Force to write while it is open." -ForegroundColor Yellow
}

function Set-PrismGgufPreference {
    param([string]$Path, [string]$EngineName, [string]$Version)
    $parent = Split-Path $Path -Parent
    if (-not (Test-Path $parent)) { return }
    $existingJson = $null
    if (Test-Path -LiteralPath $Path) {
        $existingJson = Get-Content -LiteralPath $Path -Raw
    }
    try {
        $merged = if ((Split-Path -Leaf $Path) -eq "backend-preferences-v2.json") {
            Merge-PrismGgufPreferenceV2 -ExistingJson $existingJson -EngineName $EngineName -Version $Version
        } else {
            Merge-PrismGgufPreference -ExistingJson $existingJson -EngineName $EngineName -Version $Version
        }
    } catch {
        Write-Host "  [!] $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "      Left unchanged: $Path" -ForegroundColor Yellow
        $script:ConfigFailed = $true
        return
    }
    Write-PrismAtomicText -Path $Path -Text $merged.Json
    Write-Host "     [OK] Updated only the GGUF row in: $Path" -ForegroundColor Green
    Write-Host "          Original, if one existed, is kept once at $(Get-PrismOriginalBackupPath -Path $Path)" -ForegroundColor Gray
}

if ($selectDefault -and -not $skipProfileWrites -and -not $installFailed) {
    Write-Host "  -SetDefaultRuntime: the GGUF default runtime will be set to $selectedEngine." -ForegroundColor Yellow
    foreach ($pf in $prefFiles) {
        if ((Test-Path (Split-Path $pf -Parent)) -or (Test-Path $pf)) {
            Set-PrismGgufPreference -Path $pf -EngineName $selectedEngine -Version $(if ($selectedEngine -eq $script:PrismEngineCuda) { $script:PrismCudaManifestVersion } else { $script:PrismPackageVersion })
        }
    }
} elseif (-not $SetDefaultRuntime) {
    Write-Host "  GGUF default runtime was not changed. Pass -SetDefaultRuntime to select $selectedEngine." -ForegroundColor Gray
}

# Update internal engine index
foreach ($idx in $indexFiles) {
    if ($skipProfileWrites -or $installFailed) { break }
    if (Test-Path -LiteralPath $idx) {
        try {
            $raw = Get-Content -LiteralPath $idx -Raw -ErrorAction Stop
            if (-not $raw) { continue }
            $parsed = $raw | ConvertFrom-Json
            $template = $null
            if ($parsed.json) {
                $template = @($parsed.json) | Where-Object {
                    $_.manifest -and $_.launchInfo -and $_.dirPath
                } | Select-Object -First 1
            }
            if (-not $template) {
                Write-Host "  [!] Engine index has no usable template. Leaving file unchanged: $idx" -ForegroundColor Yellow
                $script:ConfigFailed = $true
                continue
            }

            $kinds = @()
            if ($installedVulkan) { $kinds += "vulkan" }
            if ($installedHip) { $kinds += "rocm" }
            if ($installedCuda) { $kinds += "cuda" }
            if ($kinds.Count -eq 0) { continue }
            $updated = Update-PrismEngineIndex -Index $parsed -Kinds $kinds `
                -RocmDir (Join-Path $lmStudioBackendsPath $HipDirName) `
                -VulkanDir (Join-Path $lmStudioBackendsPath $VulkanDirName) `
                -CudaDir (Join-Path $lmStudioBackendsPath $script:PrismCuda.DirName)
            Write-PrismAtomicText -Path $idx -Text (ConvertTo-PrismJson -Value $updated)
            Write-Host "     [OK] Registered $($kinds -join ', ') in: $idx" -ForegroundColor Green
            Write-Host "          'compatible' here means registered for LM Studio, not that inference was tested." -ForegroundColor Gray
            Write-Host "          Original index, if one existed, is kept once at $(Get-PrismOriginalBackupPath -Path $idx)" -ForegroundColor Gray
        } catch {
            Write-Host "  [!] Engine index was not modified: $idx" -ForegroundColor Yellow
            Write-Host "      $($_.Exception.Message)" -ForegroundColor Yellow
            $script:ConfigFailed = $true
        }
    }
}

# Verify with LM Studio CLI
if (Test-Path $lmsExePath) {
    if ($selectDefault -and -not $installFailed -and -not $skipProfileWrites) {
        Write-Host "`nSelecting $selectedEngine via LM Studio CLI because -SetDefaultRuntime was set..." -ForegroundColor Gray
        try {
            & $lmsExePath runtime select $selectedEngine
            if ($LASTEXITCODE -ne 0) { throw "lms runtime select exited with code $LASTEXITCODE" }
        } catch {
            Write-Host "  [!] $($_.Exception.Message)" -ForegroundColor Yellow
            $script:ConfigFailed = $true
        }
    }
    
    Write-Host "Verifying installed engines via 'lms runtime ls'..." -ForegroundColor Gray
    Write-Host "----------------------------------------------------------" -ForegroundColor DarkGray
    try {
        & $lmsExePath runtime ls
    } catch {
        Write-Host "     Note: CLI query skipped: $($_.Exception.Message)" -ForegroundColor Gray
    }
    Write-Host "----------------------------------------------------------" -ForegroundColor DarkGray
    
    Write-Host "Verifying hardware survey via 'lms runtime survey'..." -ForegroundColor Gray
    Write-Host "----------------------------------------------------------" -ForegroundColor DarkGray
    try {
        & $lmsExePath runtime survey
    } catch { }
    Write-Host "----------------------------------------------------------" -ForegroundColor DarkGray
} else {
    Write-Host "LM Studio CLI not found at default location. Manual check in GUI required." -ForegroundColor Gray
}

if ($installFailed -or $script:ConfigFailed) {
    Write-Host "`n==========================================================" -ForegroundColor Red
    Write-Host "              Installation finished with errors            " -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Red
    if ($installFailed) {
        Write-Host "A requested backend failed file validation or llama-server.exe --version. It was not selected as the default runtime." -ForegroundColor Red
    }
    if ($script:ConfigFailed) {
        Write-Host "The files are installed, but registering or selecting the runtime in LM Studio failed. See the messages above." -ForegroundColor Red
    }
    # 'exit' would close the user's PowerShell window when this runs through 'irm | iex'.
    if ($PSCommandPath) { exit 1 }
    throw "PrismML installation finished with errors."
}

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "                Installation Completed!                   " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Status in LM Studio:" -ForegroundColor Yellow
if ($installedHip) {
    Write-Host "   - PrismML ROCm/HIP (RX 9070 XT): installed" -ForegroundColor Green
}
if ($installedVulkan) {
    Write-Host "   - PrismML Vulkan (fallback): installed" -ForegroundColor Green
}
if ($installedCuda) {
    Write-Host "   - PrismML NVIDIA CUDA ($($script:PrismCuda.Tag)): installed" -ForegroundColor Green
}
if ($selectDefault -and -not $installFailed) {
    Write-Host "   - GGUF default requested: $selectedEngine" -ForegroundColor Green
} else {
    Write-Host "   - GGUF default runtime was not changed." -ForegroundColor Green
}
Write-Host ""
Write-Host "Next Steps for LM Studio:" -ForegroundColor Yellow
Write-Host "1. Restart LM Studio (close and open again)."
Write-Host "2. Confirm the PrismML runtime is selected for GGUF models."
Write-Host "3. Load your PrismML ternary model (*-PQ2_0.gguf or *-Q2_0_g64.gguf)."
Write-Host "4. Enjoy hardware-accelerated 1-bit / ternary inference!"
Write-Host ""
