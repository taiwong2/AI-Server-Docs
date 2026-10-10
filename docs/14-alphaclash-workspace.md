# AlphaClash workspace (new system, 2026-10-07)

Where the rebuilt Clash of Clans RL system is developed on this box, and how to work on it over SSH.

> **Since 2026-10-10 this box does only the GPU training of this system.** Every CPU stage below (parsing,
> synthetic rendering, sampling, propose, scrapers, forge, the site build and the :8787 site) moved to AI Server 2;
> the sections below describe how things ran here before and stay as history. Current setup, runner, data mirror
> and measured transfer speeds: [AI Server 2](15-ai-server-2-battle-box.md). ClashLab site:
> https://ai-server-2.tail215694.ts.net/ (the old http://100.71.113.77:8787/ redirects there).
The old AlphaClash workspace is archived on Drive (see [Agents and chat](09-agents-and-chat.md)); this is a
fresh workspace for the **new** system. No training runs here yet: the plan is build → small tests → train.

## One repo and the git workflow (2026-10-10)

**BaseFinder and the old AlphaClash repo are now inside ClashEngineering**, with their git history:
`ClashEngineering/basefinder/` (BaseFinder main ae72b1d, 69 commits) and `ClashEngineering/legacy/alphaclash/`
(9.256-era AlphaClash, 6 commits, minus game assets: `www/`, sprites/screenshots, keystore, GeoIP db). Data, models
and runs stay outside git as before (`AlphaClash-Workspace\data\basefinder`, `$REG18_DIR`).

- **Paths.** CE code finds BaseFinder through `clashlab/bf_root.py`: `$BF_ROOT`, else `<checkout>\basefinder`, else the
  old `AlphaClash-Workspace\BaseFinder`. `ops/aiserver/basedesigner.ps1` / `league_direct.ps1` (and AI Server 2's
  `ops/strixhalo/jobs/env.sh`) pick `<ce>\basefinder` when that checkout has it, else the old copy, so nothing
  changes for a deploy copy until it is synced, and the code is the same either way. BaseFinder scripts run from
  `<ce>\basefinder` exactly as from the old repo root (`cd ...\ClashEngineering\basefinder; python scripts\bf18_job.py ...`).
- **The old checkouts are frozen** at ae72b1d (`AlphaClash-Workspace\BaseFinder`, `bf_v5`, `bf_v4train`,
  `AlphaClash`; on AI Server 2 `~/AlphaClash-Workspace/BaseFinder`). They stay only so queued and running jobs that
  reference them finish; new BaseFinder commits go to `ClashEngineering/basefinder/`.
- **Deploy copies.** `AlphaClash-Workspace\ClashEngineering` here and `~/ClashEngineering` on AI Server 2 are
  deploy-only: they receive `origin/main` from the Mac with `tools/deploy_sync.sh --apply` (an updateInstead push;
  refused when the copy is dirty, has diverged, or the server has running jobs unless `--busy-ok`). Never edit them
  by hand; experiments run from their own checkout/worktree (`ce_att`, `ce_*`, AI Server 2 `~/ce_<task>`).
  As of 2026-10-10 06:30 UTC this box's copy had 19 locally modified designer files (mostly LF/CRLF noise from
  `core.autocrlf=true`, one real edit), so `deploy_sync` skips it until that is resolved.
- **Agents** follow `ClashEngineering/AGENTS.md`: a worktree per task (`tools/agent_worktree.sh <task>` ->
  `../ce-wt/<task>`, branch `agent/<task>`), small `area: what` commits, merges only through
  `tools/agent_merge.sh` (lock, rebase on origin/main, fast tests, fast-forward push, log in `.git/agent-merge.log`).

## Layout

