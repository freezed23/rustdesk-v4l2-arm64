#!/usr/bin/env bash
set -euo pipefail

RUSTDESK_DIR="${1:-rustdesk}"
cd "$RUSTDESK_DIR"

python3 - <<'PY'
from pathlib import Path

p = Path('hwcodec-local/cpp/ffmpeg_ram/ffmpeg_ram_decode.cpp')
s = p.read_text()

# V4L2M2M decode is asynchronous. Keep polling receive_frame() on EAGAIN
# instead of immediately treating the first packet as a decode failure.
include_old = '''#include <memory>
#include <stdbool.h>
'''
include_new = '''#include <memory>
#include <stdbool.h>
#include <chrono>
#include <thread>
'''
if '#include <thread>' not in s:
    if include_old not in s:
        raise SystemExit('ffmpeg_ram_decode.cpp include insertion point not found')
    s = s.replace(include_old, include_new, 1)

# hwcodec's FFmpeg RAM decoder originally recognizes only H264/HEVC names.
# Allow VP9/VP8 V4L2M2M decoder names to reach avcodec_open2().
fmt_old = '''    if (name_.find("h264") != std::string::npos) {
      data_format_ = DataFormat::H264;
    } else if (name_.find("hevc") != std::string::npos) {
      data_format_ = DataFormat::H265;
    } else {
      LOG_ERROR(std::string("unsupported data format:") + name_);
      return -1;
    }
'''
fmt_new = '''    if (name_.find("h264") != std::string::npos) {
      data_format_ = DataFormat::H264;
    } else if (name_.find("hevc") != std::string::npos) {
      data_format_ = DataFormat::H265;
    } else if (name_.find("vp9") != std::string::npos) {
      data_format_ = DataFormat::VP9;
    } else if (name_.find("vp8") != std::string::npos) {
      data_format_ = DataFormat::VP8;
    } else {
      LOG_ERROR(std::string("unsupported data format:") + name_);
      return -1;
    }
'''
if 'DataFormat::VP9' not in s:
    if fmt_old not in s:
        raise SystemExit('ffmpeg_ram_decode.cpp DataFormat block not found')
    s = s.replace(fmt_old, fmt_new, 1)

recv_old = '''      if ((ret = avcodec_receive_frame(c_, frame_)) != 0) {
        if (ret != AVERROR(EAGAIN)) {
          LOG_ERROR(std::string("avcodec_receive_frame failed, ret = ") + av_err2str(ret));
        }
        goto _exit;
      }
'''
recv_new = '''      if ((ret = avcodec_receive_frame(c_, frame_)) != 0) {
        if (ret == AVERROR(EAGAIN) &&
            name_.find("_v4l2m2m") != std::string::npos) {
          // V4L2M2M is asynchronous. The packet may already be queued while
          // the capture frame is not ready yet. Wait briefly and retry until
          // the existing decoder timeout is reached.
          std::this_thread::sleep_for(std::chrono::milliseconds(1));
          ret = 0;
          continue;
        }
        if (ret != AVERROR(EAGAIN)) {
          LOG_ERROR(std::string("avcodec_receive_frame failed, ret = ") + av_err2str(ret));
        }
        goto _exit;
      }
'''
if 'V4L2M2M is asynchronous' not in s:
    if recv_old not in s:
        raise SystemExit('ffmpeg_ram_decode.cpp receive_frame block not found')
    s = s.replace(recv_old, recv_new, 1)

p.write_text(s)
PY

echo '===== V4L2M2M RUNTIME FIX SUMMARY ====='
grep -nE 'DataFormat::VP9|DataFormat::VP8|V4L2M2M is asynchronous|_v4l2m2m' \
  hwcodec-local/cpp/ffmpeg_ram/ffmpeg_ram_decode.cpp | head -40
