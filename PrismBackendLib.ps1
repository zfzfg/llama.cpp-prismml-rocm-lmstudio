# Pure helpers for the PrismML LM Studio installer.
# Dot-source this file. It does not change the machine by itself.

$script:PrismEngineRocm = "llama.cpp-win-x86_64-prism-rocm-rx9070"
$script:PrismEngineVulkan = "llama.cpp-win-x86_64-prism-vulkan"
$script:PrismPackageVersion = "2.64.0"
# Adapter contract used by the tested RX 9070 XT LM Studio bridge.
# These are registration versions, not a measurement of the .node binaries.
$script:PrismAdapterEngineVersion = "0.1.2"
$script:PrismAdapterBindingVersion = "0.2.26"

$script:PrismRequiredRuntimeFiles = @{
    rocm   = @(
        "llama-server.exe", "llama-server-impl.dll", "llama.dll", "llama-common.dll",
        "ggml.dll", "ggml-base.dll", "ggml-hip.dll", "libhipblas.dll", "libhipblaslt.dll", "rocblas.dll", "mtmd.dll"
    )
    vulkan = @(
        "llama-server.exe", "llama-server-impl.dll", "llama.dll", "llama-common.dll",
        "ggml.dll", "ggml-base.dll", "ggml-vulkan.dll", "mtmd.dll"
    )
    cuda   = @(
        "llama-server.exe", "llama-server-impl.dll", "llama.dll", "llama-common.dll",
        "ggml.dll", "ggml-base.dll", "ggml-cuda.dll", "mtmd.dll",
        "cudart64_13.dll", "cublas64_13.dll", "cublasLt64_13.dll"
    )
}

$script:PrismRequiredAdapterFiles = @(
    "llm_engine_vulkan.node",
    "liblmstudio_bindings_vulkan.node"
)

# LM Studio 0.4.28 passes --lazy-mode to every llama.cpp LLM engine whose manifest
# version is at least this value (feature "llamaLazyMode"). Read from its main bundle.
$script:PrismLazyModeMinManifestVersion = "2.32.0"

$script:PrismBuilds = @{
    b10809 = @{
        Tag = "prism-b10809-b3ebc47"; EngineSuffix = ""
        HipSha256 = $null; VulkanSha256 = $null
    }
    b12128 = @{
        Tag = "prism-b12128-d7b2896"; EngineSuffix = "-b12128"
        HipSha256 = "6829fc192d2c77d11bbfbb02a198328d0026f25f0f8b60cf681eb348fae6e1ce"
        VulkanSha256 = "ec1479514a34272c815b3d194046d27003867aa9c95069d9cd3031b5c31e01ff"
    }
}

function Set-PrismBuild {
    <#
    Selects a PrismML build. A build with an EngineSuffix registers next to the
    existing engines and does not replace them.
    #>
    param([Parameter(Mandatory)][string]$Build)
    $info = $script:PrismBuilds[$Build]
    if (-not $info) { throw "Unknown PrismML build '$Build'." }
    $script:PrismEngineRocm = "llama.cpp-win-x86_64-prism-rocm-rx9070$($info.EngineSuffix)"
    $script:PrismEngineVulkan = "llama.cpp-win-x86_64-prism-vulkan$($info.EngineSuffix)"
    $version = $info.Tag -replace "^prism-", ""
    $releaseUrl = "https://github.com/PrismML-Eng/llama.cpp/releases/download/$($info.Tag)"
    [pscustomobject]@{
        Tag           = $info.Tag
        Suffix        = $info.EngineSuffix
        HipZipUrl     = "$releaseUrl/llama-prism-$version-bin-win-hip-radeon-x64.zip"
        VulkanZipUrl  = "$releaseUrl/llama-prism-$version-bin-win-vulkan-x64.zip"
        HipDirName    = "llama.cpp-prism-$version-bin-win-hip-radeon-x64-lm-studio"
        VulkanDirName = "llama.cpp-prism-$version-bin-win-vulkan-x64-lm-studio"
        HipSha256     = $info.HipSha256
        VulkanSha256  = $info.VulkanSha256
    }
}

function Test-PrismFileHash {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ieq $ExpectedSha256
}

function Get-PrismHelpFlags {
    param([AllowEmptyString()][string]$HelpText)
    @([regex]::Matches($HelpText, "(?<![\w-])--?[a-zA-Z][\w-]*") | ForEach-Object { $_.Value } | Sort-Object -Unique)
}

