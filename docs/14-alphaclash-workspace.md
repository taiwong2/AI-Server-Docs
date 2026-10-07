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

## Rules that apply here

- Heavy or long work goes through the job queue; GPUs only with a `gpulease` lease (AGENTS.md rules 1–2).
- Run scripts by copying a `.ps1`/`.py` over and executing it; inline commands quoted through SSH break easily.
- `pip` inside an SSH session fails with WinError 448 unless the `OpenAI\Codex\bin` entry is removed from PATH
  for that command (see [Troubleshooting](08-troubleshooting.md)).
