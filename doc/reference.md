# comls reference

Detailed usage, discovery limitations, and maintainer notes. For a quick start,
see the [README](../README.md). Run all build commands from the repository root.

- [Download and checksums](#download)
- [Usage and output](#usage)
- [Build and test](#build-and-test)
- [Releases and versioning](#releases-and-versioning)
- [Discovery and classification](#discovery-and-classification)
- [Contributing and security](#contributing-and-security)
- [Updating the USB database](#updating-the-usb-database)
- [License](#license)

## Download

Download `comls.exe` and the combined `LICENSE` file from
[GitHub Releases](https://github.com/ah01/comls/releases). The executable is
standalone; no installer or Visual C++ Redistributable is required.
**Alpha** releases are automatic snapshots, marked as GitHub prereleases.
Stable releases are explicitly promoted from an existing Alpha without rebuilding;
the executable and checksums remain identical. Until a stable release is promoted,
only prereleases are available.

Each release includes `LICENSE`, which combines the application and bundled-data
license notices, and `SHA256SUMS.txt`. To check the executable after downloading:

```powershell
Get-FileHash .\comls.exe -Algorithm SHA256
```

Compare the result with the `comls.exe` entry in `SHA256SUMS.txt`.
Checksums detect corrupted downloads, not an untrusted release source. Builds are
not code-signed, so Windows SmartScreen may warn about an unfamiliar executable.

## Usage

```powershell
.\build\comls.exe
.\build\comls.exe -vv
.\build\comls.exe --usb-only
.\build\comls.exe --sort-by-time
.\build\comls.exe --version
```

`--usb-only` (`-u`) lists only ports classified as `USB` and can be combined with
either detail level (`-v`, `-d`, or `-vv`). The summary counts only the selected ports. Bluetooth ports
backed by a USB radio are excluded, as are native, virtual, and unknown ports.
When no USB ports match, the usual empty-list output is shown and the exit code
is `0`. Help and version output do not enumerate devices even with this option.

`--sort-by-time` (`-t`) orders ports by last arrival, newest first, instead of
their COM numbers. Equal timestamps are ordered numerically by COM number;
ports with unknown timestamps come last, also in numeric order.
The option works with both detail levels and `--usb-only`. In compact output,
Recent remains before Rest, with time sorting applied within each section.
Verbose output uses time sorting across the entire selected list.

The default view shows aligned port names, connection types in parentheses, and
descriptions, without a table header. Optional details follow the description as
`[Manufacturer, USB: vendor / product]`, using the Windows-reported manufacturer
and, for USB ports only, names from the embedded `usb.ids` database.
The manufacturer `Microsoft` (case-insensitive) and missing or `Unknown` detail
values are omitted. If only one USB name is known, it is shown without a slash;
if no details remain, the square brackets are omitted. Values are not truncated.
A missing description is still shown as `Unknown`. Bluetooth is abbreviated
as `BL`; other connection types retain their names. Ports are sorted numerically
(`COM2` before `COM10`).
When the last-arrival time is known, the line ends with a compact age such as
` +5 min`, using whole seconds (`s`), minutes (`min`), hours (`h`), or days (`d`).
Less than one second ago is ` +0 s`; future timestamps use a minus sign.
Missing ages are omitted. The age follows any square-bracketed device details.
When at least one port has a known last-arrival time within the last five minutes
(including exactly five minutes ago), the default view places all such ports
under `Recent (last 5 minutes):` and the remaining ports under `Rest:`.
Each section retains the selected ordering and shared column alignment.
An empty `Rest:` section is omitted. If no ports qualify as recent, the default
view stays ungrouped. The five-minute window is fixed; `--usb-only` filters ports
before grouping and counting. Missing or future arrival times do not qualify as recent.
All output levels start with the total number of present ports and a breakdown by connection
type, followed by a blank line. Types with no ports are omitted; an empty list shows
`Found 0 ports:` followed by a blank line.
If a description ends with the same port name in parentheses, that redundant suffix
and its surrounding whitespace are omitted from the default view. Verbose output
preserves the original description.

When standard output is a Windows console (including Windows Terminal), the
default view colors `(BL)` blue, `(USB)` yellow, and the trailing square-bracketed
details and Recent/Rest section headings gray, and compact ages aqua.
Both verbose levels use the same type colors in their detail
blocks, with detail labels in gray. Other text
retains the terminal's original colors.
Console support is detected automatically using Windows console APIs;
the background and original text attributes are preserved. Redirected output
and pipes stay plain UTF-8, with no color escape sequences.

Illustrative output (not a scan of your computer):

```text
Found 2 ports (1 bluetooth, 1 USB):

COM1   (USB) USB Serial Port [FTDI, USB: Future Technology Devices International, Ltd / FT232 Serial (UART) IC] +15 min
COM10  (BL)  Bluetooth serial port +9 h
```

Illustrative grouped output:

```text
Found 2 ports (1 bluetooth, 1 USB):

Recent (last 5 minutes):
COM1   (USB) USB Serial Port +2 min

Rest:
COM10  (BL)  Bluetooth serial port +9 h
```

`--verbose` (`-v`, with `-d` as an alias for details) shows only a detail block
for each port after the shared `Found ...` summary, headed by its COM name, with
a blank line between ports and no summary table. Detail blocks include
the type, full description and manufacturer, and USB vendor/product names
and interface number when available. Numeric USB VID/PID are omitted when both
vendor and product names are known; if either name is unknown, the IDs remain visible.

`-vv` shows the complete diagnostic output, additionally including `Instance ID`,
`Hardware IDs`, `Driver version`, `Location`, `USB instance`, `Driver provider`,
`Service`, and `Parent instance`. Numeric USB VID/PID are always included when
available, even when both names are known.
Repeating detail flags (for example, `-v -v` or `--verbose --verbose`) also selects
the full level; further repetitions stay at that level.
Both levels use the same colors and support `--usb-only`.

Both detail levels include `Last arrival:`, with the computer's local date and
time (including daylight saving time), and a relative age, for example
`2026-11-03 19:35:00 (5 minutes ago)`.
Relative ages use whole seconds, minutes, hours, or days; less than one second
ago is `just now`. A future timestamp is shown as `in ...`, not marked recent.
All ports in one output use the same reference time. Missing arrival metadata
is `Unknown`. Verbose output remains an ungrouped list of detail blocks,
ordered numerically unless `--sort-by-time` is selected.

The timestamp comes from Windows `DEVPKEY_Device_LastArrivalDate` for the COM
device node. It records the latest Plug and Play arrival, not necessarily physical
cable insertion: reboot, re-enumeration, or device/driver restart can update it.
Multiple ports of one device can have the same arrival time. Availability depends
on the device and Windows; installation dates and parent-device timestamps are
not used as substitutes. No port is opened and no connection history is stored.

Both detail levels preserve full manufacturer and description values. Missing metadata
is shown as `Unknown`. Every detail label ends with a colon, with values aligned
in a shared column (for example, `Type:`, `Description:`, and `USB VID:PID:`).

For ports classified as `USB`, all output levels include the vendor and product names.
Verbose details label these as `USB vendor` and
`USB product`, resolved from the embedded USB ID Repository snapshot, supplemented
with the [Raspberry Pi USB product ID list](https://github.com/raspberrypi/usb-pid)
for VID `2E8A`, using the device VID/PID. Existing usb.ids names take precedence;
the supplement adds missing products using their Product Description, excluding
reservations and empty descriptions. These are separate from the Windows-reported manufacturer
and description, which are preserved. An unlisted ID is `Unknown` in verbose
output and omitted from the default view; a listed
vendor is still shown when the product is unlisted. A missing or corrupt embedded
database is an error (exit code `1`) when a USB lookup is needed, at any output level.
The lookup never accesses the network or opens a device. The database is
MSZIP-compressed in the executable and decompressed once before the first
USB lookup. Its memory is released after resolving the names; help/version
and scans without USB lookups do not decompress it.

`--help` (`-h`) and `--version` do not enumerate devices.
`--version` also shows the embedded database sources' upstream snapshot dates
and the Raspberry Pi source commit:

```text
comls 0.1.0

USB vendor and product ID sources:
  usb.ids: 2026-06-26
  raspberrypi/usb-pid: 2026-10-16 (550d9fc1a39859daa80321c4ec1341c1bdabb7de)
```

The usb.ids date comes from the source snapshot's `# Date:` header. The Raspberry
Pi date is the UTC commit date of the latest source revision affecting `Readme.md`,
and its full commit SHA identifies the downloaded revision. Neither date is the
download or build time. This metadata is compiled into the executable without
decompressing the database, so version output works without Git history or external files.

Console output uses Unicode. Redirected output is UTF-8 without a BOM:

```powershell
.\build\comls.exe --verbose > ports.txt
```

Device identifiers may identify your hardware. Review and redact diagnostic output
before posting it publicly.

## Build and test

Target: **Windows 10/11, x64**. Administrator rights are not required to run comls.

Install **Visual Studio Build Tools** with the **Desktop development with C++**
workload (MSVC x64/x86 compiler and Windows SDK), and **PowerShell 7**.
No CMake or third-party libraries are used.

From the repository root:

```powershell
pwsh -NoProfile -File .\build.ps1
pwsh -NoProfile -File .\build.ps1 -Test
```

Normal builds do not download data and work offline.
It works from a regular terminal; a Developer Command Prompt is not required.
`build\comls.exe` is the standalone Release executable. Copy that file to a directory
on your `PATH` to invoke it as `comls`. PowerShell and the compiler are build/test
tools only, not application dependencies.

The Release build optimizes for size, removes unused code, and statically links the
C runtime (`/MT`), so the Visual C++ Redistributable is not required. The build prints
the actual executable size; size and runtime vary with compiler and hardware.

A local build with the 2026.06.26 snapshot measured **441,344 bytes (431 KiB)**,
compared with 906,752 bytes (about 886 KiB) with the uncompressed database.
The 750,443-byte indexed database compresses to 285,180 bytes. A USB
lookup temporarily needs about 733 KiB for the decompressed data. Compression
and decompression use the system `cabinet.dll`, available on the supported
Windows versions; no additional DLL is distributed.
These are local observations, not size or performance guarantees; the build
prints the actual executable size.

`-Test` builds and runs C unit tests and PowerShell CLI smoke tests. Synthetic
fixtures cover empty/error discovery and Unicode metadata without modifying or
opening real devices. Unit tests cover port validation, sorting, merging, transport
classification, USB identifier parsing, Unicode console output, console colors
and attribute restoration, plain redirected output, exact UTF-8 bytes,
and output errors. USB tests cover deterministic conversion, source validation,
failed-update preservation, deterministic MSZIP compression, decompression size
limits and cleanup, corrupt/truncated streams, binary validation, scoped vendor/product lookup,
Unicode names, USB-only enrichment in both views, missing/corrupt resources, and
standalone execution without external data files. Raspberry Pi tests cover Markdown
table parsing, reservations, source provenance, collision precedence, deterministic
merging, and paired-update failure preservation. CLI smoke tests also enumerate local
devices, but do not require a particular port or attached hardware.

GitHub Actions runs the same build and tests on Windows for pushes and pull requests.
Tests also require Git to exercise release versioning in temporary local repositories;
they never create real releases or write to GitHub.

## Releases and versioning

The existing **CI** workflow builds and tests every push and pull request. A successful
push to `main` additionally tags the exact tested commit and publishes an Alpha
prerelease. Other branches and pull requests cannot publish. Release mutations are
serialized, with up to 100 pending jobs queued rather than replaced by newer pushes;
tags created with the workflow token do not trigger another CI run.

Tags use `vX.Y.Z` (Git does not allow spaces in tag names). `--version` reports
`X.Y.Z`; Alpha/stable is a GitHub release status, not a suffix in the binary.
The version is calculated as follows:

- `X.Y` comes from `COMLS_VERSION` in `src\ports.h`; its source patch component
  remains the default for ordinary local builds.
- Without a `vX.Y.0` baseline tag, `Z` is the number of commits in the target
  commit's first-parent history, including the root.
- With that baseline, `Z` is the number of first-parent commits **after** it.
  The baseline itself has `Z = 0`. A baseline off the target's first-parent
  history is an error.

For example, without a baseline, the fifth mainline commit with source version
`0.1.0` becomes `v0.1.5`. If `v0.2.0` marks the first commit in a new series,
the next mainline commit becomes `v0.2.1`. A PR merge counts once, regardless of
the number of commits in the merged branch. Rebase/fast-forward merges can add
multiple mainline commits. Failed or skipped workflow runs can leave version gaps.

Change X/Y in source when starting a new series. To reset its counter, explicitly
create a baseline tag **before that series has published releases**, on the intended
mainline commit (replace the example SHA):

```powershell
git tag v0.2.0 <full-commit-sha>
git push origin v0.2.0
```

A tag push alone does not publish a release; the next push to `main` does.
Changing X/Y without creating a baseline continues counting from the start of
history. Do not move version tags, rewrite main's published history, or add a
baseline retroactively to a series with releases; doing so changes the numbering.
Keep published main history append-only and protect it with required CI checks.

For a versioned local build, without changing tracked source:

```powershell
pwsh -NoProfile -File .\build.ps1 -Test -Version 0.1.42
```

Running the normal build again restores the source version. Generated version
headers stay under ignored `build\`; ordinary builds do not need Git history.

### Promoting an Alpha to stable

In **Actions > CI > Run workflow**, select branch **main** and enter an existing
Alpha tag, such as `v0.1.42`. The workflow verifies its mainline commit, version,
assets, checksums, and executable version, then clears the prerelease flag,
updates the release title/notes, and marks it **Latest**. It does not rebuild,
retag, or replace files. The selected Alpha can be older than the current main.
Repeating promotion of an already stable release leaves it unchanged.

The workflow uses only the built-in `GITHUB_TOKEN`, with `contents: write` limited
to publishing/promotion jobs. Repository or organization policies must allow that
permission and creation of `v*` tags. No personal access token or other secret is
needed. Branch protection and tag rules must not prevent the workflow from creating
new version tags; existing tags are never moved.

Assets are uploaded and verified in a draft before publication. To recover a
transient upload failure, rerun **failed jobs**, reusing the tested executable
artifact (retained for seven days). Existing matching draft files are reused;
conflicting files fail explicitly and are never overwritten. An identical
publication rerun preserves an already published release, including a stable
release's status. Rebuilding the whole workflow may produce different bytes
because compiler output is not guaranteed reproducible; an asset conflict then
requires investigation rather than automatic replacement. An expired artifact
also requires investigation; the publisher does not silently rebuild it.

All releases are retained. The release scripts use PowerShell and GitHub CLI;
there is no separate release framework, installer, or runtime dependency.

The Scoop manifest is updated manually, independently of release publication. To
update `comls.json`, select a published release and change its version,
both asset URLs, and both SHA-256 hashes using that release's `SHA256SUMS.txt`.
Update the README if the selected release is no longer an Alpha.

## Discovery and classification

comls enumerates currently present COM device interfaces and the Ports/Modem device
classes using SetupAPI, with the live `SERIALCOMM` registry map as a fallback for
ports without standard PnP metadata. Configuration Manager supplies properties and
device ancestry. The results are merged by COM name.

| Type | Evidence |
| --- | --- |
| `Native` | The port itself is PCI-enumerated or a standard ACPI serial controller |
| `USB` | A USB device appears in the port's ancestry |
| `Bluetooth` | A Bluetooth serial device appears in the ancestry, even if its radio uses USB |
| `Virtual` | A recognized software/virtual enumerator appears in the ancestry |
| `Unknown` | Metadata does not establish one of these categories |

Classification reflects driver metadata, not a physical inspection. For example,
a PCI management-controller serial endpoint is `Native` even if it is not an
external RS-232 connector. Arbitrary proprietary virtual ports cannot always be
recognized. The manufacturer is the driver-reported value, not necessarily the
manufacturer of the final product.

For Bluetooth ports backed by a USB radio, verbose USB details describe that radio,
not the remote Bluetooth device. The connection type remains `Bluetooth`, and
database vendor/product names are not added for these ports.

USB database names identify the registered VID/PID, not necessarily the final
marketed device: they may describe a chipset, bridge, or generic product family.
They do not change transport classification or verify device authenticity.

comls does not infer a USB serial number from the trailing instance ID, which can
instead be a Windows-generated location identifier. USB instance IDs are available
in full diagnostic output (`-vv`), but are not labeled as serial numbers.

Only present devices are listed, not disconnected historical devices. Enumeration
does **not** open ports, change settings, test communication, or check whether another
application has a port open. A listed port is not guaranteed to be free or working.
Hot-plugging can change the result during a scan.

Local hardware verification covered a PCI/AMT serial endpoint, Bluetooth serial
ports backed by a USB radio, and a USB serial device. Proprietary virtual drivers
were not exercised on real hardware; virtual/unknown cases have synthetic coverage.

## Contributing and security

See [CONTRIBUTING.md](../CONTRIBUTING.md) for development and
[SECURITY.md](../SECURITY.md) for security reporting. Repository source, comments,
documentation, and other authored text are in English.

## Updating the USB database

The complete USB ID Repository snapshot is committed as `data\usb.ids`.
Normalized Raspberry Pi assignments and their repository, path, source timestamp,
and commit are committed together as `data\raspberrypi-usb-pid.json`. To update both:

```powershell
pwsh -NoProfile -File .\scripts\update-usb-ids.ps1
pwsh -NoProfile -File .\build.ps1 -Test
```

The update script explicitly downloads https://usb-ids.gowdy.us/usb.ids over HTTPS
with a timeout and no redirects. It validates vendor/product syntax, UTF-8 names,
and unique IDs, plus a valid upstream date header, before replacing the old snapshot. A failed download or validation
leaves the old snapshots unchanged. It also queries the public GitHub REST API
for the latest commit affecting `raspberrypi/usb-pid`'s `Readme.md`, downloads that
file pinned to the returned full SHA, and validates its VID, table structure,
unique PIDs, and UTF-8 product descriptions. Both downloads use HTTPS, a timeout,
and no redirects. GitHub API errors, including rate limits, fail the update
explicitly; normal builds never use the API.

Both sources are staged and validated before replacing either snapshot. If a
replacement fails, the script restores the previous snapshots; a filesystem error
that also prevents restoration is reported and leaves recovery backups in place.
Review and commit both resulting snapshots; rebuilding is required to update
the names in an existing executable. The original usb.ids file is not modified
by the Raspberry Pi import. All usable assignments under VID `2E8A` are included,
not only RP2040 products; no MCU type or transport is inferred from a PID.

The build-time converter is `scripts\convert-usb-ids.ps1`, followed by
`scripts\compress-usb-ids.ps1`. The indexed `build\usb_ids.bin` is compressed to
`build\usb_ids.mszip`, which is embedded as RCDATA; generated binaries and
resources stay under ignored `build\`. The converter includes all vendors/products, ignoring
USB interface names, classes, and the remaining non-device sections (which can
contain legacy-encoded text). Runtime lookup uses sorted vendor/product indexes,
binary search, and an uncompressed UTF-8 string pool. Format version 1 uses
little-endian 32-bit integers: a 32-byte header (`CUSBIDS\0`, version, vendor count,
product count, string-pool offset, string-pool size, reserved zero), 16-byte vendor
records (VID, relative name offset, first product index, product count), 8-byte
product records (PID, relative name offset), and NUL-terminated strings. Product
ranges are contiguous and sorted within each sorted vendor. This indexed format
is unchanged by compression: the resource uses the Windows Compression API's
MSZIP buffer format, which carries the decompressed size. Both build-time
compression and runtime decompression limit the indexed data to 64 MiB.
After decompression, the indexed database is validated before any lookups;
decompression failures use the same error path as other corrupt-resource errors.

## License

comls code is [MIT](../LICENSE). The USB ID Repository database is distributed using
its BSD-3-Clause option; see [the database attribution and license](../data/usb.ids.LICENSE)
and [upstream licensing](https://usb-ids.gowdy.us/). The snapshot's original header
is retained, and the attribution/license notice is embedded as a separate RCDATA
resource in the executable. The Raspberry Pi assignments use BSD-3-Clause;
see [their attribution and license](../data/raspberrypi-usb-pid.LICENSE), also embedded
as a separate RCDATA resource. Include both third-party notices when distributing
the executable; GitHub releases combine them with the application license in `LICENSE`.
The application needs only the executable to run.
