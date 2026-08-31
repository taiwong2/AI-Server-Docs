"""Deep research on one topic, by the local Qwen model.

    python research_qwen.py --topic-id 03 --out C:\\AI-Server\\out\\llm-efficiency

NOT a single prompt. One turn produces a survey; real depth needs the model to
plan, read, check itself, and only then write. So a topic runs as a PIPELINE:

    SURVEY   map the field -> 3 clusters, each naming specific papers to read
      |
    DIVE x3  one fresh session per cluster: read the actual sources, take notes
      |
    VERIFY   re-check every arXiv id the notes cite actually resolves, and that
             the title matches what was claimed. Produces a correction list.
      |
    SYNTH    write the final report from the notes plus the corrections

**Every phase gets a FRESH session, carrying forward only the distilled notes.**
That is the load-bearing decision. The agent stores full history per session and
a single `web_fetch` returns up to 20k characters, so a six-turn conversation
would bury the model in raw HTML long before the last turn. Passing notes rather
than transcripts keeps each phase's context small and its attention on the task.

The VERIFY phase exists because a 27B model will produce fluent, plausible,
wrong arXiv ids, and a survey full of invented citations looks exactly like a
good one. Checking is cheap; being wrong in a document someone acts on is not.

Runtime is roughly 45-90 min per topic. That is the cost of depth, and it is why
this belongs on the queue rather than in a session.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

QWEN_DIR = r"C:\AI-Server\qwen-agent"
DISCORD_ADMIN = r"C:\AI-Server\scripts\discord_admin.py"
DISCORD_PY = r"C:\Users\poopl\AppData\Local\Programs\Python\Python312\python.exe"
CHANNEL = os.environ.get("RESEARCH_CHANNEL_ID", "1544075375066222652")

N_CLUSTERS = int(os.environ.get("RESEARCH_CLUSTERS", "5"))

# TOTAL budget for notes fed to SYNTH, split across clusters. This is a cap on
# the SYNTH prompt, not on the research: every dive is written to .notes.md in
# full regardless. Raising N_CLUSTERS buys more reading, not a longer prompt --
# which matters because the model's context has to hold this plus its output.
TOTAL_NOTES_CHARS = int(os.environ.get("RESEARCH_NOTES_BUDGET", "60000"))
MAX_NOTES_CHARS = TOTAL_NOTES_CHARS // N_CLUSTERS

SEARCH_RULES = """
SEARCH TOOLS — use them properly:

- `web_search` for orientation, then `web_fetch` to read the ACTUAL source.
- arXiv API, for finding papers:
    http://export.arxiv.org/api/query?search_query=all:%22exact+phrase%22&start=0&max_results=8&sortBy=submittedDate&sortOrder=descending
  QUOTE multi-word phrases (%22...%22) or the API silently ORs the words and
  returns nonsense.
- To read one specific paper: fetch https://arxiv.org/abs/<id>
- Prefer the paper or the official technical report. A blog post counts only
  for something no paper covers.

NEVER invent an arXiv id, a title, a number, or a benchmark result. If you did
not read it, say "not verified". A wrong arXiv id is worse than no citation.
"""

ENTRY_FORMAT = """
Write each technique as EXACTLY this shape:

### <Technique or paper name> (<arXiv id or venue>, <year>)
- **Mechanism:** what it does mechanically, 2-4 sentences. Be specific enough
  that a reader could sketch the implementation.
- **Reported gain:** the measured number AND what it was measured against
  (model, hardware, baseline). If the source gives no number, write
  "no number reported" -- do not estimate one.
- **Cost / limitation:** what it trades away. Everything trades something.
- **Adoption:** shipped in vLLM / SGLang / llama.cpp / TensorRT-LLM / a named
  model, or research-only.
