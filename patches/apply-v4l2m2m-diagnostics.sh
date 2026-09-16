#!/usr/bin/env bash
set -euo pipefail

RUSTDESK_DIR="${1:-rustdesk}"
cd "$RUSTDESK_DIR"

# Diagnostic build for Amlogic meson-vdec.
# We intentionally do not change FFmpeg/V4L2 buffer sizing yet. The kernel
# warning "esparser_pad_start_code: unable to pad start code" means the driver
# could not fit its mandatory 4 KiB minimum padding + 512-byte search pattern
# into the negotiated OUTPUT plane. First record the real RustDesk packet sizes
# and decoder behaviour, then decide whether the correct fix belongs in FFmpeg
# buffer negotiation or the kernel driver.
python3 - <<'PY'
from pathlib import Path

p = Path('hwcodec-local/cpp/ffmpeg_ram/ffmpeg_ram_decode.cpp')
s = p.read_text()

if '[V4L2DBG]' not in s:
    old = '''#include <memory>\n#include <stdbool.h>\n'''
    new = '''#include <memory>\n#include <iomanip>\n#include <sstream>\n#include <stdbool.h>\n'''
    if old not in s:
        raise SystemExit('diagnostic include insertion point not found')
    s = s.replace(old, new, 1)

    old = '''  bool hwaccel_ = true;\n\n  std::string name_;\n'''
    new = '''  bool hwaccel_ = true;\n  int dbg_packets_ = 0;\n  int dbg_frames_ = 0;\n\n  std::string name_;\n'''
    if old not in s:
        raise SystemExit('diagnostic counter insertion point not found')
    s = s.replace(old, new, 1)

    old = '''    free_decoder();\n    const AVCodec *codec = NULL;\n'''
    new = '''    free_decoder();\n    dbg_packets_ = 0;\n    dbg_frames_ = 0;\n    if (name_.find("_v4l2m2m") != std::string::npos) {\n      // Diagnostic build only: also expose FFmpeg's V4L2 format negotiation.\n      av_log_set_level(AV_LOG_DEBUG);\n    }\n    const AVCodec *codec = NULL;\n'''
    if old not in s:
        raise SystemExit('diagnostic reset insertion point not found')
    s = s.replace(old, new, 1)

    old = '''    pkt_->data = (uint8_t *)data;\n    pkt_->size = length;\n    ret = do_decode(obj);\n'''
    new = '''    if (name_.find("_v4l2m2m") != std::string::npos && dbg_packets_ < 80) {\n      std::ostringstream os;\n      os << "[V4L2DBG] codec=" << name_\n         << " packet=" << dbg_packets_\n         << " len=" << length\n         << " ctx=" << (c_ ? c_->width : 0) << "x" << (c_ ? c_->height : 0)\n         << " extradata=" << (c_ ? c_->extradata_size : 0)\n         << " head=";\n      const int head_len = length < 32 ? length : 32;\n      os << std::hex << std::setfill('0');\n      for (int i = 0; i < head_len; ++i) {\n        if (i) os << ' ';\n        os << std::setw(2) << static_cast<unsigned int>(data[i]);\n      }\n      LOG_INFO(os.str());\n    }\n    dbg_packets_++;\n\n    pkt_->data = (uint8_t *)data;\n    pkt_->size = length;\n    ret = do_decode(obj);\n'''
    if old not in s:
        raise SystemExit('diagnostic packet insertion point not found')
    s = s.replace(old, new, 1)

    old = '''    ret = avcodec_send_packet(c_, pkt_);\n    if (ret < 0) {\n'''
    new = '''    ret = avcodec_send_packet(c_, pkt_);\n    if (name_.find("_v4l2m2m") != std::string::npos && dbg_packets_ <= 80) {\n      LOG_INFO(std::string("[V4L2DBG] send_packet packet=") +\n               std::to_string(dbg_packets_ - 1) + " ret=" +\n               std::to_string(ret) + " (" + av_err2str(ret) + ")");\n    }\n    if (ret < 0) {\n'''
    if old not in s:
        raise SystemExit('diagnostic send_packet insertion point not found')
    s = s.replace(old, new, 1)

    old = '''      if ((ret = avcodec_receive_frame(c_, frame_)) != 0) {\n        if (ret == AVERROR(EAGAIN) &&\n'''
    new = '''      if ((ret = avcodec_receive_frame(c_, frame_)) != 0) {\n        if (name_.find("_v4l2m2m") != std::string::npos && dbg_packets_ <= 80) {\n          LOG_INFO(std::string("[V4L2DBG] receive_frame packet=") +\n                   std::to_string(dbg_packets_ - 1) + " ret=" +\n                   std::to_string(ret) + " (" + av_err2str(ret) + ")");\n        }\n        if (ret == AVERROR(EAGAIN) &&\n'''
    if old not in s:
        raise SystemExit('diagnostic receive_frame insertion point not found; runtime patch may not have applied')
    s = s.replace(old, new, 1)

    old = '''      decoded = true;\n#ifdef CFG_PKG_TRACE\n'''
    new = '''      if (name_.find("_v4l2m2m") != std::string::npos && dbg_frames_ < 40) {\n        const char *pix_name = av_get_pix_fmt_name((AVPixelFormat)tmp_frame->format);\n        std::ostringstream os;\n        os << "[V4L2DBG] frame=" << dbg_frames_\n           << " " << tmp_frame->width << "x" << tmp_frame->height\n           << " pixfmt=" << (pix_name ? pix_name : "unknown")\n           << " linesize=" << tmp_frame->linesize[0] << ","\n           << tmp_frame->linesize[1] << "," << tmp_frame->linesize[2];\n        LOG_INFO(os.str());\n      }\n      dbg_frames_++;\n      decoded = true;\n#ifdef CFG_PKG_TRACE\n'''
    if old not in s:
        raise SystemExit('diagnostic frame insertion point not found')
    s = s.replace(old, new, 1)

