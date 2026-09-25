# HDL simulator & compiler for cocotb

**Session ID:** ses_014e2ff09ffeZxNSI63nBbNlXi
**Created:** 8/10/2026, 12:59:34 PM
**Updated:** 8/17/2026, 11:45:36 AM

---

## User

What HDL simulator and compiler would you use in this setup, which would use cocotb as the testbench?

---

## Assistant (Plan · DeepSeek V4 Flash · 2.6s)

_Thinking:_

The user is asking about what HDL simulator and compiler to use in this setup, with cocotb as the testbench. This is a SystemVerilog floating point unit project. Let me explore the codebase first to understand what's there — check for any existing config files (Makefiles, cocotb configs, requirements.txt, etc.).

Let me look at the repo structure.

**Tool: bash**

**Input:**
```json
{
  "command": "ls -la"
}
```

**Output:**
```
total 36
drwxrwxr-x  4 jesse jesse 4096 Aug 10 12:57 .
drwxr-xr-x 31 jesse jesse 4096 Aug 10 12:57 ..
drwxrwxr-x  7 jesse jesse 4096 Aug 10 12:57 .git
-rw-rw-r--  1 jesse jesse  109 Aug 10 12:57 .gitignore
-rw-rw-r--  1 jesse jesse   99 Aug 10 12:57 main.py
-rw-rw-r--  1 jesse jesse  189 Aug 10 12:57 pyproject.toml
-rw-rw-r--  1 jesse jesse    5 Aug 10 12:57 .python-version
-rw-rw-r--  1 jesse jesse    0 Aug 10 12:57 README.md
-rw-rw-r--  1 jesse jesse 3347 Aug 10 12:57 uv.lock
drwxrwxr-x  4 jesse jesse 4096 Aug 10 12:57 .venv

```

**Tool: glob**

**Input:**
```json
{
  "pattern": "**/*.{md,txt,cfg,mk,toml,yml,yaml,json}"
}
```

**Output:**
```
/home/jesse/Documents/systemverilog_fp_unit/pyproject.toml
/home/jesse/Documents/systemverilog_fp_unit/README.md
```

---

## Assistant (Plan · DeepSeek V4 Flash · 20.0s)

_Thinking:_

Let me look at the existing files to understand the setup.

**Tool: read**

**Input:**
```json
{
  "filePath": "/home/jesse/Documents/systemverilog_fp_unit/pyproject.toml"
}
```

**Output:**
```
<path>/home/jesse/Documents/systemverilog_fp_unit/pyproject.toml</path>
<type>file</type>
<content>
1: [project]
2: name = "systemverilog-fp-unit"
3: version = "0.1.0"
4: description = "Add your description here"
5: readme = "README.md"
6: requires-python = ">=3.13"
7: dependencies = [
8:     "cocotb>=2.0.1",
9: ]

(End of file - total 9 lines)
</content>
```

**Tool: read**

**Input:**
```json
{
  "filePath": "/home/jesse/Documents/systemverilog_fp_unit/main.py"
}
```

**Output:**
```
<path>/home/jesse/Documents/systemverilog_fp_unit/main.py</path>
<type>file</type>
<content>
1: def main():
2:     print("Hello from systemverilog-fp-unit!")
3: 
4: 
5: if __name__ == "__main__":
6:     main()

(End of file - total 6 lines)
</content>
```

**Tool: bash**

**Input:**
```json
{
  "command": "ls .venv/lib/*/site-packages/ 2>/dev/null | head -50; which iverilog verilator vcs questa vsim xrun 2>/dev/null"
}
```

**Output:**
```
cocotb
cocotb-2.0.1.dist-info
cocotb.libs
cocotb_tools
find_libpython
find_libpython-0.5.1.dist-info
pygpi
_virtualenv.pth
_virtualenv.py
iverilog not found
verilator not found
vcs not found
questa not found
vsim not found
xrun not found

```

---

## Assistant (Plan · DeepSeek V4 Flash · 11.3s)

_Thinking:_

The user has a fresh project with cocotb 2.0.1 installed via uv, but no simulator installed. They're asking what HDL simulator and compiler to use in this setup with cocotb as the testbench.

Let me check what tools are available on the system - maybe check for other simulators, and check the OS/package manager.

The project uses cocotb 2.0.1. Cocotb 2.x dropped support for some simulators. Let me think about the options:

1. **Verilator** - open source, very fast, good SystemVerilog support (SystemVerilog 2017 mostly), works with cocotb. Requires C++ compiler. Free. Best for RTL simulation. Limitations: limited support for some testbench constructs, no native timing in some cases but cocotb handles that via the Verilator co-simulation.

2. **Icarus Verilog (iverilog)** - open source, simple, but SystemVerilog support is poor (only Verilog-2005 + some SV features). For a SystemVerilog FP unit, this could be limiting.

3. **Commercial**: VCS, Questa/ModelSim, Xcelium - expensive, not available.

Since this is a SystemVerilog floating point unit project, Verilator is the best choice: free, excellent SystemVerilog support, fast, and has first-class cocotb integration (cocotb 2.x supports Verilator well). Cocotb officially supports Icarus, Verilator, Questa, VCS, Xcelium, GHDL, etc.

