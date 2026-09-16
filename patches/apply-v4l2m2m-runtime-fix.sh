#!/usr/bin/env bash
set -euo pipefail

RUSTDESK_DIR="${1:-rustdesk}"
cd "$RUSTDESK_DIR"

python3 - <<'PY'
from pathlib import Path

p = Path('hwcodec-local/cpp/ffmpeg_ram/ffmpeg_ram_decode.cpp')
s = p.read_text()

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

# V4L2M2M decoders can legitimately accept an input packet without producing
# an output frame yet. On EAGAIN, return success with an empty frame vector so
# RustDesk can feed the next packet. Blocking here waiting for output causes a
# deadlock-like startup: the decoder may need more compressed packets before it
# can produce the first capture frame.
decoded_old = '''    bool decoded = false;
'''
decoded_new = '''    bool decoded = false;
    bool pending = false;
'''
if 'bool pending = false;' not in s:
    if decoded_old not in s:
        raise SystemExit('ffmpeg_ram_decode.cpp decoded flag not found')
    s = s.replace(decoded_old, decoded_new, 1)

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
          // Packet was accepted, but the stateful V4L2M2M decoder needs more
          // compressed input before a capture frame is ready. Do not block;
          // return success with no output frame and let RustDesk feed another
          // packet on the next call.
          pending = true;
          goto _exit;
        }
        if (ret != AVERROR(EAGAIN)) {
          LOG_ERROR(std::string("avcodec_receive_frame failed, ret = ") + av_err2str(ret));
        }
        goto _exit;
      }
'''
if 'stateful V4L2M2M decoder needs more' not in s:
    if recv_old not in s:
        raise SystemExit('ffmpeg_ram_decode.cpp receive_frame block not found')
    s = s.replace(recv_old, recv_new, 1)

return_old = '''    return decoded ? 0 : -1;
'''
return_new = '''    return (decoded || pending) ? 0 : -1;
'''
if return_new.strip() not in s:
    if return_old not in s:
        raise SystemExit('ffmpeg_ram_decode.cpp return block not found')
    s = s.replace(return_old, return_new, 1)

p.write_text(s)
PY

# Expose whether the active RustDesk decoder is one of our V4L2M2M RAM
# decoders. This lets the client give a stateful hardware decoder enough input
# packets to produce its first output frame instead of blacklisting it after
# only the first three no-output packets.
python3 - <<'PY'
from pathlib import Path
p = Path('libs/scrap/src/common/codec.rs')
s = p.read_text()
needle = '''    pub fn valid(&self) -> bool {
        self.valid
    }
'''
insert = '''    pub fn valid(&self) -> bool {
        self.valid
    }

    #[cfg(feature = "hwcodec")]
    pub fn is_v4l2m2m(&self) -> bool {
        self.vp8_ram
            .as_ref()
            .map_or(false, |d| d.info.name.ends_with("_v4l2m2m"))
            || self
                .vp9_ram
                .as_ref()
                .map_or(false, |d| d.info.name.ends_with("_v4l2m2m"))
            || self
                .h264_ram
                .as_ref()
                .map_or(false, |d| d.info.name.ends_with("_v4l2m2m"))
            || self
                .h265_ram
                .as_ref()
                .map_or(false, |d| d.info.name.ends_with("_v4l2m2m"))
    }

    #[cfg(not(feature = "hwcodec"))]
    pub fn is_v4l2m2m(&self) -> bool {
        false
    }
'''
if 'pub fn is_v4l2m2m(&self)' not in s:
    if needle not in s:
        raise SystemExit('codec.rs valid() insertion point not found')
    s = s.replace(needle, insert, 1)
p.write_text(s)
PY

python3 - <<'PY'
from pathlib import Path
p = Path('src/client.rs')
s = p.read_text()

# Do not immediately mark a V4L2M2M decoder unsupported just because the very
# first compressed packet produced no output frame. Statefully decoded H26x/VP9
# commonly needs several packets before the first capture buffer is ready.
old = '''                        if self.first_frame && self.fail_counter < MAX_DECODE_FAIL_COUNTER {
                            log::error!("decode first frame failed");
                            self.fail_counter = MAX_DECODE_FAIL_COUNTER;
                        } else {
                            self.fail_counter += 1;
                        }
'''
new = '''                        if self.first_frame
                            && !self.decoder.is_v4l2m2m()
                            && self.fail_counter < MAX_DECODE_FAIL_COUNTER
                        {
                            log::error!("decode first frame failed");
                            self.fail_counter = MAX_DECODE_FAIL_COUNTER;
                        } else {
                            self.fail_counter += 1;
                            if self.first_frame && self.decoder.is_v4l2m2m() {
                                log::debug!(
                                    "V4L2M2M decoder accepted first packet; waiting for output frame"
                                );
                            }
                        }
'''
if 'V4L2M2M decoder accepted first packet' not in s:
    if old not in s:
        raise SystemExit('client.rs first-frame fail block not found')
    s = s.replace(old, new, 1)

# Give V4L2M2M up to 30 consecutive no-output packets (~1-3 seconds depending
# on session FPS) before falling back. Other decoders keep RustDesk's original
# threshold of 3.
old2 = '''                            if !handler.decoder.valid()
                                || handler.fail_counter >= MAX_DECODE_FAIL_COUNTER
                            {
'''
new2 = '''                            let max_decode_fail_counter = if handler.decoder.is_v4l2m2m() {
                                30
                            } else {
                                MAX_DECODE_FAIL_COUNTER
                            };
                            if !handler.decoder.valid()
                                || handler.fail_counter >= max_decode_fail_counter
                            {
'''
if 'let max_decode_fail_counter = if handler.decoder.is_v4l2m2m()' not in s:
    if old2 not in s:
        raise SystemExit('client.rs unsupported threshold block not found')
    s = s.replace(old2, new2, 1)

p.write_text(s)
PY

echo '===== V4L2M2M RUNTIME FIX SUMMARY ====='
grep -nE 'DataFormat::VP9|DataFormat::VP8|stateful V4L2M2M|pending' \
  hwcodec-local/cpp/ffmpeg_ram/ffmpeg_ram_decode.cpp | head -60
grep -nE 'is_v4l2m2m|V4L2M2M decoder accepted|max_decode_fail_counter' \
  libs/scrap/src/common/codec.rs src/client.rs | head -80