"""


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def clip(text, limit=MAX_NOTES_CHARS):
    """Bound a dive's notes for the SYNTH prompt, keeping BOTH ends.

    A dive can run to 40k characters. Naive head-truncation throws away the
    cluster takeaway, which is the most distilled part and always last. Keep
    two thirds from the front and one third from the back, cutting on entry
    boundaries so no citation is sliced in half.
    """
    if len(text) <= limit:
        return text
    head_n, tail_n = int(limit * 0.66), int(limit * 0.34)
    head, tail = text[:head_n], text[-tail_n:]
    cut = head.rfind("\n### ")
    if cut > head_n * 0.4:
        head = head[:cut]
    cut = tail.find("\n### ")
    if 0 <= cut < tail_n * 0.6:
        tail = tail[cut:]
    return head.rstrip() + "\n\n[... middle of these notes omitted for length; "\
           "the full text is in the .notes.md file ...]\n\n" + tail.lstrip()


TOPICS = {
  "01": ("Quantization",
    "Post-training and quantization-aware methods for LLM weights and activations: "
    "GPTQ, AWQ, SmoothQuant, QuIP#, AQLM, HQQ, FP8 and NVFP4/MXFP4 formats, "
    "1-bit/1.58-bit (BitNet), and KV-cache quantization (KIVI, KVQuant). What breaks "
    "at each bit width, and which formats the RTX 3090 (Ampere, no native FP8) can "
    "actually execute rather than merely store."),
  "02": ("Attention and KV cache",
    "FlashAttention 1/2/3, Multi-Query and Grouped-Query Attention, DeepSeek's "
    "Multi-head Latent Attention (MLA), sliding-window and sparse attention, "
    "PagedAttention, prefix/prompt caching, and KV-cache compression or eviction "
    "(H2O, SnapKV, StreamingLLM). Focus on memory-per-token and long-context cost."),
  "03": ("Mixture of Experts",
    "Sparse MoE for efficiency: Mixtral, DeepSeek-V2/V3 fine-grained and shared "
    "experts, auxiliary-loss-free load balancing, Qwen3 MoE, OLMoE. The gap between "
    "FLOPs saved and wall-clock/VRAM actually saved, expert routing and load "
    "balancing, and why MoE is awkward on a 24GB consumer card."),
  "04": ("Distillation, pruning and small models",
    "Knowledge distillation, structured and depth/width pruning (Sheared LLaMA, "
    "NVIDIA Minitron), and the small-model line: Phi, Gemma, MiniCPM, SmolLM, Qwen "
    "small variants. What transfers from a big teacher to a small student, and the "
    "measured compute saving versus training from scratch."),
  "05": ("Speculative and parallel decoding",
    "Speculative decoding, self-speculation, Medusa, EAGLE 1/2/3, Lookahead decoding, "
    "n-gram/prompt-lookup drafting, multi-token prediction. Acceptance rates, the "
    "interaction with batch size, and the regimes where speculation LOSES to plain "
    "decoding."),
  "06": ("Serving and inference systems",
    "vLLM, SGLang, TensorRT-LLM, llama.cpp and LM Studio: continuous batching, "
    "chunked prefill, prefill/decode disaggregation, RadixAttention prefix reuse, "
    "CUDA graphs, offloading. Separate what matters for a single-user local setup "
    "from what only matters at high QPS."),
  "07": ("Efficient architectures beyond the transformer",
    "State-space and linear-attention models and hybrids: Mamba/Mamba-2, RWKV, Jamba, "
    "and hybrid-attention designs such as Qwen3-Next and MiniMax. Cover the "
    "linear-vs-quadratic claim honestly, including the measured recall and "
    "in-context-retrieval ability these give up."),
  "08": ("Efficient training and fine-tuning",
    "LoRA, QLoRA, DoRA, ReLoRA, and full-model efficiency: ZeRO/FSDP, activation "
    "checkpointing, FP8 and low-precision training, the Muon optimizer, muP transfer, "
    "data-efficiency and curriculum results. Emphasise what is reachable on 2x24GB."),
  "09": ("Long-context efficiency",
    "RoPE scaling and YaRN, position interpolation, ring/sequence-parallel attention, "
    "context compression, retrieval-instead-of-context, and the real cost curve of "
    "128k+ contexts. Include honest evaluation: needle-in-haystack vs RULER vs "
    "LongBench."),
  "10": ("Qwen and frontier model reports",
    "Read the official technical reports and extract their EFFICIENCY engineering "
    "specifically: Qwen2.5, Qwen3, Qwen3-Next, DeepSeek-V3 and R1, Llama 3/4, Gemma "
    "2/3, Mistral. For each: what architectural or training choice was made "
    "explicitly to cut compute, and what number they report for it."),
  "12": ("Kernels and low-level optimization",
    "The layer under the frameworks: Triton, CUTLASS, FlashInfer, custom fused "
    "kernels, torch.compile and CUDA graphs, kernel autotuning, and what fusion "
    "actually buys. Cover why a technique that looks good in a paper often has no "
    "kernel that makes it fast on real hardware, and which kernels exist for Ampere "
    "specifically."),
  "13": ("Measuring efficiency honestly",
    "Benchmarking methodology for LLM inference and training: time-to-first-token vs "
    "inter-token latency vs throughput, why single-stream and batched numbers are not "
    "comparable, warmup and CUDA-graph capture effects, MLPerf Inference, and the "
    "common ways published speedup numbers mislead (different baselines, different "
    "batch sizes, cherry-picked sequence lengths). What a trustworthy benchmark "
    "report must state."),
  "14": ("Retrieval, embeddings and RAG efficiency",
    "The cost of the retrieval half: embedding model size and inference cost, vector "
    "index choices (HNSW, IVF-PQ, ScaNN, DiskANN) and their memory/recall tradeoffs, "
    "late-interaction (ColBERT) vs dense bi-encoders, reranker cost, and when RAG is "
    "cheaper than long context. Include quantized and binary embeddings."),
  "15": ("Agent and multi-turn inference efficiency",
    "Efficiency of agentic and multi-step LLM systems: prefix/KV reuse across turns "
    "and tool calls, context growth over a long agent loop, cost of tool-call "
    "round-trips, caching strategies, routing cheap steps to small models, and "
    "parallel/speculative agent execution. What dominates cost in a real agent loop "
    "versus what people assume does."),
  "16": ("Batching, scheduling and multi-tenancy",
    "Request scheduling for LLM serving: continuous batching internals, iteration-level "
    "scheduling, fairness and SLO-aware scheduling, priority and preemption, "
    "admission control, and the latency/throughput frontier. Cover what changes when "
    "you are the only user versus serving many."),
  "17": ("Low-rank and structural compression",
    "Compression that is not quantization: low-rank factorization (SVD-based, ASVD, "
    "SliceGPT), tensor decomposition, weight sharing and layer tying, early-exit and "
    "layer-skipping architectures, and depth-vs-width tradeoffs. Cover why these have "
    "seen far less adoption than quantization despite comparable paper claims."),
  "18": ("Data efficiency and curation",
    "Getting more from less data: deduplication (exact and near-dup, MinHash), quality "
    "filtering and classifier-based selection, curriculum and data mixing, synthetic "
    "data, and data-constrained scaling laws. What measurable compute or quality is "
    "won per unit of curation effort."),
  "19": ("Scaling laws and compute allocation",
    "Chinchilla and its successors, over-training small models for cheap inference, "
    "inference-aware scaling laws, distillation scaling laws, and how to decide "
    "parameters vs tokens vs test-time compute for a fixed budget. Cover where the "
    "original Chinchilla conclusions have been revised."),
  "20": ("Local and consumer deployment",
    "The practical layer for a home GPU box: llama.cpp/GGUF quantization types (Q4_K_M, "
    "IQ-quants, importance matrices), Ollama and LM Studio, CPU offload and "
    "layer splitting, multi-GPU on consumer boards (PCIe bandwidth, no NVLink on 3090 "
    "without a bridge), unified memory on Apple Silicon vs discrete CUDA, and "
    "speculative decoding in llama.cpp. Concrete and hands-on."),
  "21": ("Energy, thermals and cost per token",
    "Efficiency measured in watts and dollars rather than FLOPs: power limiting and "
    "undervolting GPUs and their effect on tokens/sec, perf-per-watt across "
    "quantization levels, idle draw, cost per million tokens local vs API, and the "
    "reported energy cost of training and serving. Include how to measure this "
    "properly on consumer hardware."),
  "11": ("Reasoning and test-time compute efficiency",
    "Making reasoning models cheaper: adaptive and budgeted thinking, reasoning-effort "
    "controls, chain-of-thought compression, early exit, router-to-small-model "
    "designs, and distilling reasoning into smaller models (R1-distill). Quantify the "
    "accuracy lost per token saved."),
}


# --- phase prompts ---------------------------------------------------------

def survey_prompt(name, scope, n_clusters=N_CLUSTERS):
    blocks = "\n\n".join(
        "## CLUSTER %d: <short name>\nKey questions: <2-3 specific questions this "
        "cluster must answer>\nSources to read:\n- <paper title> (arXiv:<id>) -- "
        "<one line on why it matters>\n- ... (5 to 8 sources, each one you have "
        "ACTUALLY seen in a search result)" % i for i in range(1, n_clusters + 1))
    return f"""You are planning a deep technical literature review for an engineer who
