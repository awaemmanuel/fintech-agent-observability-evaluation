# The Agent, Explained — `project/fintech_support_agent.py`

> The one piece of code you **don't** write in this workshop. It's pre-built and shared by all
> four modules — you observe it (A), evaluate it (B), guard it (C), and cost-optimize it (D).
> Understanding it once makes every module easier. This document walks the file top to bottom.

Source: [`project/fintech_support_agent.py`](../../project/fintech_support_agent.py)

---

## 1. What it is, in one breath

A **multi-agent customer-support system for SecureBank**, built as a **LangGraph state machine**.
A customer question comes in; a **supervisor** classifies intent and routes to one of three
**specialist agents**; the chosen specialist produces the answer.

```
Customer query
     │
     ▼
 SUPERVISOR  ── classify_intent (1 LLM call) ──┐
                                               │
        ┌──────────────┬─────────────────────────┤
     "policy"   "account_status"          "escalation"
        ▼              ▼                        ▼
  POLICY AGENT    ACCOUNT AGENT          ESCALATION AGENT
  RAG over docs   regex → mock DB        empathy, no data
        └──────────────┴─────────────────────────┘
                       ▼
                    Answer
```

**Every query = at least 2 LLM calls:** the supervisor, plus one specialist. Keep that fact in
mind — it drives the trace shape (Module A) and the cost (Module D).

Two framings for a software engineer:
- It's a **typed state machine / reducer**: a shared `SupportState` dict flows through nodes;
  each node returns a partial dict that LangGraph merges back in (like a Redux reducer whose
  actions call LLMs).
- It's a **router + handlers**: the supervisor is a classifier that dispatches to one of three
  handlers.

---

## 2. Top-to-bottom tour

### Imports — what each piece is for

```python
import os, re, json
from pathlib import Path
from typing import TypedDict, Literal

from langchain.text_splitter import RecursiveCharacterTextSplitter   # chunk the policy docs
from langchain_core.documents import Document                        # page_content + metadata wrapper
from langchain_openai import ChatOpenAI, OpenAIEmbeddings            # chat model + embedding model
from langchain_chroma import Chroma                                  # in-process vector store (RAG)
from langchain.prompts import ChatPromptTemplate                     # system+human message templates
from langchain.schema.output_parser import StrOutputParser           # pull the raw string out of an LLM reply
from langchain.schema.runnable import RunnablePassthrough            # forward input unchanged in a chain
from langgraph.graph import StateGraph, END                          # the graph builder + terminal node
```

- `re` extracts account IDs like `ACC-12345` from queries.
- `json` serializes a mock account record into the prompt.
- `ChatOpenAI` ≠ `OpenAIEmbeddings` — **two different models, two cost lines.** The chat model
  (`gpt-4o-mini`) generates answers; the embedding model (`text-embedding-3-small`) turns text
  into vectors for retrieval.

### `DOCUMENTS_DIR`

```python
DOCUMENTS_DIR = Path(__file__).parent / "documents"
```
Absolute path to the 4 policy markdown files. (This is why you run scripts **from the repo
root** — paths resolve relative to the file, but the docs must exist there.)

### `MOCK_ACCOUNTS` — the fake database

```python
MOCK_ACCOUNTS = {
    "ACC-12345": {... "name": "Alice Johnson", "ssn_last4": "6789",
                  "balance": 12450.75, "status": "active", "recent_transactions": [...], ...},
    "ACC-67890": {... "Bob Smith", ... "balance": 234.50, "status": "active" ...},
    "ACC-11111": {... "Carol Davis", ... "balance": 85320.00, "status": "frozen",
                  "freeze_reason": "Suspected unauthorized activity — under fraud review"},
}
```
A plain dict standing in for a real DB call. Three accounts chosen to cover: an active
high-balance account (Alice), a low-balance active account (Bob), and a **frozen/fraud** account
(Carol). Note each record carries `ssn_last4` — remember that for §4.

### `SupportState` — the shared blackboard

