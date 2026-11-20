# comls

**Find the COM port you just plugged in.** A small, read-only CLI for
Windows 10/11 x64, written in C with no external runtime dependencies.

## Features

- See COM ports at a glance, with USB, Bluetooth, native, and virtual connection types.
- Spot recent arrivals, sort newest first, or show only USB ports.
- Get USB vendor and product names from an embedded, offline database.
- Switch from a compact, colored list to detailed device and driver diagnostics;
  redirected output stays plain UTF-8.

```text
Found 2 ports (1 bluetooth, 1 USB):

Recent (last 5 minutes):
COM1   (USB) USB Serial Port +2 min

Rest:
COM10  (BL)  Bluetooth serial port +9 h
```

Illustrative output. comls reads device metadata without opening ports or changing
settings; it does not check whether a port is free or working.

This is an AI-assisted rewrite of a tool I originally built in the .NET Framework
days, before .NET Core. I wanted to rewrite it anyway, so why not go straight to
plain C and keep it small and fast?

## Get it

Download **`comls.exe`** and the license notices from
[GitHub Releases](https://github.com/ah01/comls/releases).
No installer, administrator rights, or Visual C++ Redistributable needed.
Automatic snapshots are marked **Alpha** (prereleases). Builds are unsigned,
so Windows SmartScreen may warn.

Run it from PowerShell, or put it on your `PATH`:

```powershell
.\comls.exe
.\comls.exe -u -t   # USB ports, newest first
.\comls.exe -v      # Device details (-vv for full diagnostics)
.\comls.exe --help
```

## Build your own

Install **Visual Studio Build Tools** with the **Desktop development with C++**
workload (MSVC and Windows SDK), plus **PowerShell 7**. From the repository root:

```powershell
pwsh -NoProfile -File .\build.ps1
.\build\comls.exe
```

The script sets up MSVC automatically and builds offline from committed data.
No Developer Command Prompt, CMake, or third-party libraries required.
For tests, also install Git and run `pwsh -NoProfile -File .\build.ps1 -Test`.

## More

See the [reference](doc/reference.md) for
[all options and output details](doc/reference.md#usage),
[discovery limitations](doc/reference.md#discovery-and-classification),
[build and test internals](doc/reference.md#build-and-test),
[release versioning](doc/reference.md#releases-and-versioning), and
[USB database updates](doc/reference.md#updating-the-usb-database).

[Contributing](CONTRIBUTING.md) | [Security](SECURITY.md).
Bundled USB data uses BSD-3-Clause; see [attribution and notices](doc/reference.md#license).