runs local LLMs on two RTX 3090s (Ampere, 24GB each).

TOPIC: {name}
SCOPE: {scope}
{SEARCH_RULES}

YOUR JOB RIGHT NOW IS ONLY TO PLAN. Do not write the review.

Search enough to find out what actually exists in this area, then divide it into
exactly {n_clusters} clusters that a researcher could investigate independently.
Make them genuinely different angles -- do not produce {n_clusters} restatements
of the same question.

Output EXACTLY this structure and nothing else:

{blocks}

Every arXiv id must be one you saw in a real search result. If you are unsure of
an id, give the title and write "(id unverified)" instead of guessing."""


def dive_prompt(name, scope, cluster_text):
    return f"""You are doing the deep reading for one cluster of a technical review.

OVERALL TOPIC: {name}
OVERALL SCOPE: {scope}

YOUR CLUSTER:
{cluster_text}
{SEARCH_RULES}

Read the sources listed above -- actually fetch them, do not work from memory.
Follow up on anything important they cite. If a listed source turns out not to
exist or the id is wrong, say so explicitly and find the right one.
{ENTRY_FORMAT}

Write 4 to 8 entries covering this cluster. Be technical and specific: numbers,
mechanisms, and honest limitations. No filler, no restating the question, no
concluding paragraph about how exciting the field is.