```
C:\Users\poopl\Development\AlphaClash-Workspace\
  ClashEngineering\   exact 18.600 battle engine (C++ modules validated against the real game code), battlescope viewer
                      + artifacts\ (recovered engine, decoded game data), extracted\ (APK assets), the 18.600 APK
                      .venv\  Python 3.12 venv: unicorn, capstone, pyelftools, numpy, Pillow, imageio
  AlphaClash\         9.256 C# server/simulator (branch archive-sync-20261003) with the battlescope trace recorder,
                      Python RL code (new agent is built from scratch; old code kept for reference). Frozen: the code
                      is in ClashEngineering\legacy\alphaclash since 2026-10-10 (game assets only here)
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

The RL system's battles run on a separate Linux battle box: **AI Server 2** since 2026-10-09 (Strix Halo, `ai-server-2`, see
[AI Server 2 battle box](15-ai-server-2-battle-box.md); before that, the Mac). This box does two things for it:

- **GPU learner** — job kind `clashlearner` (`C:\AI-Server\scripts\jobkinds\clashlearner.ps1`, source of truth
  `ClashEngineering\ops\aiserver\clashlearner.ps1`). It takes a `gpulease` (8,000 MB), serves PPO updates on
  **:8890** (tailnet; `Tailscale-In` allows it), and exits after 20 min without requests or after 170 min, inside
  `job_timeout_minutes` = 180, releasing the lease. The coordinator on the battle box resubmits it over ssh when it
  disappears (`--learner-autostart ai-server`) and reloads its weights into the new learner. By hand:
  `python C:\AI-Server\scripts\jobqueue.py submit --kind clashlearner [--arg IdleExit=600]`.
  Since 2026-10-09 the kind takes **`-Ce <checkout>`** (default: the main `ClashEngineering` working copy) and the
  attacker runs submit it in lane **`attacker`** from their own checkout **`AlphaClash-Workspace\ce_att`** (git clone
  of the server repo, branch `attacker`, `receive.denyCurrentBranch updateInstead`; the Mac pushes to it as remote
  `aiserver-att`), so the learner never imports another agent's uncommitted edits:
  `python C:\AI-Server\scripts\jobqueue.py submit --kind clashlearner --lane attacker --arg Ce=C:\Users\poopl\Development\AlphaClash-Workspace\ce_att`.
  Previous launcher kept as `jobkinds\clashlearner.ps1.bak-20261009`.
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

Parameters added 2026-10-09 (renderer v4, CE b58b102): `Ce` = the ClashEngineering checkout to run (default the
workspace copy `ClashEngineering`; the renderer agent runs from its own clone **`AlphaClash-Workspace\ce_renderer`**,
detached at the pushed commit, because other agents keep uncommitted edits in the workspace copy), `ThMin`
(lowest TH for every layout source), `ParsedIds` (file restricting the `parsed` source, relative to
`data\basefinder`), `RealBgDir` (a parse dir whose registered real screenshots give `real` scenery backgrounds),
`V3Look=1` (switch the v4 realism off). v4 example (lane `renderer`):

```
python C:\AI-Server\scripts\jobqueue.py submit --kind basefinder_synth --lane renderer --arg Out=synth18_v4 --arg N=26000 --arg Seed=4 --arg Format=jpg --arg Ce=ce_renderer --arg ThMin=12 --arg Mix=parsed=0.6,gen7=0.4 --arg ParsedDir=parsed18_v3 --arg ParsedIds=synth18_v4_parsed_ids.txt --arg RealBgDir=parsed18_v3
v5 options (2026-10-09): `V5=1` (labelled traps / wall policy / facing + modes), `PoolFile=synth18_v5_pool.jsonl.gz`,
`BelowNormal=1` (the job and its workers run at below-normal CPU priority so training jobs keep their cores):
python C:\AI-Server\scripts\jobqueue.py submit --kind basefinder_synth --lane synth5a --arg Out=synth18_v5 --arg Start=0 --arg N=31000 --arg Seed=5 --arg Workers=12 --arg Rpl=1 --arg Format=jpg --arg Ce=ce_synth5 --arg V5=1 --arg PoolFile=synth18_v5_pool.jsonl.gz --arg RealBgDir=parsed18_v3 --arg BelowNormal=1
```

## BaseFinder 18.600 registration (2026-10-08)

Screenshot -> grid affine for real 18.600 screenshots (`BaseFinder\parser\register18.py`: a dense iso-coordinate
network + robust line fits, then a rectified-space refiner). Data and models live under
`data\basefinder\reg18\` (outside the repos):

```
data\basefinder\reg18\
  renders_jpg\          588 CE game-look stills (492 train / 96 val suite levels) + exact affines (scripts/reg18_render.py)
  renders_war_jpg\      same levels on the war scenery
  models_v1..v4\        coordinate net runs: reg18.pt (weights), last.pt (resume), eval.jsonl
  refine_v1, refine_v2\ refiner runs: reg18_refine.pt, last.pt, eval.jsonl
  current\              THE models register18 loads on this box by default (copied from a run, see BaseFinder
                        docs/REGISTER18.md): reg18.pt, reg18_refine.pt, scenery_{default,war}.{png,json}
  scenery\              scenery templates (APK art)
  labels_scn.jsonl      exact scenery labels for the first 817 scraped screenshots (train/val/eval splits)
  labels_unseen.jsonl   exact scenery labels for 1,597 later-scraped screenshots (664 labelled; held-out test set)
  synth18_pilot.jsonl   agent synth's pilot renders as registrar labels
  eval_*, cmp_*, zoom_* evaluation outputs; *.train.log per-run training logs
