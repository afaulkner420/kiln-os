# AD5M setup wizard

WORK IN PROGRESS. The Klipper side exists and is tested against a mock printer; the screen side (GuppyScreen
panels) is designed here and not written yet. Nothing has run on a printer.

The wizard is Kiln OS's, adapted: `klipper/extras/ad5m_setup.py` is derived from `ad5x_setup.py` by
`tools/derive_ad5m_setup.py` (same plumbing and status contract; the filament unit, purge box, bed soak and
strain-gauge steps replaced or removed). Its screen side on the AD5X is a set of HelixScreen patches
(`ui_wizard_ad5x_setup.cpp` and one XML layout per step); GuppyScreen needs its own.

## Steps

`selfcheck`, `pid`, `mesh`, `shaper`, `zoffset`, `summary`, `finish`. On the screen the user also sees the
language and touch calibration first (GuppyScreen's own calibration screen runs before anything else).

| Step | What it does on the AD5M |
|---|---|
| selfcheck | Lists the boards (both MCUs connected), accelerometer, **bed load cell** (tare through `LOAD_CELL_TARE`: fails the step if the load cell module is missing, on purpose), filament switch sensor, fans (part fan with M106, chamber fan if present; a 5M Pro adds internal/external via `check_fans`), homes, runs both heaters 10 s each |
| pid | PID for the nozzle (220 C, part fan on) then the bed (60 C); results are held until `finish` |
| mesh | Heats bed and nozzle, tares, wipes the nozzle by probing twice at the back edge, cools the nozzle below 120 C, `BED_MESH_CALIBRATE PROFILE=default`; every wait can be aborted |
| shaper | `SHAPER_CALIBRATE` for X and Y with the accelerometer (needs numpy: in the image) |
| zoffset | Heats for PLA (change with MATERIAL=), runs `PRINT_START ... LEVEL=0`, prints a 30 mm test patch at the centre (X/Y 0,0: the AD5M's coordinates are centred), the user presses Closer/Away (`adjust`) and `accept`; more patches beside the last on request; the result is saved as `zoffset = {'z': ..}` and applied by every `START_PRINT` |
| summary | Reads back the results |
| finish | Writes PID and shaper to `ad5m-tuning.cfg` (read after `ad5m.cfg`, so it wins) and the rest with `SAVE_CONFIG`; Klipper restarts, the screen reconnects |

## The contract the screen uses

Status object `ad5m_setup` (Moonraker subscription or `printer.objects.query`), keys: `step`, `state`
(`idle`, `running`, `waiting_user`, `done`, `failed`, `aborted`), `message`, `progress` (0 to 1), `results`
(a map step -> one line), `checks` (a list of `{name, ok, detail, required}`), `pending_save`, `zoffset`.

Actions: JSON-RPC `printer.ad5m_setup.control` with `{step, action[, delta][, keep_bed]}`, action one of
`start`, `abort`, `adjust` (with `delta`, at most 0.5 mm, 1 mm in all), `accept`, `wizard`. It works while a long
command holds the G-code lock. Fallback when the endpoint is missing: the G-code
`SETUP_WIZARD_STEP STEP=<step> ACTION=<action> [DELTA=<mm>]`.

Rerun request: the `SETUP_WIZARD` macro (or `ACTION=wizard`) writes
`/home/klipper/printer_data/comms/run-setup-wizard` and prints `// action:ad5m_setup_wizard`; a running
screen opens the wizard at once, otherwise at its next start (and then removes the file).

## What the GuppyScreen side has to be (from reading Helix's patches)

One panel, one reusable step card, driven only by the status object:
- Header: "Setup" and the step's name, "Step n of 7".
- Card: the step's explanation (below), a status message, a progress bar while `running`, a results line when
  `done`, the self-check list (one line per check: `OK`, `WARN` or `FAIL`, name, detail) for `selfcheck`.
- Buttons by state: `idle` Start; `running` Abort; `waiting_user` (Z offset only) Closer 0.05 / 0.01, Away
  0.05 / 0.01, Accept, Abort and "New patch"; `done` Run again (Next enabled); `failed`/`aborted` Retry (Skip
  enabled). Back is always possible; leaving a running step aborts it.
- The Z offset line shows the live `zoffset`, and a step in `running` with a heater must stay visible so the
  user can reach Abort and the emergency stop.
- Open when: the first start (the config key `setup_wizard_done` is false), the rerun flag above, a
  Settings entry "Run setup wizard", or the action line. After `finish` (Klipper restarts): set
  `setup_wizard_done` and delete the flag file.

Step texts (shortened from Helix's for 800x480; edit freely):
- selfcheck: "Checks the boards, accelerometer, bed load cell, filament sensor and fans, homes, and heats the
  nozzle and bed briefly. Fans and heaters each run about 10 seconds and switch off again."
- pid: "Tunes the heater control: the nozzle at 220 C with the part fan running, then the bed at 60 C. Takes 10
  to 20 minutes; stay near the printer."
- mesh: "Heats the bed to 60 C, cleans the nozzle on the bed edge and probes the bed to measure its shape. Keep
  the bed clear. The bed stays warm for the Z offset test that follows."
- shaper: "Measures the frame's vibrations with the toolhead accelerometer and sets vibration compensation. The
  printer is loud for a few minutes."
- zoffset: "Heats for PLA and prints a 30 mm test patch at the centre. While it prints, press Closer or Away until
  the lines are flat and just touch each other, then press Accept. New patch prints another beside it. Load
  filament first."
- finish: "Saves the results to the printer configuration. Klipper restarts and the screen reconnects by itself."

## Not covered yet

- The GuppyScreen panels themselves (C++ on LVGL; a patch to ghzserg/guppyscreen_ff5m, with its own rules in
  `AGENTS.md`: minimal changes, new comments in Russian, measure memory).
- The time zone step (Helix has one); Wi-Fi setup (this GuppyScreen build has no Wi-Fi client).
- Testing against a real Klipper: `tools/test_ad5m_setup.py` uses a mock printer; the image check
  (`tools/ad5m-verify-image.sh`) loads the module through Klipper's own test mode when QEMU is available.
