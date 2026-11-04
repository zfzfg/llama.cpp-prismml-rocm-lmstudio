$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\PrismBackendLib.ps1")

$failures = New-Object System.Collections.Generic.List[string]
function Assert-True($Condition, [string]$Name) {
    if (-not $Condition) { $script:failures.Add($Name); Write-Host "FAIL $Name" -ForegroundColor Red }
    else { Write-Host "PASS $Name" -ForegroundColor Green }
}

Write-Host "PowerShell $($PSVersionTable.PSVersion) on $($PSVersionTable.PSEdition)"

$missing = Merge-PrismGgufPreference -ExistingJson $null -EngineName $script:PrismEngineRocm
$missingParsed = $missing.Json | ConvertFrom-Json
Assert-True (@($missingParsed).Count -eq 1 -and $missingParsed[0].model_format -eq "gguf") "missing preferences become one GGUF object inside an array"
Assert-True ($missing.Json.TrimStart().StartsWith("[")) "missing preferences serialize as an array"
Assert-True (-not $missing.Json.TrimStart().StartsWith("[[")) "single preference is not a nested array"

$one = Merge-PrismGgufPreference -ExistingJson '[{"model_format":"gguf","name":"old","version":"1.0.0","extra":true}]' -EngineName $script:PrismEngineVulkan
$oneParsed = @($one.Json | ConvertFrom-Json)
Assert-True ($oneParsed.Count -eq 1 -and $oneParsed[0].name -eq $script:PrismEngineVulkan) "one existing GGUF row is replaced"
Assert-True ($null -eq $oneParsed[0].extra) "replaced GGUF row does not keep the old engine identity"

$manyJson = '[{"model_format":"mlx","name":"keep-mlx","version":"9.0.0"},{"model_format":"gguf","name":"old-prism","version":"1.0.0"},{"model_format":"onnx","name":"keep-onnx","version":"3.0.0"}]'
$many = Merge-PrismGgufPreference -ExistingJson $manyJson -EngineName $script:PrismEngineRocm
$manyParsed = @($many.Json | ConvertFrom-Json)
Assert-True ($manyParsed.Count -eq 3) "non-GGUF rows are kept and GGUF stays a single row"
Assert-True (($manyParsed | Where-Object { $_.model_format -eq "mlx" }).name -eq "keep-mlx") "mlx row is unchanged"
Assert-True (($manyParsed | Where-Object { $_.model_format -eq "onnx" }).version -eq "3.0.0") "onnx row is unchanged"
Assert-True (($manyParsed | Where-Object { $_.model_format -eq "gguf" }).name -eq $script:PrismEngineRocm) "existing prism GGUF row is replaced"

$invalidThrew = $false
try { Merge-PrismGgufPreference -ExistingJson "{not json" -EngineName $script:PrismEngineRocm | Out-Null }
catch { $invalidThrew = $true }
Assert-True $invalidThrew "invalid preference JSON is rejected"

