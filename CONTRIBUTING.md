# Contributing

Keep changes focused on a small, fast, read-only Windows COM-port listing tool.
Use English for code, identifiers, comments, documentation, issues, and pull requests,
regardless of the language used in development conversations.

1. Follow the build prerequisites in [README.md](README.md).
2. Make a focused change and add tests for behavior changes.
3. Run `pwsh -NoProfile -File .\build.ps1 -Test`.
4. Open a pull request describing the change, how it was verified, and any hardware
   scenarios that could not be exercised.

Keep compiler warnings clean and preserve the existing MIT license. Avoid adding
runtime dependencies or opening COM ports as part of discovery.

Git is also required for the release tests invoked by `build.ps1 -Test`. These
tests create disposable repositories under `build\` and mock GitHub publication;
they do not publish tags or releases. Keep the default source version in
`COMLS_VERSION` in `src\ports.h`. CI derives X/Y from that definition and injects
the calculated mainline patch version at build time without committing generated
files. See [Releases and versioning](README.md#releases-and-versioning) for baseline
tags, versioned local builds, and manually promoting an Alpha to stable.

For bug reports, include the Windows version, `comls --version`, the command used,
and expected versus actual behavior. A redacted `-vv` excerpt can help with
driver-specific issues; remove device serial numbers and identifying instance IDs
before sharing it. Use [SECURITY.md](SECURITY.md) for security issues.
