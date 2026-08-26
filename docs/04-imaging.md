# Imaging

Background extension and super-resolution on the local 3090s. Originals are
never overwritten.

Two entry points, sharing one geometry contract and one set of weights:

| | |
|---|---|
| `tools/imaging/enhance_file.py` | a loose file — a screenshot, an asset someone sent |
| `tools/imaging/run_pipeline.py` | catalog products keyed by EAN, with a ledger and an approval gate |

Both live in the `korean-Pharmacy-Workspace` repo. `enhance_file.py` *composes*
`run_pipeline`'s `classify`/`upscale` and `extend_bg`'s `extend` rather than
reimplementing them, so the contract cannot drift between them.

## Running it

```bash
PY="C:/Users/poopl/miniconda3/envs/ai/python.exe"     # deps live ONLY here

$PY tools/imaging/enhance_file.py IMG --out DIR          # square + upscale
$PY tools/imaging/enhance_file.py *.jpg --out DIR        # a batch
$PY tools/imaging/enhance_file.py IMG --out DIR --dry    # decide, change nothing
$PY tools/imaging/enhance_file.py IMG --out DIR --no-extend   # upscale only
$PY tools/imaging/enhance_file.py IMG --out DIR --json   # machine-readable
```

Or queue it, which is better for anything large or when the box may be asleep:

```bash
python C:\AI-Server\scripts\jobqueue.py submit --kind image \
    --arg Src="C:\pics\shot.jpg" --arg Out="C:\AI-Server\out\shot"
```

`Src` takes a file, a directory, or a comma-separated list.

## What it decides

| Input | Action |
|---|---|
| Long edge < 900px | DAT-2 ×4 **first**, so extension sees real pixels |
| Long edge < 2000px | DAT-2 ×2 first |
| Corner-white packshot | padded to square with white — a white ring on white is a no-op |
| Background reaches every edge | deterministic `extend_bg` to 1:1, 30% bleed |
| A subject touches the frame edge | **refused**, with a pointer to `genfill.py` |
| Over 4472px after all that | downscaled — Shopify rejects ~25 MP |

The refusal matters. Edge statistics continue a *background*; asked to continue
a hand or a hairline they smear. `--force` overrides it, after you have looked
at the image.

## The upscaler

`4xRealWebPhoto_v4_dat2` (DAT-2 via spandrel), weights at
`C:\AI-Server\models\sr\`. It replaced Real-ESRGAN after measurement: on small
print, Real-ESRGAN scored **worse than doing nothing** — character error rate
0.752 versus 0.562 for the raw source and 0.388 for plain Lanczos. It turned
"medicube" into "medlcube". DAT-2 runs in bf16 because it artifacts in fp16.

## Rules

- **Never overwrite an original.** Output goes to `--out`, always a new file.
- **Do not invent detail.** Upscaling sharpens what is there. If the source is a
  58×148 thumbnail, the honest answer is "find a better source", not a 4000px
  hallucination of one.
- **No brand names into any generative path.** A captioner that reads a label
  and feeds it to a diffusion model produces counterfeit packaging.
- **Look at the output.** Extension is statistical and can look wrong. A seam, a
  smear, or a repeated texture band means the image belonged in `genfill`.

## Not yet proven

Automated quality gates have failed here three separate times — a face detector
passed an invented face, a depth/edge gate scored a smearing arm as safe, and a
12B vision judge approved five images an adversarial reviewer rejected. Treat
any automated "this looks fine" as advisory. Render a contact sheet and look.
