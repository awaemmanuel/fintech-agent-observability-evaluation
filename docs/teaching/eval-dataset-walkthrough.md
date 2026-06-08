# The Evaluation Datasets, Explained — `module_b_evaluation/eval_dataset.py`

> Module B's shared "test fixtures." This one file defines the labeled examples every Module B
> script (demo, exercise, solution) evaluates against, plus the helpers that upload them to
> LangSmith. Understanding it makes the evaluators, A/B experiments, and MRR all click.

Source: [`module_b_evaluation/eval_dataset.py`](../../module_b_evaluation/eval_dataset.py)

---

## 1. What it is, in one breath

A **labeled dataset = test fixtures for an LLM system.** Each example is an input plus the
*expected* output. You run the agent over them and score how close it gets. This file holds
**two** datasets and the code to register them in LangSmith:

- **`EVAL_EXAMPLES`** — 15 broad-coverage examples (policy, account, escalation, out-of-scope).
  The general "does the whole system behave?" suite.
- **`HILL_CLIMB_EXAMPLES`** — 8 policy-only, number-heavy questions. A focused suite tuned to
  make retrieval-quality changes (chunk_size, top_k) show up clearly.

> **Why a separate file?** So demo / exercise / solution all evaluate the *same* fixtures, and
> so the data lives apart from the evaluator logic. Same reason you keep test fixtures out of
> the test functions.

---

## 2. The example format — a triplet

Every example is **input + expected answer + expected intent**:

```python
{
    "inputs":  {"question": "What is the overdraft fee?"},
    "outputs": {
        "answer": "The overdraft fee is $35 per transaction, with a maximum of 3 overdraft fees per day ($105 maximum).",
        "intent": "policy",
    },
}
```

- `inputs.question` — what you feed the agent.
- `outputs.intent` — the **ground-truth route** (which agent *should* handle it). Drives the
  `routing_evaluator`.
- `outputs.answer` — the **reference answer**. Drives `correctness` (LLM-as-judge) and
  `keyword_correctness` (does the response contain the expected numbers?).

The expected answers are **the actual policy values** from `project/documents/*.md` — $35
overdraft, $12.99 monthly fee waived above $1,500, 620 credit score, etc. That's what makes them
ground truth: they match the source docs.

---

## 3. `EVAL_EXAMPLES` — coverage by design (15 examples)

This isn't a random pile of questions. It's engineered to exercise **every path and every edge**:

| Category | Count | Examples | What it tests |
|---|---|---|---|
| Policy — account fees | 3 | overdraft fee, Premium monthly fee, out-of-network ATM | RAG over `account_fees.md` |
| Policy — loans | 2 | credit score for personal loan, prepayment penalty | RAG over `loan_policy.md` |
| Policy — transfers | 2 | domestic wire cost, can I cancel a wire | RAG over `transfer_policy.md` |
| Policy — fraud | 1 | reporting window / liability | RAG over `fraud_policy.md` |
| Account status | 4 | balance (ACC-12345), transactions (ACC-67890), **frozen** (ACC-11111), **non-existent** (ACC-99999) | DB lookup + edge cases |
| Escalation | 2 | "$15,000 withdrawn!", "I want a manager" | empathy routing |
| Out-of-scope | 1 | "What stock should I invest in?" → refusal | graceful "I don't know" |

> **Teaching point — coverage beats volume.** 15 well-chosen examples that hit every agent,
> both edge cases (frozen / non-existent account), and a **refusal** case are worth far more than
> 200 happy-path policy questions. If your dataset never tests refusal, you'll never catch the
> day the agent starts giving stock tips.

Two examples worth calling out:
- **`ACC-99999`** (non-existent) — expected answer is "I couldn't find account ACC-99999". Tests
  the graceful not-found path, not a crash.
- **"What stock should I invest in?"** — expected `intent: "policy"` with the refusal answer. The
  agent should route it to policy and then *decline* using the fallback sentence. Tests that the
  system says "I don't know" instead of hallucinating advice.

---

## 4. `HILL_CLIMB_EXAMPLES` — the focused retrieval suite (8 examples)

All 8 are **policy questions requiring precise numbers** (fees, APRs, limits): overdraft +
daily max, fee-waiver conditions, wire cost, auto-loan APR range, personal-loan APR, fraud
liability, international wire fee, late-payment fee.

```python
{
    "inputs": {"question": "What is the overdraft fee and the daily maximum?"},
    "outputs": {"answer": "The overdraft fee is $35 per transaction, with a maximum of 3 "
                          "overdraft fees per day ($105 maximum).", "intent": "policy"},
}
```

> **Why policy-only and number-heavy?** Because this suite exists to make **retrieval quality**
> visible. Account and escalation paths don't use RAG, so including them would *dilute* the
> signal. Every example here depends on the retriever surfacing the right chunk — so when you
> change `chunk_size` (demo) or `top_k` (solution), the `keyword_correctness` score moves
> clearly. That's the hill-climbing demo. A mixed dataset would mute the effect.

