#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-rustdesk}"
CODEC="$ROOT/libs/scrap/src/common/codec.rs"
MC="$ROOT/libs/scrap/src/common/mediacodec.rs"
NDK="$ROOT/flutter/ndk_arm64.sh"
MANIFEST="$ROOT/flutter/android/app/src/main/AndroidManifest.xml"

python3 - "$CODEC" "$MC" "$NDK" "$MANIFEST" <<'PY'
from pathlib import Path
import sys

codec = Path(sys.argv[1])
mc = Path(sys.argv[2])
ndk = Path(sys.argv[3])
manifest = Path(sys.argv[4])

s = codec.read_text()
s = s.replace(
    'h264_media_codec: MediaCodecDecoder,',
    'h264_media_codec: Option<MediaCodecDecoder>,'
)
s = s.replace(
    'h265_media_codec: MediaCodecDecoder,',
    'h265_media_codec: Option<MediaCodecDecoder>,'
)
codec.write_text(s)

s = mc.read_text()

# Fix the obvious duplicated pixel-format branch.
old = '''                        ImageFormat::ARGB => {
                            I420ToABGR('''
if old in s:
    s = s.replace(old, '''                        ImageFormat::ABGR => {
                            I420ToABGR(''', 1)

# Use a real initial decoder size for the TV-box diagnostic build.
# RustDesk's dormant MediaCodec path configured 0x0, which many Android codecs reject.
s = s.replace(
    'media_format.set_i32("width", 0);\n    media_format.set_i32("height", 0);',
    'media_format.set_i32("width", 1920);\n    media_format.set_i32("height", 1080);'
)

# Make startup probing compile and actually test the two decoders.
start = s.index('pub fn check_mediacodec() {')
s = s[:start] + '''pub fn check_mediacodec() {
    std::thread::spawn(move || {
        let h264 = MediaCodecDecoder::new(CodecFormat::H264);
        let h265 = MediaCodecDecoder::new(CodecFormat::H265);

        H264_DECODER_SUPPORT.store(h264.is_some(), Ordering::SeqCst);
        H265_DECODER_SUPPORT.store(h265.is_some(), Ordering::SeqCst);

        log::info!(
            "[ANDROID-MC] probe h264={} h265={}",
            h264.is_some(),
            h265.is_some()
        );

        if let Some(d) = h264 {
            let _ = d.stop();
        }
        if let Some(d) = h265 {
            let _ = d.stop();
        }
    });
}
'''

# Add a one-line output-format diagnostic before the I420 interpretation.
needle = '                let buf = output_buffer.buffer();\n'
diag = '''                let color_format = res_format.i32("color-format").unwrap_or(-1);
                let slice_height = res_format.i32("slice-height").unwrap_or(h as i32);
                log::info!(
                    "[ANDROID-MC] output {}x{} stride={} slice-height={} color-format={} bytes={}",
                    w,
                    h,
                    stride,
                    slice_height,
                    color_format,
                    output_buffer.buffer().len()
                );
                let buf = output_buffer.buffer();
'''
if needle in s:
    s = s.replace(needle, diag, 1)

mc.write_text(s)

s = ndk.read_text()
s = s.replace(
    '--features flutter,hwcodec',
    '--features flutter,mediacodec'
)
ndk.write_text(s)

s = manifest.read_text()
marker = '<manifest xmlns:android="http://schemas.android.com/apk/res/android"\n    package="com.carriez.flutter_hbb">'
if marker in s:
    s = s.replace(marker, marker + '''
    <uses-feature android:name="android.hardware.touchscreen" android:required="false" />
    <uses-feature android:name="android.software.leanback" android:required="false" />''', 1)
manifest.write_text(s)

print("Applied Android MediaCodec TV-box diagnostic patch")
PY

grep -n "features flutter" "$NDK"
grep -n "h264_media_codec" "$CODEC" | head
grep -n "ANDROID-MC" "$MC"
