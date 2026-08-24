# TD: Running the TEI embedding server on RunPod

Companion to [TD_Vectorisation.md](TD_Vectorisation.md). This is how the
embeddings for `emb_keypapers_title_abstract` are produced: a
[TEI](https://github.com/huggingface/text-embeddings-inference) server on a
rented RunPod GPU, which `R/embed_works.R` talks to over HTTPS.

> **History.** This used to be a manual procedure — copy the merged SPECTER2
> model onto a pod, start TEI by hand, paste the host back. That is all gone.
> The Dockerfiles and pod-pool scripts now live in the **`external/runpod`
> submodule**, the model is baked into the image, and pod creation is one
> command. The old walkthrough is in git history if it is ever needed.

## Prerequisites

```bash
git submodule update --init          # populates external/runpod
export RUNPOD_API_KEY=...            # RunPod REST API key
```

The submodule talks to the RunPod REST API directly, so `runpodctl` does not
need to be installed locally.

## 1. Start a pod

The pod's shape (image, GPU type, disk, idle watchdog) is described by a
config file. This repo keeps its own at
[input/pods.conf.tei-bge-large-en-v1.5](input/pods.conf.tei-bge-large-en-v1.5):

```bash
external/runpod/scripts/runpod/create_pods.sh -n 1 \
  -c "$(pwd)/input/pods.conf.tei-bge-large-en-v1.5"
```

`-n 1` because `R/embed_works.R` talks to a single host. The script polls the
pod's `/health` endpoint until TEI is *actually serving* (not merely the proxy
answering with a "pod starting" 502), then prints a ready-to-paste `host:`
line.

## 2. Point the pipeline at it

Paste the printed host into `input/config.yaml` under the active embedding
config:

```yaml
embeddings:
  active: bge_large_runpod
  configs:
    bge_large_runpod:
      host: <pod-id>-8080.proxy.runpod.net
      port: 443
      scheme: https
      model: BAAI/bge-large-en-v1.5
```

Host/port/scheme are deliberately excluded from the *tracked* embedding config
in `_targets.R` (see `emb_volatile`), so swapping pods does **not** invalidate
embeddings that have already been computed.

## 3. Stop it

```bash
external/runpod/scripts/runpod/stop_pods.sh          # stop (resumable)
external/runpod/scripts/runpod/stop_pods.sh -d       # delete permanently
```

The image also runs an idle watchdog (`IDLE_MIN` in the pods.conf, default 5
minutes) that stops the pod itself once no `/embed` requests arrive, so a
forgotten pod does not bill indefinitely.

## Images

Built from the submodule, not from this repo — there are deliberately no
docker targets in this repo's Makefile:

```bash
make -C external/runpod docker-tei-bge-large REGISTRY=ghcr.io/rkrug VERSION=v0.1.0
make -C external/runpod docker-tei           REGISTRY=ghcr.io/rkrug VERSION=v0.1.3
```

| config | image | model |
|---|---|---|
| `bge_large_runpod` (active) | `tei-runpod-bge-large-en-v1.5` | BAAI/bge-large-en-v1.5, 1024-dim |
| `SPECTER2_runpod` | `tei-runpod` (`proximity-v0.1.3`) | SPECTER2 merged adapter, 768-dim |

SPECTER2 remains a valid alternative — flip `embeddings.active` and give it a
host. Because the active config name is also the `config=` hive partition
under `output/NXS_TCA_corpus/embeddings/`, the two models' outputs coexist on
disk rather than overwriting each other.

## Notes

- `scripts/runpod/start_tei_runpod.sh` is retained for the case of starting
  TEI by hand inside an already-running pod; the normal path does not need it.
- `scripts/runpod/sync_embeddings_to_r2.sh` mirrors embeddings to Cloudflare
  R2. It was needed by the (now removed) BERTopic dispatch and is kept only as
  a manual utility.