function Test-PrismFlagContract {
    <#
    Compares a real argument list from an LM Studio log with llama-server --help.
    A flag that is not in the help text is reported as unknown.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Arguments,
        [AllowEmptyString()][string]$HelpText
    )
    $known = Get-PrismHelpFlags -HelpText $HelpText
    $unknown = @($Arguments | Where-Object { $_ -match "^--?[a-zA-Z]" -and $known -cnotcontains $_ } | Sort-Object -Unique)
    [pscustomobject]@{ Compatible = ($unknown.Count -eq 0); UnknownFlags = $unknown }
}

function Test-PrismLazyModeContract {
    <#
    LM Studio derives --lazy-mode from the manifest version only. The server must
    accept the flag when the manifest version reaches the threshold.
    #>
    param(
        [Parameter(Mandatory)][string]$ManifestVersion,
        [AllowEmptyString()][string]$HelpText
    )
    $receivesFlag = [version]$ManifestVersion -ge [version]$script:PrismLazyModeMinManifestVersion
    $acceptsFlag = (Get-PrismHelpFlags -HelpText $HelpText) -ccontains "--lazy-mode"
    [pscustomobject]@{
        ReceivesFlag = $receivesFlag
        AcceptsFlag  = $acceptsFlag
        Compatible   = ((-not $receivesFlag) -or $acceptsFlag)
    }
}

# The CUDA package exists only for a build whose server accepts --lazy-mode.
$script:PrismEngineCuda = "llama.cpp-win-x86_64-prism-cuda13-b12128"
$script:PrismCudaManifestVersion = "2.67.0"
$script:PrismRequiredCudaAdapterFiles = @(
    "llm_engine_cuda12.node",
    "liblmstudio_bindings_cuda12.node"
)
$script:PrismCuda = [pscustomobject]@{
    Tag              = "prism-b12128-d7b2896"
    DirName          = "llama.cpp-prism-b12128-d7b2896-bin-win-cuda-13.3-x64-lm-studio"
    ZipUrl           = "https://github.com/PrismML-Eng/llama.cpp/releases/download/prism-b12128-d7b2896/llama-prism-b12128-d7b2896-bin-win-cuda-13.3-x64.zip"
    Sha256           = "86c6546685ffe2f0954bac062d0bdb347694a2b5eee6f5ddeb1bbfe82d2be1b6"
    RuntimeZipUrl    = "https://github.com/PrismML-Eng/llama.cpp/releases/download/prism-b12128-d7b2896/cudart-llama-bin-win-cuda-13.3-x64.zip"
    RuntimeSha256    = "1462a050eb4c684921ba51dcc4cc488a036674c3e73e9945ee705b854808d03e"
}

function Get-PrismRequiredAdapterFiles {
    param([Parameter(Mandatory)][string]$Kind)
    if ($Kind -eq "cuda") { return $script:PrismRequiredCudaAdapterFiles }
    return $script:PrismRequiredAdapterFiles
}

function Get-PrismCudaPackageJson {
    $manifest = [ordered]@{
        version = $script:PrismCudaManifestVersion
        domains = @("llm", "embedding")
        engine = "llama.cpp"
        extension_type = "engine"
        target_libraries = @(
            [ordered]@{ name = "llm_engine_cuda12.node"; type = "llm_engine"; version = $script:PrismAdapterEngineVersion },
            [ordered]@{ name = "liblmstudio_bindings_cuda12.node"; type = "liblmstudio"; version = $script:PrismAdapterBindingVersion }
        )
        platform = "win"
        cpu = [ordered]@{ architecture = "x86_64"; instruction_set_extensions = @("AVX2") }
        gpu = [ordered]@{
            make = "Nvidia"
            framework = "CUDA"
            targets = @("7.5", "8.0", "8.9", "9.0", "10.0", "12.0")
            minimum_driver_version = "12040"
        }
        supported_model_formats = @("gguf")
        manifest_version = "4"
        vendor_lib_package_names = @("win-llama-cuda12-vendor-v2")
        minimum_lmstudio_version = "0.4.0+15"
        minimum_llmster_version = "0.0.1+9"
        engine_protocol_server = [ordered]@{ runtime_kind = "llama-server"; executable_relative_path = "llama-server.exe" }
        name = $script:PrismEngineCuda
    }
    $display = ,@("en", [ordered]@{
        langKey = "en"
        displayName = "Prism ML b12128 CUDA 13.3 llama.cpp (Windows)"
        description = "Nvidia CUDA 13.3 accelerated llama.cpp engine with native Prism ML PQ2_0 ternary model support"
        releaseNotes = @([ordered]@{ version = $script:PrismCudaManifestVersion; releaseNotes = "- PrismML llama.cpp build b12128 (commit d7b2896)`n- Accepts the --lazy-mode flag passed by LM Studio 0.4.28`n" })
    })
    $files = @("ggml-base.dll", "ggml-cpu.dll", "ggml-cuda.dll", "ggml_llamacpp.dll", "llama-common.dll", "llama-server-impl.dll", "llama-server.exe", "llama.dll", "mtmd.dll")
    $artifacts = [ordered]@{
        schema_version = 1
        runtime_kind = "llama-server"
        executable_relative_path = "llama-server.exe"
        files = @($files | ForEach-Object { [ordered]@{ relative_path = $_; executable = ($_ -eq "llama-server.exe") } })
    }
    [pscustomobject]@{
        Manifest  = ($manifest | ConvertTo-Json -Depth 8)
        Display   = (ConvertTo-Json -InputObject $display -Depth 8 -Compress)
        Artifacts = ($artifacts | ConvertTo-Json -Depth 8)
    }
}

