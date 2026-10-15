# CATS Development Notes

Handoff notes for whoever picks up CATS next, person or Claude session. See
[README.md](README.md) for what the app does and how operators use it.

Status as of 2026-10-15: the app is feature-complete on the simulated VNA and the
Keysight N5230A. **Next step: bring up the production VNA-485E** (checklist below).

---

## 1. Repos and layout

| Repo | Local path (dev PC) | What it is |
|---|---|---|
| `cdeveauCTS/CATS` | `D:\MATLAB\CATS` | This app |
| `cdeveauCTS/rf-test-common` | `D:\MATLAB\rf-test-common`, and `common/` here as a submodule | VNA drivers, part profiles, pass/fail evaluation, report writer. Shared with 3TS. |
| `Thermal Phase Tracking` (3TS) | `D:\MATLAB\Thermal Phase Tracking` | Thermal test app. Branch `feature/shared-common` moves it onto the submodule; not merged, and its submodule pointer is out of date. |

```
CATS/
  CATSApp.m          entry point (waitfor when compiled)
  CATS.prj           MATLAB project: puts the root and common/ on the path
  +CATS/App.m        the whole UI and controller (~3400 lines, programmatic uifigure)
  +CATS/Storage.m    batches, records, logs, data folders
  +CATS/Settings.m   %APPDATA%\CATS\settings.json
  +CATS/Theme.m      CTS colours, fonts, light/dark
  +CATS/SerialNumber.m
  Tests/CATSCoreTest.m
  build/             (empty: compiling to CATS.exe not started)
  docs/              vendor quote and cal certificate (git-ignored)
  common/            rf-test-common submodule
    +VNA/            VNABase, VNAFactory, Drivers/, Config/*.json, Utilities/DiscoverVNAs
    +Specs/          loadProfile, evaluate, criterionTypes, writeReport, drawSpecOverlays, ...
    Profiles/        1233-1236.json (filters), CER0943B.json (diplexer)
```

**Changing shared code:** commit and push in `rf-test-common` first. Then in CATS:
`cd common`, `git pull origin main`, `cd ..`, `git add common`, commit, push.

**Setting up a new PC:**

```
git clone --recurse-submodules https://github.com/cdeveauCTS/CATS.git
```

In MATLAB, open the project with `openProject("CATS.prj")`, then run `app = CATSApp();`.

The PC needs:
- MATLAB R2026a with RF Toolbox and Instrument Control Toolbox
- a VISA library (Keysight IO Libraries is used on the dev PC)

## 2. Working rules (learned the hard way)

- **Close CATS before editing `+CATS/App.m` or any driver.** Editing a class while an
  instance is open breaks that window. It shows errors like "Unable to find function
  @(~,~)obj.onEngineeringPush()" and locks up. Check first with
  `findall(groot,'Type','figure')`.
- **Keep MATLAB responsive.** A sweep timer firing every 0.1 s, slower than the sweep
  itself, once hung MATLAB until a reboot. The sweep timer is `fixedSpacing`, with
  `BusyMode drop` and at least a 0.3 s gap (`SweepGapSec`). The sweep callback uses
  `drawnow limitrate`. Keep it that way.
- After a test script, make sure no timers, figures or VISA sessions are left:
  `timerfindall`, `findall(groot,'Type','figure')`, `visadevfind`.
- `clear classes` also clears workspace variables.
- UI testing: `App.ScriptedAnswers` answers dialogs in order. Components are tagged
  `CATS_<name>`, so `findobj(app.Figure,'Tag','CATS_EngMode')` finds them.
  `refresh`, `refreshInstrument` and other callbacks are private. Drive them through
  component callbacks, for example `c.ButtonPushedFcn(c,[])`.

## 3. Decisions made with the user

- **PASS** is enabled only when every criterion passes. **FAIL** is always available.
- **Overridable criteria**: HSR on 1233-1236, because the fixture's RF coupling makes
  parts fail that pass on low-coupling fixtures and SMA eval boards. This enables
  **PASS w/ Override**.
  - The override needs a statement, asked once per criterion per batch and reused for
    later parts.
  - The statement is stored in Settings per profile and criterion.
  - It is recorded in the metadata, the batch log Notes, and the report NOTES column.
- **Uncorrected testing** is a switch in Engineering mode (Instrument tab).
  - The cal check then only checks the sweep settings.
  - The Test and Instrument tabs show UNCORRECTED in bold orange.
  - Every saved part is marked UNCORRECTED in its metadata, log Notes and report NOTES.
  - It turns off at batch end, when Engineering mode is turned off, and on restart.
- **ECal**: CATS pushes the profile sweep, then asks the operator to run ECal on the
  VNA. It then verifies that correction is on and the sweep matches the profile.
  - `VNA_485E.runECal()` exists for a future "Run ECal" button.
- **Serials** are text ending in a number. The number auto-increments and keeps its
  zero padding. Operators can Skip a serial or enter one by hand. Retesting a serial
  returns to where the batch had got to.
- **Batches** run from Start to Finish, and Finish writes the report. Day/shift reports
  come from the Reports tab. Operator ID defaults to USERNAME.
- **Filter profiles** (1233-1236) sweep 20 MHz-6 GHz, 6401 points, 10 kHz IFBW,
  -5 dBm. The user specified these values.
- **PH (phase) and GDU (group delay unit-to-unit)** are measured at 1850 MHz against
  reference values. The references are medians of the 3TS FAQ3 20 °C data in
  `D:\Echodyne\Thermal Phase`.
  - Phase: within ±45° of the reference (90° total spread).
  - Group delay: within ±2.5 ns.