data\basefinder\torch_home\   TORCH_HOME for the jobs (torchvision ImageNet weights, downloaded on first use)
```

GPU work goes through the queue as a `shell` job that runs `BaseFinder\scripts\reg18_job.py {train|refine|eval|label}`;
the launcher takes a `gpulease` (10,000 MB, or `REG18_VRAM_MB`), pins `CUDA_VISIBLE_DEVICES`, then runs the script as
a child; runs stop themselves at `--max-minutes 160` and resume from `last.pt` when resubmitted. No new job kind,
no packages installed. Note the queue is serial: a 160-min training chunk blocks every other queued job.
Short GPU evals / small fine-tunes (minutes) were also run directly over ssh through the same launcher (it still
takes the lease) while the serial queue was held by a long scraper job. The always-on LLM leaves ~4.7 GB per card
leasable, so registrar runs then use `REG18_VRAM_MB=4400` and `--bs 6`.

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

## BaseFinder v5: 18.600 grid model training and scraped-screenshot parsing (2026-10-08/09)

Trains BaseFinder's per-cell grid model and level head on synthetic 18.600 data and parses every scraped
screenshot. No new job kind and no packages installed. Everything runs as queued `shell` jobs through
`BaseFinder\scripts\bf18_job.py`, which:
- takes a `gpulease` (default 4,400 MB, set by `BF18_VRAM_MB`);
- pins `CUDA_VISIBLE_DEVICES`;
- runs the script as a child.

Grid training resumes from where it stopped. With `--chain N`, when a 160-min chunk stops on its time limit, the
launcher resubmits the identical command at priority 4, in the same lane when `--lane` is given. It does this at
most N times (counted in `<out>\chain_count`), so every queue job stays inside `job_timeout_minutes` = 180. The
parse runs as 2 shards in their own queue lanes (`--shard K/2`, lanes `bfparse0` and `bfparse1`), with the CPU
scenery-registration stage in process pools.

```
data\basefinder\
  synth18_v1\            24,000 synthetic samples, JPEG (basefinder_synth job, Format=jpg, Seed=1; 45 min, 8.9 img/s);
                         storages are drawn EMPTY in this set
  synth18_v2\            16,000 samples (Seed=2) with storage fill levels + collector frames (CE 09e0bd1)
  scraped_mac\scraped\   copy of the Mac's ~/Documents/ClashData/scraped (tar over ssh, 2026-10-08). The server's own
                         scraper keeps writing data\basefinder\scraped\. The parser reads both and de-duplicates by image_url
  models\grid18_v1\      first grid run (synth18_v1 only, stopped at step 6,200: empty-storage data)
  models\grid18_v2\      grid run on v1+v2, 30,000 steps: best.pt / final.pt / last.pt, train.jsonl, chain*.log
  models\grid18_v2_final\ THE grid model (final.pt of grid18_v2 as best.pt) + metadata.json + final_eval.json
  models\level18_v1\     level head: level.pt, metadata.json, crops_{train,val}.npz (12 GB crop cache), run.log
  parsed18_v1\           2,817 parsed screenshots: layouts\ (BF JSON + diagnostics), levels\ (engine level JSON from
                         ClashEngineering clashlab.basefinder.parsed_level convert-dir), overlays\, contact\,
                         index.jsonl, stats.json, engine_verify.txt
  synth18_v4\            renderer v4 synthetic set (Seed=4, TH12-18, JPEG): parsed18_v3 gold+silver layouts
                         (synth18_v4_parsed_ids.txt, 2,550 ids from compare_v1_v3) 60 % + gen7 40 %; traps / teslas /
                         hero banners / crafted defenses / mode variants / legacy era / real-scenery backgrounds;
                         synth18_v4_smoke\ = 60-sample smoke test (deletable)
  synth18_v5\            synth v5 (Seed=5, JPEG, label_schema basefinder-synth18/5): traps drawn AND labelled on ~45 %
                         (traps_visible, traps, trap_attrs, owner_view), one wall level in ~72 %, facing / attack-mode
                         object_attrs, val split by split_key (real screenshot / designer sample); lanes synth5a
                         (Start 0) + synth5b (Start 31000), N=31000 each, BelowNormal priority, Ce=ce_synth5.
                         DONE 2026-10-09: 62,000 samples, 40.4 GB, err 0, ~2 h 45 min at ~6.4 img/s (2 x 12 workers);
                         train 58,979 / val 3,021 (1,103 held-out layouts, 0 overlap); stats.json, manifest.jsonl
  synth18_v5_pool.jsonl.gz  v5 known-layout pool (CE `python -m clashlab.basefinder.layouts pool`): 990 cleaned + closed
                         real bases (compare_v1_v3 gold/silver consensus, parsed18_v3 ok; gt18 ids excluded) + 1,877
                         designer / designer_ar valid levels; .stats.json = counts and rejection reasons
  ce_renderer\ (workspace root, not data)  ClashEngineering clone the renderer agent runs synth jobs from
  ce_synth5\ (workspace root, not data)  ClashEngineering clone the synth_v5 agent runs synth jobs from (push remote
                         srv5 from the Mac; artifacts\ copied from ce_renderer)
  compare_v1_v3\          parsed18_v1 vs parsed18_v3 agreement (BaseFinder scripts/parsed18_compare.py, CPU, ~3 min):
                         index.jsonl (v3 rows + agreement_confidence, train_tier gold/silver/review), consensus\<id>.json
                         (agreed objects + disputed_tiles), per_screenshot.jsonl, summary.json, REPORT.md, ANALYSIS.md,
                         heatmaps\, sheets\; log compare_v1_v3.log
  parsed18_v4\            BaseFinder v6 parse (2026-10-09): grid18_v3 + v5 decoder on the parsed18_v3 register18 affines
                         (--reuse-affine), statuses from agreement with parsed18_v1 (scripts/parsed18_finalize.py, ok >= 0.94):
                         ok 2,300 / review 517; stats.json, gt18_eval_{all,train,holdout}.json + GT18_EVAL_*.md;
                         layouts keep the v5 status as status_v5; logs ..\parsed18_v4.shard{0,1}.log
  real18_v4\              real-domain training data (BaseFinder scripts/build_real18_train.py): gt_train\ (gt18 train half,
                         exact labels, 20) and consensus\ (compare_v1_v3 gold+silver consensus pseudo-labels, 2,309 train /
                         150 val; disputed tiles + near-object rings ignored). Images are hard links to scraped\
  tune18\                 bf_v4 experiments on the 40 gt18 shots: per-model parses with probs\ (gt_*), decoder tuning
                         (tune*_*.json), holdout.json / HOLDOUT.md (deletable)
  models\grid18_v4*       grid18_v4 (= v4a final), grid18_v4a/b/c/d, grid18_v4b_s14400: experiments, all worse than grid18_v3
                         on the gt18 holdout (BaseFinder docs/PIPELINE_VERSIONS.md v6); grid18_v3 stays production
  bf_v4train\ (workspace root, not data)  BaseFinder clone (detached at origin/main) the bf_v4 train / parse jobs ran from
  grid18_smoke, parse_probe*, models\grid18_*_snap|_best|_final   smoke tests and probes (deletable, except _final)