function Get-PrismManagedEngineNames {
    @($script:PrismEngineRocm, $script:PrismEngineVulkan, $script:PrismEngineCuda)
}

function ConvertTo-PrismJson {
    param($Value, [int]$Depth = 30)
    if ($Depth -lt 0) { return "null" }
    if ($null -eq $Value) { return "null" }
    if ($Value -is [string]) { return (ConvertTo-Json -InputObject $Value -Compress) }
    if ($Value -is [bool]) { if ($Value) { return "true" } else { return "false" } }
    if ($Value -is [ValueType]) { return (ConvertTo-Json -InputObject $Value -Compress) }
    if ($Value -is [pscustomobject]) {
        $parts = foreach ($prop in @($Value.PSObject.Properties | Where-Object { $_.MemberType -eq "NoteProperty" })) {
            $name = ConvertTo-Json -InputObject ([string]$prop.Name) -Compress
            $inner = ConvertTo-PrismJson -Value $prop.Value -Depth ($Depth - 1)
            "${name}:${inner}"
        }
        return "{" + (@($parts) -join ",") + "}"
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = foreach ($key in @($Value.Keys)) {
            $name = ConvertTo-Json -InputObject ([string]$key) -Compress
            $inner = ConvertTo-PrismJson -Value $Value[$key] -Depth ($Depth - 1)
            "${name}:${inner}"
        }
        return "{" + ($parts -join ",") + "}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = foreach ($item in @($Value)) {
            ConvertTo-PrismJson -Value $item -Depth ($Depth - 1)
        }
        return "[" + (@($parts) -join ",") + "]"
    }
    return "null"
}

function ConvertTo-PrismJsonArray {
    param([AllowEmptyCollection()][object[]]$Items)
    ConvertTo-PrismJson -Value @($Items)
}

function Merge-PrismGgufPreference {
    param(
        [AllowNull()][string]$ExistingJson,
        [Parameter(Mandatory)][string]$EngineName,
        [string]$Version = $script:PrismPackageVersion
    )
    $rows = @()
    if (-not [string]::IsNullOrWhiteSpace($ExistingJson)) {
        try {
            $parsed = $ExistingJson | ConvertFrom-Json
        } catch {
            throw "Preference JSON is invalid and was not modified: $($_.Exception.Message)"
        }
        if ($null -ne $parsed) { $rows = @($parsed) }
    }
    $kept = @($rows | Where-Object { $_.model_format -ne "gguf" })
    $row = [pscustomobject]@{
        model_format = "gguf"
        name         = $EngineName
        version      = $Version
    }
    $merged = @($kept + $row)
    [pscustomobject]@{
        Rows = $merged
        Json = (ConvertTo-PrismJsonArray -Items $merged)
    }
}

function Merge-PrismGgufPreferenceV2 {
    # backend-preferences-v2.json holds formatDefaults and versions, not rows.
    param(
        [AllowNull()][string]$ExistingJson,
        [Parameter(Mandatory)][string]$EngineName,
        [Parameter(Mandatory)][string]$Version
    )
    $parsed = $null
    if (-not [string]::IsNullOrWhiteSpace($ExistingJson)) {
        try {
            $parsed = $ExistingJson | ConvertFrom-Json
        } catch {
            throw "Preference JSON is invalid and was not modified: $($_.Exception.Message)"
        }
    }
    if ($null -eq $parsed -or $parsed -is [array] -or -not $parsed.PSObject.Properties["formatDefaults"]) {
        $parsed = [pscustomobject]@{ formatDefaults = [pscustomobject]@{}; versions = [pscustomobject]@{} }
    }
    if (-not $parsed.PSObject.Properties["versions"]) {
        $parsed | Add-Member -NotePropertyName versions -NotePropertyValue ([pscustomobject]@{})
    }
    $parsed.formatDefaults | Add-Member -NotePropertyName gguf -NotePropertyValue $EngineName -Force
    $parsed.versions | Add-Member -NotePropertyName $EngineName -NotePropertyValue $Version -Force
    [pscustomobject]@{ Json = (ConvertTo-PrismJson -Value $parsed) }
}

