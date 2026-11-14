# apps/

Portable binaries for machines with no internet and no existing tools
(BAC-141, BAC-145):

- `kiwix-serve` (required for library hosting)
- `kiwix-desktop` (optional GUI)
- `llamafile` runtime (used when a tier has a `.gguf` instead of a self-contained `.llamafile`)

A single `apps/kiwix-serve` or `apps/kiwix-serve.exe` is enough if you
only need one OS. For a multi-OS drive, use subfolders:

- `apps/linux-x86_64/`
- `apps/linux-aarch64/`
- `apps/darwin-x86_64/`
- `apps/darwin-arm64/`
- `apps/windows-x86_64/`

Git ignores binaries in this tree. See docs/LAYOUT.md for search order.
