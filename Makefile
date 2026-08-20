# ----------------------------------------------------------------------------
# TCAC 2.0 — operator interface.
#
# `make help` prints all targets.
#
# Docker image build/push is NOT here — the Dockerfiles and build logic live
# in the external/runpod submodule. Build/push directly there, e.g.:
#   make -C external/runpod docker-tei           REGISTRY=ghcr.io/rkrug VERSION=v0.1.3
#   make -C external/runpod docker-tei-bge-large REGISTRY=ghcr.io/rkrug VERSION=v0.1.0
# (run `git submodule update --init` after cloning; see external/runpod/README.md).
# ----------------------------------------------------------------------------

.PHONY: help \
        tar-make tar-visnetwork tar-outdated tar-invalidate tar-clean \
        mmd mmd-clean

# Mermaid CLI binary. Install via `npm i -g @mermaid-js/mermaid-cli` or
# `brew install mermaid-cli`. Override on the make line if needed.
MMDC      ?= mmdc

# Source diagrams + rendered outputs.
MMD_SRC   := $(wildcard input/mmd/*.mmd)
MMD_SVG   := $(MMD_SRC:input/mmd/%.mmd=output/figures/mmd/%.svg)
MMD_PNG   := $(MMD_SRC:input/mmd/%.mmd=output/figures/mmd/%.png)

help: ## Show this help message
	@echo "TCAC 2.0 make targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  %-26s %s\n", $$1, $$2}'
	@echo ""
	@echo "Docker images: build/push from the external/runpod submodule (see header)."

# --- targets pipeline -------------------------------------------------------

tar-make: ## Run the targets pipeline
	Rscript -e "targets::tar_make()"

tar-visnetwork: ## Visualise the targets pipeline as a network
	Rscript -e "targets::tar_visnetwork()"

tar-outdated: ## List outdated targets
	Rscript -e "targets::tar_outdated()"

tar-invalidate: ## Invalidate all targets (force rebuild)
	Rscript -e "targets::tar_invalidate(everything())"

tar-clean: ## Remove all target outputs
	Rscript -e "targets::tar_destroy()"

# --- mermaid diagrams -------------------------------------------------------
# Renders every .mmd under input/mmd/ to SVG (vector) and PNG (raster) in
# output/figures/mmd/. SVG is the recommended embed format for the QMD
# report; PNG is a fallback for tools that don't render SVG.
#
# Requires the mermaid CLI (mmdc). On macOS: `brew install mermaid-cli`.

output/figures/mmd/%.svg: input/mmd/%.mmd
	@mkdir -p $(dir $@)
	$(MMDC) -i $< -o $@ -b transparent

output/figures/mmd/%.png: input/mmd/%.mmd
	@mkdir -p $(dir $@)
	$(MMDC) -i $< -o $@ -b white -s 2

mmd: $(MMD_SVG) $(MMD_PNG) ## Render all mermaid diagrams to SVG + PNG

mmd-clean: ## Remove all rendered mermaid output
	rm -rf output/figures/mmd
