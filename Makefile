.PHONY: check fmt build sizes source boundary layout labs

check: fmt build sizes source boundary layout labs

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

layout:
	node check-storage-layout.mjs

labs:
	forge fmt --check --root labs
	forge build --root labs
	forge test --root labs
