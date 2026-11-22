#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs klipper/extras/ad5m_setup.py against a mock printer (no Klipper needed): construction, the
# status contract, the self-check branches (batch mode, missing chamber fan, missing load cell), the
# dispatch rules, the Z offset test patch geometry and the order of the mesh step's commands.
# usage: python3 tools/test_ad5m_setup.py     (exit status 1 if anything fails)
import sys, types, importlib.util, logging, time
logging.disable(logging.CRITICAL)
import os
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ad5m_setup", os.path.join(HERE, "..", "klipper", "extras", "ad5m_setup.py"))
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)

class CmdError(Exception): pass
class Reactor:
    def __init__(self): self.t = 1000.
    def monotonic(self): return self.t
    def pause(self, t): self.t = max(self.t, t)
    def register_callback(self, cb): cb(self.t)
class Gcode:
    def __init__(self): self.sent=[]; self.cmds={}; self.info=[]
    def register_command(self, name, fn, desc=None): old=self.cmds.get(name); self.cmds[name]=fn; return old
    def run_script(self, s): self.sent.append(s)
    run_script_from_command = run_script
    def respond_info(self, m, log=True): self.info.append(m)
class Web:
    def __init__(self): self.ep={}
    def register_endpoint(self, n, f): self.ep[n]=f
class Heater:
    def __init__(self, t): self.t=t; self.control=None
    def get_status(self, e): return {'temperature': self.t}
    def set_control(self, c): old=self.control; self.control=c; return old
    def get_name(self): return "h"
class Heaters:
    def __init__(self): self.heaters={'extruder':Heater(25.),'heater_bed':Heater(24.)}
    def lookup_heater(self, n): return self.heaters[n]
    def turn_off_all_heaters(self): pass
class Mcu:
    def get_status(self, e): return {'mcu_version':'v0.13.0-808'}
class Fan:
    def get_status(self, e): return {}
class Switch:
    def __init__(self, d): self.d=d
    def get_status(self, e): return {'filament_detected': self.d}
class Printer:
    def __init__(self, batch=True, objs=None):
        self.r=Reactor(); self.g=Gcode(); self.w=Web(); self.batch=batch
        self.objs={'gcode':self.g,'webhooks':self.w,'heaters':Heaters(),
                   'mcu':Mcu(),'mcu eboard':Mcu(),'fan':Fan(),'fan_generic chamber_fan':Fan(),
                   'filament_switch_sensor runout_sensor':Switch(True),
                   'save_variables':types.SimpleNamespace(allVariables={'zoffset':{'z':-0.1}}),
                   'toolhead':types.SimpleNamespace(get_status=lambda e:{'homed_axes':'xyz'}),
                   'print_stats':types.SimpleNamespace(get_status=lambda e:{'state':'standby'})}
        if objs: self.objs.update(objs)
        self.command_error=CmdError; self.config_error=ValueError
    def get_reactor(self): return self.r
    _S=object()
    def lookup_object(self, n, d=_S):
        if n in self.objs: return self.objs[n]
        if d is Printer._S: raise KeyError(n)
        return d
    def lookup_objects(self, prefix): return [(k,v) for k,v in self.objs.items() if k==prefix or k.startswith(prefix+' ')]
    def register_event_handler(self, *a): pass
    def get_start_args(self): return {'debugoutput': 'x'} if self.batch else {}
    def is_shutdown(self): return False
class Config:
    def __init__(self, p): self.p=p
    def get_printer(self): return self.p
    def getfloat(self, n, d=None, **k): return d
    def getboolean(self, n, d=None): return d
    def get(self, n, d=None): return d
    def getfloatlist(self, n, d=None, count=None): return d

fails=0
def check(name, cond, extra=""):
    global fails
    print(("ok   " if cond else "FAIL ")+name+(" "+str(extra) if extra and not cond else ""))
    fails += (not cond)

p=Printer(); w=mod.AD5MSetup(Config(p))
check("module constructs (no AD5X-only option left)", True)
st=w.get_status(1000.)
check("status has the contract keys", all(k in st for k in ('step','state','message','progress','results','checks','pending_save','zoffset')), list(st))
check("steps are the AD5M's", mod.STEPS==("selfcheck","pid","mesh","shaper","zoffset","summary","finish"), mod.STEPS)
check("registers SETUP_WIZARD_STEP and the ad5m_setup endpoint", 'SETUP_WIZARD_STEP' in p.g.cmds and 'ad5m_setup/control' in p.w.ep)
check("defaults: centred patch, runout_sensor, part+chamber fans", w.patch_center==(0.,0.) and w.filament_sensor=='runout_sensor' and w.fans==['part','chamber_fan'], (w.patch_center,w.filament_sensor,w.fans))

