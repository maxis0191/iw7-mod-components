# Extraction provenance

The source repository and baseline are recorded in import.json. Every exported
path retains its Git blob at extraction. commit-map.txt records filter-repo's
old/new commit mapping, including empty commits omitted from this product.
The original published source history is unchanged. This new history is private.
Uncommitted and unpublished feature work was not imported. Retained operational
checkouts and frozen plans remain where the server migration inventory records.

Tool: git-filter-repo 2.47.0, installed locally from the official PyPI wheel,
SHA256 2cd04929b9024e83e65db571cbe36aec65ead0cb5f9ec5abe42158654af5ad83.
The official upstream procedure filters a fresh independent clone; it was never
run against the original repository or any retained experimental checkout.
