# AlphaClash workspace (new system, 2026-10-07)

Where the rebuilt Clash of Clans RL system is developed on this box, and how to work on it over SSH.
The old AlphaClash workspace is archived on Drive (see [Agents and chat](09-agents-and-chat.md)); this is a
fresh workspace for the **new** system. No training runs here yet: the plan is build → small tests → train.

## Layout

```
C:\Users\poopl\Development\AlphaClash-Workspace\
  ClashEngineering\   exact 18.600 battle engine (C++ modules validated against the real game code), battlescope viewer
                      + artifacts\ (recovered engine, decoded game data), extracted\ (APK assets), the 18.600 APK
                      .venv\  Python 3.12 venv: unicorn, capstone, pyelftools, numpy, Pillow, imageio
  AlphaClash\         9.256 C# server/simulator (branch archive-sync-20261003) with the battlescope trace recorder,
                      Python RL code (new agent is built from scratch; old code kept for reference)
```

Nothing from the Drive archive is restored by default. `AlphaClash\ops\restore_from_archive.py --plan` lists a
28 GB working subset; run it only if old data is needed (it must run as poopl, because G: is per-user).

## Syncing with the Mac

Both directories are git working copies that accept pushes to their checked-out branch
(`receive.denyCurrentBranch updateInstead`). On the Mac each repo has a remote `aiserver`:

```sh
git remote add aiserver "ai-server:C:/Users/poopl/Development/AlphaClash-Workspace/<Repo>"
git config remote.aiserver.uploadpack  'powershell -NoProfile -Command git upload-pack'
git config remote.aiserver.receivepack 'powershell -NoProfile -Command git receive-pack'
git push aiserver <branch>
```

The PowerShell wrapper is required: git single-quotes the repo path, and `cmd` (the OpenSSH default shell) keeps
the quotes. The server has no GitHub credentials on purpose; GitHub pushes happen from the Mac.

## Toolchain added for this (2026-10-07)

| Tool | Install | Use |
| --- | --- | --- |
| .NET SDK 10.0.401 | `winget install Microsoft.DotNet.SDK.10` | Build the 9.256 simulator: `dotnet build -c Release -p:AlphaClashTfm=net10.0 AlphaClashServer.Tools.Headless\AlphaClashServer.Tools.Headless.csproj` (without the flag Windows builds the old netcoreapp2.2) |
| LLVM 23.1.3 (clang) | `winget install LLVM.LLVM` | Build ClashEngineering C++ modules and tests (`C:\Program Files\LLVM\bin\clang++.exe`, target x86_64-pc-windows-msvc) |

The .NET 3.1 SDK that was already installed is untouched.

## Verified

- The 9.256 simulator built with net10.0 gives **bit-identical** results on this box and on the Mac (M2, ARM64):
  example battle checksum 509550182, same replay and battle-log hashes, and the traced run equals the untraced run.
- The native ARM64 oracle in ClashEngineering (`tools/native_battle_*`) runs the original game code natively and is
  **Mac-only**; on this x86 box use the Unicorn validators instead.

## Training and the website (ClashLab, 2026-10-07)

The RL system's battles run on a separate Linux battle box (a Strix Halo; the Mac until it arrives). This box does
two things for it:

- **GPU learner** — job kind `clashlearner` (`C:\AI-Server\scripts\jobkinds\clashlearner.ps1`, source of truth
  `ClashEngineering\ops\aiserver\clashlearner.ps1`). It takes a `gpulease` (8,000 MB), serves PPO updates on
  **:8890** (tailnet; `Tailscale-In` allows it), and exits after 20 min without requests or after 170 min, inside
  `job_timeout_minutes` = 180, releasing the lease. The coordinator on the battle box resubmits it over ssh when it
  disappears (`--learner-autostart ai-server`) and reloads its weights into the new learner. By hand:
  `python C:\AI-Server\scripts\jobqueue.py submit --kind clashlearner [--arg IdleExit=600]`.