```

```
python C:\AI-Server\scripts\jobqueue.py submit --kind shell --arg cmd="& 'C:\Users\poopl\miniconda3\envs\ai\python.exe' 'C:\Users\poopl\Development\AlphaClash-Workspace\BaseFinder\scripts\bf18_job.py' train --chain 3 --datasets <data>\synth18_v1 <data>\synth18_v2 --out <data>\models\grid18_vN --steps 30000 --batch 12 --width 1.25 --max-minutes 160"
```

Measured:
- Grid training: about 36 img/s on one 3090 with 3.2 GB of VRAM; about 17 img/s while other jobs held the CPU.
- Full synthetic val: object F1 0.981, wall F1 0.976.
- Level head: 10 epochs on 455k crops in about 25 min, synthetic val exact 0.996.
- Parse: about 1.5 s per screenshot per shard.
- Engine load check (Mac): 30 of 30 parsed levels load completely.

## Learned base designer (2026-10-08)

ClashEngineering `clashlab/designer/` (README there): a masked-token (MaskGIT-objective) U-Net + transformer that
generates home layouts on BaseFinder's 44x44 class grid, decoded with BaseFinder's TH-aware decoder pieces, plus a
heuristic placer for Hidden Teslas / hero flags / traps, a hard validity gate, a value model and an engine-in-the-loop
fine-tuning step (battles on the Mac). **Data and models live outside the repos:**

```
C:\Users\poopl\Development\AlphaClash-Workspace\data\designer\
  src\archive\<dir>\*.home.json     AlphaClash real payloads copied from the Drive archive (G: is per-user; SYSTEM
                                    jobs cannot read it, so the dataset builder reads this copy)
  dataset_<tag>\                    grids.npz, records.jsonl, report.json, enclosure_policy.json
  runs\prior_<tag>\, runs\ft_*\     checkpoints (last.pt resume, best.pt, final.pt), metrics.jsonl, config.json
  samples\<name>\                   levels\*.level.json + .meta.json, samples.jsonl, grids.npz, summary.json
  improve\r<k>\                     candidates, picks, engine.json (from the Mac), extra.npz (fine-tuning weights)
  value_v<k>.npz / .pkl             value-model data (built on the Mac from the forge cache) and model
  realism_*.json                    realism reports
  watch_<tag>.json, retrain_<tag>.submitted   parsed18 watcher state
