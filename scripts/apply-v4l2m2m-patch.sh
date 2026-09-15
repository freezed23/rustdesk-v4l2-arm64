#!/usr/bin/env bash
set -euo pipefail

RUSTDESK_DIR="${1:-rustdesk}"
HWCODEC_COMMIT="778df1f99597722473b29443bac22ae6c23946fe"

cd "$RUSTDESK_DIR"

python3 - <<'PY'
from pathlib import Path
p = Path('res/vcpkg/ffmpeg/portfile.cmake')
s = p.read_text()
old = '--disable-v4l2-m2m \\\n'
new = '--enable-v4l2-m2m \\\n'
if old not in s:
    raise SystemExit('FFmpeg v4l2-m2m disable line not found')
s = s.replace(old, new, 1)
needle = '--enable-decoder=h264 \\\n--enable-decoder=hevc \\\n'
replacement = '--enable-decoder=h264 \\\n--enable-decoder=hevc \\\n--enable-decoder=h264_v4l2m2m \\\n'
if 'h264_v4l2m2m' not in s:
    if needle not in s:
        raise SystemExit('FFmpeg decoder insertion point not found')
    s = s.replace(needle, replacement, 1)
p.write_text(s)
PY

rm -rf hwcodec-local
git clone --recursive https://github.com/rustdesk-org/hwcodec.git hwcodec-local
git -C hwcodec-local checkout "$HWCODEC_COMMIT"
git -C hwcodec-local submodule update --init --recursive

python3 - <<'PY'
from pathlib import Path
p = Path('hwcodec-local/src/ffmpeg_ram/decode.rs')
s = p.read_text()
marker = '''        #[cfg(target_os = "windows")]
        {
'''
insert = '''        #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
        {
            codecs.push(CodecInfo {
                name: "h264_v4l2m2m".to_owned(),
                format: H264,
                hwdevice: AV_HWDEVICE_TYPE_NONE,
                priority: Priority::Best as _,
                ..Default::default()
            });
        }

'''
if 'h264_v4l2m2m' not in s:
    if marker not in s:
        raise SystemExit('hwcodec insertion point not found')
    s = s.replace(marker, insert + marker, 1)
p.write_text(s)
PY

python3 - <<'PY'
from pathlib import Path
p = Path('libs/scrap/Cargo.toml')
s = p.read_text()
old = '''[dependencies.hwcodec]
git = "https://github.com/rustdesk-org/hwcodec"
optional = true
'''
new = '''[dependencies.hwcodec]
path = "../../hwcodec-local"
optional = true
'''
if old not in s:
    raise SystemExit('hwcodec dependency block not found')
p.write_text(s.replace(old, new, 1))
PY

cargo update -p hwcodec

echo '===== V4L2M2M PATCH SUMMARY ====='
grep -nE 'v4l2-m2m|h264_v4l2m2m' res/vcpkg/ffmpeg/portfile.cmake
grep -n -A10 -B3 h264_v4l2m2m hwcodec-local/src/ffmpeg_ram/decode.rs
grep -A3 '\[dependencies.hwcodec\]' libs/scrap/Cargo.toml
cargo tree -p scrap --features hwcodec | grep -A2 -B2 hwcodec
