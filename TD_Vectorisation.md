---
title: "TD — Vectorisation (TEI embeddings)"
format:
  html:
    toc: true
    embed-resources: true
---

Companion to [TD_RunPodSetup.md](TD_RunPodSetup.md), which covers running the
TEI server itself. This file covers the embedding model and text handling.

> **Scope note.** This began as a handoff summary for **TCAC 2.0**, a ~6M-work
> OpenAlex corpus embedded end-to-end with SPECTER2. That is no longer what
> this pipeline does. After the prune, the only embedding target left is
> `emb_keypapers_title_abstract` — the ~28 TCA/Nexus concept **definitions**
> in `input/TCA and Nexus Definitions-1.xlsx`. The full-corpus embedding and
> scoring layers were removed. The corpus statistics that used to sit here
> described that 6M-work corpus and no longer apply; see git history for them.

## Context

Embeddings are produced by `R/embed_works.R`, which POSTs text to a
[TEI](https://github.com/huggingface/text-embeddings-inference) server and
writes float parquet under
`output/NXS_TCA_corpus/embeddings/config=<name>/source=keypaper/variant=<v>/`.
The model-side helpers live in the R package **`openalexVectorComp`**.

The active model name is also the `config=` hive-partition value, so several
models coexist on disk instead of overwriting one another.

## Embedding model

Configured under `embeddings.configs.<name>` in `input/config.yaml`; the
active one is `embeddings.active`.

| | **`bge_large_runpod`** (active) | `SPECTER2_runpod` |
|---|---|---|
| Model | `BAAI/bge-large-en-v1.5` | `allenai/specter2_base` + `proximity` adapter |
| Dimensions | 1024 | 768 |
| Max tokens | 512 | 512 |
| Title/abstract join | raw concat, `sep_token: ""` | `title [SEP] abstract` |
| Pooling | cls | cls |

The separator matters: SPECTER2 was trained with an explicit `[SEP]` between
title and abstract, whereas BGE is a single-text model with no such
convention, so its `sep_token` is empty and the two fields are concatenated
directly. `title_cap_combined: 200` caps the title in the combined variant for
both.

SPECTER2 remains domain-appropriate (trained on the scientific citation
graph); BGE is the current default. Switching is a one-line `active:` change
plus a host — outputs land in separate `config=` partitions.

`variant_preprocessor()` (`R/embed_works.R`) also supports `title`-only and
`abstract`-only variants, but only `title_abstract` is currently wired up as
an actual `_targets.R` target (`emb_keypapers_title_abstract`) — the other
two are unused code paths, not active embedding sets.

---

## Input Preparation (R)

TEI handles truncation automatically — no preprocessing needed beyond
joining title + abstract per the active config's `sep_token`
(`""` for BGE, `"[SEP]"` for SPECTER2) and `title_cap_combined`
(`preprocessor_title_abstract()`, `R/embed_works.R`).

---

## TEI Server Setup

See [TD_RunPodSetup.md](TD_RunPodSetup.md) — the current setup is a RunPod-
hosted TEI image (model baked in), not a local server. The old local
Homebrew/`cargo`, SPECTER2-merge-script walkthrough that used to live here is
retired; see git history if it's ever needed again for local development.
