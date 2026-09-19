.PHONY: check fmt build sizes source boundary layout

check: fmt build sizes source boundary layout

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
