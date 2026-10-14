.PHONY: check fmt build sizes source boundary layout labs bench

check: fmt build sizes source boundary layout labs bench

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

# The gas bench forks Robinhood Chain and is run on its own (bench/README.md); this builds it and checks its figures.
bench:
	forge fmt --check --root bench
	forge build --root bench
	node bench/gas-figures.mjs --check