Verilator caveats: it doesn't support some SV features (like certain netlists, but for RTL synthesis-like code it's great), and 2-state simulation (no X/Z propagation) — actually Verilator is 4-state since 4.x? Verilator supports 4-state but by default 2-state. For an FP unit (purely combinational/sequential arithmetic), this is fine.

Icarus is simpler to install but its SystemVerilog support is very weak — for a SystemVerilog FP unit with packages, structs, etc., it would likely fail. So Verilator is the recommended choice.

Also cocotb 2.x requires Python 3.9+, and the project has Python 3.13 — cocotb 2.0.1 supports it.

The user is on Linux. Verilator install: `sudo apt install verilator` (may be old version; Ubuntu 24.04 has 5.020 which is fine). Or build from source for latest.

Should I check apt availability? I'm in plan mode, read-only — checking is fine but it's a question-answer, not a task. The user asked a question: "What HDL simulator and compiler would you use in this setup, which would use cocotb as the testbench?"

This is primarily a question. I should answer concisely, and since I'm in plan mode, maybe offer a plan for setting it up. The answer: Verilator (open source, best SystemVerilog support among free simulators, first-class cocotb support). Compiler: Verilator compiles SystemVerilog to C++, so it needs g++/clang++. Icarus Verilog as a fallback for quick smoke tests but its SV support is limited.

Let me verify cocotb 2.0.1 simulator support matrix quickly. Cocotb 2.x removed support for... let me recall. Cocotb 2.0 dropped support for: Aldec ActiveHDL? No. Cocotb 2.0 dropped Icarus? No, Icarus is still supported. Cocotb 2.0 changelog: dropped Python 3.8, dropped support for Riviera? Hmm. Actually cocotb 2.0 dropped support for: Verilog simulators - it still supports Icarus Verilog, Verilator, Cadence Xcelium, Mentor Questa/ModelSim, Siemens. VHDL: GHDL, NVC, Riviera-PRO, Modelsim. Actually cocotb 2.0 removed support for Cadence's "incisive"? I don't need to be that precise. Verilator and Icarus are both supported.

Let me check the system package manager availability of verilator versions to give concrete install advice. Actually, I could check quickly. But keep it simple - I can answer from knowledge.

Let me quickly check if apt is available and what verilator version is available. This is read-only.

Actually, let me be careful: the user asked a question. In plan mode, I answer the question and can propose a plan. Let me do a quick check of the system.

**Tool: bash**

**Input:**
```json
{
  "command": "apt-cache policy verilator iverilog 2>/dev/null | head -20; ls /usr/bin | grep -iE 'g\\+\\+|clang' | head"
}
```

**Output:**
```
verilator:
  Installed: (none)
  Candidate: 5.020-1
  Version table:
     5.020-1 500
        500 http://fi.archive.ubuntu.com/ubuntu noble/universe amd64 Packages
iverilog:
  Installed: (none)
  Candidate: 12.0-2build2
  Version table:
     12.0-2build2 500
        500 http://fi.archive.ubuntu.com/ubuntu noble/universe amd64 Packages
clang
clang++
clang++-18
clang-18
clang-cpp-18
clangd-20
g++
g++-13
x86_64-linux-gnu-g++
x86_64-linux-gnu-g++-13

```

---

## Assistant (Plan · DeepSeek V4 Flash · 11.6s)

_Thinking:_

Good. So the system has g++ and clang available. Verilator 5.020 and iverilog 12.0 are available via apt.

My recommendation: **Verilator** as the primary simulator/compiler. Reasons:
- This is a SystemVerilog FP unit — Verilator has the best SystemVerilog-2017 support among open-source simulators
- First-class cocotb integration (cocotb 2.x supports Verilator)
- Fast, open source
- Requires g++/clang++ which are already installed

Icarus Verilog as fallback: supports cocotb too but SV support is weak (only partial SV-2005), likely to choke on modern SV constructs (packages, interfaces, assertions).

Note cocotb 2.0.1 + Python 3.13 works. Verilator's cocotb support: `SIM=verilator`.

Caveats: Verilator is 2-state (no X/Z) — fine for an FP unit. Also no waveform by default (needs --trace).

I'll answer concisely and offer a plan since I'm in plan mode. The user asked a question — answer it. Keep under 4 lines ideally, but this warrants a bit of detail. Let me give a recommendation plus brief setup steps as a plan.

**Verilator** — it's the best open-source SystemVerilog-2017 compiler, has first-class cocotb support, and runs fast (important for FP unit testbenches with many vectors). Your system already has `g++`/`clang++`, which Verilator needs; `apt install verilator` gives 5.020.

- **Verilator 5.020** — primary: excellent SV support, cocotb runs via `SIM=verilator`. Caveats: 2-state (no X/Z), synthesizable subset only — fine for RTL arithmetic.
- **Icarus Verilog 12.0** — fallback for quick checks, but its SV support is weak (partial SV-2005); it will likely fail on modern SV packages/interfaces, so I wouldn't rely on it.

Plan if you want me to set it up:
1. `apt install verilator` (plus `iverilog` optional)
2. Add a `Makefile` (or cocotb-bus-free `cocotb-config`-driven) harness with `SIM=verilator`, `TOPLEVEL_LANG=verilog`, and an `hdl/` + `tests/` layout
3. Add a `dut.py`/`test_*.py` with a smoke test to verify the toolchain end-to-end

Want me to proceed with this setup?

---

