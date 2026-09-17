#!/usr/bin/env bash
set -euo pipefail

RUSTDESK_DIR="${1:-rustdesk}"
cd "$RUSTDESK_DIR"

# The common V4L2M2M patch was initially limited to Linux aarch64.
# RK3288 is ARMv7 (armhf), so extend only those target guards to Linux ARM32/ARM64.
python3 - <<'PY'
from pathlib import Path

p = Path('hwcodec-local/src/ffmpeg_ram/decode.rs')
s = p.read_text()
old = '#[cfg(all(target_os = "linux", target_arch = "aarch64"))]'
new = '#[cfg(all(target_os = "linux", any(target_arch = "aarch64", target_arch = "arm")))]'
count = s.count(old)
if count < 2:
    raise SystemExit(f'expected at least two Linux aarch64 V4L2M2M guards, found {count}')
s = s.replace(old, new)
p.write_text(s)
PY

echo '===== RK3288 ARMv7 V4L2M2M guard summary ====='
grep -n -B2 -A3 'target_arch = "arm"' hwcodec-local/src/ffmpeg_ram/decode.rs || true
