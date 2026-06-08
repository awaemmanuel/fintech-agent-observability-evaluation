# Student Guide — Agent Observability, Evaluation & Safety
### Your reference for the 4-hour workshop

You're going to take one multi-agent app — a FinTech support bot for **SecureBank** — and
harden it the way you'd harden any production service: make it **observable**, **testable**,
**safe**, and **affordable**. Four disciplines you already know from normal software,
rebuilt for a component that fails *silently and confidently*: a language model.

```
   DEPLOY → OBSERVE (A) → EVALUATE (B) → GUARD (C) → OPTIMIZE (D) → repeat
             see it        measure it     secure it    afford it
```

> **The one idea to keep:** *You can't evaluate or secure what you can't see.*
> Observability comes first; everything else builds on traces.

---

## Setup (do this before the workshop)

1. **Python 3.12** venv (not 3.13/3.14 — `tiktoken` and `chroma-hnswlib` have no wheels yet).
   ```bash
   python3.12 -m venv .venv && source .venv/bin/activate    # Win: py -3.12 -m venv .venv
   python -m pip install --upgrade pip
   ```
2. **Install dependencies** — pick one:
   ```bash
   # Recommended — one step, no version conflicts:
   pip install --no-deps -r requirements.lock

   # Or, the editable path (then you MUST run the fix below):
   pip install -r requirements.txt
   bash scripts/fix-deps.sh        # Win: powershell -ExecutionPolicy Bypass -File scripts\fix-deps.ps1
   ```
   > **Why the fix?** `guardrails-ai` pulls in `langchain-core` 1.x, which breaks the
   > `langchain` 0.3.x the agent uses → `ImportError: cannot import name 'PipelinePromptTemplate'`.
   > `fix-deps` re-pins it. The `requirements.lock` path avoids the conflict entirely.
3. **API keys** — copy `.env.example` to `.env`, fill in:
   ```env
   OPENAI_API_KEY=sk-...                  # must have credits — powers ~everything
   LANGCHAIN_API_KEY=lsv2_pt_...          # free at smith.langchain.com
   LANGCHAIN_TRACING_V2=true
   LANGCHAIN_PROJECT=fintech-support-agent
   ```
4. **Module C extras:**
   ```bash
   python -m spacy download en_core_web_lg          # ~560 MB, Presidio NER
   guardrails configure                              # free token from hub.guardrailsai.com/keys; say YES to remote inferencing
   guardrails hub install hub://guardrails/regex_match
   guardrails hub install hub://guardrails/toxic_language
   guardrails hub install hub://guardrails/competitor_check
   bash scripts/fix-deps.sh                          # IMPORTANT: hub installs re-break langchain — re-pin LAST
   ```
   > If `ToxicLanguage` later imports as "no attribute", that's the local-model post-install
   > failing (needs `torch>=2.4`) — harmless with remote inferencing on. The repo's
   > `.guardrails/hub_registry.json` already registers it.
5. **Smoke test** (run from the repo **root**, always):
   ```bash
   python module_a_observability/demo.py
   ```
   If traces show up in LangSmith, you're ready.

> **Golden rules:** (1) run every script from the **repo root** (scripts resolve
> `project/documents/` relative to root). (2) **Activate the venv** before any `pip`.
> (3) `fix-deps` is always the **last** step — every `pip`/`guardrails hub install`
> re-breaks langchain-core.

---

## The system you're hardening

