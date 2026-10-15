# CATS — CTS Acceptance Test System

Room-temperature bench acceptance testing for production: load a part profile,
sweep each part live on the VNA, PASS / FAIL, and produce the test report.

## Run

```matlab
openProject("CATS.prj")   % puts the app and common/ on the path
app = CATSApp();
```

After cloning: `git submodule update --init` (fetches `common/` = rf-test-common:
VNA drivers, part profiles and pass/fail evaluation shared with 3TS).

## Operator workflow

1. CATS finds and connects the VNA on launch.
2. **Start Batch**: part profile, operator, work order, first serial. The profile's
   sweep is pushed to the VNA; run ECal when prompted; CATS verifies the cal
   (correction on, sweep matches the profile) before testing is allowed.
3. **Start** sweeps live. The wideband plot (top) and passband plot (bottom) show
   every criterion's limit; the table shows values and PASS/FAIL.
4. **PASS** (only when every criterion passes) or **FAIL** saves the sweep and
   metadata and moves to the next serial. **Skip** logs a missing serial;
   **Set Serial…** jumps (a retest returns to where the batch had got to).
5. **PASS w/ Override**: when only criteria marked `Overridable` in the profile fail
   (e.g. HSR on fixtures with RF coupling). A statement is required the first time
   and reused for the rest of the batch (Edit… to change it); it is recorded in the
   metadata, batch log and report NOTES.
6. **Finish Batch** writes the report (ILRLRippleAtt "Table 3" layout, columns from
   the profile). The **Reports** tab also writes batch and day/shift reports later.

Tabs: Test · Log (all results at this station, from disk) · Review (overlay and compare
saved Touchstone files against a profile) · Reports (batch and day/shift, with preview) ·
Instrument (VNA connection, sweep vs profile, cal per S-parameter, errors; Engineering
mode to push a sweep by hand).
Light/Dark switch in the header; settings are saved per user.

## Data

```
<DataRoot>/<yyyy-MM-dd>/<Profile>/
    Batch_<id>.csv, Report_<Profile>_<id>.xlsx
    <Serial>/SweepData/<Serial>_<timestamp>.s2p|.s3p
    <Serial>/Metadata/<Serial>_<timestamp>.json
```

Defaults: data in `C:\Users\Public\Documents\CATS\Data`, editable profiles in
`C:\Users\Public\Documents\CATS\Profiles` (seeded from `common/Profiles` on first
run). Change both under **Settings**.

## Tests

```matlab
runtests("Tests")          % CATS core: serials, settings, storage
runtests("common/Tests")   % profiles, evaluation, reports, discovery
```

The simulated VNA (Settings → "List the simulated VNA") makes a golden part for the
selected profile, so the whole workflow can be exercised without hardware.

## Hardware

Production VNA: iTest (Itenest) VNA-485E, 8.5 GHz, 4-port, with ECK09 ECal. Driver
`common/+VNA/+Drivers/VNA_485E.m` (Keysight ENA E5071C-style SCPI) is written but not
yet tested on the instrument. Also supported: Keysight N5230A (lab stand-in) and the
simulated VNA. Vendor documents live in `docs/` (not in git).

Development status, decisions and the hardware bring-up checklist:
[DEVELOPMENT_NOTES.md](DEVELOPMENT_NOTES.md).