$index = [pscustomobject]@{
    json = @(
        [pscustomobject]@{
            dirPath = "C:\other"
            libLmStudioPath = "C:\other\bind.node"
            unknownField = "keep-me"
            launchInfo = [pscustomobject]@{ engineLibPath = "C:\other\engine.node"; extra = 7 }
            manifest = [pscustomobject]@{ name = "llama.cpp-win-x86_64-cuda"; version = "1.2.3"; gpu = [pscustomobject]@{ framework = "CUDA" } }
            backendCompatibility = [pscustomobject]@{ status = "compatible"; message = "stock" }
        },
        [pscustomobject]@{
            dirPath = "C:\vk"
            libLmStudioPath = "C:\vk\liblmstudio_bindings_vulkan.node"
            launchInfo = [pscustomobject]@{ engineLibPath = "C:\vk\llm_engine_vulkan.node" }
            manifest = [pscustomobject]@{ name = $script:PrismEngineVulkan; version = "2.64.0"; gpu = [pscustomobject]@{ framework = "Vulkan" }; custom = "vulkan-field" }
            backendCompatibility = [pscustomobject]@{ status = "compatible"; message = "old vulkan" }
        },
        [pscustomobject]@{
            dirPath = "C:\other-prism"
            libLmStudioPath = "C:\other-prism\bind.node"
            launchInfo = [pscustomobject]@{ engineLibPath = "C:\other-prism\engine.node" }
            manifest = [pscustomobject]@{ name = "some-other-prism-build"; version = "0.1.0" }
            backendCompatibility = [pscustomobject]@{ status = "unknown" }
        }
    )
}
$updated = Update-PrismEngineIndex -Index $index -Kinds @("rocm") -RocmDir "D:\rocm" -VulkanDir "D:\vulkan"
$names = @($updated.json | ForEach-Object { $_.manifest.name })
Assert-True ($names -contains $script:PrismEngineVulkan) "rocm-only update keeps the managed Vulkan entry"
Assert-True ($names -contains "some-other-prism-build") "rocm-only update keeps an unrelated prism name"
Assert-True ($names -contains "llama.cpp-win-x86_64-cuda") "rocm-only update keeps a non-prism backend"
Assert-True (@($names | Where-Object { $_ -eq $script:PrismEngineRocm }).Count -eq 1) "rocm identity is registered once"
$vk = @($updated.json | Where-Object { $_.manifest.name -eq $script:PrismEngineVulkan })[0]
Assert-True ($vk.dirPath -eq "C:\vk" -and $vk.manifest.custom -eq "vulkan-field") "existing Vulkan entry is not rebuilt from another backend"
$cuda = @($updated.json | Where-Object { $_.manifest.name -eq "llama.cpp-win-x86_64-cuda" })[0]
Assert-True ($cuda.unknownField -eq "keep-me" -and $cuda.manifest.gpu.framework -eq "CUDA") "unrelated backend fields stay unchanged"
$rocm = @($updated.json | Where-Object { $_.manifest.name -eq $script:PrismEngineRocm })[0]
Assert-True ($rocm.dirPath -eq "D:\rocm") "new rocm entry points at the rocm directory"
Assert-True ($rocm.manifest.gpu.framework -eq "Vulkan") "registered rocm manifest uses the Vulkan bridge framework"
Assert-True ($rocm.launchInfo.engineLibPath -like "*llm_engine_vulkan.node") "registered rocm entry does not keep the template engine path"
Assert-True ($rocm.backendCompatibility.message -like "*not a runtime*") "compatible status is documented as registration"

