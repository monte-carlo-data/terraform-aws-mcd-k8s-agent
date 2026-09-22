.PHONY: default sanity-check

default:
	@echo "Read the readme"

sanity-check:
	# Validate TF configuration files and formatting. Used in CI pipeline.
	terraform init -backend=false
	terraform fmt -recursive -check -diff
	terraform validate
	# Validate each example.
	for d in examples/*/; do \
		terraform -chdir=$$d init -backend=false && \
		terraform -chdir=$$d validate || exit 1; \
	done