This is the dataset behind the Module B A/B experiment where `keyword_correctness` jumps from
~0.55–0.65 (tiny chunks) to ~0.80–0.90 (whole-section chunks).

---

## 5. The dataset names — one set per file (no collisions)

```python
DEMO_DATASET_NAME     = "fintech-demo-eval"
EXERCISE_DATASET_NAME = "fintech-exercise-eval"
SOLUTION_DATASET_NAME = "fintech-solution-eval"

DEMO_HC_DATASET_NAME     = "fintech-demo-hill-climb"
EXERCISE_HC_DATASET_NAME = "fintech-exercise-hill-climb"
SOLUTION_HC_DATASET_NAME = "fintech-solution-hill-climb"
```

Six names = {demo, exercise, solution} × {general, hill-climb}.

> **Why separate names matter:** these datasets live in **LangSmith** (shared cloud), not on
> disk. If demo, exercise, and solution all wrote to one dataset, a room of 30 students running
> simultaneously would stomp each other's data and experiments. Per-file names keep everyone
> isolated. This is the same reason `build_support_agent` takes a `collection_name`.

---

## 6. The helpers — idempotent upload to LangSmith

```python
def _ensure_dataset(dataset_name, examples, description, client=None):
    client = client or Client()
    existing = list(client.list_datasets(dataset_name=dataset_name))
    if existing:
        print(f"Dataset '{dataset_name}' already exists in LangSmith.")
        return existing[0]                      # don't recreate — reuse
    dataset = client.create_dataset(dataset_name=dataset_name, description=description)
    client.create_examples(
        inputs=[e["inputs"] for e in examples],
        outputs=[e["outputs"] for e in examples],
        dataset_id=dataset.id,
    )
    return dataset
```

**Create-if-not-exists.** Run it twice and it won't duplicate — it finds the existing dataset and
returns it. The thin wrappers just bind a name + example set:

```python
def ensure_solution_dataset(client=None):
    return _ensure_dataset(SOLUTION_DATASET_NAME, EVAL_EXAMPLES, f"{_EVAL_DESC} (solution)", client)
def ensure_solution_hc_dataset(client=None):
    return _ensure_dataset(SOLUTION_HC_DATASET_NAME, HILL_CLIMB_EXAMPLES, f"{_HC_DESC} (solution)", client)
# ...demo / exercise variants likewise
```

> **One contrast worth noting:** the **demo** script (`demo.py`) deliberately **deletes and
> recreates** its hill-climb dataset each run (so a re-run starts clean for the live A/B). The
> `_ensure_*` helpers used by exercise/solution instead **reuse** an existing dataset. Both are
> valid — just know which script does which if you see "already exists" vs "deleting and
> recreating" in the output.

---

## 7. How Module B uses these

```
eval_dataset.py
   ├── EVAL_EXAMPLES        → general evaluators (routing, faithfulness, correctness)
   │                          in exercise.py / solution.py
   └── HILL_CLIMB_EXAMPLES  → A/B hill-climbing (chunk_size in demo, top_k in solution)
```

- **`demo.py`** → uses `HILL_CLIMB_EXAMPLES` for the chunk_size A/B (the visible win).
- **`exercise.py` / `solution.py`** → use `EVAL_EXAMPLES` for the full evaluator suite, and the
  hill-climb set for a second A/B on `top_k`. The solution also **appends edge-case examples**
  (multi-part question, `ACC-00000`, exact-threshold $1,500 boundary) to show dataset curation
  as an ongoing step — the loop from Module A (harvest failing traces → grow the dataset).

---

## 8. Quick FAQ

- **"Where does the data physically live?"** In **LangSmith** (cloud) once uploaded. This file is
  the source of truth; the helpers push it up. Datasets persist across runs.
- **"Can I add examples?"** Yes — append to `EVAL_EXAMPLES`/`HILL_CLIMB_EXAMPLES`. New examples
  are picked up next time you run `evaluate()` against that dataset. That's exactly how you grow
  coverage from failing production traces.
- **"Why two `intent` values for borderline cases?"** Ground truth is your design decision —
  e.g. "I want a manager. Your fees are outrageous!" is labeled `escalation`, not `policy`, even
  though it mentions fees. Labeling the boundaries is how you test routing on the hard cases.
- **"15 examples — isn't that tiny?"** For a teaching suite, yes by design. The lesson is
  coverage and diversity over volume. In production you'd grow it to 100+ by curating real
  failures.

*See also: `module_b_evaluation/notes.md` (datasets, MRR, evaluators in depth) and the
agent walkthrough ([agent-walkthrough.md](agent-walkthrough.md)).*
