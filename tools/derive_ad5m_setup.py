#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#!/usr/bin/env python3
"""Derive klipper/extras/ad5m_setup.py from Kiln's ad5x_setup.py (the AD5X-only parts replaced).

This is how ad5m_setup.py was made; it is kept so the differences can be reviewed (diff the two
files) and re-derived when ad5x_setup.py changes. It rewrites ad5m_setup.py: re-apply by hand any
later edit made to that file, or move it into this script first. Run from a Kiln OS checkout:
    python3 tools/derive_ad5m_setup.py
"""
import re, sys
import os
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "klipper", "extras", "ad5x_setup.py")
DST = os.path.join(HERE, "..", "klipper", "extras", "ad5m_setup.py")
s = open(SRC, encoding="utf-8").read()

def block_span(text, name):
    m = re.search(r"(?m)^    def %s\(" % re.escape(name), text)
    if not m:
        raise SystemExit("block not found: " + name)
    n = re.search(r"(?m)^(    def |def |class |    # [A-Z][a-z]+ ?[a-z ]*\n    def )", text[m.end():])
    end = m.end() + n.start() if n else len(text)
    return m.start(), end

def replace_block(text, name, new):
    a, b = block_span(text, name)
    return text[:a] + new.rstrip("\n") + "\n" + text[b:]

def delete_block(text, name):
    a, b = block_span(text, name)
    return text[:a] + text[b:]

# ---- 1. names, endpoint, messages
s = s.replace("AD5XSetup", "AD5MSetup").replace("ad5x_setup/control", "ad5m_setup/control")
s = s.replace("ad5x_setup", "ad5m_setup").replace("AD5X setup", "AD5M setup")

# ---- 2. steps
s = re.sub(r'STEPS = \("selfcheck".*?"finish"\)', 'STEPS = ("selfcheck", "pid", "mesh", "shaper", "zoffset", "summary", "finish")', s, flags=re.S)
s = s.replace("SETUP_WIZARD_STEP STEP=<selfcheck|pid|mesh|shaper|ifs|zoffset|finish>", "SETUP_WIZARD_STEP STEP=<selfcheck|pid|mesh|shaper|zoffset|summary|finish>")
s = s.replace('"Setup wizard step: STEP=selfcheck|pid|trash|zoffset|mesh|shaper|"\n        "ifs|soak|summary|finish [ACTION=start|abort|adjust|accept] "',
              '"Setup wizard step: STEP=selfcheck|pid|mesh|shaper|zoffset|"\n        "summary|finish [ACTION=start|abort|adjust|accept] "')
s = s.replace('(\"zoffset\", \"trash\") if action == \'accept\'', '(\"zoffset\",) if action == \'accept\'')

# ---- 3. options
s = s.replace("'check_fans', 'fanM106, pcb_fan').split(',')", "'check_fans', 'part, chamber_fan').split(',')")
s = s.replace("self.filament_sensor = config.get('filament_sensor', 'toolhead')\n        self.require_ifs = config.getboolean('require_ifs', True)\n",
              "# a [filament_switch_sensor <name>] section\n        self.filament_sensor = config.get('filament_sensor', 'runout_sensor')\n        self.require_loadcell = config.getboolean('require_loadcell', True)\n        # where the head parks after a test patch (the AD5M's own centred coordinates)\n        self.park_y = config.getfloat('park_y', 105.)\n")
s = s.replace("config.getfloatlist('patch_center', (107.5, 107.5),", "config.getfloatlist('patch_center', (0., 0.),")
s = s.replace("'/home/klipper/printer_data/config/ad5x-tuning.cfg'", "'/home/klipper/printer_data/config/ad5m-tuning.cfg'")
s = re.sub(r"        # ESTIMATE=1 on the Z offset step.*?self\.estimate_enabled = config\.getboolean\('zoffset_estimate', False\)\n", "", s, flags=re.S)

# ---- 4. abort / make safe
s = re.sub(r"        # The soak waits for the bed to reach its target.*?soak\.abort = True\n", "", s, flags=re.S)
s = re.sub(r"        ifs = self\.printer\.lookup_object\('ifs', None\)\n        if ifs is not None:\n            ifs\.stop_requested = True     # as IFS_STOP: ends a tuning feed\n", "", s)
s = s.replace('script += ["_PARK_END", "M84 X Y E"]', 'script += ["_AD5M_PARK", "M84 X Y E"]')

# ---- 5. delete the AD5X-only blocks
for name in ("_ifs_owner", "_step_ifs", "_step_trash", "_purge_box_pos", "_step_soak", "_estimate_start", "_scrub"):
    s = delete_block(s, name)
