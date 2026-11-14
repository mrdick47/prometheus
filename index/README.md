# index/

One vector index (or subdirectory) per library source, built in Phase 4
(BAC-150) on POSEIDON's GPU. Examples: `wikipedia/`, `wikimed/`,
`gutenberg/`. Do not mix sources into a single index.

Each article should carry a hash/fingerprint so later updates on ZEUS
only re-embed changed articles. Index data is gitignored; all model
tiers share these indexes.