```python
class SupportState(TypedDict):
    query: str                    # original customer question
    intent: str                   # "policy" | "account_status" | "escalation"
    response: str                 # final answer
    context: str                  # retrieved policy chunks OR account JSON
    retrieved_sources: list[str]  # source filenames (traceability)
```
Every node reads from and writes to this typed dict. A node returns a *partial* dict (e.g.
`{"intent": "policy"}`) and LangGraph **merges** it into the running state. `context` and
`retrieved_sources` exist largely so Modules A and B can inspect *what the agent saw*, not just
what it said.

### `DEFAULT_POLICY_SYSTEM_PROMPT`

The Policy Agent's instructions. Three deliberate design choices to point out:
- **"based ONLY on the provided policy documents"** → discourages hallucination (Module B tests
  whether this holds — faithfulness).
- An explicit **fallback sentence** for "I don't know" → graceful refusal for out-of-scope
  questions.
- **"NEVER disclose SSN / full account numbers"** → a *prompt-level* guardrail. Module C's whole
  point is that this is a **suggestion**, not a guarantee.

It's a parameter (`policy_system_prompt`) so Module B can A/B-test different wordings.

---

## 3. `build_support_agent(...)` — the factory

This single function builds and returns the whole system. Signature:

```python
def build_support_agent(
    collection_name="support_docs_multi",
    chunk_size=1000,
    chunk_overlap=100,
    top_k=3,
    model="gpt-4o-mini",
    policy_system_prompt=None,
    enable_reranking=False,
    rerank_fetch_k=None,
):
```

Those parameters **are the experiment surface** for the whole workshop (see §5). It runs in 10
steps.

### Steps 1–3 — build the RAG vector store

```python
# 1. Load: each .md file → one Document tagged with its source filename
all_documents.append(Document(page_content=content, metadata={"source": filename}))

# 2. Chunk: split on paragraph boundaries, with overlap so straddling facts survive
splitter = RecursiveCharacterTextSplitter(chunk_size=chunk_size, chunk_overlap=chunk_overlap)
chunks = splitter.split_documents(all_documents)

# 3. Embed + store: 1536-dim vectors in an IN-MEMORY Chroma collection
embeddings = OpenAIEmbeddings(model="text-embedding-3-small")
vectorstore = Chroma.from_documents(chunks, embeddings, collection_name=collection_name)
retriever = vectorstore.as_retriever(search_kwargs={"k": top_k})
```