> **Deep dive:** for a top-to-bottom walkthrough of the provided agent code, see
> [agent-walkthrough.md](agent-walkthrough.md) — it explains every part of
> `project/fintech_support_agent.py` (the one file you don't write).

```
Customer query
     │
     ▼
 SUPERVISOR  ── classifies intent (one LLM call) ──┐
                                                   │
        ┌──────────────┬───────────────────────────┤
     "policy"   "account_status"            "escalation"
        ▼              ▼                          ▼
  POLICY AGENT   ACCOUNT AGENT             ESCALATION AGENT
  RAG over 4     regex → mock DB           empathy only,
  policy docs    lookup, LLM formats       no data retrieval
  (Chroma)
```

- It's a **LangGraph** state machine. A shared `SupportState` dict flows through; each
  node returns a partial dict that gets merged in. Think reducer / typed state machine.
- **Every query = at least 2 LLM calls** (supervisor + one specialist). Remember this for
  cost and for reading traces.
- `temperature=0` everywhere for reproducibility — but note: temp=0 is **not** fully
  deterministic. That matters in evaluation.

**Test accounts:**

| ID | Name | Type | Balance | Status |
|---|---|---|---|---|
| ACC-12345 | Alice Johnson | Premium Checking | $12,450.75 | active |
| ACC-67890 | Bob Smith | Basic Checking | $234.50 | active |
| ACC-11111 | Carol Davis | High-Yield Savings | $85,320.00 | **frozen** (fraud) |

**Key policy numbers** (the RAG docs; you'll evaluate against these):

| Fact | Value |
|---|---|
| Overdraft fee | $35/transaction, max 3/day ($105) |
| Overdraft *protection* | $12/transfer (different product!) |
| Premium Checking monthly fee | $12.99, waived if balance > $1,500 or DD ≥ $500/mo |
| Out-of-network ATM | $3.00 |
| Domestic wire (outgoing) | $25 (incoming free) |
| International wire | $45 out / $15 in |
| Personal loan | credit score ≥ 620, APR 6.99–24.99% |
| Auto loan APR | 4.49–12.99% new / 5.49–14.99% used |
| Loan late fee | $39 or 5%, after 15-day grace |
| Fraud reporting | within 60 days; within 2 business days caps liability at $50 |

**How the vector store works** (Policy Agent only — Account does a DB lookup, Escalation has no data):

```
project/documents/*.md → chunk (RecursiveCharacterTextSplitter) → embed (text-embedding-3-small, 1536-dim) → Chroma (in-memory) → retriever (top_k)
```

- **In-memory, rebuilt every run** — no persistence; each `build_support_agent()` re-reads,
  re-chunks, and re-embeds. Clean + reproducible; costs a few seconds + a tiny embedding charge.
- **Embedding model ≠ chat model** — `text-embedding-3-small` is a separate OpenAI cost line.
- **Tunables: `chunk_size`, `chunk_overlap`, `top_k`** — the RAG levers you adjust for quality
  (Module B / MRR) and cost (Module D). Defaults: `1000` / `100` / `3`.
- **`chroma-hnswlib`** (the HNSW index) is the C++ package that needs a compiler at install.

---

## Diagrams

Visual reference for each module (rendered from Graphviz, in [`diagrams/`](diagrams/)):

![Architecture](diagrams/01-architecture.svg)

![Hardening loop](diagrams/02-hardening-loop.svg)

| | |
|---|---|
| ![Trace tree](diagrams/03-module-a-trace.svg) | ![Eval layers](diagrams/04-module-b-layers.svg) |
| ![Guarded pipeline](diagrams/05-module-c-pipeline.svg) | ![Cost structure](diagrams/06-module-d-cost.svg) |

---

# Module A — Observability

**Goal:** turn "the AI gave a wrong answer" into "the *retriever* fetched the wrong
document" — a specific, fixable bug.

### The problem: silent, confident failure

A normal bug crashes and hands you a stack trace. An LLM bug returns *"The overdraft fee
is $25"* (it's $35) — plausible, confident, nothing thrown, monitoring green. With five
possible failure points, you can't tell which broke from the answer alone:

```
Wrong answer → which layer?
  supervisor misrouted? · retriever wrong doc? · right doc ranked low?
  · LLM hallucinated? · too much context confused it?
```

A **trace** answers this in seconds.

### Three things people confuse

| | Captures | Answers |
|---|---|---|
| **Logging** | flat events | "Did X happen?" |
| **Monitoring** | aggregates (p95, error rate) | "Healthy on average?" |
| **Observability** | per-request trees (I/O, tokens, latency) | "Why did **this** request fail?" |

Averages hide individual failures — "avg 900ms" can be 95% fast + 5% at 8 seconds. You
need per-trace observability to debug; monitoring only spots trends.

### LangSmith in one env var

LangSmith is a standalone platform (not LangChain). Because LangChain/LangGraph are
auto-instrumented, you flip one switch and everything is traced:

```python
import os
os.environ["LANGCHAIN_TRACING_V2"] = "true"   # + LANGCHAIN_API_KEY
# raw OpenAI?  client = wrap_openai(OpenAI())
# any function? @traceable
```

### Vocabulary
- **Trace** = one request end-to-end (one query). · **Run** = one step inside it (LLM /
  retriever / node call). One trace, many runs, in a parent-child tree.

### The debugging skill (this is what you're learning)

```
Wrong answer → open the trace tree
  ├─ Supervisor routed wrong?    → fix routing prompt
  ├─ Retriever got wrong docs?   → fix embeddings / chunk_size / k
  ├─ Right docs ranked too low?  → increase k / rerank
  └─ Right docs, wrong answer?   → hallucination → strengthen prompt
```

### Tagging & sampling
Tag runs to slice them later; sample in production (free tier = 5,000 traces/mo):
```python
app.invoke(inputs, config={"tags": ["agent-type:policy", "version:v2"]})
# dev/staging: 100% tracing · prod: 10–20%, 100% only during an incident
```

### Your exercise (`exercise.py`)
Enable tracing → build the agent → run policy/account/escalation queries → **answer 5
questions by reading the LangSmith UI** (which agent, # LLM calls, priciest call's tokens,
latency, retrieved docs) → run `ACC-99999` and trace the not-found path → tag your runs.

Note: the not-found case is a graceful return, **not** an exception — in the trace it
looks like a normal completed run. Agent "errors" are often valid-looking outputs, which
is exactly why you inspect them.

### Self-check
1. Why can't you debug an LLM failure from the final answer alone?
2. Trace vs run — which contains which?
3. A policy query returned the wrong fee. The retriever's output shows `account_fees.md`
   *with* "$35" in the chunk. Which layer failed, and what do you fix?

---

# Module B — Evaluation

> **Dataset deep dive:** [eval-dataset-walkthrough.md](eval-dataset-walkthrough.md) explains
> `module_b_evaluation/eval_dataset.py` — the two datasets (general + hill-climb), the example
> format, and why coverage is designed the way it is.

**Goal:** measure quality across many cases, per layer, and prove a change helped — the
hill-climbing loop.

### Why it's hard: five layers, and they cascade

```
1. ROUTING       right agent?     ← if wrong, nothing downstream matters
2. RETRIEVAL     right docs?
3. RANKING       right doc ranked high?
4. FAITHFULNESS  grounded, not hallucinated?
5. CORRECTNESS   matches the truth?
```

**Fix routing first.** If the supervisor misroutes, even a perfect specialist gives a
useless answer. One "is it good" score hides which layer broke — use a metric per layer.

### Datasets = test fixtures

```python
{"inputs":  {"question": "What is the overdraft fee?"},
 "outputs": {"answer": "$35/transaction, max 3/day ($105).", "intent": "policy"}}
```
Good datasets cover **every** agent path, include boundaries ("I hate these fees!" —
policy or escalation?), edge cases (`ACC-99999`), and **refusals** (out-of-scope "what
stock should I buy?"). 15 sharp examples beat 200 happy-path ones.

### Evaluators = assertions that return a float

```python
def routing_evaluator(run, example):
    return {"key": "routing_accuracy",
            "score": 1.0 if run.outputs.get("intent") == example.outputs.get("intent") else 0.0}
```
Two families:
- **Deterministic / free** — routing (exact match), `keyword_correctness` (regex the
  dollar amounts out of the expected answer, check they appear). Fast, but only catches
  *missing numbers*, not *wrong meaning*.
- **LLM-as-judge** — `faithfulness`, `correctness`. A separate LLM scores 0–1 (it's
  unbiased vs the generator, but costs tokens and is itself noisy — never trust one run).

### ⚠️ Faithfulness ≠ Correctness (the trap)
- **Faithful** = grounded in the context you retrieved.
- **Correct** = matches the truth.

Retriever pulls the *wrong* doc, LLM summarizes it accurately → **faithfulness 1.0,
correctness 0.0**. You need both: faithfulness catches hallucination, correctness catches
retrieval errors.

### MRR — retrieval quality (a ranking metric)

$$MRR = \frac{1}{|Q|}\sum_i \frac{1}{\text{rank}_i}$$

```
right doc at rank 1 → 1.0 · rank 2 → 0.5 · rank 3 → 0.33 · not found → 0
MRR = average of those.   1.0 perfect · >0.8 good (prod target) · <0.5 unreliable
```
Measures **retrieval, not generation**. Rewards getting the right doc to the *top* — for
RAG you usually only need one good chunk, and rank-1 docs drive the answer.

### A/B + hill climbing (the core workflow)

Change **exactly one variable**, re-measure, compare:
```
v1: chunk_size=100,  top_k=1   → fragments, numbers split → keyword_correctness ~0.55–0.65
v2: chunk_size=1500, top_k=1   → whole section in one chunk → ~0.80–0.90
routing_accuracy stays 1.0 (unaffected, as expected)
```
Loop: **fix the worst metric → change one thing → re-measure → confirm → repeat**, while
watching that other metrics don't regress.

**`num_repetitions=3`:** temp=0 isn't deterministic, so a single run is noisy (0.72 then
0.58 on the *same* agent). Run each example 3×, average — otherwise you'll pick the wrong
version on luck.

This is **offline** eval (fast, reproducible) — not production A/B testing (traffic
splitting + statistical significance over weeks).

### DeepEval & G-Eval (CI/CD)
- **DeepEval** — pytest-native, 50+ pre-built metrics; run as tests that fail the build.
  ```python
  assert_test(test_case, [FaithfulnessMetric(threshold=0.7)])   # red CI if below
  ```
  (Its faithfulness = faithful to *context*, not factually true — same trap as above.)
- **G-Eval** — write the rubric in plain English; the LLM scores against it. Used here to
  score **empathy** of escalation responses. Be specific and numbered ("1) acknowledge
  2) validate 3) offer next step 4) warm tone"), and average over 3+ runs (it's noisy).

