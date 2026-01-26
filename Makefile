.PHONY: help renv-status renv-snapshot renv-restore renv-update renv-deps renv-clean renv-init \
        pkgdown-build pkgdown-articles pkgdown-reference pkgdown-home pkgdown-news pkgdown-clean \
        readme tar-make tar-visnetwork tar-outdated tar-invalidate tar-clean

help: ## Show this help message
	@echo "Available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

renv-status: ## Check if lockfile is in sync with library and source files
	Rscript -e "renv::status()"

renv-snapshot: ## Save current package state to lockfile
	Rscript -e "renv::snapshot()"

renv-restore: ## Install packages from lockfile
	Rscript -e "renv::restore()"

renv-update: ## Update all packages
	Rscript -e "renv::update()"

renv-deps: ## Show detected package dependencies
	Rscript -e "renv::dependencies()"

renv-clean: ## Remove unused packages from library
	Rscript -e "renv::clean()"

renv-init: ## Initialize renv (run once when setting up project)
	Rscript -e "renv::init()"

# pkgdown targets

pkgdown-build: ## Build the complete pkgdown site
	Rscript -e "pkgdown::build_site()"

pkgdown-articles: ## Build only the articles/vignettes
	Rscript -e "pkgdown::build_articles()"

pkgdown-reference: ## Build only the function reference
	Rscript -e "pkgdown::build_reference()"

pkgdown-home: ## Build only the home page
	Rscript -e "pkgdown::build_home()"

pkgdown-news: ## Build only the news/changelog
	Rscript -e "pkgdown::build_news()"

pkgdown-clean: ## Remove the built pkgdown site
	Rscript -e "pkgdown::clean_site()"

# targets pipeline

tar-make: ## Run the targets pipeline
	Rscript -e "targets::tar_make()"

tar-visnetwork: ## Visualize the targets pipeline
	Rscript -e "targets::tar_visnetwork()"

tar-outdated: ## List outdated targets
	Rscript -e "targets::tar_outdated()"

tar-invalidate: ## Invalidate all targets (force rebuild)
	Rscript -e "targets::tar_invalidate(everything())"

tar-clean: ## Remove all target outputs
	Rscript -e "targets::tar_destroy()"
