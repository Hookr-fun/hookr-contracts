.PHONY: check fmt build sizes source boundary

check: fmt build sizes source boundary

fmt:
	forge fmt --check

build:
	forge build

sizes:
	forge build --sizes

source:
	node check-source-manifest.mjs

boundary:
	node check-review-boundary.mjs
