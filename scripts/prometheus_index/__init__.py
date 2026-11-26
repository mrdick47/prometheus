"""Prometheus indexer: one checkpointed, resumable vector index per source.

Indexes store offsets and content hashes, never chunk text. Text is read
back from the ZIM at query time. See docs/INDEX.md.
"""

__version__ = "0.1.0"
