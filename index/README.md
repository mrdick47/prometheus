# index/

One vector index (or subdirectory) per library source, built in Phase 4
(BAC-150) on POSEIDON's GPU. Examples: `wikipedia/`, `wikimed/`,
`gutenberg/`. Do not mix sources into a single index.

Each article should carry a hash/fingerprint so later updates on ZEUS
only re-embed changed articles. Index data is gitignored; all model
tiers share these indexes.

Built and maintained by `scripts/index` (see [docs/INDEX.md](../docs/INDEX.md)):
`index/<source>/` holds `state.db` and int8 vector segments, and only offsets
and content hashes, never chunk text. Each index lives on the same drive as its
source ZIM.

`scripts/index clone --to <drive>` copies finished indexes to another drive instead of
embedding them again (see docs/INDEX.md, "Cloning to another drive").