Key facts: the store is **in-memory** (no `persist_directory`) and **rebuilt + re-embedded on
every call** — clean and reproducible, at the cost of a few seconds + a tiny embedding charge.
`collection_name` is a parameter so Module B can build several agents in one process without
collisions. (Full detail in the README's "Vector Store & RAG Setup" section.)

### `format_docs` helper

```python
def format_docs(docs):
    return "\n\n---\n\n".join(f"[{doc.metadata.get('source','')}]\n{doc.page_content}" for doc in docs)
```
Concatenates retrieved chunks into one string, **prefixing each with its `[source.md]`** so both
the LLM and human reviewers can see which file a fact came from.

### The chat model

```python
llm = ChatOpenAI(model=model, temperature=0)
```
**`temperature=0`** for reproducibility — important so Module B's evaluations are stable.
(Caveat repeated all workshop: temp=0 is *not* fully deterministic, which is why Module B averages
over repetitions.)

### Step 4 — the Policy RAG chain (LCEL)

```python
rag_chain = (
    {"context": retriever | format_docs, "question": RunnablePassthrough()}
    | policy_prompt | llm | StrOutputParser()
)
```
Read this as a pipeline with two parallel branches feeding the prompt:
- `context` branch: `query → retriever → format_docs` → a string of relevant chunks.
- `question` branch: `RunnablePassthrough()` forwards the query unchanged.

Both land in `policy_prompt`, then the LLM, then `StrOutputParser()` extracts the text. This
standalone chain is also returned so Module B can call it directly.

### Step 5 — the Supervisor (`classify_intent`)

```python
def classify_intent(state):
    chain = classification_prompt | llm | StrOutputParser()
    intent = chain.invoke({"query": state["query"]}).strip().lower()
    if intent not in ("policy", "account_status", "escalation"):
        intent = "policy"   # safe default on unexpected output
    return {"intent": intent}
```
One LLM call that returns a single category word. The guard clause forces any unexpected output
back to `"policy"` so the graph always routes somewhere valid. **This is the most important node
to get right** — Module B calls routing accuracy the most critical metric, because a misroute
makes everything downstream irrelevant.

### Step 6 — the Policy Agent (RAG)

The default path retrieves and answers:
```python
retrieved_docs = retriever.invoke(question)
context = format_docs(retrieved_docs)
sources = [doc.metadata.get("source","") for doc in retrieved_docs]
answer = (policy_prompt | llm | StrOutputParser()).invoke({"context": context, "question": question})
return {"response": answer, "context": context, "retrieved_sources": sources}
```
It calls the prompt→LLM chain directly (not `rag_chain`) because it needs the `sources` list for
traceability.

**Optional reranking** (`enable_reranking=True`, used in a Module B exercise): over-fetch
candidates, then have the LLM score each 0–10 for relevance and keep the top_k:
```python
candidate_docs = vectorstore.similarity_search(question, k=fetch_k)   # fetch_k = rerank_fetch_k or top_k*2
# LLM-as-reranker scores each doc, sort desc, keep top_k
```
This is how you can lift retrieval quality (MRR) — at the cost of extra LLM calls per candidate.

### Step 7 — the Account Agent (DB lookup)

```python
match = re.search(r"ACC-\d+", query, re.IGNORECASE)     # 1. find the account id
if not match: return {... "provide your account number" ...}
account = MOCK_ACCOUNTS.get(match.group(0).upper())     # 2. look it up
if not account: return {... "couldn't find account ..." ...}
context = json.dumps(account, indent=2)                 # 3. serialize the record
response = (account_prompt | llm | StrOutputParser()).invoke(
    {"account_data": context, "question": query})       # 4. LLM formats a friendly summary
return {"response": response, "context": context, "retrieved_sources": []}
```
No RAG — deterministic regex + dict lookup, then the LLM just phrases the data. Two graceful
non-exception paths: missing account number, and unknown account (`ACC-99999`). Those show up in
traces as *normal completed runs*, not errors — a Module A teaching point.

> **The planted vulnerability:** the full record — **including `ssn_last4`** — is `json.dumps`'d
> straight into the prompt ([line ~376](../../project/fintech_support_agent.py#L376)). A comment
> admits it's intentional. Module C exists to catch the resulting leak. See §4.

### Step 8 — the Escalation Agent (empathy)

```python
def escalation_agent(state):
    response = (escalation_prompt | llm | StrOutputParser()).invoke({"query": state["query"]})
    return {"response": response, "context": "", "retrieved_sources": []}
```
No retrieval, no data. The prompt tells it to acknowledge, empathize, hand off to a human, and
give contact info — and explicitly **not** to make policy claims. This is the agent Module B
scores with **G-Eval (empathy)**, precisely because "is this warm?" has no built-in metric.

### Step 9 — routing

```python
def route_by_intent(state) -> Literal["policy_agent","account_agent","escalation_agent"]:
    return {"policy":"policy_agent", "account_status":"account_agent",
            "escalation":"escalation_agent"}.get(state["intent"], "policy_agent")
```
Maps the supervisor's intent string to a node name; defaults to `policy_agent`.

### Step 10 — assemble the graph

```python
graph = StateGraph(SupportState)
graph.add_node("classify_intent", classify_intent)     # supervisor
graph.add_node("policy_agent", policy_agent)
graph.add_node("account_agent", account_agent)
graph.add_node("escalation_agent", escalation_agent)

graph.set_entry_point("classify_intent")
graph.add_conditional_edges("classify_intent", route_by_intent)   # supervisor → one specialist
graph.add_edge("policy_agent", END)
graph.add_edge("account_agent", END)
graph.add_edge("escalation_agent", END)

app = graph.compile()
```
`START → classify_intent → [policy_agent | account_agent | escalation_agent] → END`. The
conditional edge is the routing; each specialist terminates the graph.

### The return value

```python
return {
    "app": app,              # compiled graph — invoke via ask()
    "retriever": retriever,  # for direct retrieval tests (Module B MRR)
    "format_docs": format_docs,
    "llm": llm,              # shared chat model (Module D token counting)
    "rag_chain": rag_chain,  # standalone Policy RAG chain
    "vectorstore": vectorstore,  # raw Chroma (similarity_search_with_relevance_scores)
}
```
The factory hands back not just the runnable app but its **internals**, so each module can poke
the part it needs without rebuilding.

### `ask(app, query)` — the convenience helper

```python
def ask(app, query: str) -> dict:
    return app.invoke({"query": query, "intent": "", "response": "",
                       "context": "", "retrieved_sources": []})
```
Initializes every `SupportState` field to empty and runs the graph. Returns the final state dict
(`intent`, `response`, `context`, `retrieved_sources`). This is what you call in almost every
module.

---

## 4. The planted SSN vulnerability (don't "fix" it by accident)

The Account Agent sends the entire account record — `ssn_last4` included — into the LLM prompt.
The account prompt even says "Never reveal the customer's SSN," and the default policy prompt says
the same. **That's the point:** prompt instructions are probabilistic. Under the right query the
model can leak it anyway.

This is deliberate teaching scaffolding:
- **Module A** — you can *see* the SSN sitting in the prompt by reading the trace.
- **Module C** — you *catch* it: regex/`RegexMatch` on the output, and Presidio NER redaction.
  (Presidio also catches the subtler "Hello **Alice**!" name leak that no regex would.)

Leave it in. It's the thing the rest of the workshop is built to detect and defend against.

---

## 5. The parameters are the workshop

Almost every experiment you run is just `build_support_agent(...)` with different arguments:

| Parameter | What it changes | Where it's used |
|---|---|---|
| `chunk_size` | size of each document chunk | Module B (quality/MRR), Module D (cost) |
| `chunk_overlap` | shared text between adjacent chunks | Module B |
| `top_k` | how many chunks retrieved per query | Module B (recall vs noise), Module D (cost) |
| `model` | the chat model | Module D (model routing / cost-quality) |
| `policy_system_prompt` | override the Policy Agent's instructions | Module B (A/B prompt experiments) |
| `enable_reranking` / `rerank_fetch_k` | LLM-as-reranker over-fetch | Module B (lift MRR) |
| `collection_name` | Chroma collection name | always — avoids collisions across runs |

Change **one** at a time, measure, compare — that's the hill-climbing loop of Module B.

---

## 6. How each module touches this file

| Module | Uses | To do what |
|---|---|---|
| **A — Observability** | `ask(app, q)` | run queries; read the trace tree (supervisor → specialist → retriever → LLM) |
| **B — Evaluation** | `ask`, `retriever`, `vectorstore`, `rag_chain`, `policy_system_prompt` | routing/faithfulness/correctness evaluators, MRR, A/B experiments |
| **C — Guardrails** | `ask(app, q)` | wrap input/output guardrails around the agent; catch the SSN/name leak |
| **D — Cost** | `app`, `llm`, `chunk_size`/`top_k` | token counting + before/after cost comparison |

---

## 7. Mental model & quick FAQ

- **"Is there a database running?"** No. `MOCK_ACCOUNTS` is a dict; Chroma is an in-memory,
  in-process library (SQLite-for-vectors) rebuilt each call. Nothing persists to disk.
- **"Why two models?"** `gpt-4o-mini` writes answers; `text-embedding-3-small` powers retrieval.
  Separate calls, separate costs.
- **"Why does an account that doesn't exist not error?"** It returns a friendly "couldn't find
  it" string — a valid output, not an exception. That's realistic, and it's why you *inspect*
  agent behavior rather than just watching for crashes.
- **"Which node is most important?"** The supervisor. Misrouting makes a perfect specialist
  answer the wrong question. Fix routing first.
- **"What's the one line that summarizes the whole file?"** A supervisor classifies intent and
  routes to one of three specialists — RAG, DB lookup, or empathy — over a shared typed state.

*See also: the README "Architecture Deep Dive", the instructor/student guides under
`docs/teaching/`, and each module's `notes.md`.*