```

New job kind **`basedesigner`** (`C:\AI-Server\scripts\jobkinds\basedesigner.ps1`, source of truth
`ClashEngineering\ops\aiserver\basedesigner.ps1`). GPU work takes a `gpulease` (4,000 MB) through
`clashlab.designer.job`; training stops itself at 150 min and resumes from `last.pt`. No packages installed.

```
python C:\AI-Server\scripts\jobqueue.py submit --kind basedesigner --arg Cmd=retrain [--arg Tag=v1]
    dataset (incl. data\basefinder\parsed18_v1 when present) -> prior training (resubmits itself until done)
    -> samples TH12-18 + realism report
python C:\AI-Server\scripts\jobqueue.py submit --kind basedesigner --arg Cmd=watch
    self-rescheduling hourly check (a few seconds per run, at most 72 checks): once parsed18_v1 has >= 1000
    layouts and an unchanged count over 2 checks, it queues Cmd=retrain once
python C:\AI-Server\scripts\jobqueue.py submit --kind basedesigner --arg Cmd=sample --arg Rest="--ckpt ... --out ..."
```

Designer jobs go to job-queue lane **`designer`** (`--lane designer`; one job per lane). `Parsed=` picks the parse
(`parsed18_v0` = BaseFinder's early parse, `parsed18_v1` = final). Watchers queued on 2026-10-08: tag v1 (parsed18_v1)
and tag v1b (completed parsed18_v0); the current model is `runs\prior_v1n2` (v1n: wall rules, style conditioning, exact symmetry; earlier `prior_v1m`). Short GPU runs (minutes: smoke training, sampling)
were also run directly over ssh through `clashlab.designer.job` (it still takes the lease) while the serial queue
was held by the scraper / BaseFinder jobs.

## Designer AR: orbit-placement base designer (2026-10-09)

ClashEngineering `clashlab/designer_ar/` (README there): the alternative learned designer (autoregressive placement
over symmetric orbits; walls drawn as connected ears / rings, closed and waste-free by construction). It runs from its
own checkout **`AlphaClash-Workspace\ce_designer_ar`**: a git clone of the server repo with
`receive.denyCurrentBranch updateInstead` (the Mac pushes to it as remote `arsrv`, using
`powershell -NoProfile -Command git receive-pack` as the receive-pack) and a directory junction
`ce_designer_ar\artifacts -> ClashEngineering\artifacts` (game data / id map, read-only use). No packages installed.

```
C:\Users\poopl\Development\AlphaClash-Workspace\data\designer_ar\
  parsed18_v1_compact.jsonl   parsed18_v1 layouts compacted (compact18.py); dataset_ar1\ (layouts.jsonl, report.json)
  runs\<name>\               best.pt / last.pt / history.json / done (ar1, ar2, ft_r1 ...)
  samples\<tag>\             levels\*.level.json + .meta.json, grids.npz, samples.jsonl, summary.json
  extra_r*.jsonl              engine-weighted self-generated records (RWR fine-tuning)
  realism_*.json, *.log       evaluation outputs; *.ps1 = the job scripts below