End with:

**Cluster takeaway:** 2-3 bullets on what a practitioner on 2x RTX 3090 should
actually do about this cluster."""


def verify_prompt(name, citations):
    listed = "\n".join("- %s -- claimed title: %s" % (cid, title)
                       for cid, title in citations)
    return f"""You are fact-checking citations in a technical review of "{name}".

Below are arXiv ids that were cited, with the title each was claimed to have.
For EACH one, fetch https://arxiv.org/abs/<id> (or the arXiv API) and compare the
REAL title to the claimed title.

{listed}

Output EXACTLY one line per citation, in this format:

<arxiv-id> | OK | <real title>
<arxiv-id> | WRONG | claimed "<claimed>" but is actually "<real title>"
<arxiv-id> | NOT FOUND | no such paper

Nothing else. No preamble, no summary. Check every single one."""


def synth_prompt(name, scope, notes, corrections=None):
    return f"""Write the final technical review. The research is already done --
everything you need is below. You are only WRITING it up.

TOPIC: {name}

=== RESEARCH NOTES ===
{notes}

Citations have ALREADY been checked and corrected in those notes. Where one is
marked [verified title: ...] use that title. Where one is marked
[CITATION UNVERIFIED] drop the entry or say the citation is unverified. Do not
discuss, reconcile or explain any of this -- it is already settled.

CRITICAL OUTPUT RULES -- read these twice:

- **Your very first line must be exactly:** ## {name}
  Any other first line is a failed response.
- **Do NOT plan out loud.** Do not write "Let me organize", do not list your
  merging decisions, do not narrate which entries you are combining. No
  meta-commentary of any kind. Write the finished document only.
- Merge duplicate techniques across clusters silently, keeping the best version.
- Invent nothing. If a number is not in the notes, it does not appear.

Produce exactly this document:

## {name}

**Why it matters:** 2-3 sentences on what inefficiency this attacks.

Then 6 to 10 entries, each exactly:

