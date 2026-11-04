## 2026-10-31 (M4)

- **D-026 The project-installed CLI runs as `<node> <project>/node_modules/@b4run/cli/dist/index.js`, never through `node_modules/.bin/b4` or a shell, and is never downloaded.** The pnpm shim resolves `node` from `PATH`, which a Finder-launched app does not have. The version is read from the package's `package.json`; the minimum is 0.15.7. Inspection (`b4 routes --json --cwd <project>`) executes the project's config and route modules, so registration is the trust decision and both the CLI and the form say so.