```

Jobs: kind `shell` in lanes **`designer_ar`** (data build, sampling, realism; CPU, up to 14-20 processes) and
**`designer_ar2`** (long training). GPU work takes a `gpulease` (8,000 MB, job name `designer_ar`) through
`clashlab.designer_ar.job`; training stops at 165-170 min and resumes from `last.pt` (the queue's retry resumes it).
Scripts: `ds_build.ps1`, `train_ar1.ps1` / `train_ar2.ps1`, `ft.ps1 -Init -Out -Extra -Steps`,
`sample_ar.ps1 -Run -Ckpt -Tag -N -Draws -Seed [-Temp] [-WallTemp] [-Groups]`, `realism.ps1 -Sets a,b -Out f.json`:

```
python C:\AI-Server\scripts\jobqueue.py submit --kind shell --lane designer_ar --requester designer_ar --arg cmd="powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\poopl\Development\AlphaClash-Workspace\data\designer_ar\sample_ar.ps1 -Run ar2 -Tag x -N 16"
```

## scrape2: more real TH12-18 base screenshots (2026-10-09)

Polite, resumable scrapers (ClashEngineering `tools/scrape/scrape2_*.py`, notes in `tools/scrape/SCRAPE2.md`) run
from their own checkout `C:\Users\poopl\Development\AlphaClash-Workspace\ce_scrape` (files copied there; no git
remote needed) in job-queue lane **`scrape`** (shell kind, `ce_scrape\tools\scrape\run_scrape2.ps1 -Mode scrape
-Minutes 170`; resubmit the same command to continue, finished sites exit at once). CPU / network only, no GPU.
Output (data, outside the repos):

```
data\basefinder\scraped2\
  README.md                    layout + status meanings
  _index\existing.jsonl        sha1 + 256-bit dhash of every image in scraped\ and scraped_mac\scraped\ (+ their urls)
  _index\report.json           per site x TH status counts (scrape2_run.py report)
  <site>\th<N>\images\         new, unique, full-size (width >= 1000) screenshots
  <site>\th<N>\lowres\         new, unique, narrower originals
  <site>\th<N>\manifest.jsonl  one record per base (th, title, category, source_url, image_url, share_link text, status)
  <site>\_skipped.jsonl, _errors.jsonl, _run.log, _candidates.json
```
Sites: cocbases, basemelon, clash_bases_com, clashcodes, cocbase_net (re-check), clashofclans_layouts (re-check).

## oracle_sim source pools backup (2026-10-09)

A Mac temp cleanup deleted the session scratch that held the oracle_sim corpus sources. They were restored from the
Drive archive and are now kept (191 small JSON files, 8 MB) at:

```
C:\Users\poopl\Development\AlphaClash-Workspace\data\oracle_sim_src\
  pools_v4\ pools_v4max\   runs\pools_v4{,max}\train (6) + \holdout (2 v4_real)
  pro_bases\ real_bases\ real_aug_tw\ (= runs\real_bases_aug2026_traps_walls) coevolve\ (runs\coevolve_pool)
  basefinder\              AlphaClashBaseFinder\data\ml_datasets\th11_game_layouts\layouts (150)
  basegen\                 BaseGen v6 seeds 7, 11, 23 (regenerated)