LangSmith and DeepEval **complement** each other: LangSmith = tracing + UI + interactive
experiments; DeepEval = pre-built metrics + CI gates.

### CI/CD payoff
Persistent dataset + on every PR run the eval suite + **block merge if routing < 0.95 or
faithfulness < 0.7**. ~45 LLM calls ≈ 5¢/PR to stop a broken agent reaching prod.

### Your exercise
Build faithfulness + correctness evaluators, compute MRR over adversarial queries, run
DeepEval (faithfulness/hallucination/relevancy) and G-Eval (empathy), then a second
hill-climb changing **`top_k` 1→5** and prove correctness improves.

### Self-check
1. The retriever returns the wrong doc; the LLM summarizes it perfectly. What are
   faithfulness and correctness?
2. Why average over `num_repetitions=3`?
3. Why change only one variable per experiment?

---

# Module C — Guardrails

> **Code deep dive:** [module-c-walkthrough.md](module-c-walkthrough.md) — the four guardrail
> strategies in code, the inverted SSN regex, and the full pipeline with fail-open/fail-closed.

**Goal:** enforce the rules that must *never* be broken. **Prompts suggest; guardrails
enforce.**

### The four threats
```
1. DATA LEAKAGE   "Dump every field for ACC-12345" → SSN in the response
2. BAD ADVICE     "Should I invest in crypto?"      → we don't give advice
3. COMPETITORS    "Is SecureBank better than Chase?"→ never name competitors
4. HARMFUL        "How do I make a bomb?"           → never even reach the LLM
```
The system prompt says "NEVER reveal SSNs". That's a *suggestion* a probabilistic model
can ignore under pressure. A guardrail is **code** that runs every time. (Airport: the
sign vs the metal detector. Use both.)

