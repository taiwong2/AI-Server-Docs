# as1-llm-policy.ps1: AI Server 1 is GPU training only and serves NO LLM (user decision 2026-10-12: "boot off
# antoines lm studio model and also migrate everything over to ai server 2. so no llm stuff should run there unless
# specified"). Every script that could load a model here (LM Studio, llama-host, child host, model proxy, Flash
# benches) dot-sources this file and calls Assert-AS1LlmAllowed first.
# LLM work goes to Flash-Next on AI Server 2 through the relay (scripts\as2_llm_relay.py, task \AI-LLMRelay):
#   AS1 consumers  http://127.0.0.1:1240/v1      Antoine / pp-antoine  http://127.0.0.1:1234/v1
# Override ONLY when the user explicitly asks for an LLM on AS1: create C:\AI-Server\state\as1-llm.allowed (write who
# asked and why in it), and delete it afterwards.
$script:AS1LlmMarker = 'C:\AI-Server\state\as1-llm.allowed'
function Test-AS1LlmAllowed { return (Test-Path $script:AS1LlmMarker) }
function Assert-AS1LlmAllowed([string]$What = 'this LLM action') {
    if (Test-AS1LlmAllowed) { return }
    $msg = "REFUSED: $What. AI Server 1 is GPU training only and serves no LLM (user decision 2026-10-12). " +
           "Use Flash-Next on AI Server 2 through the relay http://127.0.0.1:1240/v1 (it switches AI Server 2's LLM mode " +
           "on by itself). Only if the user explicitly asks for an LLM on AI Server 1: create $script:AS1LlmMarker."
    try { Add-Content -Path 'C:\AI-Server\logs\as1-llm-policy.log' -Value "$(Get-Date -Format s) $What (refused)" } catch {}
    throw $msg
}