### <Technique or paper name> (<arXiv id or venue>, <year>)
- **Mechanism:** 2-4 sentences, specific enough to sketch the implementation.
- **Reported gain:** the number AND its baseline (model, hardware). If the notes
  give none, write "no number reported".
- **Cost / limitation:** what it trades away.
- **Adoption:** named framework or model, or research-only.

**Takeaway for 2x RTX 3090:** 3-5 bullets, ranked by leverage.

**Open questions:** 2-3 things the literature does not settle.

Start writing now, beginning with the "## {name}" line."""


def synth_retry_prompt(name, notes):
    """Stripped to the bone. Used only after a normal synthesis failed to start."""
    return f"""Below are research notes on {name}.

{notes}

Write ONLY a markdown document. Your first line is `## {name}`. Then 6-10 entries,
each starting `### <name> (<arXiv id>, <year>)` with bullets for Mechanism,
Reported gain, Cost / limitation, Adoption. End with `**Takeaway for 2x RTX 3090:**`
and 3-5 bullets.

Do not think out loud. Do not explain. Do not preface. Emit the document and stop.
First characters of your reply: ## {name}"""


# --- helpers ---------------------------------------------------------------

_ARXIV = re.compile(r"arXiv[:\s]*(\d{4}\.\d{4,5})", re.I)
_HEADING = re.compile(r"^###\s+(.+?)\s*$", re.M)
# Our own per-cluster separator, not a paper title. Without this exclusion a
# citation appearing before the first real entry heading gets "claimed title:
# Cluster 1 notes", and VERIFY dutifully reports it as WRONG -- a false
# positive that makes the real mis-citations harder to see.
_OUR_HEADING = re.compile(r"^Cluster \d+ notes$", re.I)


def extract_citations(text, limit=24):
    """(arxiv_id, nearest preceding ### heading) pairs, deduped."""
    heads = [(m.start(), m.group(1)) for m in _HEADING.finditer(text)
             if not _OUR_HEADING.match(m.group(1).strip())]
    seen, out = set(), []
    for m in _ARXIV.finditer(text):
        cid = m.group(1)
        if cid in seen:
            continue
        seen.add(cid)
        title = ""
        for pos, h in heads:
            if pos < m.start():
                title = h
            else:
                break
        out.append((cid, title or "(unknown)"))
        if len(out) >= limit:
            break
    return out


def split_clusters(survey):
    parts = re.split(r"^##\s*CLUSTER\s*\d+\s*:", survey, flags=re.M | re.I)
    return [p.strip() for p in parts[1:] if p.strip()]


_VERDICT = re.compile(r"^\s*(\d{4}\.\d{4,5})\s*\|\s*(OK|WRONG|NOT FOUND)\s*\|?\s*(.*)$",
                      re.M | re.I)


def parse_verdicts(corrections):
    """{arxiv_id: (status, real_title)} from the VERIFY phase's line format."""
    out = {}
    for m in _VERDICT.finditer(corrections or ""):
        cid, status, rest = m.group(1), m.group(2).upper(), m.group(3).strip()
        title = rest
        # "claimed \"X\" but is actually \"Y\"" -> keep Y
        m2 = re.search(r"is actually\s+[\"\u201c]?(.+?)[\"\u201d]?\s*$", rest, re.I)
        if m2:
            title = m2.group(1).strip()
        out[cid] = (status, title.strip(' "\u201c\u201d'))
    return out


def apply_corrections(notes, verdicts):
    """Fix the notes ourselves before SYNTH ever sees them.

    Handing the model a list of WRONG citations and asking it to reconcile them
    is what broke synthesis twice: it deliberates about each one at length and
    burns its whole budget before writing a single heading. This is a mechanical
    substitution, so do it mechanically and give SYNTH clean notes with nothing
    to argue with.
    """
    if not verdicts:
        return notes, 0
    fixed = 0

    def repl(m):
        nonlocal fixed
        cid = m.group(1)
        v = verdicts.get(cid)
        if not v:
            return m.group(0)
        status, title = v
        if status == "OK":
            return m.group(0)
        fixed += 1
        if status == "NOT FOUND":
            return "arXiv:%s [CITATION UNVERIFIED - no such paper found]" % cid
        return "arXiv:%s [verified title: %s]" % (cid, title[:120])

    notes = re.sub(r"arXiv[:\s]*(\d{4}\.\d{4,5})", repl, notes)
    return notes, fixed