s = replace_block(s, "_reload_channel", '''    def _reload_channel(self):
        """No filament unit: nothing to reload."""
        return 0''')
s = replace_block(s, "_loaded_material", '''    def _loaded_material(self):
        """The AD5M has no filament unit that knows the material."""
        return None''')

# ---- 6. the self-check
s = replace_block(s, "_step_selfcheck", '''    def _step_selfcheck(self, params):
        self.checks = []
        total = 6. + len(self.fans)
        def add(name, ok, detail, required=True):
            self.checks = self.checks + [{'name': name, 'ok': bool(ok),
                                          'detail': detail,
                                          'required': required}]
            self.progress = len(self.checks) / total
        def try_gcode(name, script, detail, required=True):
            try:
                self._gcode(script)
                add(name, True, detail, required)
            except self.printer.command_error as e:
                if self.abort_requested:
                    raise SetupAborted()
                add(name, False, str(e), required)
        # Boards. Klipper only gets ready with every MCU connected.
        now = self.reactor.monotonic()
        for name, mcu in self.printer.lookup_objects('mcu'):
            add("MCU %s" % (name.split()[-1],), True,
                mcu.get_status(now).get('mcu_version', 'connected'))
        self._set("Checking the accelerometer")
        if self._batch():
            # No sensor data in file output mode (the query would crash)
            add("Accelerometer", True, "not checked (file output mode)")
        else:
            try_gcode("Accelerometer", "ACCELEROMETER_QUERY", "answers")
        # The load cell: its zero is what the probe trigger is measured from.
        # LOAD_CELL_TARE (ad5m-macros.cfg) stops with an error when the module is missing.
        self._set("Checking the bed load cell")
        if self._batch():
            add("Bed load cell", True, "not checked (file output mode)")
        else:
            try_gcode("Bed load cell", "LOAD_CELL_TARE", "tared", self.require_loadcell)
        sensor = self.printer.lookup_object(
            'filament_switch_sensor %s' % (self.filament_sensor,), None)
        if sensor is None:
            add("Filament sensor", False, "not configured")
        else:
            present = sensor.get_status(now).get('filament_detected')
            add("Filament sensor", True, "filament" if present else "empty")
        # Fans, one at a time, check_time each. "part" is the [fan] section
        # (M106); the others are [fan_generic] fans.
        for fan in self.fans:
            if fan == "part":
                obj = self.printer.lookup_object('fan', None)
                label = "Part fan"
                on, off = "M106 S255", "M106 S0"
            else:
                obj_name = fan if ' ' in fan else 'fan_generic %s' % (fan,)
                obj = self.printer.lookup_object(obj_name, None)
                label = {"chamber_fan": "Chamber fan", "internal_fan": "Internal fan",
                         "external_fan": "External fan"}.get(fan, fan)
                on = "SET_FAN_SPEED FAN=%s SPEED=1" % (fan,)
                off = "SET_FAN_SPEED FAN=%s SPEED=0" % (fan,)
            if obj is None:
                # a fan this model does not have (the chamber fan on a plain 5M)
                add(label, True, "not on this printer", False)
                continue
            self._set("%s should spin now (%.0f s)" % (label, self.check_time))
            rpm = None
            try:
                self._gcode(on)
                self._pause(self.check_time)
                rpm = obj.get_status(self.reactor.monotonic()).get('rpm')
            finally:
                self._gcode_raw(off)
            if rpm is None:
                add(label, True, "ran %.0f s (no speed sensor)"
                    % (self.check_time,), False)
            else:
                add(label, rpm > 0, "%.0f rpm" % (rpm,))
        # Homing
        self._set("Homing")
        try_gcode("Homing", "G28", "X, Y and Z home")
        # Heaters, together: check_time on, then off; rise measured until
        # check_watch after switching off
        ext, bed = self._heater('extruder'), self._heater('heater_bed')
        t_ext, t_bed = self._temp(ext), self._temp(bed)
        tgt_ext = min(max(self.check_nozzle_temp, t_ext + 40.), 200.)
        tgt_bed = min(max(self.check_bed_temp, t_bed + 15.), 90.)
        max_ext, max_bed = t_ext, t_bed
        start = self.reactor.monotonic()
        try:
            self._gcode("SET_HEATER_TEMPERATURE HEATER=extruder TARGET=%g\\n"
                        "SET_HEATER_TEMPERATURE HEATER=heater_bed TARGET=%g"
                        % (tgt_ext, tgt_bed))
            while self.reactor.monotonic() - start < self.check_time:
                max_ext = max(max_ext, self._temp(ext))
                max_bed = max(max_bed, self._temp(bed))
                self._set("Heater test: nozzle %.1f C, bed %.1f C" % (
                    self._temp(ext), self._temp(bed)))
                self._pause(.5)
        finally:
            self._gcode_raw("SET_HEATER_TEMPERATURE HEATER=extruder TARGET=0\\n"
                            "SET_HEATER_TEMPERATURE HEATER=heater_bed TARGET=0")
        off = self.reactor.monotonic()
        while self.reactor.monotonic() - off < self.check_watch and (
                max_ext - t_ext < self.nozzle_rise
                or max_bed - t_bed < self.bed_rise):
            max_ext = max(max_ext, self._temp(ext))
            max_bed = max(max_bed, self._temp(bed))
            self._set("Heaters off; nozzle %.1f C, bed %.1f C" % (
                self._temp(ext), self._temp(bed)))
            self._pause(.5)
        if self._batch():
            # Klipper's test mode has no temperatures
            add("Nozzle heater", True, "not tested (Klipper test mode)")
            add("Bed heater", True, "not tested (Klipper test mode)")
        else:
            add("Nozzle heater", max_ext - t_ext >= self.nozzle_rise,
                "+%.1f C in %.0f s" % (max_ext - t_ext, self.check_time))
            add("Bed heater", max_bed - t_bed >= self.bed_rise,
                "+%.1f C in %.0f s" % (max_bed - t_bed, self.check_time))
        failed = [c['name'] for c in self.checks
                  if not c['ok'] and c['required']]
        ok = len([c for c in self.checks if c['ok']])
        self._result("selfcheck", "%d of %d checks OK" % (
            ok, len(self.checks)))
        if failed:
            raise self.printer.command_error(
                "Self-check failed: %s" % (", ".join(failed),))
        self._set("All checks passed", 1.)''')