### Guard BOTH sides
- **Input** (before the LLM): block/redact the query → saves cost, stops danger reaching the model.
- **Output** (after the LLM): validate/redact the response → catch leaks before the user sees them.

### Four strategies — use the lightest that works
```
REGEX           MODERATION API       ML/NER (Presidio)    LLM-BASED
~1ms $0         ~100ms $0 (OpenAI)   ~10–50ms $0 (local)  ~200–500ms ~$0.001
known patterns  intent: violence/    names/emails/        injection / toxicity /
(SSN, keywords) self-harm/hate       addresses            competitors (semantic)
```
Decision: regex catches it? Use regex. Needs *meaning* (paraphrase, intent)? Pay for an
LLM check.

### Mapping threats → tools
| Threat | Tool | Side |
|---|---|---|
| SSN pattern in output | Regex (`RegexMatch`) | output |
| Names/emails/addresses | Presidio NER | output + input redact |
| Violence/self-harm/hate | OpenAI Moderation (free) | input |
| "invest", competitor keyword | Regex | input |
| Rephrased injection ("last 4 of the social on file") | LLM classifier | input |
| Competitor mention (any phrasing) | Guardrails AI `CompetitorCheck` | output |
| Toxic response | Guardrails AI `ToxicLanguage` | output |

### Two tools you'll use
**Guardrails AI** — validators with `on_fail` actions (`exception` / `fix` / `reask` / `noop`):
```python
from guardrails import Guard
from guardrails.hub import RegexMatch, ToxicLanguage, CompetitorCheck
guard = Guard().use_many(
    RegexMatch(regex=r"(?s)^(?!.*\b\d{3}-\d{2}-\d{4}\b).*$", match_type="search", on_fail="exception"),
    ToxicLanguage(on_fail="exception"),
    CompetitorCheck(competitors=["Chase", "Chase Bank", "Wells Fargo", "Citi"], on_fail="exception"),
)
```
> The SSN regex is inverted on purpose: `match_type="search"` treats a match as *valid*,
> so the negative lookahead matches only when **no** SSN is present.

