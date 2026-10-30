# comls

Small Windows-only x64 CLI in C, using SetupAPI and Configuration Manager.
`src\comls.c` handles the CLI, `src\ports.c` owns data and classification,
`src\win_ports.c` discovers devices, and `src\output.c` writes Unicode output.
Tests live in `tests\`.

## Language

Write all source code, identifiers, comments, CLI messages, documentation, and
other authored repository text in English, regardless of the language a developer
uses to communicate with an AI agent. Preserve device-provided names as received.

## Build and verify

From the repository root on Windows with MSVC C++ Build Tools, Windows SDK,
and PowerShell 7 installed:

```powershell
pwsh -NoProfile -File .\build.ps1
pwsh -NoProfile -File .\build.ps1 -Test
```

The executable is `build\comls.exe`. Run the test command after C or build changes;
keep `/W4 /WX` clean. See [README.md](README.md) for usage and discovery limitations.

## Invariants

- Keep the runtime in C and Windows APIs, with a statically linked CRT.
- Read device metadata only; leave ports unopened and device settings unchanged.
- Classify from device evidence, preserving `Unknown` when evidence is insufficient.
- Keep redirected output UTF-8 and console output Unicode.
- Maintain the version in `COMLS_VERSION` in `src\ports.h`.
- Keep build artifacts in the ignored `build\` directory.