$temp = Join-Path $env:TEMP ("prism-backup-test-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $temp | Out-Null
$file = Join-Path $temp "prefs.json"
[System.IO.File]::WriteAllText($file, "original")
$first = Save-PrismOriginalOnce -Path $file
Write-PrismAtomicText -Path $file -Text "second"
Write-PrismAtomicText -Path $file -Text "third"
Assert-True ((Get-Content -LiteralPath $first -Raw) -eq "original") "the original backup is not overwritten"
Assert-True ((Get-Content -LiteralPath $file -Raw) -eq "third") "atomic write leaves the latest text"
Remove-Item -LiteralPath $temp -Recurse -Force

$missingServer = Test-PrismServerVersion -ServerPath (Join-Path $temp "missing-llama-server.exe")
Assert-True ((-not $missingServer.FilesPresent) -and (-not $missingServer.ServerStarted) -and (-not $missingServer.InferenceTested)) "a missing server is not reported as started or inference-tested"

$pwsh = (Get-Command pwsh).Source
$started = Test-PrismServerVersion -ServerPath $pwsh
Assert-True ($started.ServerStarted -and $started.ExitCode -eq 0 -and -not $started.InferenceTested) "a process that exits 0 is started, and inference is still not claimed"

$helpOld = "--mmproj FILE`n-ngl, --gpu-layers N`n--load-mode MODE, --no-mmap"
$helpNew = "$helpOld`n-lzm, --lazy-mode {on,off,auto}"
Assert-True (-not (Test-PrismLazyModeContract -ManifestVersion "2.64.0" -HelpText $helpOld).Compatible) "server without --lazy-mode fails above the manifest threshold"
Assert-True (Test-PrismLazyModeContract -ManifestVersion "2.41.0" -HelpText $helpNew).Compatible "server with --lazy-mode passes above the threshold"
Assert-True (Test-PrismLazyModeContract -ManifestVersion "2.31.9" -HelpText $helpOld).Compatible "server without --lazy-mode passes below the threshold"
Assert-True (-not (Test-PrismLazyModeContract -ManifestVersion "2.32.0" -HelpText $helpOld).Compatible) "the threshold version itself receives the flag"
$flagCheck = Test-PrismFlagContract -Arguments @("--mmproj", "x", "--lazy-mode", "auto", "-ngl", "99") -HelpText $helpOld
Assert-True ((-not $flagCheck.Compatible) -and ($flagCheck.UnknownFlags -join ",") -eq "--lazy-mode") "unknown flags are reported and values are ignored"
Assert-True (Test-PrismFlagContract -Arguments @("--mmproj", "x") -HelpText $helpOld).Compatible "known flags pass"

$newBuild = Set-PrismBuild -Build "b12128"
Assert-True ($script:PrismEngineVulkan -eq "llama.cpp-win-x86_64-prism-vulkan-b12128") "b12128 registers a separate engine identity"
Assert-True ($newBuild.VulkanZipUrl -like "*/prism-b12128-d7b2896/llama-prism-b12128-d7b2896-bin-win-vulkan-x64.zip") "b12128 Vulkan URL matches the release asset"
Assert-True ($newBuild.HipDirName -eq "llama.cpp-prism-b12128-d7b2896-bin-win-hip-radeon-x64-lm-studio") "b12128 uses its own directory"
Assert-True ($newBuild.HipSha256.Length -eq 64 -and $newBuild.VulkanSha256.Length -eq 64) "b12128 archives are pinned"
$oldBuild = Set-PrismBuild -Build "b10809"
Assert-True ($script:PrismEngineRocm -eq "llama.cpp-win-x86_64-prism-rocm-rx9070" -and $oldBuild.HipDirName -eq "llama.cpp-prism-b10809-b3ebc47-bin-win-hip-radeon-x64-lm-studio") "b10809 keeps its existing identity and directory"

$cudaIndex = [pscustomobject]@{ json = @(
    [pscustomobject]@{ dirPath = "C:\vk"; libLmStudioPath = "C:\vk\b.node"; launchInfo = [pscustomobject]@{ engineLibPath = "C:\vk\e.node" }; manifest = [pscustomobject]@{ name = "official-vulkan"; version = "1.0.0"; gpu = [pscustomobject]@{ framework = "Vulkan" } }; backendCompatibility = [pscustomobject]@{ status = "compatible" } },
    [pscustomobject]@{ dirPath = "C:\cu"; libLmStudioPath = "C:\cu\b.node"; launchInfo = [pscustomobject]@{ engineLibPath = "C:\cu\e.node" }; manifest = [pscustomobject]@{ name = "official-cuda"; version = "1.0.0"; gpu = [pscustomobject]@{ framework = "CUDA"; make = "Nvidia" } }; backendCompatibility = [pscustomobject]@{ status = "compatible" } }
) }
$cudaUpdated = Update-PrismEngineIndex -Index $cudaIndex -Kinds @("cuda") -RocmDir "D:\r" -VulkanDir "D:\v" -CudaDir "D:\c"
$cudaEntry = @($cudaUpdated.json | Where-Object { $_.manifest.name -eq $script:PrismEngineCuda })[0]
Assert-True ($cudaEntry.dirPath -eq "D:\c" -and $cudaEntry.manifest.gpu.make -eq "Nvidia" -and $cudaEntry.manifest.gpu.framework -eq "CUDA") "cuda entry is built from a CUDA template"
Assert-True ($cudaEntry.launchInfo.engineLibPath -like "*llm_engine_cuda12.node" -and $cudaEntry.libLmStudioPath -like "*liblmstudio_bindings_cuda12.node") "cuda entry points at the CUDA adapter"
Assert-True ($cudaEntry.manifest.version -eq $script:PrismCudaManifestVersion) "cuda entry uses its own manifest version"
Assert-True (@($cudaUpdated.json).Count -eq 3) "cuda update keeps the other entries"
$metaIndex = '{"json":[{"dirPath":"C:\\a","libLmStudioPath":"x","launchInfo":{"engineLibPath":"y"},"manifest":{"name":"llama.cpp-win-x86_64-prism-cuda13-b12128","version":"1.0.0","gpu":{"framework":"CUDA"}},"backendCompatibility":{"status":"compatible"}},{"dirPath":"C:\\b","libLmStudioPath":"x","launchInfo":{"engineLibPath":"y"},"manifest":{"name":"official-cuda","version":"1.0.0","gpu":{"framework":"CUDA"}},"backendCompatibility":{"status":"compatible"}}],"meta":{"values":{"0.displayData":["map"],"1.displayData":["map"],"1.visibleDevicesConfig":["undefined"]},"other":1}}' | ConvertFrom-Json
$metaUpdated = Update-PrismEngineIndex -Index $metaIndex -Kinds @("cuda") -RocmDir "D:\r" -VulkanDir "D:\v" -CudaDir "D:\c"
$metaKeys = @($metaUpdated.meta.values.PSObject.Properties.Name)
Assert-True ($metaUpdated.json[0].manifest.name -eq "official-cuda" -and $metaKeys -contains "0.visibleDevicesConfig") "index meta follows an entry that moved"
Assert-True ($metaUpdated.json[1].manifest.name -eq $script:PrismEngineCuda -and $metaKeys -contains "1.displayData") "a new index entry gets the template meta"
Assert-True ($metaKeys.Count -eq 3 -and $metaUpdated.meta.other -eq 1) "no stale index meta remains and other meta fields stay"

$cudaPackage = Get-PrismCudaPackageJson
$cudaManifest = $cudaPackage.Manifest | ConvertFrom-Json
Assert-True ($cudaManifest.name -eq $script:PrismEngineCuda -and $cudaManifest.gpu.framework -eq "CUDA" -and $cudaManifest.target_libraries[0].name -eq "llm_engine_cuda12.node") "cuda manifest names the CUDA engine and adapter"
$cudaDisplay = $cudaPackage.Display | ConvertFrom-Json -NoEnumerate
Assert-True ($cudaPackage.Display.StartsWith('[["en",{') -and $cudaPackage.Display.EndsWith('}]]')) "cuda display data keeps the nested LM Studio shape"
Assert-True (($cudaPackage.Artifacts | ConvertFrom-Json).files.Count -eq 9) "cuda artifacts list the runtime files"
$cudaMissing = Join-Path $env:TEMP ("prism-cuda-" + [guid]::NewGuid().ToString("n"))
Assert-True ((Get-PrismMissingFiles -Directory $cudaMissing -Kind "cuda") -contains "llm_engine_cuda12.node") "cuda checks its own adapter files"

$v2 = (Merge-PrismGgufPreferenceV2 -ExistingJson '{"formatDefaults":{"gguf":"old","mlx":"keep"},"versions":{"old":"1.0.0"}}' -EngineName "new" -Version "2.0.0").Json | ConvertFrom-Json
Assert-True ($v2.formatDefaults.gguf -eq "new" -and $v2.formatDefaults.mlx -eq "keep") "v2 preferences change only the GGUF default"
Assert-True ($v2.versions.new -eq "2.0.0" -and $v2.versions.old -eq "1.0.0") "v2 preferences add the engine version and keep others"
$v2Repair = (Merge-PrismGgufPreferenceV2 -ExistingJson '[{"model_format":"gguf","name":"old"}]' -EngineName "new" -Version "2.0.0").Json | ConvertFrom-Json
Assert-True ($v2Repair.formatDefaults.gguf -eq "new") "v2 file with the old array shape becomes the v2 shape"

$hashTemp = Join-Path $env:TEMP ("prism-hash-test-" + [guid]::NewGuid().ToString("n"))
[System.IO.File]::WriteAllText($hashTemp, "abc")
Assert-True (Test-PrismFileHash -Path $hashTemp -ExpectedSha256 "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD") "matching SHA-256 passes"
Assert-True (-not (Test-PrismFileHash -Path $hashTemp -ExpectedSha256 ("0" * 64))) "wrong SHA-256 fails"
Remove-Item -LiteralPath $hashTemp -Force

$atomicDir = Join-Path $env:TEMP ("prism-atomic-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $atomicDir | Out-Null
$atomicFile = Join-Path $atomicDir "state.json"
Write-PrismAtomicText -Path $atomicFile -Text "one"
Write-PrismAtomicText -Path $atomicFile -Text "two"
Assert-True ((Get-Content -LiteralPath $atomicFile -Raw) -eq "two") "atomic write replaces an existing file"
Assert-True (@(Get-ChildItem -LiteralPath $atomicDir -Force -Filter "*.tmp").Count -eq 0) "atomic write leaves no temporary file"
Remove-Item -LiteralPath $atomicDir -Recurse -Force

Assert-True (-not (Test-PrismDefaultRuntimeAllowed -Kind "vulkan" -LazyModeIncompatibleKinds @("vulkan"))) "a runtime that rejects --lazy-mode is not selected"
Assert-True (Test-PrismDefaultRuntimeAllowed -Kind "vulkan" -LazyModeIncompatibleKinds @("vulkan") -Force) "-Force selects it anyway"
Assert-True (Test-PrismDefaultRuntimeAllowed -Kind "cuda" -LazyModeIncompatibleKinds @("vulkan")) "another incompatible runtime does not block selection"
Assert-True (Test-PrismDefaultRuntimeAllowed -Kind "cuda" -LazyModeIncompatibleKinds @()) "no incompatible runtime allows selection"

$sortedDirs = Get-PrismVersionedDirectories -Directories @(
    [pscustomobject]@{ Name = "x-2.9.0" }, [pscustomobject]@{ Name = "x-2.10.0" }, [pscustomobject]@{ Name = "x-2.10.0.bak-prism-original" }
)
Assert-True ($sortedDirs.Count -eq 2 -and $sortedDirs[0].Name -eq "x-2.10.0") "directories sort by version and unversioned names are skipped"

$pinned = Set-PrismBuild -Build "b10809"
Assert-True ($pinned.HipSha256.Length -eq 64 -and $pinned.VulkanSha256.Length -eq 64) "b10809 archives are pinned"

if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "All PrismBackendLib tests passed."