- **Website** — the `AlphaClash-Dashboard` task (:8787, `C:\AI-Server\www\alphaclash`) now serves the **ClashLab**
  site (runs, learning curves, evals, battle videos), published from the battle box with `python -m clashlab
  publish` (tar over ssh, only changed files; `.clashlab_manifest.json` tracks them). The old 9.256 page is kept as
  `legacy.html`; `recordings\` and the audit notes are untouched.

**torch on this box:** the learner uses the conda `ai` env (`C:\Users\poopl\miniconda3\envs\ai`, torch
2.6.0+cu124). A current torch wheel installed into the ClashEngineering venv failed with *WinError 4551: An
Application Control policy has blocked this file* (`torch\lib\shm.dll`) and was removed again — same cause as the
numba/scipy pins in [Troubleshooting](08-troubleshooting.md).

## BaseFinder 18.600 catalog and tests (2026-10-08)

`BaseFinder\parser\catalog18.json` (exported by ClashEngineering `clashlab/basefinder/catalog_export.py`) makes the
screenshot parser's classes, counts, footprints and levels 18.600-native for TH1-18; `BF_CATALOG=th11` keeps the
archived TH11 pipeline. **pytest 9.1 was installed into the conda `ai` env** (2026-10-08) to run the BaseFinder
tests on this box:

```
cd C:\Users\poopl\Development\AlphaClash-Workspace\BaseFinder
C:\Users\poopl\miniconda3\envs\ai\python.exe -m pytest -q tests\test_catalog18.py
```

The tests run BaseFinder in the `ai` env (cv2) and call `ClashEngineering\.venv` (unicorn, game data) in a
subprocess for the 18.600 layouts; the first run builds CE's engine id map (several minutes).

## BaseFinder synthetic training data (2026-10-08)

Game-look 18.600 screenshots of known layouts with exact labels, made on the CPU (no GPU lease) by
ClashEngineering `clashlab/basefinder/synth.py`. **Data lives outside the repos** in a new directory:

```
C:\Users\poopl\Development\AlphaClash-Workspace\data\basefinder\
  oracle_sim\apk\assets\{sc,font}   APK art (553 .sc/.sctx files) extracted from the 18.600 APK by extract_apk_art.py
  gen7_snapshot\gen7.py               old copy of BaseGen v7 v0; obsolete since 2026-10-08: clashlab/basegen is
                                     committed (gen7 v1) and the job imports ClashEngineering\clashlab\basegen\gen7.py
  synth18_pilot\                      pilot dataset: 640 samples (598 train / 42 val), 2.4 GB of PNG
```

**Installed into the conda `ai` env (2026-10-08): `zstandard 0.25.0` and `texture2ddecoder 1.0.6`** (the APK
.sc decoder needs both; neither is blocked by Application Control).

New job kind **`basefinder_synth`** (`C:\AI-Server\scripts\jobkinds\basefinder_synth.ps1`, source of truth
`ClashEngineering\ops\aiserver\basefinder_synth.ps1`): 28 worker processes, resumable (resubmit the same
arguments to continue), stops after `TimeLimit` = 165 min inside the 180-min job timeout. Measured: ~6 img/s
(640 samples in 1.8 min, rate still climbing as the per-worker sprite caches warm up). A PNG sample averages
3.75 MB, so 20,000 samples take about 75 GB.

```
python C:\AI-Server\scripts\jobqueue.py submit --kind basefinder_synth --arg Out=synth18_v1 --arg N=20000 --arg Seed=1
```

## BaseFinder 18.600 registration (2026-10-08)

Screenshot -> grid affine for real 18.600 screenshots (`BaseFinder\parser\register18.py`: a dense iso-coordinate
network + robust line fits, then a rectified-space refiner). Data and models live under
`data\basefinder\reg18\` (outside the repos):

```
data\basefinder\reg18\
  renders_jpg\          588 CE game-look stills (492 train / 96 val suite levels) + exact affines (scripts/reg18_render.py)
  models_v1\            coordinate net: reg18.pt (weights), last.pt (resume), eval.jsonl
  refine_v1\            refiner: reg18_refine.pt, last.pt, eval.jsonl
  *.train.log           per-run training logs
data\basefinder\torch_home\   TORCH_HOME for the jobs (torchvision ImageNet weights, downloaded on first use)
```

GPU work goes through the queue as a `shell` job that runs `BaseFinder\scripts\reg18_job.py {train|refine|eval|label}`;
the launcher takes a `gpulease` (10,000 MB, or `REG18_VRAM_MB`), pins `CUDA_VISIBLE_DEVICES`, then runs the script as
a child; runs stop themselves at `--max-minutes 160` and resume from `last.pt` when resubmitted. No new job kind,
no packages installed. Note the queue is serial: a 160-min training chunk blocks every other queued job.

## Rules that apply here

- Heavy or long work goes through the job queue; GPUs only with a `gpulease` lease (AGENTS.md rules 1–2).
- Run scripts by copying a `.ps1`/`.py` over and executing it; inline commands quoted through SSH break easily.
- `pip` inside an SSH session fails with WinError 448 unless the `OpenAI\Codex\bin` entry is removed from PATH
  for that command (see [Troubleshooting](08-troubleshooting.md)).

## BaseGen v7 forge results (2026-10-08)

BaseGen v7 (ClashEngineering `clashlab/basegen/`: `gen7.py` generator, `forge.py` engine strength harness,
`DESIGN.md` learned designer + league plan). Battles run on the Mac (ARM64 engine); the results are mirrored to the
server, outside the repos (no job kind, no packages installed):

```
C:\Users\poopl\Development\AlphaClash-Workspace\data\basegen\forge\
  battle_cache.jsonl          every forge battle (level sha1, policy, army, seed -> stars, destruction, G)
  20261008-search-v1\         gen7 search TH9-18: summary.json, compare.json/.md, levels\*.level.json + meta, render\
  *.log                       search / compare / register logs
```
Refresh from the Mac: `tar czf` ~/Documents/ClashRuns/forge (with COPYFILE_DISABLE=1), scp, `tar xzf` here.
