# IPBES TCA–Nexus literature pipeline

R `targets` pipeline behind the approaches × actions analysis of the IPBES
Transformative Change / Nexus article. It builds an OpenAlex corpus over the two
IPBES Zotero groups, extracts definition citations, embeds the TCA/Nexus
concept definitions with BAAI/bge-large-en-v1.5, and draws the approaches ×
actions heat map that appears as Figure 2.

## What this repository is not

It does not hold the expert elicitation. The 1,692 expert judgements linking the
22 transformative-change actions to the 71 Nexus response options, the
application that collected them, and the figures drawn from them are archived
separately: software [10.5281/zenodo.22686359](https://doi.org/10.5281/zenodo.22686359),
dataset [10.5281/zenodo.22686363](https://doi.org/10.5281/zenodo.22686363).

## Running it

```bash
renv::restore()        # dependencies are pinned in renv.lock
targets::tar_make()    # replays the whole pipeline
```

Before running, set up:

- An [OpenAlex](https://openalex.org) API key, in the system keyring:
  `keyring::key_set("API_openalex")`. `_targets.R` checks for this and stops
  immediately if it's missing.
- A Zotero API key with read access to the private IPBES NXS assessment
  literature group, in the system keyring under the entry named by
  `zotero.api_key_keyring` in `input/config.yaml` (currently
  `API_zotero_all_groups`); the public TCA group needs no key.
- A [RunPod](https://runpod.io) account and a running TEI pod serving the
  active embedding model (`BAAI/bge-large-en-v1.5` by default) — see
  [TD_RunPodSetup.md](./TD_RunPodSetup.md) for how to start one and point
  `input/config.yaml`'s `embeddings.configs.<active>.host` at it.

## Inputs

| | |
|---|---|
| `input/corpus_chapter/` | Extracted 2026-07-09 from the OpenAlex snapshot `RELEASE 2026-01-15`, for every work matched by DOI from the two Zotero group libraries below (no search-term query — the corpus is defined entirely by group membership). 2,487 TCA + 15,901 NXS works, ~70 MB. |
| Zotero groups | TCA (id `4589462`, public), read 2026-07-06, 2,990 items. NXS assessment literature (id `4596166`, private), read 2026-07-06, 19,668 items. |
| `external/` | Sub-module containing the machinery to start and control the runpods |


## Outputs

`output/figures/pair_heatmap_appr_act_combined.{png,svg,pdf,eps}` is the figure
the article carries. `output/reports/` holds the rendered analysis reports, also
published at <https://rkrug.github.io/IPBES-TCA-Nexus-Linker-pipeline/>.

## Licence

MIT — see [LICENSE](./LICENSE).

OpenAlex based corpora: CC0

## Citation

See [CITATION.cff](./CITATION.cff). Each release is archived on Zenodo. Cite the
concept DOI [10.5281/zenodo.22687426](https://doi.org/10.5281/zenodo.22687426),
which always resolves to the latest version and does not go stale.