function Get-PrismMissingFiles {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Kind
    )
    $required = @($script:PrismRequiredRuntimeFiles[$Kind] + (Get-PrismRequiredAdapterFiles -Kind $Kind))
    $missing = foreach ($rel in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $Directory $rel))) { $rel }
    }
    @($missing)
}

function Test-PrismServerVersion {
    <#
    .OUTPUTS
    FilesPresent, ServerStarted, ExitCode, Output, InferenceTested
    InferenceTested is always $false. --version does not load a model.
    #>
    param(
        [Parameter(Mandatory)][string]$ServerPath,
        [string]$Argument = "--version"
    )
    $result = [ordered]@{
        FilesPresent    = (Test-Path -LiteralPath $ServerPath)
        ServerStarted   = $false
        ExitCode        = $null
        Output          = ""
        InferenceTested = $false
    }
    if (-not $result.FilesPresent) {
        return [pscustomobject]$result
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ServerPath
    $psi.Arguments = $Argument
    $psi.WorkingDirectory = Split-Path -Parent $ServerPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        $result.Output = $_.Exception.Message
        return [pscustomobject]$result
    }
    $result.ServerStarted = $true
    # Read both streams before waiting. Long --help output would otherwise fill the pipe.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(20000)) {
        try { $proc.Kill() } catch {}
        $result.ExitCode = -1
        $result.Output = "llama-server.exe $Argument did not exit within 20 seconds."
        return [pscustomobject]$result
    }
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $result.ExitCode = $proc.ExitCode
    $result.Output = (($stdout + "`n" + $stderr).Trim())
    return [pscustomobject]$result
}

function Get-PrismIndexEntryMeta {
    # The index is superjson encoded. meta.values keys start with the entry position,
    # such as "3.displayData", and LM Studio rejects the file when they do not line up.
    param($Index, [int]$Position)
    $found = [ordered]@{}
    if ($Index.meta -and $Index.meta.values) {
        foreach ($prop in $Index.meta.values.PSObject.Properties) {
            if ($prop.Name.StartsWith("$Position.")) {
                $found[$prop.Name.Substring("$Position.".Length)] = $prop.Value
            }
        }
    }
    return $found
}