p.write_text(s)
PY

# Log pixel-conversion failures instead of silently turning them into FPS 0.
python3 - <<'PY'
from pathlib import Path
p = Path('libs/scrap/src/common/codec.rs')
s = p.read_text()
old = '''                if image.to_fmt(rgb, i420).is_ok() {\n                    ret = true;\n                }\n'''
new = '''                match image.to_fmt(rgb, i420) {\n                    Ok(_) => ret = true,\n                    Err(e) => log::error!("V4L2DBG frame conversion failed: {e:?}"),\n                }\n'''
if 'V4L2DBG frame conversion failed' not in s:
    if old not in s:
        raise SystemExit('codec.rs to_fmt diagnostic insertion point not found')
    s = s.replace(old, new, 1)
p.write_text(s)
PY

# Fail fast during diagnostics. The previous 30-packet grace can hammer a
# wedged meson-vdec hard enough to make the S912 box unresponsive/reboot.
python3 - <<'PY'
from pathlib import Path
p = Path('src/client.rs')
s = p.read_text()
old = '''                            let max_decode_fail_counter = if handler.decoder.is_v4l2m2m() {\n                                30\n                            } else {\n'''
new = '''                            let max_decode_fail_counter = if handler.decoder.is_v4l2m2m() {\n                                8\n                            } else {\n'''
if old not in s:
    raise SystemExit('client.rs V4L2M2M grace block not found')
s = s.replace(old, new, 1)
p.write_text(s)
PY

echo '===== V4L2M2M DIAGNOSTIC PATCH SUMMARY ====='
grep -nE 'V4L2DBG|dbg_packets_|dbg_frames_|av_log_set_level' \
  hwcodec-local/cpp/ffmpeg_ram/ffmpeg_ram_decode.cpp | head -120 || true
grep -nE 'V4L2DBG frame conversion failed|max_decode_fail_counter' \
  libs/scrap/src/common/codec.rs src/client.rs | head -80 || true
