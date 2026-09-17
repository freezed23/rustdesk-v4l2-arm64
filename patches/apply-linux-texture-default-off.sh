#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-rustdesk}"
FILE="$ROOT/src/ui_interface.rs"

python3 - "$FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old = '''    #[cfg(target_os = "linux")]
    return cfg!(feature = "flutter")
        && LocalConfig::get_option(config::keys::OPTION_TEXTURE_RENDER) != "N";
'''

new = '''    #[cfg(target_os = "linux")]
    // Armbian ARM64 V4L2M2M build: keep Flutter texture rendering opt-in.
    // PixelBuffer rendering avoids the Linux ARM64 green-screen issue seen
    // with libtexture_rgba_renderer_plugin.so. Users can still explicitly
    // enable the texture path by setting use-texture-render = 'Y'.
    return cfg!(feature = "flutter")
        && LocalConfig::get_option(config::keys::OPTION_TEXTURE_RENDER) == "Y";
'''

if old not in text:
    raise SystemExit(f"expected Linux use_texture_render block not found in {path}")

path.write_text(text.replace(old, new, 1))
print(f"patched {path}: Linux texture renderer now defaults OFF (opt-in with Y)")
PY
