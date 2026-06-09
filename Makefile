# ----------------------------------------------------------------------------
# TCAC 2.0 — operator interface.
#
# `make help` prints all targets.
# Override image versions on the command line:
#   make docker-tei-build       VERSION=v0.1.1
#   make docker-bertopic-push   VERSION=v0.1.2
# ----------------------------------------------------------------------------

# Image registry namespace. Override with REGISTRY=ghcr.io/<other-user> if you fork.
REGISTRY ?= ghcr.io/rkrug

# Default image version. Bump for each new build (see docker/*/CHANGES.md).
VERSION  ?= v0.1.0

# TEI CUDA tag (Hopper/Ada L40S = 89-1.5). See docker/tei-runpod/README.md.
TEI_TAG  ?= 89-1.5

# Docker buildx platform — RunPod nodes are amd64 even from Apple Silicon.
PLATFORM ?= linux/amd64

.PHONY: help \
        tar-make tar-visnetwork tar-outdated tar-invalidate tar-clean \
        docker-tei-build docker-tei-push docker-tei \
        docker-bertopic-build docker-bertopic-push docker-bertopic \
        docker-all

help: ## Show this help message
	@echo "TCAC 2.0 make targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  %-26s %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables (override on the make command line):"
	@echo "  REGISTRY=$(REGISTRY)"
	@echo "  VERSION=$(VERSION)"
	@echo "  TEI_TAG=$(TEI_TAG)"
	@echo "  PLATFORM=$(PLATFORM)"

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

# --- docker images ----------------------------------------------------------
# Each image has a build target, a push target, and a combined build+push.
# Bump VERSION (and document in docker/*/CHANGES.md) before rebuilding.

docker-tei-build: ## Build TEI images (proximity + adhoc_query adapters)
	docker buildx build --platform $(PLATFORM) \
	    -t $(REGISTRY)/tei-specter2:proximity-$(VERSION) \
	    --build-arg ADAPTER=proximity \
	    --build-arg TEI_TAG=$(TEI_TAG) \
	    -f docker/tei-runpod/Dockerfile .
	docker buildx build --platform $(PLATFORM) \
	    -t $(REGISTRY)/tei-specter2:adhoc_query-$(VERSION) \
	    --build-arg ADAPTER=adhoc_query \
	    --build-arg TEI_TAG=$(TEI_TAG) \
	    -f docker/tei-runpod/Dockerfile .

docker-tei-push: ## Push TEI images to the registry
	docker push $(REGISTRY)/tei-specter2:proximity-$(VERSION)
	docker push $(REGISTRY)/tei-specter2:adhoc_query-$(VERSION)

docker-tei: docker-tei-build docker-tei-push ## Build + push TEI images

docker-bertopic-build: ## Build the BERTopic RunPod image
	docker buildx build --platform $(PLATFORM) \
	    -t $(REGISTRY)/bertopic-runpod:$(VERSION) \
	    -f docker/bertopic-runpod/Dockerfile .

docker-bertopic-push: ## Push the BERTopic RunPod image to the registry
	docker push $(REGISTRY)/bertopic-runpod:$(VERSION)

docker-bertopic: docker-bertopic-build docker-bertopic-push ## Build + push BERTopic image

docker-all: docker-tei docker-bertopic ## Build + push all docker images