# ---- 7. the mesh
s = replace_block(s, "_step_mesh", '''    def _step_mesh(self, params):
        keep_bed = int(params.get('KEEP_BED', 0) or 0)
        self._home()
        cx, cy = self.patch_center
        self._gcode("G90\\nG1 X%.1f Y%.1f Z10 F6000" % (cx, cy))
        try:
            self._heat_and_wait({'heater_bed': self.mesh_bed,
                                 'extruder': self.mesh_nozzle}, (0., .3))
            # As AUTO_BED_LEVEL: tare the load cell, wipe the nozzle by probing twice
            # at the plate's back edge, let the nozzle cool below ooze temperature,
            # then the mesh. Split here (not one AUTO_BED_LEVEL) so that every wait is
            # one the wizard can abort.
            self._set("Zeroing the load cell and wiping the nozzle", .32)
            # The Z offset from the step before is still applied: clear it for the
            # wipe (the macros' moves are in the plain frame)
            self._gcode("G90\\n_SET_GCODE_OFFSET Z=0\\nG1 Z5 F800\\nLOAD_CELL_TARE\\n"
                        "_AD5M_NOZZLE_WIPE")
            self._set("Letting the nozzle cool before probing", .4)
            self._gcode("M106 S255\\nM104 S0")
            self._cool_nozzle(120., (.4, .5))
            self._gcode("M106 S0\\nG1 X10 F300")
            self._set("Probing the bed", .5)
            self._gcode("BED_MESH_CALIBRATE PROFILE=default")
        except Exception:
            self._gcode_raw("SET_HEATER_TEMPERATURE HEATER=heater_bed "
                            "TARGET=0")
            raise
        finally:
            self._gcode_raw("SET_HEATER_TEMPERATURE HEATER=extruder TARGET=0\\nM106 S0")
        if not keep_bed:
            self._gcode("SET_HEATER_TEMPERATURE HEATER=heater_bed TARGET=0")
        bm = self.printer.lookup_object('bed_mesh').get_status(
            self.reactor.monotonic())
        points = [z for row in bm.get('probed_matrix') or [] for z in row]
        rows = bm.get('probed_matrix') or [[]]
        if points:
            self._result("mesh", "%dx%d points, range %.3f mm" % (
                len(rows[0]), len(rows), max(points) - min(points)))
        else:
            self._result("mesh", "done")
        self.pending_save = True
        self._set("Bed mesh ready to save", 1.)
    def _cool_nozzle(self, limit, prog):
        """Wait (abortable) until the nozzle is at or below limit C."""
        ext = self._heater('extruder')
        end = self.reactor.monotonic() + self.heat_timeout
        t0 = self._temp(ext)
        while self._temp(ext) > limit:
            if self.reactor.monotonic() > end:
                raise self.printer.command_error(
                    "The nozzle did not cool to %.0f C in %.0f s" % (
                        limit, self.heat_timeout))
            frac = 1. if t0 <= limit else min(1., max(0., (t0 - self._temp(ext)) / (t0 - limit)))
            self.progress = prog[0] + (prog[1] - prog[0]) * frac
            self._set("Nozzle cooling: %.0f C (to %.0f C)" % (self._temp(ext), limit))
            self._pause(.5)''')

