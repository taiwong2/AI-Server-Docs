# Creative writing endpoint

Stories, poems, scenes and lyrics from **Gemma 4 12B** (`google/gemma-4-12b`),
served by the model proxy on port 1235.

```
POST http://ai-server:1235/v1/creative/write      # Tailscale
POST http://192.168.1.24:1235/v1/creative/write   # LAN
```

Same API key as every other proxy route (`Authorization: Bearer <key>`; keys
live in `C:\AI-Server\scripts\.api-key`). It also shows up in the proxy's
interactive docs at `/docs`.

## Use

```bash
curl http://ai-server:1235/v1/creative/write \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"prompt": "A lighthouse keeper finds a letter addressed to a drowned man",
       "tone": "melancholy, quietly hopeful", "length": "short"}'
```

```json
{"text": "...", "words": 780, "model": "google/gemma-4-12b",
 "finish_reason": "stop", "usage": {"prompt_tokens": 180, "completion_tokens": 979}}
```

Check `finish_reason`. `"length"` means the piece was cut off — raise
`target_words` or shorten `continue_from`.

## Fields

| Field | Default | Notes |
|---|---|---|
| `prompt` | *(required)* | Premise, characters, a first line — anything |
| `form` | `story` | `story`, `flash_fiction`, `scene`, `poem`, `dialogue`, `song_lyrics`, `monologue`, `freeform` |
| `genre`, `tone`, `style`, `pov`, `audience`, `instructions` | — | Free text, folded into the prompt |
| `length` | `medium` | `short` ~250 words, `medium` ~700, `long` ~1800 |
| `target_words` | — | 20–4000; overrides `length` |
| `continue_from` | — | An existing draft. The reply contains only the new text |
| `think` | `false` | Let Gemma plan before writing. Slower; adds 2000 tokens of budget |
| `temperature` / `top_p` | 0.9 / 0.95 | |
| `frequency_penalty` | 0.2 | Damps repeated phrasing |
| `presence_penalty`, `seed` | — | Passed through |
| `stream` | `false` | OpenAI-style SSE chunks (`choices[0].delta.content`) |
| `model` | `google/gemma-4-12b` | Any LM Studio model, e.g. `gemma4-12b-qat-uncensored-hauhaucs-balanced` |

`max_tokens` is derived from the word target (`words × 1.6 + 200`), so you do
not set it.

## Gemma 4 is a thinking model — the trap this endpoint handles

Called raw through `/v1/chat/completions`, Gemma 4 spends the **entire**
`max_tokens` budget on hidden reasoning and returns `content: ""` with
`finish_reason: "length"`. A 400-token request measured 397 reasoning tokens
and no story.

Measured 2026-09-24 against LM Studio, which switches actually turn it off:

| Request field | Result |
|---|---|
| `"reasoning_effort": "none"` | **works** — 0 reasoning tokens, 131-token story, `stop` |
| `"reasoning": {"effort": "none"}` | ignored — all reasoning, empty content |
| `"chat_template_kwargs": {"enable_thinking": false}` | ignored |
| `"reasoning": "off"` | ignored |

The endpoint sends `reasoning_effort: "none"` unless `think: true`. If you call
Gemma 4 through the plain chat route, send it yourself.

## Performance

| Test (2026-09-24) | Result |
|---|---|
| 700-word story | 780 words, 61 s, finish `stop` |
| Short poem, streamed | 20 s, 303 chunks |
| 200-word continuation | 175 words, 17 s |

That is ~16 tok/s, and it was measured **while two training runs held both
GPUs** (GPU 1 had 52 MB free). Expect considerably faster on an idle box.

## Things to know

- **Model loading.** The endpoint loads Gemma with a 16k context so long pieces
  fit. If Gemma was already loaded by another route at LM Studio's default
  4096, it is reused as-is and a `long` piece may truncate — unload it
  (`POST /proxy/models/unload`) and call again.
- **One model at a time.** Like every proxy route, loading Gemma unloads
  whatever else is in LM Studio — including the Qwen model the Discord
  `qwen-*` channels use.
- **No GPU lease.** The proxy loads models without taking a
  [GPU lease](03-gpu-leasing.md). It can land on a card a training run has
  claimed, and both slow down. This predates the endpoint.

## Where it lives

- Route: `/v1/creative/write` in `C:\AI-Server\scripts\model-proxy.py`
  (backup of the pre-change file: `model-proxy.py.bak-20260924`).
- The proxy is started by `start-services.ps1` in the interactive session. To
  restart it after an edit, kill the process on port 1235 and relaunch it in
  session 1 — a process started from an SSH session dies when SSH disconnects.
- Requests are logged to `C:\AI-Server\logs\model-proxy.log` as
  `Creative: form=… words=… think=… stream=…`.