def clean_report(report, name):
    """Drop anything before the report's own first heading.

    Even told not to, the model sometimes narrates its plan before writing. The
    document always really begins at a `##` heading, so cut to it. Returns
    (cleaned, had_preamble).
    """
    if not report:
        return "", False
    m = re.search(r"^##\s+.+$", report, re.M)
    if not m:
        return report.strip(), False
    return report[m.start():].strip(), m.start() > 40


def looks_like_a_report(text, name):
    """Cheap structural check. A wall of planning prose is not a report."""
    if not text:
        return False, "empty"
    if not re.search(r"^##\s+", text, re.M):
        return False, "no '##' heading -- model never started the document"
    n_entries = len(re.findall(r"^###\s+", text, re.M))
    if n_entries < 3:
        return False, "only %d '###' entries (need 3+)" % n_entries
    if len(text) < 1500:
        return False, "only %d chars" % len(text)
    return True, "%d entries" % n_entries


def post_to_discord(path):
    try:
        r = subprocess.run([DISCORD_PY, DISCORD_ADMIN, "post",
                            "--channel", CHANNEL, "--file", path],
                           capture_output=True, text=True, timeout=600)
        print("[discord] rc=%s %s%s" % (r.returncode, r.stdout.strip(), r.stderr.strip()),
              flush=True)
        return r.returncode == 0
    except Exception as e:
        print("[discord] FAILED: %r" % e, flush=True)
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--topic-id", required=True)
    ap.add_argument("--out", default=r"C:\AI-Server\out\llm-efficiency")
    ap.add_argument("--deadline-min", type=int, default=150,
                    help="stop starting new phases past this; job_timeout is 180")
    ap.add_argument("--skip-verify", action="store_true")
    a = ap.parse_args()

    if a.topic_id not in TOPICS:
        raise SystemExit("unknown topic-id %r; have %s"
                         % (a.topic_id, ",".join(sorted(TOPICS))))
    name, scope = TOPICS[a.topic_id]

    os.environ.setdefault("QWEN_REASONING_EFFORT", "medium")
    os.environ.setdefault("QWEN_MAX_TOKENS", "20000")
    # Per-PHASE cap. Six phases at 900s each stays inside job_timeout_minutes.
    # Must be set before `agent` imports config, which reads it once.
    os.environ.setdefault("QWEN_TURN_TIME_BUDGET_SEC", "900")

    sys.path.insert(0, QWEN_DIR)
    import agent  # noqa: E402

    t_start = time.time()
    sess = "deep-%s-%d" % (a.topic_id, int(t_start))

    def elapsed_min():
        return (time.time() - t_start) / 60.0

    def run(phase, prompt):
        """One phase, in its own session, so context never accumulates."""
        print("\n[%s] starting (%.0f min elapsed)" % (phase, elapsed_min()), flush=True)
        t0 = time.time()
        ans = agent.run_turn("%s-%s" % (sess, phase), prompt,
                             on_step=lambda s: print("    %s" % s, flush=True))
        print("[%s] %d chars in %.0fs" % (phase, len(ans or ""), time.time() - t0),
              flush=True)
        return ans or ""

    # --- SURVEY ---
    survey = run("survey", survey_prompt(name, scope))
    clusters = split_clusters(survey)
    if not clusters:
        # The model ignored the format. Rather than fail the topic, fall back to
        # three generic slices of the scope so the dives still happen.
        print("[survey] no clusters parsed; falling back to generic slices", flush=True)
        clusters = ["%s\nKey questions: cover this thoroughly.\nSources to read: "
                    "search for them.\n(part %d of %d)" % (scope, i + 1, N_CLUSTERS)
                    for i in range(N_CLUSTERS)]
    print("[survey] %d clusters" % len(clusters), flush=True)

    # --- DIVES ---
    notes = []
    for i, cluster in enumerate(clusters[:N_CLUSTERS], 1):
        if elapsed_min() > a.deadline_min:
            print("[dive] deadline reached, stopping after %d clusters" % (i - 1),
                  flush=True)
            break
        text = run("dive%d" % i, dive_prompt(name, scope, cluster))
        if text.strip():
            notes.append("### Cluster %d notes\n\n%s" % (i, clip(text.strip())))

    if not notes:
        raise SystemExit("no cluster notes produced -- failing so the queue retries")

    all_notes = "\n\n".join(notes)

    # --- VERIFY ---
    corrections = ""
    citations = extract_citations(all_notes, limit=40)
    if citations and not a.skip_verify and elapsed_min() < a.deadline_min:
        print("[verify] checking %d citations" % len(citations), flush=True)
        corrections = run("verify", verify_prompt(name, citations))
    else:
        print("[verify] skipped (%d citations, %.0f min elapsed)"
              % (len(citations), elapsed_min()), flush=True)

    # --- SYNTH ---
    verdicts = parse_verdicts(corrections)
    all_notes, n_fixed = apply_corrections(all_notes, verdicts)
    print("[verify] parsed %d verdicts, corrected %d citations in the notes"
          % (len(verdicts), n_fixed), flush=True)

    report = run("synth", synth_prompt(name, scope, all_notes))
    report, had_preamble = clean_report(report, name)
    if had_preamble:
        print("[synth] stripped a preamble the model emitted before the report",
              flush=True)

    ok, why = looks_like_a_report(report, name)
    print("[synth] structure check: %s (%s)" % ("PASS" if ok else "FAIL", why), flush=True)

    if not ok and elapsed_min() < a.deadline_min:
        # The dives are the expensive part and they are already done. One more
        # attempt with a stripped prompt is far cheaper than failing the topic
        # and re-running an hour of research.
        print("[synth] retrying with a minimal prompt", flush=True)
        report2 = run("synth2", synth_retry_prompt(name, all_notes))
        report2, _ = clean_report(report2, name)
        ok2, why2 = looks_like_a_report(report2, name)
        print("[synth2] structure check: %s (%s)" % ("PASS" if ok2 else "FAIL", why2), flush=True)
        if ok2:
            report, ok, why = report2, ok2, why2

    if not ok:
        # Save the bad output for inspection, then fail so the queue retries the
        # whole topic rather than archiving a plan as if it were a review.
        os.makedirs(a.out, exist_ok=True)
        with open(os.path.join(a.out, "%s-%s.FAILED.md" % (a.topic_id, slug(name))),
                  "w", encoding="utf-8") as f:
            f.write(report or "(empty)")
        raise SystemExit("synthesis did not produce a report (%s) -- failing so the "
                         "queue retries" % why)

    os.makedirs(a.out, exist_ok=True)
    dest = os.path.join(a.out, "%s-%s.md" % (a.topic_id, slug(name)))
    header = (
        "# %s. %s\n\n"
        "*Deep research by `qwen3.8-27b-uncensored` via the local qwen-agent, %s.*\n"
        "*Pipeline: survey -> %d cluster dives -> citation verification -> synthesis, "
        "%.0f min.*\n\n" % (a.topic_id, name, time.strftime("%Y-%m-%d"),
                            len(notes), elapsed_min()))
    body = header + report.strip() + "\n"

    with open(dest, "w", encoding="utf-8") as f:
        f.write(body)
    print("[research] wrote %s" % dest, flush=True)

    # Keep the raw notes and the verification log: the report is a summary of
    # them, and when a number looks wrong this is where you check it.
    with open(os.path.join(a.out, "%s-%s.notes.md" % (a.topic_id, slug(name))),
              "w", encoding="utf-8") as f:
        f.write("# %s -- raw research notes\n\n## Survey\n\n%s\n\n## Notes\n\n%s\n\n"
                "## Citation verification\n\n%s\n"
                % (name, survey, all_notes, corrections or "(not run)"))

    post_to_discord(dest)
    print("[research] done in %.0f min" % elapsed_min(), flush=True)


if __name__ == "__main__":
    main()