# ---- 8. the Z offset step: no filament unit
a, b = block_span(s, "_step_zoffset")
z = s[a:b]
z = re.sub(r"        sensor = self\.printer\.lookup_object\(\n            'adc_filament_sensor.*?self\._gcode\(\"IFS_LOAD SLOT=%d\" % \(chan,\)\)\n", '''        sensor = self.printer.lookup_object(
            'filament_switch_sensor %s' % (self.filament_sensor,), None)
        if sensor is not None and not sensor.get_status(
                self.reactor.monotonic()).get('filament_detected'):
            raise self.printer.command_error(
                "No filament in the toolhead: load it first (LOAD_FILAMENT)")
''', z, flags=re.S)
z = re.sub(r"        start_z = self\.patch_start_z\n        if params\.get\('ESTIMATE'\).*?start_z = self\._estimate_start\(nozzle\)\n", "        start_z = self.patch_start_z\n", z, flags=re.S)
z = z.replace("# Keep it: SET_GCODE_OFFSET (ad5x.cfg's wrapper) saves zoffset", "# Keep it: SET_GCODE_OFFSET (ad5m-macros.cfg's wrapper) saves zoffset")
s = s[:a] + z + s[b:]
s = s.replace('"G1 X%.2f Y%.2f F12000" % (self.patch_center[0], 215.)]', '"G1 X%.2f Y%.2f F12000" % (self.patch_center[0], self.park_y)]')

# ---- 9. header, wording and the removed estimate attribute
a = s.index("# AD5X setup wizard steps") if "# AD5X setup wizard steps" in s else s.index("# AD5M setup wizard steps")
e = s.index("import logging")
header = """# AD5M setup wizard steps (first boot and on demand)
#
# WORK IN PROGRESS, NOT TESTED ON A PRINTER. Derived from Kiln OS's ad5x_setup.py (same contract,
# same plumbing; tools/derive_ad5m_setup.py shows what was replaced): the filament unit, purge box,
# bed soak and strain-gauge steps are gone, the self-check, the mesh and the Z offset step are
# the AD5M's (load cell tare, filament switch sensor, AUTO_BED_LEVEL's wipe, centred coordinates).
#
# SETUP_WIZARD_STEP STEP=<selfcheck|pid|mesh|shaper|zoffset|summary|finish>
# [ACTION=start|abort|adjust|accept] and the printer.ad5m_setup status
# object (the screen's wizard panels read it; docs/ad5m-wizard.md). Each step
# runs in the background (as virtual_sdcard does), taking the G-code lock
# only for each command it sends, so ACTION=abort/adjust/accept get
# through between them. The same actions are also a Klipper API endpoint,
# ad5m_setup/control (Moonraker: printer.ad5m_setup.control), which works
# even while a long command (PID_CALIBRATE, BED_MESH_CALIBRATE) holds the
# lock.
#
# Copyright (C) 2026  ad5x-open contributors
#
# This file may be distributed under the terms of the GNU GPLv3 license.
"""
s = s[:a] + header + s[e:]
s = re.sub(r"# Order on the screen\. The mesh step comes before.*?STEPS = ", "# Order on the screen. The mesh step comes before the Z offset step: the\n# mesh's nozzle wipe doesn't yet work after a Z offset step (the offset\n# is still applied there).\nSTEPS = ", s, flags=re.S)
s = s.replace("# picks one, default the loaded IFS slot's type, else PLA.", "# picks one, default PLA.")
s = s.replace("# Sections the calibrations write that ad5x.cfg (an include) also sets:", "# Sections the calibrations write that ad5m.cfg (an include) also sets:")
s = s.replace("# so finish writes them to tuning_file, which setup.cfg includes after\n# ad5x.cfg.", "# so finish writes them to tuning_file, which ad5m-setup.cfg includes after\n# ad5m.cfg.")
s = s.replace("            'estimate': self.estimate_enabled,\n", "            'estimate': False,      # the AD5X's load cell estimate: not on the AD5M\n")
s = s.replace('"[DELTA=] [WAIT=1] [ESTIMATE=1]; "', '"[DELTA=] [WAIT=1]; "')
s = s.replace("ad5x.cfg", "ad5m.cfg")
s = s.replace("leave the flag for the screen (S70helixscreen", "leave the flag for the screen (S80guppyscreen")

open(DST, "w", encoding="utf-8").write(s)
print("written", DST, len(s.splitlines()), "lines")