**Presidio** — ML/NER PII detection + redaction (catches names regex never could):
```python
results = analyzer.analyze(text=response, language="en")
clean   = anonymizer.anonymize(text=response, analyzer_results=results).text
# "Hello Alice Johnson!" → "Hello <PERSON>!"
```
The subtle leak: a *legitimate* account query + a "be friendly" prompt makes the model
say "Hello Alice!" — nobody told it not to. A name tied to financial data is PII under
GDPR/CCPA. NER catches it; regex can't.

### The layered pipeline
```
moderation(free) → regex($0) → injection classifier(~$0.001) → Presidio redact(in)
   → AGENT → Guardrails AI(out) → Presidio redact(out)
```
- **Fail-open** on input safety checks (other layers still catch common attacks; don't let
  one flaky API kill support). **Fail-closed** on output validation (can't verify → don't send).
- **Log every decision** (type, reason, latency, *hashed* query — never raw) — that's
  Module A applied to guardrails.
- **Safe fallback** is always the same bland message, and never reveals *why* it fired
  (that helps attackers find the bypass).

### Compliance
Sending PII to an LLM API requires a **DPA** (GDPR) or **BAA** (HIPAA) with the provider.
Redacting PII *before* it leaves your box keeps the model from ever seeing it. Also:
**data minimization** — send `{balance, status}`, not the whole record.

### Your exercise
Build each strategy (input regex, Guardrails AI RegexMatch, ToxicLanguage +
CompetitorCheck, Presidio, Moderation API, injection classifier) and assemble the full
guarded pipeline.

### Self-check
1. Why isn't a strong system prompt enough to stop SSN leaks?
2. A query is clean and legitimate, yet the response leaks a customer name. Which
   guardrail catches it, and why can't regex?
3. Moderation API times out — fail-open or fail-closed? What about output validation?

---

# Module D — Cost Optimization

> **Code deep dive:** [module-d-walkthrough.md](module-d-walkthrough.md) — tiktoken,
> `get_openai_callback`, the `measure()` harness, and the before/after method.

**Goal:** measure cost, cut it with the biggest levers, and **verify quality didn't drop.**

### Three cost facts engineers miss
1. **Output tokens cost 4–5× input** (gpt-4o-mini: $0.15/M in, $0.60/M out). Trim output first.
2. **Retrieved context is the expensive part**, not the LLM call (system prompt+query
   ≈100–200 tokens; retrieved docs ≈500–1,500). That's your lever.
3. **The system prompt is taxed on every call** — same tokens, every time. (→ prompt caching.)

