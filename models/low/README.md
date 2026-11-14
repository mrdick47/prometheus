# models/low

Place the low-tier (~3B) llamafile or GGUF here. The auto launcher
selects this tier for machines with about 8 GB of RAM and no stronger
GPU option, and walks down to it if a larger tier is missing.
