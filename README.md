# PrismML llama.cpp for LM Studio (Windows packaging fork)

> [!IMPORTANT]
> This repository is a **packaging fork**. It does not reimplement llama.cpp. It redistributes **pre-compiled PrismML `llama.cpp` runtimes** and adds Windows installer scripts, LM Studio manifests, and diagnostics so those runtimes can be selected inside **LM Studio**.
>
> Use it to **run PrismML Bonsai 1-bit / ternary GGUF models in LM Studio**, including `*-PQ2_0.gguf` and `*-Q2_0_g64.gguf`.
>
> **Stock LM Studio `llama.cpp` runtimes do not include the PrismML kernels these models need.** If a Bonsai model fails to load, select a PrismML runtime from this repository.
>
> **No compilation is required.** Copy a backend folder, or run `setup-rocm-backend.ps1`, to install it under `%USERPROFILE%\.lmstudio\extensions\backends\`.

<div align="center">

# LM Studio runtimes for AMD ROCm, Vulkan, CUDA, and CPU

**Windows packages of the PrismML llama.cpp fork, with an LM Studio installer**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%20x64-lightgrey.svg)](../../releases)
[![Target](https://img.shields.io/badge/Target-LM%20Studio%20Extensions-purple.svg)](https://lmstudio.ai/)
[![Hardware](https://img.shields.io/badge/Hardware-AMD%20Radeon%20%2F%20NVIDIA%20RTX-red.svg)](../../releases)

[Releases](../../releases) &bull; [Request a Build](../../issues) &bull; [Upstream PrismML](https://github.com/PrismML-Eng/llama.cpp)

</div>

---

## What this fork is

| Piece | Where it comes from | What this repository changes |
| :--- | :--- | :--- |
| Inference binaries (`llama-server.exe`, `ggml-*.dll`, rocBLAS / hipBLASLt libraries) | [PrismML-Eng/llama.cpp](https://github.com/PrismML-Eng/llama.cpp), itself a fork of [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) | Nothing. The DLLs are the published PrismML builds. |
| LM Studio engine adapter (`.node` files such as `llm_engine_vulkan.node`) | Official LM Studio runtime, copied at install time when present | Not rebuilt here. The HIP package is launched through that existing Vulkan adapter. |
| `setup-rocm-backend.ps1`, `diagnose-lmstudio.ps1`, manifests, `display-data.json`, this README | This packaging fork | Installer, English display names, and diagnostics for Windows LM Studio. |

Stock LM Studio builds of upstream `llama.cpp` do not contain the PrismML low-bit kernels. Loading a Bonsai model on those builds can fail, return NaNs, or produce garbled text.

Included GPU coverage for the HIP build:

* **AMD Radeon RX 9000 (RDNA 4):** RX 9070 XT and RX 9070 (`gfx1201` / `gfx1200`).
* **AMD Radeon RX 7000 (RDNA 3):** `gfx1100`, `gfx1101`, `gfx1102`, `gfx1150`, `gfx1151`.
* **Vulkan:** fallback for current AMD, Intel, and NVIDIA GPUs through the normal Windows driver.

The installer adds backends next to the ones LM Studio already has. It does not delete other runtime folders. It does not change the GGUF default runtime unless you pass `-SetDefaultRuntime`. Close LM Studio before you run it. If LM Studio is still open, preference and engine-index writes are skipped unless you pass `-Force`.

`HSA_OVERRIDE_GFX_VERSION=12.0.1` is the value tested with ROCm on an RX 9070 XT. The installer writes it only for a ROCm or combined install when an RX 9070 or RX 9000 adapter is detected. A Vulkan-only install does not change it. The variable is user-wide. A different existing value is left alone unless you pass `-Force`. `-ClearHsaOverride` restores the previous value only when this installer recorded one and the current value is still `12.0.1`.

---

## Supported Backends

| Backend | Platform | Target Devices / Architectures | Build / Tag | Status |
| :--- | :--- | :--- | :--- | :--- |
| **AMD ROCm / HIP** | Windows x64 | **RX 9070 XT: tested by the maintainer in LM Studio.**<br>RX 9000 (`gfx1201` / `gfx1200`), RX 7000, and RX 6000 are the architectures this HIP build is expected to target. Those other cards were not tested here. | `prism-b10809` | **Included** |
| **Vulkan** | Windows x64 | Expected to use the normal Windows driver on current AMD, Intel, and NVIDIA GPUs. Not a hardware test of every card. Polaris cards such as the RX 580 are outside the ROCm package. | `prism-b10809` | **Included** |
| **CUDA 13.3** | Windows x64 | `prism-b12128` run directly on an RTX 5070 Ti with GLM-OCR and Bonsai. Other NVIDIA cards were not tested. | `prism-b12128` (installer), `prism-b10709` (repository) | **Included** |
| **CPU / AVX2** | Windows x64 | Expected on modern x86_64 CPUs. Not tested in this packaging pass. | `prism-b10709` | Available in repository |

---

## Quick Start (No Git Clone Required!)

Your friend can install the entire backend **without installing Git or cloning this repository** simply by opening **PowerShell** and running this single command:

```powershell
irm https://raw.githubusercontent.com/zfzfg/llama.cpp-prismml-rocm-lmstudio/main/setup-rocm-backend.ps1 | iex
```

### Alternatively (If cloned locally):
Run the installer directly from this folder:
```powershell
.\setup-rocm-backend.ps1
```
Install one backend only:

```powershell
.\setup-rocm-backend.ps1 -Backend rocm
.\setup-rocm-backend.ps1 -Backend vulkan
```

With no `-Backend` value, an AMD GPU installs ROCm and Vulkan, and a detected NVIDIA GPU installs PrismML CUDA 13.3 (`prism-b12128`). A machine with only NVIDIA installs CUDA only. A machine with no detected GPU installs Vulkan only. `-Backend cuda` installs CUDA without detection. `-Backend all` stages ROCm and Vulkan and does not add CUDA. The CUDA package needs an official LM Studio CUDA 12 runtime as its adapter source, and it downloads about 590 MB.

`-SkipHardwareCheck` skips GPU detection and does not change `HSA_OVERRIDE_GFX_VERSION`. `-Force` recopies local binaries over an existing install, may replace an existing HSA value with `12.0.1` on an RX 9070 during a ROCm install, and writes LM Studio files even if the app is open. `-SetDefaultRuntime` is what changes the GGUF default. `-ClearHsaOverride` restores a previously recorded HSA value.

`-PrismBuild b12128` installs the newer PrismML build next to the existing packages, with its own folder and engine identity. Its archives are checked against pinned SHA-256 values. ROCm and Vulkan stay on `b10809` by default because their `b12128` builds have not been run here. Only the CUDA `b12128` package was tested, with GLM-OCR and Bonsai in LM Studio 0.4.28 on an RTX 5070 Ti.

A successful install means the staged files were complete and `llama-server.exe --version` exited 0. It does not mean a model was loaded. For the default `b10809` build, this repository has no SHA-256 pin, so the installer checks the archive only by size and by the files it extracts. A failed update leaves the previous backend directory in place or restores it.

The first backup of a preference file, engine index, or replaced backend directory is `*.bak-prism-original` and is not overwritten. Later backups use a timestamp. Restore the original by moving that directory or file back yourself. Do not delete backups from other installs.

`backendCompatibility.status` set to `compatible` is how this installer registers the Vulkan-adapter bridge with LM Studio. It is not the result of a compatibility test. The RX 9070 XT ROCm path was tested in LM Studio by the maintainer; that registration flag remains because the tested setup uses it.

After a failed load, run `.\diagnose-lmstudio.ps1`. It prints GPU, HSA, installed backends, and recent LM Studio log lines, then copies the report to the clipboard. The report can contain local paths and log excerpts. Read it before you share it. The script does not change LM Studio files unless you pass `-ClearIndexCache`.

Run the installer logic tests with:

```powershell
.\tests\PrismBackendLib.Tests.ps1
```


---

## Manual Installation

### 1. Copy to LM Studio Extensions
A fresh clone holds only the JSON files for the `b10809` folders, because their binaries are not tracked. Run the installer, or unpack the release archive into the folder first.

Copy the desired backend directory:
- `llama.cpp-prism-b10809-b3ebc47-bin-win-hip-radeon-x64-lm-studio` (ROCm / HIP)
- `llama.cpp-prism-b10809-b3ebc47-bin-win-vulkan-x64-lm-studio` (Vulkan)

Directly into LM Studio's backend extensions directory:
```text
C:\Users\<Username>\.lmstudio\extensions\backends\
```
> **Shortcut:** Press `Win + R`, paste `%USERPROFILE%\.lmstudio\extensions\backends`, and press Enter.

Your directory layout should look like this:
```text
C:\Users\<Username>\.lmstudio\extensions\backends\
├── llama.cpp-prism-b10809-b3ebc47-bin-win-hip-radeon-x64-lm-studio\
│   ├── backend-manifest.json
│   ├── display-data.json
│   ├── engine-protocol-server-artifacts.json
│   ├── llama-server.exe
│   ├── ggml-hip.dll
│   ├── rocblas.dll
│   ├── rocblas/
│   │   └── library/ (*_gfx1201.hsaco)
│   └── ...
└── llama.cpp-prism-b10809-b3ebc47-bin-win-vulkan-x64-lm-studio\
    └── ...