function Update-PrismEngineIndex {
    <#
    Replaces only the managed identities requested in Kinds.
    Other entries, including the other managed identity and any other name
    that happens to contain "prism", stay as they are.
    backendCompatibility.status "compatible" is a registration flag so LM Studio
    lists the engine. It is not a hardware or inference test.
    #>
    param(
        [Parameter(Mandatory)]$Index,
        [Parameter(Mandatory)][string[]]$Kinds,
        [Parameter(Mandatory)][string]$RocmDir,
        [Parameter(Mandatory)][string]$VulkanDir,
        [string]$CudaDir
    )
    $entries = @()
    if ($Index.json) { $entries = @($Index.json) }
    $replace = @{}
    if ($Kinds -contains "rocm") { $replace[$script:PrismEngineRocm] = "rocm" }
    if ($Kinds -contains "vulkan") { $replace[$script:PrismEngineVulkan] = "vulkan" }
    if ($Kinds -contains "cuda") { $replace[$script:PrismEngineCuda] = "cuda" }

    $kept = @()
    $keptMeta = @()
    for ($position = 0; $position -lt $entries.Count; $position++) {
        $entry = $entries[$position]
        if ($replace.ContainsKey([string]$entry.manifest.name)) { continue }
        $kept += $entry
        $keptMeta += ,(Get-PrismIndexEntryMeta -Index $Index -Position $position)
    }

    foreach ($name in $replace.Keys) {
        $kind = $replace[$name]
        $dir = if ($kind -eq "rocm") { $RocmDir } elseif ($kind -eq "cuda") { $CudaDir } else { $VulkanDir }
        $framework = if ($kind -eq "cuda") { "CUDA" } else { "Vulkan" }
        $adapterSuffix = if ($kind -eq "cuda") { "cuda12" } else { "vulkan" }
        $existing = @($entries | Where-Object { $_.manifest.name -eq $name } | Select-Object -First 1)
        $template = $null
        $existingHasMeta = $existing.Count -gt 0 -and $existing[0] -and ((-not ($Index.meta -and $Index.meta.values)) -or (Get-PrismIndexEntryMeta -Index $Index -Position ([array]::IndexOf($entries, $existing[0]))).Count -gt 0)
        if ($existingHasMeta) {
            $template = $existing[0]
        } else {
            $template = @($entries | Where-Object {
                $_.manifest -and $_.launchInfo -and $_.dirPath -and
                ($_.manifest.gpu.framework -eq $framework -or ($kind -ne "cuda" -and $_.manifest.name -eq $script:PrismEngineVulkan))
            } | Select-Object -First 1)
            if (-not $template) {
                $template = @($entries | Where-Object { $_.manifest -and $_.launchInfo -and $_.dirPath } | Select-Object -First 1)
            }
        }
        if (-not $template) {
            throw "Engine index has no entry with manifest, launchInfo, and dirPath. It was not modified."
        }
        $template = @($template)[0]
        $keptMeta += ,(Get-PrismIndexEntryMeta -Index $Index -Position ([array]::IndexOf($entries, $template)))
        $clone = $template | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $clone.dirPath = $dir
        $clone.libLmStudioPath = [System.IO.Path]::Combine($dir, "liblmstudio_bindings_$adapterSuffix.node")
        if (-not $clone.launchInfo) { $clone | Add-Member -NotePropertyName launchInfo -NotePropertyValue ([pscustomobject]@{}) }
        $clone.launchInfo.engineLibPath = [System.IO.Path]::Combine($dir, "llm_engine_$adapterSuffix.node")
        if (-not $clone.manifest) { $clone | Add-Member -NotePropertyName manifest -NotePropertyValue ([pscustomobject]@{}) }
        $clone.manifest.name = $name
        if ($kind -eq "cuda" -and $clone.displayData) {
            $displayInfo = @($clone.displayData)[0][1]
            $displayInfo.displayName = "Prism ML b12128 CUDA 13.3 llama.cpp (Windows)"
            $displayInfo.releaseNotes = @()
        }
        $clone.manifest.version = if ($kind -eq "cuda") { $script:PrismCudaManifestVersion } else { $script:PrismPackageVersion }
        if ($clone.manifest.gpu) { $clone.manifest.gpu.framework = $framework }
        if (-not $clone.backendCompatibility) {
            $clone | Add-Member -NotePropertyName backendCompatibility -NotePropertyValue ([pscustomobject]@{})
        }
        $clone.backendCompatibility | Add-Member -NotePropertyName status -NotePropertyValue "compatible" -Force
        $clone.backendCompatibility | Add-Member -NotePropertyName message -NotePropertyValue "Registered by the PrismML LM Studio installer. This flag is not a runtime or model-inference test." -Force
        $kept += $clone
    }
    $Index.json = @($kept)
    if ($Index.meta -and $Index.meta.values) {
        $values = [ordered]@{}
        foreach ($prop in $Index.meta.values.PSObject.Properties) {
            if ($prop.Name -notmatch "^\d+\.") { $values[$prop.Name] = $prop.Value }
        }
        for ($position = 0; $position -lt $keptMeta.Count; $position++) {
            foreach ($key in $keptMeta[$position].Keys) {
                $values["$position.$key"] = $keptMeta[$position][$key]
            }
        }
        $Index.meta.values = [pscustomobject]$values
    }
    return $Index
}

function Get-PrismOriginalBackupPath {
    param([Parameter(Mandatory)][string]$Path)
    return "$Path.bak-prism-original"
}

function Save-PrismOriginalOnce {
    param([Parameter(Mandatory)][string]$Path)
    $backup = Get-PrismOriginalBackupPath -Path $Path
    if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $Path -Destination $backup -Force
    }
    return $backup
}

function Write-PrismAtomicText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Path) {
        Save-PrismOriginalOnce -Path $Path | Out-Null
    }
    $tmp = Join-Path $dir (".{0}.{1}.tmp" -f (Split-Path -Leaf $Path), [guid]::NewGuid().ToString("n"))
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, $Text, $utf8)
    if (Test-Path -LiteralPath $Path) {
        [System.IO.File]::Delete($Path)
    }
    [System.IO.File]::Move($tmp, $Path)
}
