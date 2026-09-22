.PHONY: default sanity-check

default:
	@echo "Read the readme"

sanity-check:
	# Validate TF configuration files and formatting. Used in CI pipeline.
	terraform init -backend=false
	terraform fmt -recursive -check -diff
	terraform validate
	# Run the module test suite. Every run plans against fully mocked
	# providers, so no AWS credentials are needed.
	terraform test
	# Validate each example.
	for d in examples/*/; do \
		terraform -chdir=$$d init -backend=false && \
		terraform -chdir=$$d validate || exit 1; \
	done