# Repository and artifact policy

## Sources and evidence

The team GitHub repository is the implementation source of truth. Track RTL,
testbenches, scripts, XDC/Tcl, model exports and small input/golden vectors.
Compact npz/checkpoint inputs are retained deliberately; document provenance
and model role before replacing them. The separate assignment workspace is
learning/history, not another DUT copy.

Keep selected timing/utilization reports, test summaries and dated operator
logs under docs/reports with source revision, tool/top/configuration and
SHA256 manifest. Historical failures are useful. Never relabel an old report
as current or delete historical numbers globally.

Ignore transient builds, SDKs, virtual environments, GUI bin/obj, waveforms,
editor metadata and personal camera inputs. local_inputs/ is private; GUI
captures go under ignored build/. Inspect staged paths instead of blanket
`git add .` when personal files are present. A large ignored local folder
does not bloat GitHub; tree size and complete history size are different.

## Current and historical documentation

Update STATUS_AND_ISSUES.md and GETTING_STARTED.md for current behavior.
Architecture/interfaces describe active modules. STUDY_PROGRESS.md is a dated
journal; earlier pending statements describe those sessions. Preserve
superseded contracts/status snapshots in archive directories, linked to the
current index. Original report and test payloads stay intact.

## Review and releases

Use a feature branch, integrate main, run relevant checks, push and open a PR
with scope/evidence/limits. The Repository checks workflow runs Windows
host/GUI smoke plus Linux core simulations and documentation/archive checks
on PRs and main pushes, with read-only permissions and pinned action commits.
CI is not physical-board acceptance. Documentation
cleanup should not change RTL or weights.

Publish final bitstreams/executables/video as deliberate GitHub Release or
agreed delivery artifacts, not whole generated directories. Include source/tag,
build command/tool/top/part/clock, input hashes, bitstream hash, timing,
utilization/DRC and operator acceptance. No release or license selection is
implied by this policy. The team chooses the code license separately from
dataset attribution.
