#!/usr/bin/env python3
"""Auto-attach BridgeEA to an MT5 chart profile for headless startup.

Modifies a .chr file in the Default profile to include the BridgeEA expert
section, so no manual noVNC setup is needed.

Usage: setup_bridge_chart.py <MT5_DIR> [HOST] [PORT]
"""

import glob
import os
import sys


EA_NAME = "BridgeEA"

EXPERT_SECTION = """<expert>
name={ea_name}
path=
flags=339
window_num=0
<inputs>
InpHost={host}
InpPort={port}
InpTimerMs=100
InpReconnectS=5
</inputs>
</expert>
"""

# Minimal chart file if none exist
MINIMAL_CHART = """<chart>
id=100000000000000001
symbol=EURUSD
period_type=1
period_size=1
digits=5
scale=8
mode=1
grid=1
volume=0
scroll=1
ohlc=1
askline=1
days=0
descriptions=0
shift=1
shift_size=20
fixed_pos=0
window_left=0
window_top=0
window_right=0
window_bottom=0
window_type=0
background_color=0
foreground_color=16777215
barup_color=65280
bardown_color=255
bullcandle_color=65280
bearcandle_color=255
chartline_color=65280
volumes_color=3329330
grid_color=10061943
askline_color=255
stops_color=255

<window>
height=100

<indicator>
name=Main
path=
apply=1
show_data=1
scale_inherit=0
scale_line=0
scale_line_percent=50
scale_line_value=0
scale_fix_min=0
scale_fix_min_val=0
scale_fix_max=0
scale_fix_max_val=0
</indicator>
</window>

{expert_section}</chart>
"""


def read_chr(path):
    """Read a .chr file, handling UTF-16LE or UTF-8."""
    with open(path, "rb") as f:
        raw = f.read()
    for enc in ("utf-16-le", "utf-16", "utf-8", "latin-1"):
        try:
            text = raw.decode(enc)
            # Strip BOM if present
            if text and text[0] == "\ufeff":
                text = text[1:]
            return text, enc
        except (UnicodeDecodeError, UnicodeError):
            continue
    return raw.decode("utf-8", errors="ignore"), "utf-8"


def write_chr(path, text, encoding="utf-16-le"):
    """Write a .chr file in UTF-16LE with BOM."""
    with open(path, "wb") as f:
        f.write(b"\xff\xfe")  # UTF-16LE BOM
        f.write(text.encode(encoding))


def has_bridge_ea(text):
    """Check if BridgeEA is already configured."""
    return EA_NAME.lower() in text.lower()


def inject_expert(text, host, port):
    """Add the <expert> section before </chart>."""
    section = EXPERT_SECTION.format(ea_name=EA_NAME, host=host, port=port)
    # Insert before closing </chart> tag
    close_tag = "</chart>"
    idx = text.rfind(close_tag)
    if idx < 0:
        # No closing tag found, append
        return text + "\n" + section + "\n" + close_tag + "\n"
    return text[:idx] + section + "\n" + text[idx:]


def main():
    if len(sys.argv) < 2:
        print("Usage: setup_bridge_chart.py <MT5_DIR> [HOST] [PORT]", file=sys.stderr)
        sys.exit(1)

    mt5_dir = sys.argv[1]
    host = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
    port = sys.argv[3] if len(sys.argv) > 3 else "15555"

    # Check if BridgeEA.ex5 exists
    ex5_path = os.path.join(mt5_dir, "MQL5", "Experts", f"{EA_NAME}.ex5")
    if not os.path.isfile(ex5_path):
        print(f"WARNING: {EA_NAME}.ex5 not found at {ex5_path}", file=sys.stderr)
        print("BridgeEA needs to be compiled by MT5 first. Will configure chart anyway.", file=sys.stderr)

    # Find chart profile directories
    profile_dirs = [
        os.path.join(mt5_dir, "MQL5", "Profiles", "Charts", "Default"),
        os.path.join(mt5_dir, "Profiles", "Charts", "Default"),
    ]

    # Check existing charts for BridgeEA
    for pdir in profile_dirs:
        if not os.path.isdir(pdir):
            continue
        for chr_file in sorted(glob.glob(os.path.join(pdir, "*.chr"))):
            text, enc = read_chr(chr_file)
            if has_bridge_ea(text):
                print(f"BridgeEA already configured in {chr_file}")
                return

    # Not found — modify the first chart file or create one
    target_dir = None
    for pdir in profile_dirs:
        if os.path.isdir(pdir):
            target_dir = pdir
            break

    if target_dir is None:
        # Create the profile directory
        target_dir = profile_dirs[0]
        os.makedirs(target_dir, exist_ok=True)
        print(f"Created profile directory: {target_dir}")

    # Try to modify existing chart01.chr
    chr_files = sorted(glob.glob(os.path.join(target_dir, "*.chr")))
    if chr_files:
        target_file = chr_files[0]
        text, enc = read_chr(target_file)
        text = inject_expert(text, host, port)
        write_chr(target_file, text)
        print(f"Added BridgeEA to existing chart: {target_file}")
    else:
        # Create new chart file
        target_file = os.path.join(target_dir, "chart01.chr")
        section = EXPERT_SECTION.format(ea_name=EA_NAME, host=host, port=port)
        text = MINIMAL_CHART.format(expert_section=section)
        write_chr(target_file, text)
        print(f"Created new chart with BridgeEA: {target_file}")

    # Also ensure the other profile dir is synced
    for pdir in profile_dirs:
        if pdir == target_dir or not os.path.isdir(pdir):
            continue
        other_chrs = sorted(glob.glob(os.path.join(pdir, "*.chr")))
        if other_chrs:
            text_check, _ = read_chr(other_chrs[0])
            if not has_bridge_ea(text_check):
                text_check = inject_expert(text_check, host, port)
                write_chr(other_chrs[0], text_check)
                print(f"Also updated: {other_chrs[0]}")


if __name__ == "__main__":
    main()