```

ClashEngineering `tools/oracle_sim_src.py restore` pulls from here (falls back to the Drive archive, copying into
this dir first) and checks every file against `tools/oracle_sim_src_manifest.json` (sha256). The Mac copy lives in
CE `.toolchain/scratch/oracle_sim/src`, the corpus in `.toolchain/oracle_sim/corpus` (env `ORACLE_SIM_SRC`,
`ORACLE_SIM_CORPUS`).

## ClashLink data tunnel and the league (2026-10-09)

**ClashLink hub** (ClashEngineering `clashlab/link`): the persistent data connection between the AI server, the battle
box (AI Server 2, `100.65.60.112`, which reaches the hub over the tailnet) and the Mac. TCP **8892** on every interface (tailnet `100.71.113.77`, LAN
`192.168.1.24`); zstd-framed messages, HMAC token auth, durable queues with backpressure, versioned keys, resumable
file transfer, submission of the whitelisted job kinds `basedesigner`, `clashlearner`, `clashlink`.

- Runs as the scheduled task **`AlphaClash-ClashLink`** (logon trigger, user poopl, interactive token like
  `AlphaClash-Dashboard`), not as a queue job: a hub job held one of the 5 queue lanes for its whole life. The task
  runs `C:\AI-Server\tools\clashlink\hub.ps1` (source of truth `ClashEngineering\ops\aiserver\clashlink_hub_task.ps1`),
  a loop that restarts the hub from the clean checkout **`AlphaClash-Workspace\ce_wf`** (git clone of the server repo,
  the league's own checkout). Log `C:\AI-Server\logs\clashlink-hub.log`. After a `ce_wf` update:
  `powershell -ExecutionPolicy Bypass -File C:\AI-Server\tools\clashlink\hub.ps1 -Restart` (ends the task, kills the
  process on 8892, starts the task). Install / re-register: `... clashlink_hub_task.ps1 -Install`.
- Firewall: inbound rule **`clashlink-hub`** (TCP 8892, all profiles), added 2026-10-09 next to `alphaclash-site`.
  8892 is not in `busy_ports`: the hub does not keep the box awake.
- Token: `C:\Users\poopl\.clashlink\token` (the same file on every box, never in git). Hub state (queues, keys):
  `data\link\hub\`. File roots: `league` = `data\league` (rw), `runs` = `runs` (rw), `designer` / `basefinder` /
  `basegen` = `data\<name>` (read-only).
- Job kind **`clashlink`** (`jobkinds\clashlink.ps1`, source `ops\aiserver\clashlink.ps1`): `Role=learner` = the
  league's PPO learner behind the hub (gpulease 8,000 MB, queue `learner.in` -> key `learner/<run>/weights`, exits
  after 20 min idle / 170 min or on a shutdown message), submitted by the league in lane **`league`**. `Role=hub`
  still exists as a fallback when the task is missing.
- `C:\AI-Server\tools\clashlink\league_direct.ps1` (source `ops\aiserver\league_direct.ps1`): the same launchers run
  directly over ssh. Only for short dry runs when every lane is taken (the league config `server.direct_after_s`
  cancels a job that has not started by then and runs it this way). Long work stays in the queue.

**League** (ClashEngineering `clashlab/league`, runbook in its README): the attacker <-> designer loop. It runs on the
battle box; on this machine it only uses the hub, the `clashlink` learner job (lane `league`) and `basedesigner`
jobs (lane `league`: `Cmd=improve Rest="propose ..."`, `Cmd=improve Rest="ftdata ..."`, `Cmd=train Rest="... --init
... --extra ..."`). Data: `data\league\<name>\designer\gen<n>\` (proposals: `cands\levels`, `picks.json`,
`candidates.json`, `engine.json` from the battle box, `extra.npz`) and `data\league\<name>\designer\D<k>\`
(fine-tuned designers: `best.pt`, `last.pt`, `DONE`). Dry run 2026-10-09: league `dry1`.

Throughput Mac <-> hub over the tailnet (WAN, 68.7 ms RTT, `python -m clashlab.link bench`): upload 7-9 MB/s,
download ~4 MB/s whatever the stream count (the server's uplink); a 92 MB PPO batch goes as 4.5 MB of zstd in 1.07 s.

## BaseFinder gt18 ground truth + review tool (2026-10-09)

Real ground truth for the 18.600 screenshot parser, so parse accuracy is measured on real screenshots (the synthetic
val numbers are same-renderer).

- **Review web app** — scheduled task **`BF-GT18-Review`** (SYSTEM, AtStartup, restart on failure, no time limit):
  `C:\Users\poopl\miniconda3\envs\ai\python.exe -u ...\AlphaClash-Workspace\gt18_review\clashlab\basefinder\review\server.py
  --bind 100.71.113.77 --port 8788` (stdlib only). **http://100.71.113.77:8788/** — tailnet only (bound to the tailnet
  address; `Tailscale-In` allows it; no new firewall rule; not in `busy_ports`, never keeps the box awake; retries the
  bind every 10 s if Tailscale is not up yet at boot). Log `data\basefinder\gt18\review_server.log`. Code: a
  `git archive` export of ClashEngineering `clashlab/basefinder/review` into `AlphaClash-Workspace\gt18_review` (kept
  out of `ce_wf`, which is the ClashLink checkout). Update: unzip a new export over it, `schtasks /end /tn
  BF-GT18-Review`, stop the python listening on 8788, `schtasks /run /tn BF-GT18-Review`.
- **Data** `data\basefinder\gt18\`: `picks.json` (40 screenshots, TH12-18 x site, BaseFinder `scripts/gt18_pick.py`),
  `labels\<id>.json` (corrected layouts; previous versions in `labels\_history\`), `EVAL.md` + `eval_v1_v3.json`
  (BaseFinder `scripts/gt18_eval.py` on parsed18_v1 / parsed18_v3).
- Re-run the metrics: `cd BaseFinder && python scripts\gt18_eval.py --parse ..\data\basefinder\parsed18_vN [...]
  --md ..\data\basefinder\gt18\EVAL.md`.
- `split.json` (2026-10-09, BaseFinder `scripts/build_real18_train.py`): 20 `train` / 20 `holdout` ids. `gt18_eval.py
  --split holdout` gives the final real number; tune and train only on `train` (grid18_v4 runs trained on it).

## BaseFinder v7: catalog v2, traps, composed ensemble (2026-10-09)

Checkouts (my own, so the shared copies are never touched): `C:\Users\poopl\Development\AlphaClash-Workspace\bf_v5`
(BaseFinder; push from the Mac with remote `srvv5`, receivepack/uploadpack `powershell -NoProfile -Command git ...`,
`receive.denyCurrentBranch updateInstead`) and `ce_v5` (ClashEngineering origin/main; `artifacts\game_data`,
`artifacts\recovered\libg.so` and `artifacts\validation\native_battle_cov_data_ids.json` copied from `ce_synth5`, needed
by the still renderer that BaseFinder's render-and-compare imports through `$CE_ROOT` / ce_v5). BaseFinder's
`bf18_job.py` gained `BF18_GPU` (pin the leased card).

```
data\basefinder\
  models\grid18_v5a, grid18_v5b   66-class (catalog v2) grid models, fine-tuned from grid18_v3 on synth18_v5 (+v1-v4, gt18
                                 train half); final_eval.json = full synth18_v5 val
  models\level18_v2              level + facing + attack-mode crop model (60 types; crops_val.npz kept, crops_train deleted)
  real18_v5\gt_train|gt_holdout  gt18 halves with render-refined affines (diagnostic; NOT used for training)
  gt18\labels_traps\            20 trap-showing screenshots, render-adjudicated (traps labelled; _history\ = v3 seeds)
  gt18\labels_v7\               gt18 labels re-anchored on refined affines with render-only one-tile building fixes
  gt18\EVAL_v7_*.md, eval_v7_*.json, tune_v7_comp_train.json
  parsed18_v5_gt_v5ens|v5comp\   evaluation parses of the 60 GT screenshots (probs\ dumped)
  parsed18_v5\                   THE v7 parse of scraped + scraped2 (composed ensemble, decoder v7, errmaps\, overlays\,
                                 stats.json); shards bf5p0..3 via bf18_job parse --chain 4
```
Production command: `BF_CATALOG=18600v2 bf18_job.py parse ... --decoder v7 --grid-dir models\grid18_v5a models\grid18_v5b
--base-grid models\grid18_v3 --level-dir models\level18_v2 --errmaps --overlays`. Parse cost ~1.7 s / screenshot alone,
~4-5 s per shard with four shards (CPU-bound: register18 scenery stage + CE renders). Details: BaseFinder
`docs/PIPELINE_VERSIONS.md` (v7) and `docs/REGISTER18.md` (render-and-compare check of the registration).
