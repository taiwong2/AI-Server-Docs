# Clash model archive (Google Drive)

Set up 2026-10-11 (Tai: "can you setup automatic model archiving in google drive"). Every 2 hours AI Server 1 copies
the Clash models that matter into Google Drive, so a later reader can find and reload them even after the hosts prune
or lose their checkpoints. The originals are never moved or deleted.

| | |
|---|---|
| Task | `AI-ModelArchive` (AI Server 1, poopl, Interactive, every 2 h, idle CPU + background IO priority, pass <= 100 min, killed at 115) |
| Engine | `C:\AI-Server\scripts\model_archive.py` (+ `model_archive_sources.json`, `model_archive.ps1`). Source of truth: ClashEngineering `ops/aiserver/` (copy them over after a change) |
| Archive | `G:\My Drive\AI-Server-Archive\Models\<family>\<run>\<file>`, families `attacker`, `designer`, `league`, `basefinder` |
| Index | `Models\README.md` (contents, official models, run finals) and `Models\<family>\manifest.jsonl` |
| State | `C:\AI-Server\state\model-archive\state.json` (hash cache, archived set, milestones, rolling lists) |
| Logs | `C:\AI-Server\logs\model-archive\archive.log`, `status.txt` (one line), `skipped.jsonl`, `manifests\` (local copies) |
| AS2 access | key `C:\AI-Server\state\ssh\model-archive_ed25519`, authorized on AI Server 2 with `from="100.71.113.77",command="/usr/local/bin/model-archive-ssh"` (read-only: `list`, `sha256`, `cat` of model files under `~/ClashRuns`, `~/Documents/ClashRuns`, `~/AlphaClash-Workspace/data`) |

## Drive quota vs "17 GB free"

`dir G:\` reports the free space of **C:** (Drive for desktop streams through its cache on C:), not the Drive quota.
The account quota, read from DriveFS's cached account record (`metadata_sqlite_db`, property `driveway_account`), is
**10 TiB (10.99 TB), 0.53 TB used** on 2026-10-11. The real limit is C:: bytes written to G: sit in the DriveFS cache
on C: until uploaded, and C: had only 18-24 GB free. So the engine copies a file only while C: keeps 8 GB free and
the written-but-not-yet-uploaded backlog stays under 1.5 GB, and it writes at most 2.5 MB/s (about what AI Server 1's
uplink uploads) so the upload never saturates the uplink for long. AS2 pulls are capped at 4 MB/s.

## What gets archived (policy)

Sources (`model_archive_sources.json`): AI Server 1 `AlphaClash-Workspace\data\{attv3, designer\runs, designer_ar\runs,
league, basefinder\models, basefinder\reg18}`, clash-sim `~/Documents/ClashRuns` + `~/ClashRuns` (read through
`\\wsl.localhost\clash-sim`), AI Server 2 `~/Documents/ClashRuns`, `~/ClashRuns`, `~/AlphaClash-Workspace/data/...`.
Excluded: `*smoke*`, `*.aborted*`, `torch_home`, `colab_stage`, `old/`. Each model file is classified:

- **training run** (`<run>/checkpoints/<step>.pt`, merged across hosts by run name): a **milestone** every 250k steps
  (the earliest checkpoint of each 250k bucket), the **final** (highest step) once the run has had no new checkpoint
  for 6 h, and while it is active a **rolling** latest: the newest 3 are kept in `<run>\rolling\`, older rolling copies
  are deleted from the archive only;
- **run dir** with `final/last/best.pt` (designer self-train rounds, BaseFinder, SFT anchors): all its files once it
  has `final.pt`/`DONE` or is idle 6 h (class final), else rolling;
- **any other model file** (judge `ca4_judge_v1`, SFT anchors `ca4_v4`, frozen attackers, orbit inits): **official**.

Content is deduplicated by sha256 across hosts and families (a duplicate source gets a manifest row with `dup_of`).
A file modified in the last 3 minutes is skipped as still being written; a copy is accepted only if the received bytes
hash to the source's sha256 (AS2 hashes its side at nice 19 / idle IO), then it counts as uploaded once DriveFS's DB
shows Google's md5 equal to ours. Quota rules (never silent; every skip goes to `skipped.jsonl`): below 200 GB free
rolling copies are skipped, below 50 GB milestones too, below 10 GB everything but official models. Items that do not
fit in a pass (time, C: room, 20 GB per pass) are deferred to the next pass.

Each run folder also gets `config.<host>.json` (the run config, with the ClashEngineering commit, which the manifest
copies into `commit`) and, for training runs, `checkpoints-index.<host>.jsonl`.

Colab outputs: they land on AI Server 2 (`~/ClashRuns/designer/runs/grid15*`, `~/ClashRuns/attv3/sftv5/...`) and are
archived from there. Run dirs that exist only on the Mac (`~/Documents/ClashRuns/*colab*`) are not a source (the Mac
does no work for this).

## Commands (AI Server 1)

```
python C:\AI-Server\scripts\model_archive.py status            # counts/GB per family+class, pending uploads, quota, last pass
python C:\AI-Server\scripts\model_archive.py run --dry-run     # what the next pass would consider
python C:\AI-Server\scripts\model_archive.py verify --n 5      # read back from G:, check sha256 + Google's md5
python C:\AI-Server\scripts\model_archive.py restore <sha256-prefix | attacker/<run>/<file>> <dest dir>
powershell -File C:\AI-Server\scripts\model_archive.ps1 [-Status | -RunNow | -Disable | -Install]
```

Restore elsewhere: find the row in `Models\<family>\manifest.jsonl` (or `README.md`), download the file from Drive
(My Drive / AI-Server-Archive / Models / ...), check `sha256sum` against the row, and load it with
`torch.load(path, map_location="cpu")` in the commit named by the row (`config.<host>.json` has the full run config).

## Adding a source

Add `{"host": "as1" | "clash-sim" | "as2", "root": "...", "label": "..."}` to `model_archive_sources.json` in
ClashEngineering, merge, copy the file to `C:\AI-Server\scripts\`. AS2 roots must be under the forced command's allowed
roots (edit `ops/strixhalo/model-archive-ssh` and reinstall it with `sudo install -m 755 ... /usr/local/bin/` if not).

## First run (2026-10-11 20:29)

368 candidate files on the three hosts, 314 unique (21.25 GB after sha256 dedupe). The first pass copies ~14 GB in its
100 minutes (2.5 MB/s), the next pass finishes the backlog; after that a pass moves only new milestones, finals and the
rolling latest (tens to hundreds of MB). `verify --n 4` and `restore df3946b6` (the `ca4_judge_v1` judge) round-tripped
with matching sha256 and Google md5.