# self-check in file-output (batch) mode: no temperatures
w.check_time=0.1; w.check_watch=0.
w._step_selfcheck({})
names=[c['name'] for c in w.checks]
print("      checks:", names)
check("self-check lists MCUs, load cell, filament sensor, both fans, heaters", all(n in names for n in ("MCU mcu","MCU eboard","Bed load cell","Filament sensor","Part fan","Chamber fan","Homing","Nozzle heater","Bed heater")), names)
check("self-check has no IFS or weight board entry", not any("IFS" in n or "strain" in n.lower() for n in names))
check("self-check passed (nothing failed)", w.results.get('selfcheck','').startswith(str(len(w.checks))), w.results)
sent="\n".join(p.g.sent)
check("part fan runs with M106, the chamber fan with SET_FAN_SPEED", "M106 S255" in sent and "SET_FAN_SPEED FAN=chamber_fan SPEED=1" in sent)

# a plain 5M has no chamber fan object: that is not a failure
p2=Printer(); del p2.objs['fan_generic chamber_fan']; w2=mod.AD5MSetup(Config(p2)); w2.check_time=0.1; w2.check_watch=0.; w2._step_selfcheck({})
cf=[c for c in w2.checks if c['name']=="Chamber fan"][0]
check("missing chamber fan is a pass, not required", cf['ok'] and not cf['required'], cf)

# real (non-batch) mode with a failing load cell: required check fails the step
class FailGcode(Gcode):
    def run_script(self, s):
        if "LOAD_CELL_TARE" in s: raise CmdError("LOAD_CELL_TARE: the load cell module is not loaded")
        super().run_script(s)
p3=Printer(batch=False); fg=FailGcode(); p3.g=fg; p3.objs['gcode']=fg
w3=mod.AD5MSetup(Config(p3)); w3.check_time=0.1; w3.check_watch=0.
# heaters rise during the check so only the load cell fails
class RisingHeater(Heater):
    def __init__(self,t,r): super().__init__(t); self.r=r; self.n=0
    def get_status(self,e): self.n+=1; return {'temperature': self.t+self.r*min(self.n,50)}
p3.objs['heaters'].heaters={'extruder':RisingHeater(25.,2.),'heater_bed':RisingHeater(24.,1.)}
try:
    w3._step_selfcheck({}); check("a missing load cell fails the self-check", False)
except CmdError as e:
    check("a missing load cell fails the self-check", "Bed load cell" in str(e), str(e))

# dispatch rules
try: w.state="idle"; w._dispatch("zoffset","accept",{},None); check("accept refused when nothing waits", False)
except Exception as e: check("accept refused when nothing waits", True)
try: w._start("ifs",{},False); check("the AD5X's ifs step is gone", False)
except Exception as e: check("the AD5X's ifs step is gone", True)
check("no estimate in the status", st['estimate'] is False)

# z offset helper pieces and patch gcode
w.patch_center=(0.,0.); w.park_y=105.
class CF:
    def get_status(self,e): return {'settings':{'extruder':{'nozzle_diameter':0.4,'filament_diameter':1.75}}}
p.objs['configfile']=CF()
lines=w._patch_gcode(0)
check("test patch parks at park_y (centred coordinates)", lines[-1].startswith("G1 X0.00 Y105.00"), lines[-1])
check("test patch stays inside the bed (|x|,|y| <= 110)", all(abs(float(tok[1:]))<=110 for l in lines for tok in l.split() if tok[:1] in "XY" and tok[1:].replace('.','',1).replace('-','',1).isdigit()))

# ---- mesh step sequence with heaters that follow their targets
import re as _re
class HeatGcode(Gcode):
    def __init__(self, heaters): super().__init__(); self.h=heaters
    def run_script(self, s):
        super().run_script(s)
        for line in s.split("\n"):
            m=_re.match(r"SET_HEATER_TEMPERATURE HEATER=(\w+) TARGET=([\d.]+)", line)
            if m: self.h.heaters[m.group(1)].t=float(m.group(2))
            if line.startswith("M104 S0"): self.h.heaters['extruder'].t=100.
p4=Printer(batch=False); hs=Heaters(); hg=HeatGcode(hs); p4.g=hg; p4.objs.update({'gcode':hg,'heaters':hs})
p4.objs['bed_mesh']=types.SimpleNamespace(get_status=lambda e:{'probed_matrix':[[0.0,0.05,0.1]]*3})
w4=mod.AD5MSetup(Config(p4)); w4.step="mesh"; w4.state="running"
w4._step_mesh({})
seq=[l for blk in hg.sent for l in blk.split("\n") if l.strip()]
def idx(x): return next(i for i,l in enumerate(seq) if l.startswith(x))
check("mesh: load cell is tared before the wipe", idx("LOAD_CELL_TARE") < idx("_AD5M_NOZZLE_WIPE"))
check("mesh: the nozzle is switched off and cooled before the mesh", idx("M104 S0") < idx("BED_MESH_CALIBRATE"))
check("mesh: the offset is cleared with the plain command, not the saving one", any(l.startswith("_SET_GCODE_OFFSET Z=0") for l in seq) and not any(l.startswith("SET_GCODE_OFFSET Z=0") for l in seq))
check("mesh: heaters off at the end", seq[-1].startswith("SET_HEATER_TEMPERATURE HEATER=heater_bed TARGET=0") or any("heater_bed TARGET=0" in l for l in seq[-3:]), seq[-3:])
check("mesh: result recorded and pending save set", w4.pending_save and "mesh" in w4.results, w4.results)
print("\nfailures (all):", fails)
sys.exit(1 if fails else 0)