```

### 2. Activate in LM Studio
1. Start (or restart) **LM Studio**.
2. Open **Settings** (gear icon) and go to **Runtime**.
3. Under the **GGUF** section, select:
   ```text
   Prism ML AMD ROCm/HIP llama.cpp (Windows - RX 9070 XT / RDNA 4)
   ```
   *(Or select `Prism ML Vulkan llama.cpp (Windows - Universal / AMD Fallback)` if using Vulkan)*.
4. Load your PrismML Bonsai model (e.g. `Bonsai-8B-PQ2_0.gguf`) and set GPU offload to max!

---

## AMD Radeon RX 9070 XT Notes & Troubleshooting

### Target Architecture (`gfx1201`)
The Radeon RX 9070 XT was tested by the maintainer with this ROCm/HIP package inside LM Studio. It is RDNA 4 (Navi 48, `gfx1201`). The package keeps the LM Studio manifest on the Vulkan adapter bridge (`gpu.framework` is `Vulkan`) and does not list `gpu.targets`. GPU selection is done by the ROCm runtime inside `ggml-hip.dll`. That bridge is the tested integration. This repository does not treat it as an untested workaround.

### Driver Environment Variable Override
`HSA_OVERRIDE_GFX_VERSION=12.0.1` is only for RX 9070 / RX 9000 (`gfx1201`). Do not set it on RX 7000 or RX 6000 cards. The installer sets the user variable only when it detects a 9070 or 9000 adapter, and it leaves a different existing value unchanged unless you pass `-Force`.

If LM Studio outputs `No supported ROCm GPUs found` on a Radeon RX 9070 with a newer Windows Adrenalin driver:
1. Open Windows Start menu, type `Environment Variables`, and open **Edit the system environment variables**.
2. Under **User variables**, click **New**:
   - **Variable name**: `HSA_OVERRIDE_GFX_VERSION`
   - **Variable value**: `12.0.1`
3. Click OK and restart LM Studio.

### `error: invalid argument: --lazy-mode`
LM Studio 0.4.28 passes `--lazy-mode` to every llama.cpp LLM engine with a manifest version of `2.32.0` or higher. The choice depends only on that version, not on the model. PrismML builds `b10709` and `b10809` do not know the flag, so LLM loads through them fail in LM Studio, while `llama-server.exe` started directly without the flag still works. `.\diagnose-lmstudio.ps1` reports this mismatch per installed package in section 5b. On an NVIDIA GPU, run `.\setup-rocm-backend.ps1 -SetDefaultRuntime` with LM Studio closed to install and select the CUDA `b12128` package.

If GLM-OCR then reports `V Cache Quantization requires flash attention`, set V Cache Quantization to off in its load settings.

### Vulkan Fallback
If your system encounters any ROCm driver conflicts on Windows, switch the Runtime in LM Studio to:
```text
Prism ML Vulkan llama.cpp (Windows - Universal / AMD Fallback)
```
Vulkan uses standard Windows graphics drivers and does not need the HIP/ROCm stack. The Vulkan package includes the PrismML ternary kernels. That is expected support, not a separate test of every GPU or every GGUF packing.

---

## License

Two MIT notices apply. Both are in [LICENSE](LICENSE).

* **This packaging fork** (installer, diagnostics, manifests, and this documentation) is Copyright (c) 2026 Collin Lerche (zfzfg) | STERRA, under the MIT License. Website: [sterra.online](https://sterra.online).
* **The llama.cpp binaries** stay under the MIT License of the ggml authors and the PrismML fork. This repository does not relicense those binaries.

## Credits

* Packaging fork: Collin Lerche (zfzfg) | STERRA
* PrismML fork and ternary kernels: [PrismML-Eng/llama.cpp](https://github.com/PrismML-Eng/llama.cpp)
* Base inference runtime: [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)
* Desktop environment: [LM Studio](https://lmstudio.ai/)