- **Ultimate rejection** (3.5-4.5 GHz) was removed. It was a soft goal, not a spec.
- **CER0943B (diplexer) criteria** were copied from the customer report
  `ILRLRippleAtt_CER0943B_3296319_9162026 Table 3.xls.xlsx` (Room limits), via 3TS
  `+PartSwap/reportSpecs.m`.
  - Assumed port mapping: 1 = Common, 2 = Low band, 3 = High band.
  - The pass direction of each limit was inferred from its label and sign.
  - Worth confirming against a real spec sheet.
- **Look**: 3TS colours (CTS blue, green, orange) with a light/dark switch. Title
  "Acceptance Test System" next to the CTS logo; the compiled launcher will be
  named CATS.

## 4. VNA drivers

All drivers derive from `VNA.VNABase` and are created by `VNA.VNAFactory.create(cfg)`
from `+VNA/Config/<Model>.json`. `DiscoverVNAs` sends `*IDN?` to known and entered
addresses and matches each reply against every config's `IdnPattern` (a regexp,
case-insensitive).

| Model | Status | Notes |
|---|---|---|
| `SIM` | Done | Hidden unless Settings → "List the simulated VNA". `tuneToProfile` makes a golden part. |
| `N5230A` | Done, tested | PNA-L A.06.04.32 at `TCPIP0::192.168.1.200::5025::SOCKET`. See the quirks below. |
| `VNA485E` | **Written, untested** | iTest VNA-485E. Uses Keysight ENA E5071C-style SCPI. |

**N5230A quirks:**
- `inst0` fails; use the raw socket.
- 8 traces per window.
- Querying a window that doesn't exist, or `SYST:CHAN:CAT?`, hangs with no reply.
- Error +106 means a measurement that doesn't exist was selected.
- It sweeps every source port that any measurement on the channel uses. The driver
  deletes unused `PS_*` measurements for this reason.
- The screen doesn't redraw while held, so the app triggers one sweep after every push.

### VNA-485E bring-up checklist

Background: the VNA-485E is 4-port, 8.5 GHz, with TDR, serial VNA485E-21055, and
comes with an ECK09 ECal. The vendor says its SCPI is "100% Keysight compatible".
Its specs match the E5071C, so the driver
(`common/+VNA/+Drivers/VNA_485E.m`) uses E5071C commands:
- numbered traces (`CALC1:PAR:COUN`, `CALC1:PARn:DEF S21`)
- `TRIG:SOUR BUS` + `INIT1:CONT ON` + `TRIG:SING` + `*OPC?`
- `CALC1:SEL:DATA:SDAT?`, with frequencies from `SENS1:FREQ:DATA?`
- per-channel `SENS1:CORR:STAT?`
- no named cal sets

The vendor's `IOLib.exe` package has **not** been installed. It may replace the
Keysight VISA, so try without it first.

Steps:

1. **Answer `*IDN?`.** Try a socket first:
   ```matlab
   v = visadev("TCPIP0::<ip>::5025::SOCKET"); writeread(v,"*IDN?"), clear v
   ```
   If that fails, try `::inst0::INSTR` or `::hislip0::INSTR`, or USB (`visadevlist`).
2. **Make CATS recognise the reply.** Set `IdnPattern` in `common/+VNA/Config/VNA485E.json`
   to match it. It currently matches `VNA-?485`. If the instrument claims to be an
   E5071C, use something unique to it. Add the working resource to `KnownResources`.
3. **Connect.** In CATS, at "No VNA Found", choose Enter Address... and give the IP or
   resource. If the address is missing, the driver tries socket 5025, then `inst0`,
   then `hislip0`.
4. **Traces.** Start a 1233 batch. Expect 4 traces on channel 1: S11, S21, S12 and S22.
   A diplexer needs 9 traces. If the limit is lower, the driver raises
   `VNA:TooFewTraces`; raise the limit in System → Misc Setup → Channel/Trace Setup.
5. **Sweep.** Check that `TRIG:SING` + `*OPC?` waits for the full multi-port sweep.
   The timeout scales with `SENS1:SWE:TIME?`.
6. **Data.** Check that `CALC1:SEL:DATA:SDAT?` returns 2 × points values (re/im pairs)
   and that `FORM:DATA ASC` is accepted.
7. **Correction.** Check that `SENS1:CORR:STAT?` reads 1 after ECal, and that CATS
   shows "Cal verified".
8. **Errors.** Use the Instrument tab → Read and Clear Errors after each step. Any
   `-113 Undefined header` means a command needs that instrument's spelling.
9. **Later.** `runECal([1 2])` sends `SENS1:CORR:COLL:ECAL:SOLT2 1,2`. Verify it with
   the ECK09 before adding a button.

The driver prints each step to the command window. Copy that output when reporting a
problem.

## 5. Open items

1. VNA-485E bring-up (above).
2. Compile `CATS.exe` (Phase 3) with `compiler.build.standaloneApplication` plus an
   installer. `build/` is empty. Target PCs need MATLAB Runtime R2026a and VISA.
3. Eval boards (EB) show about +35° phase offset vs the fixture. A per-fixture phase
   offset is not implemented yet.
4. Unit 1235-1 is a phase outlier (+47.8°) in the low-coupling data; it hasn't been
   checked yet.
5. Dark-mode variant of the CTS logo.
6. 3TS: update the `feature/shared-common` submodule pointer and merge.

## 6. Tests

```matlab
runtests("Tests")           % CATS core: 6 tests (serials, settings, storage, logs, notes)
runtests("common/Tests")    % SpecsTest: 13 tests (profiles, evaluate, reports)
```

There is no automated UI test in the repo. On the dev PC, scripted smoke runs drove
the app on the simulated VNA (`ScriptedAnswers` plus component callbacks) and on the
N5230A. The full flow was exercised: batch, Engineering push, uncorrected mode, sweep,
PASS, finish.