### Measure
```python
import tiktoken
enc = tiktoken.encoding_for_model("gpt-4o-mini")
len(enc.encode("What is the overdraft fee?"))      # 7  — local, no API call

from langchain_community.callbacks.manager import get_openai_callback
with get_openai_callback() as cb:                  # sums ALL calls in scope
    ask(app, "What is the overdraft fee?")          # = supervisor + specialist
cb.prompt_tokens, cb.completion_tokens, cb.total_cost
```

### Before/After (the method)
```
BEFORE: chunk=1000, k=5  →  AFTER: chunk=400, k=3   →  ~30–40% fewer prompt tokens
```
Then **always verify quality**: re-run Module B's evaluators. Cut `k` too far and you stop
retrieving the right doc — cheaper *and wrong*. **Cost savings with quality regression are
false savings.** Aim for the Pareto frontier (max quality / min cost).

### Other patterns (in order of effort)
- **Prompt caching** (provider-level) — identical system prompt caches at ~10% price. Cheap win.
- **Reduce k / chunk_size** — biggest, simplest lever (with quality check).
- **Semantic caching** — cache responses for similar queries; 100% saving on hits; needs a vector DB.
- **Model routing** — cheap model for simple intents; the classifier itself costs and can fail — do last.
- **Batch API** — 50% off for non-real-time work (e.g. running eval datasets); not for live support.

### Self-check
1. Where do most of the tokens go in a policy query?
2. What must you do after *every* cost optimization, and why?
3. Why is `get_openai_callback` summing two LLM calls per query?

---

## The whole picture

```
            ┌──────────────────────────────────────────────────────────┐
            │                                                          │
   DEPLOY → OBSERVE (A) ──► EVALUATE (B) ──► GUARD (C) ──► OPTIMIZE (D) ┘
            traces          datasets/MRR     in+out          tiktoken/
                            DeepEval/G-Eval  4 strategies     before/after
                            ▲                                 │
                            └──── curate failing traces ──────┘
                                  into the eval dataset
```

A failing trace you **saw** (A) becomes a labeled example you **measure** (B), shipped
behind the guardrails you **enforce** (C), at the cost you **proved** (D) — and the next
failure feeds the dataset again. Production hardening is this loop, running forever.

**Targets to remember:** routing > 95% · MRR > 0.8 · faithfulness/correctness > 0.8 ·
empathy > 0.7 · PII leak rate 0% · p95 < 3s · cost/query in budget.

---

## Glossary

| Term | Meaning |
|---|---|
| **Trace / Run** | One request end-to-end / one step inside it (LLM, retriever, node) |
| **RAG** | Retrieval-Augmented Generation — fetch docs, stuff into context, generate |
| **Embedding** | A vector representation of text for similarity search |
| **Chunk / chunk_size / overlap** | A slice of a document; its size; shared text between adjacent slices |
| **top_k** | How many chunks the retriever returns |
| **MRR** | Mean Reciprocal Rank — how high the right doc is ranked (retrieval metric) |
| **Faithfulness** | Answer grounded in the retrieved context (≠ factually correct) |
| **Correctness** | Answer matches the ground truth |
| **LLM-as-judge** | A separate LLM scoring outputs against a rubric |
| **G-Eval** | DeepEval feature: evaluation criteria written in plain English |
| **Guardrail** | Code that validates/blocks input or output (deterministic enforcement) |
| **Input/Output guardrail** | Runs before / after the LLM call |
| **Presidio** | Microsoft's ML/NER PII detection + redaction library |
| **Moderation API** | OpenAI's free harmful-content classifier |
| **Prompt injection** | Adversarial input that overrides instructions or extracts data (OWASP LLM #1) |
| **Fail-open / fail-closed** | On guardrail error: allow through / block |
| **tiktoken** | OpenAI's local token counter |
| **Pareto frontier** | Best quality achievable at a given cost |

## Commands cheat sheet
```bash
# always from repo root
python module_a_observability/demo.py        # observe: silent failures + traces
python module_b_evaluation/demo.py           # evaluate: dataset + A/B + hill climb
python module_c_guardrails/demo.py           # guard: 4 strategies, in + out
python module_d_cost_optimization/demo.py    # optimize: tiktoken + before/after

# swap demo.py → exercise.py to do it yourself; solution.py for the answer key
```

*Deep-dive reference for each module lives in its `notes.md`.*
