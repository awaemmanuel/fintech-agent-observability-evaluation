# Module D Code, Explained — Measuring & Cutting Cost

> Module D has no separate shared data file — its "reference code" is the measurement helpers in
> [`demo.py`](../../module_d_cost_optimization/demo.py) and [`solution.py`](../../module_d_cost_optimization/solution.py).
> This walks the two tools (tiktoken, get_openai_callback) and the before/after method.

---

## 1. The idea in code

Every query through the agent is **≥2 LLM calls** (supervisor + specialist), and for policy
queries the **retrieved context dominates the token count**. Module D measures that, changes one
RAG lever, and re-measures — then verifies quality didn't drop.

Two facts that drive everything:
- **Output tokens cost 4–5× input** → trim output first.
- **The retrieved context is the expensive part**, not the system prompt → `chunk_size`/`top_k`
  are the big levers.

---

## 2. Tool 1 — `tiktoken` (count tokens locally, no API call)

```python
import tiktoken
enc = tiktoken.encoding_for_model("gpt-4o-mini")

len(enc.encode("What is the overdraft fee?"))     # 7  — the model's real tokenizer, offline
```

Used to expose the **system-prompt tax** — tokens you pay on every single call:

```python
sup_tokens = len(enc.encode(supervisor_prompt))   # ~90
print(f"{sup_tokens} tokens × 1000 queries/day = {sup_tokens*1000:,} tokens/day just for the system prompt")
```
> Teaching point: **token count ≠ word count** (~1 token ≈ 0.75 words). Always count with the
> model-specific tokenizer.

---

## 3. Tool 2 — `get_openai_callback` (real tokens + cost per run)

```python
from langchain_community.callbacks.manager import get_openai_callback

with get_openai_callback() as cb:
    result = ask(app, "What is the overdraft fee?")

cb.prompt_tokens, cb.completion_tokens, cb.total_cost
```

**Critical:** the callback sums **all** LLM calls inside the `with` block — for this agent that's
the **supervisor call + the specialist call** combined. That's why a single `ask()` reports the
true per-query cost, not just one call.

> Why measure locally when LangSmith already traces tokens? LangSmith gives *visibility*
> (per-run breakdown). This module adds *action*: before/after tables, thresholds, projected
> savings. They complement each other.

---

## 4. The `measure()` helper — the harness

```python
def measure(agent_components, label):
    app = agent_components["app"]
    total_prompt = total_completion = 0; total_cost = 0.0
    for i, query in enumerate(TEST_QUERIES, 1):
        with get_openai_callback() as cb:
            result = ask(app, query)
        total_prompt     += cb.prompt_tokens
        total_completion += cb.completion_tokens
        total_cost       += cb.total_cost
        print(f"Q{i} [{result['intent']}] prompt={cb.prompt_tokens} compl={cb.completion_tokens} ${cb.total_cost:.6f}")
    return total_cost, total_prompt, total_completion, results
```

`TEST_QUERIES` is a fixed 8-query mix — **one per path** so the numbers reflect realistic traffic:

```python
TEST_QUERIES = [
    # policy (RAG — most expensive: supervisor + retriever + generation)
    "What is the overdraft fee?", "What credit score do I need for a personal loan?",
    "How much does a domestic wire transfer cost?", "How long do I have to report unauthorized transactions?",
    "What is the monthly fee for a Premium Checking account?",
    # account status (moderate)
    "What is the balance on ACC-12345?", "Show me recent transactions for ACC-67890.",
    # escalation (cheapest — no retrieval)
    "This is terrible service! I want to speak to a manager!",
]
```
A fixed query set is what makes before/after an apples-to-apples comparison.

---

## 5. The before/after method

```python
# BEFORE — large chunks, many docs
baseline  = build_support_agent(collection_name="cost_baseline",  chunk_size=1000, chunk_overlap=100, top_k=5)
# AFTER  — smaller chunks, fewer docs  (ONE lever group changed: retrieval size)
optimized = build_support_agent(collection_name="cost_optimized", chunk_size=400,  chunk_overlap=50,  top_k=3)

b_cost, b_prompt, *_ = measure(baseline,  "BEFORE")
o_cost, o_prompt, *_ = measure(optimized, "AFTER")
```
Same `TEST_QUERIES`, two configs, compare:

```python
def safe_pct(before, after): return (before - after) / before * 100 if before else 0
# prints a table: avg prompt tokens, avg cost/query, % savings  (~30–40% fewer prompt tokens)
```

The win comes from the **retrieval levers** — smaller chunks × fewer of them = far fewer prompt
tokens, on the same questions.

---

## 6. The non-negotiable step — verify quality

```python
QUALITY_CHECKS = {
    "What is the overdraft fee?": ["overdraft", "fee"],
    "What credit score do I need for a personal loan?": ["credit", "loan"],
    "What is the balance on ACC-12345?": ["balance", "12450", "12,450"],
}
# after optimizing, confirm the expected terms still appear in the optimized responses
```
> **Cost savings with quality regression are false savings.** Cut `top_k` too far and you stop
> retrieving the doc the answer needs — cheaper *and wrong*. The smoke test here is the quick
> check; the real gate is re-running Module B's evaluators on the optimized config.

---

## 7. Projected savings (make the tiny number real)

```python
qpd = 1000
daily = (b_cost/n - o_cost/n) * qpd
print(f"Daily ${daily:.4f} | Monthly ${daily*30:.2f} | Annual ${daily*365:.2f}")
```
Per-query cost is fractions of a cent; multiplied by volume it becomes a real line item. That's
the whole argument for optimizing at scale.

---

## 8. The other patterns (named in the demo, do in this order)

| Pattern | Effort | Note |
|---|---|---|
| Prompt caching (provider) | low | identical system prompt caches at ~10% price — near-free win |
| Reduce `top_k` / `chunk_size` | low | biggest, simplest lever (verify quality) |
| Semantic caching | medium | cache responses for similar queries; 100% saving on hits; needs a vector DB |
| Model routing | high | cheap model for simple intents; the classifier itself costs + can fail — do last |
| Batch API | n/a live | 50% off for non-real-time work (e.g. running eval datasets), not live support |

---

## 9. FAQ

- **"Why is `get_openai_callback` summing two calls?"** Because one `ask()` runs supervisor +
  specialist; the context manager captures every LLM call in scope.
- **"Why these 8 queries?"** One per path (5 policy, 2 account, 1 escalation) so the average
  reflects real traffic, and a fixed set makes before/after comparable.
- **"Where do tokens actually go in a policy query?"** The retrieved context (~600–1,200 tokens),
  not the system prompt (~100–200). That's why retrieval is the lever.
- **"Is the optimized config always better?"** No — it's a tradeoff. Verify quality every time;
  keep only the points on the cost/quality Pareto frontier.

*See also: `module_d_cost_optimization/notes.md` (token economics, the 4 patterns in depth) and
the README "Cost Structure (Per Query)" section.*
