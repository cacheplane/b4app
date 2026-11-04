## 2026-10-31 (M6)

- **D-040 Runtime lookup without a shell also covers version managers by their on-disk layout: nvm's newest installed Node first, fnm's `default` alias, Homebrew's `opt/node`.** A Finder- or launchd-started process has `PATH=/usr/bin:/bin:/usr/sbin:/sbin`; shell hooks never run. `~/.local/bin`, Homebrew, npm-global, Volta, and Bun were already searched (M4); the CLI finds the bundled coordinator through its own resolved path, then `/Applications` and `~/Applications`.
