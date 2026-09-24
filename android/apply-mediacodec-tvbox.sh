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

# RustDesk 1.4.9 dormant MediaCodec code does not compile as-is.
# Apply these as REQUIRED replacements and fail if upstream shape changed.
old_fmt = 'log::error!("Unsupported codec format: {}", format);'
new_fmt = 'log::error!("Unsupported codec format: {:?}", format);'
if old_fmt not in s:
    raise SystemExit("required MediaCodec format-log patch target not found")
s = s.replace(old_fmt, new_fmt, 1)

old_stride = '''        // take dst_stride into account please
        let dst_stride = rgb.stride();
'''
if old_stride not in s:
    raise SystemExit("required obsolete rgb.stride() patch target not found")
s = s.replace(old_stride, '', 1)

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
grep -nF 'Unsupported codec format: {:?}' "$MC"
grep -nF 'ImageFormat::ABGR' "$MC"
if grep -nF 'let dst_stride = rgb.stride();' "$MC"; then
  echo "ERROR: obsolete rgb.stride() line still present" >&2
  exit 1
fi


# Direct-Surface v2: MediaCodec -> Android SurfaceView, stable capability reporting,
# normal MediaCodec format-change handling, and exportable on-device diagnostics.
CODEC="$ROOT/libs/scrap/src/common/codec.rs"
MC="$ROOT/libs/scrap/src/common/mediacodec.rs"
ANDROID_FFI="$ROOT/libs/scrap/src/android/ffi.rs"
FFI_KT="$ROOT/flutter/android/app/src/main/kotlin/ffi.kt"
MAIN_ACTIVITY="$ROOT/flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/MainActivity.kt"
SURFACE_KT="$ROOT/flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/MediaCodecSurfacePlatformView.kt"
REMOTE_PAGE="$ROOT/flutter/lib/mobile/pages/remote_page.dart"
SETTINGS_PAGE="$ROOT/flutter/lib/mobile/pages/settings_page.dart"
UI_TRAIT="$ROOT/src/ui_session_interface.rs"
FLUTTER_RS="$ROOT/src/flutter.rs"
IO_LOOP="$ROOT/src/client/io_loop.rs"
MODEL_DART="$ROOT/flutter/lib/models/model.dart"

python3 - "$CODEC" "$MC" "$ANDROID_FFI" "$FFI_KT" "$MAIN_ACTIVITY" "$SURFACE_KT" "$REMOTE_PAGE" "$SETTINGS_PAGE" "$UI_TRAIT" "$FLUTTER_RS" "$IO_LOOP" "$MODEL_DART" <<'PY2'
from pathlib import Path
import sys

(codec_p, mc_p, android_ffi_p, ffi_kt_p, main_activity_p, surface_kt_p,
 remote_page_p, settings_page_p, ui_trait_p, flutter_rs_p, io_loop_p,
 model_dart_p) = map(Path, sys.argv[1:])

# Replace the dormant ByteBuffer-only decoder with a Surface-aware diagnostic decoder.
mc_p.write_text(r'''use hbb_common::{anyhow::Error, bail, log, ResultType};
use ndk::{
    media::{
        media_codec::{MediaCodec, MediaCodecDirection, MediaFormat},
        NdkMediaError,
    },
    native_window::NativeWindow,
};
use std::{
    io::Write,
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex, Once,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use crate::{CodecFormat, I420ToABGR, I420ToARGB, ImageFormat, ImageRgb};

const H264_MIME_TYPE: &str = "video/avc";
const H265_MIME_TYPE: &str = "video/hevc";
const COLOR_FORMAT_YUV420_PLANAR: i32 = 19;
const MAX_INPUT_SIZE: i32 = 2 * 1024 * 1024;

pub static H264_DECODER_SUPPORT: AtomicBool = AtomicBool::new(false);
pub static H265_DECODER_SUPPORT: AtomicBool = AtomicBool::new(false);
static PROBE_ONCE: Once = Once::new();

lazy_static::lazy_static! {
    static ref OUTPUT_SURFACE: Mutex<Option<NativeWindow>> = Mutex::new(None);
    static ref MC_DIAG: Mutex<Vec<String>> = Mutex::new(Vec::new());
}

fn diag<S: AsRef<str>>(message: S) {
    let message = message.as_ref();
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|v| v.as_millis())
        .unwrap_or_default();
    log::info!("[ANDROID-MC] {}", message);
    let mut d = MC_DIAG.lock().unwrap();
    d.push(format!("[{}] {}", ms, message));
    if d.len() > 2000 {
        let n = d.len() - 1500;
        d.drain(0..n);
    }
}

pub fn diagnostic_log() -> String {
    let mut out = MC_DIAG.lock().unwrap().join("\n");
    out.push_str(&format!(
        "\n[STATE] h264={} h265={} surface={}\n",
        H264_DECODER_SUPPORT.load(Ordering::SeqCst),
        H265_DECODER_SUPPORT.load(Ordering::SeqCst),
        has_output_surface()
    ));
    out
}

pub fn set_output_surface(env: *mut jni::sys::JNIEnv, surface: jni::sys::jobject) {
    if surface.is_null() {
        *OUTPUT_SURFACE.lock().unwrap() = None;
        diag("surface detached");
        return;
    }

    let window = unsafe { NativeWindow::from_surface(env as *mut _, surface as _) };
    match window {
        Some(window) => {
            let width = window.width();
            let height = window.height();
            *OUTPUT_SURFACE.lock().unwrap() = Some(window);
            diag(format!("surface attached {}x{}", width, height));
        }
        None => {
            diag("ANativeWindow_fromSurface failed");
        }
    }
}

pub fn has_output_surface() -> bool {
    OUTPUT_SURFACE.lock().unwrap().is_some()
}

fn current_output_surface() -> Option<NativeWindow> {
    OUTPUT_SURFACE.lock().unwrap().as_ref().cloned()
}

pub fn update_reported_support(h264: bool, h265: bool, source: &str) {
    // Capability is sticky for the process. A transient probe failure must not
    // erase a capability already reported by Android's MediaCodecList.
    if h264 {
        H264_DECODER_SUPPORT.store(true, Ordering::SeqCst);
    }
    if h265 {
        H265_DECODER_SUPPORT.store(true, Ordering::SeqCst);
    }
    diag(format!(
        "capability source={} reported h264={} h265={} -> sticky h264={} h265={}",
        source,
        h264,
        h265,
        H264_DECODER_SUPPORT.load(Ordering::SeqCst),
        H265_DECODER_SUPPORT.load(Ordering::SeqCst)
    ));
}

fn preferred_decoder_name(mime: &str, surface_mode: bool) -> Option<String> {
    crate::android::ffi::get_codec_info().and_then(|infos| {
        infos
            .codecs
            .into_iter()
            .find(|c| {
                !c.is_encoder
                    && c.hw != Some(false)
                    && c.mime_type == mime
                    && if surface_mode { c.surface } else { c.nv12 }
            })
            .map(|c| c.name)
    })
}

pub struct MediaCodecDecoder {
    decoder: MediaCodec,
    name: String,
    surface_mode: bool,
    queued_frames: u64,
    rendered_frames: u64,
    no_output_count: u64,
}

impl std::ops::Deref for MediaCodecDecoder {
    type Target = MediaCodec;
    fn deref(&self) -> &Self::Target {
        &self.decoder
    }
}

impl MediaCodecDecoder {
    pub fn new(format: CodecFormat) -> Option<MediaCodecDecoder> {
        match format {
            CodecFormat::H264 => create_media_codec(H264_MIME_TYPE, MediaCodecDirection::Decoder),
            CodecFormat::H265 => create_media_codec(H265_MIME_TYPE, MediaCodecDirection::Decoder),
            _ => {
                diag(format!("unsupported codec format: {:?}", format));
                None
            }
        }
    }

    pub fn surface_mode(&self) -> bool {
        self.surface_mode
    }

    fn log_output_format(&self, event: &str) {
        let f = self.output_format();
        let w = f.i32("width").unwrap_or(-1);
        let h = f.i32("height").unwrap_or(-1);
        let stride = f.i32("stride").unwrap_or(-1);
        let slice = f.i32("slice-height").unwrap_or(-1);
        let color = f.i32("color-format").unwrap_or(-1);
        let crop_l = f.i32("crop-left").unwrap_or(-1);
        let crop_t = f.i32("crop-top").unwrap_or(-1);
        let crop_r = f.i32("crop-right").unwrap_or(-1);
        let crop_b = f.i32("crop-bottom").unwrap_or(-1);
        diag(format!(
            "{} codec={} surface={} {}x{} stride={} slice={} color={} crop={},{},{},{}",
            event,
            self.name,
            self.surface_mode,
            w,
            h,
            stride,
            slice,
            color,
            crop_l,
            crop_t,
            crop_r,
            crop_b
        ));
    }

    pub fn decode(&mut self, data: &[u8], rgb: &mut ImageRgb) -> ResultType<bool> {
        self.queued_frames = self.queued_frames.saturating_add(1);

        match self.dequeue_input_buffer(Duration::from_millis(20))? {
            Some(mut input_buffer) => {
                let mut buf = input_buffer.buffer_mut();
                if data.len() > buf.len() {
                    diag(format!(
                        "input too large codec={} packet={} capacity={}",
                        self.name,
                        data.len(),
                        buf.len()
                    ));
                    bail!("MediaCodec input packet bigger than input buffer");
                }
                buf.write_all(data)?;
                self.queue_input_buffer(input_buffer, 0, data.len(), self.queued_frames * 1000, 0)?;
            }
            None => {
                diag(format!("no input buffer codec={} queued={}", self.name, self.queued_frames));
                // Backpressure is not a decoder capability failure.
                return Ok(true);
            }
        }

        let output = match self.dequeue_output_buffer(Duration::from_millis(20)) {
            Ok(v) => v,
            Err(NdkMediaError::UnknownResult(status)) if status.0 == -2 => {
                // AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED.
                self.log_output_format("output-format-changed");
                return Ok(true);
            }
            Err(NdkMediaError::UnknownResult(status)) if status.0 == -3 => {
                // AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED.
                diag(format!("output-buffers-changed codec={}", self.name));
                return Ok(true);
            }
            Err(e) => {
                diag(format!("dequeue output failed codec={} err={:?}", self.name, e));
                return Err(e.into());
            }
        };

        let Some(output_buffer) = output else {
            self.no_output_count = self.no_output_count.saturating_add(1);
            if self.no_output_count <= 5 || self.no_output_count % 300 == 0 {
                diag(format!(
                    "input accepted, output pending codec={} count={}",
                    self.name, self.no_output_count
                ));
            }
            // MediaCodec decoding is asynchronous. No output yet is normal.
            return Ok(true);
        };

        if self.surface_mode {
            self.release_output_buffer(output_buffer, true)?;
            self.rendered_frames = self.rendered_frames.saturating_add(1);
            if self.rendered_frames <= 5 || self.rendered_frames % 300 == 0 {
                diag(format!(
                    "surface frame rendered codec={} rendered={} queued={}",
                    self.name, self.rendered_frames, self.queued_frames
                ));
            }
            return Ok(true);
        }

        // ByteBuffer fallback is retained only as a diagnostic fallback. It is
        // intentionally strict: non-planar output falls back instead of silently
        // interpreting vendor/tiled buffers as I420.
        let res_format = self.output_format();
        let w = res_format
            .i32("width")
            .ok_or(Error::msg("MediaCodec width missing"))? as usize;
        let h = res_format
            .i32("height")
            .ok_or(Error::msg("MediaCodec height missing"))? as usize;
        let stride = res_format.i32("stride").unwrap_or(w as i32);
        let color = res_format.i32("color-format").unwrap_or(-1);
        let slice = res_format.i32("slice-height").unwrap_or(h as i32);
        if color != COLOR_FORMAT_YUV420_PLANAR {
            diag(format!(
                "ByteBuffer unsupported format codec={} color={} stride={} slice={}",
                self.name, color, stride, slice
            ));
            self.release_output_buffer(output_buffer, false)?;
            bail!("unsupported MediaCodec ByteBuffer color format");
        }

        let buf = output_buffer.buffer();
        let bps = 4usize;
        let y_size = (stride.max(0) as usize).saturating_mul(slice.max(0) as usize);
        let uv_stride = (stride.max(0) as usize + 1) / 2;
        let uv_height = (slice.max(0) as usize + 1) / 2;
        let u = y_size;
        let v = u.saturating_add(uv_stride.saturating_mul(uv_height));
        if v >= buf.len() {
            diag(format!(
                "ByteBuffer plane bounds invalid codec={} bytes={} y={} u={} v={}",
                self.name, buf.len(), y_size, u, v
            ));
            self.release_output_buffer(output_buffer, false)?;
            bail!("invalid MediaCodec I420 plane bounds");
        }

        rgb.w = w;
        rgb.h = h;
        rgb.raw.resize(h.saturating_mul(w).saturating_mul(bps), 0);
        unsafe {
            match rgb.fmt() {
                ImageFormat::ARGB => {
                    I420ToARGB(
                        buf.as_ptr(),
                        stride,
                        buf[u..].as_ptr(),
                        uv_stride as i32,
                        buf[v..].as_ptr(),
                        uv_stride as i32,
                        rgb.raw.as_mut_ptr(),
                        (w * bps) as i32,
                        w as i32,
                        h as i32,
                    );
                }
                ImageFormat::ABGR => {
                    I420ToABGR(
                        buf.as_ptr(),
                        stride,
                        buf[u..].as_ptr(),
                        uv_stride as i32,
                        buf[v..].as_ptr(),
                        uv_stride as i32,
                        rgb.raw.as_mut_ptr(),
                        (w * bps) as i32,
                        w as i32,
                        h as i32,
                    );
                }
                _ => {
                    self.release_output_buffer(output_buffer, false)?;
                    bail!("unsupported RGB destination format");
                }
            }
        }
        self.release_output_buffer(output_buffer, false)?;
        Ok(true)
    }
}

fn create_media_codec(mime: &str, direction: MediaCodecDirection) -> Option<MediaCodecDecoder> {
    let surface = current_output_surface();
    let surface_mode = surface.is_some();
    let preferred = preferred_decoder_name(mime, surface_mode);

    let decoder = preferred
        .as_deref()
        .and_then(MediaCodec::from_codec_name)
        .or_else(|| MediaCodec::from_decoder_type(mime))?;

    let selected_name = preferred.unwrap_or_else(|| format!("auto:{}", mime));
    let media_format = MediaFormat::new();
    media_format.set_str("mime", mime);
    media_format.set_i32("width", 1920);
    media_format.set_i32("height", 1080);
    media_format.set_i32("max-input-size", MAX_INPUT_SIZE);
    if !surface_mode {
        media_format.set_i32("color-format", COLOR_FORMAT_YUV420_PLANAR);
    }

    if let Err(e) = decoder.configure(&media_format, surface.as_ref(), direction) {
        diag(format!(
            "configure failed codec={} mime={} surface={} err={:?}",
            selected_name, mime, surface_mode, e
        ));
        return None;
    }
    if let Err(e) = decoder.start() {
        diag(format!(
            "start failed codec={} mime={} surface={} err={:?}",
            selected_name, mime, surface_mode, e
        ));
        return None;
    }

    diag(format!(
        "decoder started codec={} mime={} surface={} input_max={}",
        selected_name, mime, surface_mode, MAX_INPUT_SIZE
    ));
    Some(MediaCodecDecoder {
        decoder,
        name: selected_name,
        surface_mode,
        queued_frames: 0,
        rendered_frames: 0,
        no_output_count: 0,
    })
}

pub fn check_mediacodec() {
    PROBE_ONCE.call_once(|| {
        std::thread::spawn(move || {
            let h264 = MediaCodecDecoder::new(CodecFormat::H264);
            let h265 = MediaCodecDecoder::new(CodecFormat::H265);
            update_reported_support(h264.is_some(), h265.is_some(), "startup-probe");
            if let Some(d) = h264 {
                let _ = d.stop();
            }
            if let Some(d) = h265 {
                let _ = d.stop();
            }
        });
    });
}
''')

# Surface decoder returns Option already from the v1 patch. Mark the video callback as
# a non-pixelbuffer event when direct Surface rendering is active.
s = codec_p.read_text()
old_h264 = '''                if let Some(decoder) = &mut self.h264_media_codec {
                    Decoder::handle_mediacodec_video_frame(decoder, h264s, rgb)
                } else {'''
new_h264 = '''                if let Some(decoder) = &mut self.h264_media_codec {
                    if decoder.surface_mode() {
                        *_pixelbuffer = false;
                    }
                    Decoder::handle_mediacodec_video_frame(decoder, h264s, rgb)
                } else {'''
if old_h264 not in s:
    raise SystemExit("H264 MediaCodec branch target not found")
s = s.replace(old_h264, new_h264, 1)

old_h265 = '''                if let Some(decoder) = &mut self.h265_media_codec {
                    Decoder::handle_mediacodec_video_frame(decoder, h265s, rgb)
                } else {'''
new_h265 = '''                if let Some(decoder) = &mut self.h265_media_codec {
                    if decoder.surface_mode() {
                        *_pixelbuffer = false;
                    }
                    Decoder::handle_mediacodec_video_frame(decoder, h265s, rgb)
                } else {'''
if old_h265 not in s:
    raise SystemExit("H265 MediaCodec branch target not found")
s = s.replace(old_h265, new_h265, 1)

old_loop = '''        let mut ret = false;
        for h264 in frames.frames.iter() {
            return decoder.decode(&h264.data, rgb);
        }
        return Ok(false);'''
new_loop = '''        let mut ret = false;
        for h26x in frames.frames.iter() {
            if decoder.decode(&h26x.data, rgb)? {
                ret = true;
            }
        }
        Ok(ret)'''
if old_loop not in s:
    raise SystemExit("MediaCodec packet-loop target not found")
s = s.replace(old_loop, new_loop, 1)
codec_p.write_text(s)

# JNI bridge: Android Surface -> ANativeWindow and Rust diagnostic snapshot -> Kotlin.
s = android_ffi_p.read_text()
s = s.replace('use jni::sys::jboolean;', 'use jni::sys::{jboolean, jstring};', 1)

old_setcodec = '''        if let Ok(infos) = serde_json::from_str::<MediaCodecInfos>(&info) {
            *MEDIA_CODEC_INFOS.write().unwrap() = Some(infos);
        }'''
new_setcodec = '''        if let Ok(infos) = serde_json::from_str::<MediaCodecInfos>(&info) {
            #[cfg(feature = "mediacodec")]
            {
                let h264 = infos.codecs.iter().any(|c| {
                    !c.is_encoder && c.hw != Some(false) && c.mime_type == "video/avc" && c.surface
                });
                let h265 = infos.codecs.iter().any(|c| {
                    !c.is_encoder && c.hw != Some(false) && c.mime_type == "video/hevc" && c.surface
                });
                crate::mediacodec::update_reported_support(h264, h265, "MediaCodecList");
            }
            *MEDIA_CODEC_INFOS.write().unwrap() = Some(infos);
        }'''
if old_setcodec not in s:
    raise SystemExit("setCodecInfo parse target not found")
s = s.replace(old_setcodec, new_setcodec, 1)

insert_after = '''pub fn clear_codec_info() {
    *MEDIA_CODEC_INFOS.write().unwrap() = None;
}
'''
jni_extra = r'''
#[no_mangle]
pub extern "system" fn Java_ffi_FFI_setMediaCodecSurface(
    env: JNIEnv,
    _class: JClass,
    surface: JObject,
) {
    #[cfg(feature = "mediacodec")]
    crate::mediacodec::set_output_surface(env.get_raw(), surface.as_raw());
}

#[no_mangle]
pub extern "system" fn Java_ffi_FFI_getMediaCodecLog(
    mut env: JNIEnv,
    _class: JClass,
) -> jstring {
    #[cfg(feature = "mediacodec")]
    let text = crate::mediacodec::diagnostic_log();
    #[cfg(not(feature = "mediacodec"))]
    let text = "MediaCodec feature not built".to_owned();

    match env.new_string(text) {
        Ok(v) => v.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}
'''
if insert_after not in s:
    raise SystemExit("android ffi insertion target not found")
s = s.replace(insert_after, insert_after + jni_extra, 1)
android_ffi_p.write_text(s)

# Kotlin FFI declarations.
s = ffi_kt_p.read_text()
if 'import android.view.Surface' not in s:
    s = s.replace('import android.content.Context\n', 'import android.content.Context\nimport android.view.Surface\n', 1)
needle = '    external fun setCodecInfo(info: String)\n'
if needle not in s:
    raise SystemExit("ffi.kt setCodecInfo target not found")
s = s.replace(
    needle,
    needle + '    external fun setMediaCodecSurface(surface: Surface?)\n    external fun getMediaCodecLog(): String\n',
    1,
)
ffi_kt_p.write_text(s)

# Include decoder entries in the MediaCodecList JSON and recognize Amlogic vendor codecs.
s = main_activity_p.read_text()
old_prefix = '''listOf("c2.qti", "OMX.qcom.video", "OMX.Exynos", "OMX.hisi", "OMX.MTK", "OMX.Intel", "OMX.Nvidia")'''
new_prefix = '''listOf("c2.qti", "OMX.qcom.video", "OMX.Exynos", "OMX.hisi", "OMX.MTK", "OMX.Intel", "OMX.Nvidia", "OMX.amlogic", "c2.amlogic")'''
if old_prefix not in s:
    raise SystemExit("MediaCodec hardware-prefix target not found")
s = s.replace(old_prefix, new_prefix, 1)

old_decoder_skip = '''                if (!codec.isEncoder) {
                    return@forEach
                }
                codecArray.put(codecObject)'''
if old_decoder_skip not in s:
    raise SystemExit("decoder codecArray target not found")
s = s.replace(old_decoder_skip, '                codecArray.put(codecObject)', 1)

engine_anchor = '''        super.configureFlutterEngine(flutterEngine)
        if (MainService.isReady) {'''
engine_new = '''        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "rustdesk/mediacodec_surface",
            MediaCodecSurfaceFactory()
        )
        if (MainService.isReady) {'''
if engine_anchor not in s:
    raise SystemExit("configureFlutterEngine target not found")
s = s.replace(engine_anchor, engine_new, 1)

channel_anchor = '''                "try_sync_clipboard" -> {
                    rdClipboardManager?.syncClipboard(true)
                    result.success(true)
                }'''
channel_new = '''                "try_sync_clipboard" -> {
                    rdClipboardManager?.syncClipboard(true)
                    result.success(true)
                }
                "wait_mediacodec_surface" -> {
                    MediaCodecSurfaceState.waitForSurface(result)
                }
                "export_mc_log" -> {
                    try {
                        MediaCodecLogExporter.export(this, FFI.getMediaCodecLog())
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(logTag, "MediaCodec log export failed", e)
                        result.error("MC_LOG_EXPORT", e.message, null)
                    }
                }'''
if channel_anchor not in s:
    raise SystemExit("MainActivity channel insertion target not found")
s = s.replace(channel_anchor, channel_new, 1)
main_activity_p.write_text(s)

# Android PlatformView backed by SurfaceView plus MediaStore Downloads exporter.
surface_kt_p.write_text(r'''package com.carriez.flutter_hbb

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import ffi.FFI
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object MediaCodecSurfaceState {
    @Volatile
    private var ready = false
    private val waiters = mutableListOf<MethodChannel.Result>()

    fun waitForSurface(result: MethodChannel.Result) {
        if (ready) {
            result.success(true)
            return
        }
        synchronized(waiters) {
            if (ready) {
                result.success(true)
            } else {
                waiters.add(result)
            }
        }
    }

    fun onReady() {
        ready = true
        val pending = synchronized(waiters) {
            val copy = waiters.toList()
            waiters.clear()
            copy
        }
        pending.forEach { it.success(true) }
    }

    fun onLost() {
        ready = false
    }
}

class MediaCodecSurfaceFactory :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return MediaCodecSurfacePlatformView(context)
    }
}

class MediaCodecSurfacePlatformView(
    private val context: Context
) : PlatformView, SurfaceHolder.Callback {
    private val surfaceView = SurfaceView(context)
    private var lastSurface: Surface? = null

    init {
        surfaceView.isClickable = false
        surfaceView.isFocusable = false
        surfaceView.holder.addCallback(this)
    }

    override fun getView(): View = surfaceView

    override fun surfaceCreated(holder: SurfaceHolder) {
        lastSurface = holder.surface
        FFI.setMediaCodecSurface(holder.surface)
        MediaCodecSurfaceState.onReady()
        Log.i("RustDeskMC", "MediaCodec Surface created")
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        FFI.setMediaCodecSurface(holder.surface)
        MediaCodecSurfaceState.onReady()
        Log.i("RustDeskMC", "MediaCodec Surface changed " + width + "x" + height)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        FFI.setMediaCodecSurface(null)
        lastSurface = null
        MediaCodecSurfaceState.onLost()
        Log.i("RustDeskMC", "MediaCodec Surface destroyed")
    }

    override fun dispose() {
        surfaceView.holder.removeCallback(this)
        if (lastSurface != null) {
            FFI.setMediaCodecSurface(null)
            lastSurface = null
        }
        MediaCodecSurfaceState.onLost()
    }
}

object MediaCodecLogExporter {
    fun export(context: Context, text: String): String {
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).format(Date())
        val fileName = "rustdesk_mc_" + stamp + ".log"
        val body = if (text.isBlank()) "No MediaCodec diagnostics captured.\n" else text

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                put(MediaStore.Downloads.MIME_TYPE, "text/plain")
                put(
                    MediaStore.Downloads.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS + "/RustDesk-MC"
                )
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert failed")
            resolver.openOutputStream(uri, "w")!!.bufferedWriter().use { it.write(body) }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return "Download/RustDesk-MC/" + fileName
        }

        @Suppress("DEPRECATION")
        val base = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val dir = File(base, "RustDesk-MC")
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("Cannot create " + dir.absolutePath)
        }
        val out = File(dir, fileName)
        out.writeText(body)
        return out.absolutePath
    }
}
''')

# Create the Surface PlatformView before starting the remote session so the decoder can
# configure MediaCodec with an ANativeWindow from its very first frame.
s = remote_page_p.read_text()
old_start = '''    gFFI.start(
      widget.id,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
    );'''
new_start = '''    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (isAndroid) {
        try {
          await gFFI
              .invokeMethod("wait_mediacodec_surface")
              .timeout(const Duration(seconds: 3));
        } catch (e) {
          debugPrint("[ANDROID-MC] surface wait timeout/error: $e");
        }
      }
      if (!mounted) return;
      gFFI.start(
        widget.id,
        password: widget.password,
        isSharedPassword: widget.isSharedPassword,
        forceRelay: widget.forceRelay,
      );
    });'''
if old_start not in s:
    raise SystemExit("RemotePage gFFI.start target not found")
s = s.replace(old_start, new_start, 1)

old_paints = '''          final paints = [
            ImagePaint(ffiModel: gFFI.ffiModel),'''
new_paints = '''          final paints = [
            if (isAndroid)
              Positioned.fill(
                child: IgnorePointer(
                  child: AndroidView(viewType: "rustdesk/mediacodec_surface"),
                ),
              ),
            ImagePaint(ffiModel: gFFI.ffiModel),'''
if old_paints not in s:
    raise SystemExit("RemotePage paints target not found")
s = s.replace(old_paints, new_paints, 1)
remote_page_p.write_text(s)

# Add an explicit log-export action to Android settings.
s = settings_page_p.read_text()
hw_anchor = '''            SettingsTile.switchTile(
              title: Text(translate('Enable hardware codec')),
              initialValue: _enableHardwareCodec,
              onToggle: isOptionFixed(kOptionEnableHwcodec)
                  ? null
                  : (v) async {
                      await mainSetBoolOption(kOptionEnableHwcodec, v);
                      final newValue =
                          await mainGetBoolOption(kOptionEnableHwcodec);
                      setState(() {
                        _enableHardwareCodec = newValue;
                      });
                    },
            ),
          ]),'''
hw_new = '''            SettingsTile.switchTile(
              title: Text(translate('Enable hardware codec')),
              initialValue: _enableHardwareCodec,
              onToggle: isOptionFixed(kOptionEnableHwcodec)
                  ? null
                  : (v) async {
                      await mainSetBoolOption(kOptionEnableHwcodec, v);
                      final newValue =
                          await mainGetBoolOption(kOptionEnableHwcodec);
                      setState(() {
                        _enableHardwareCodec = newValue;
                      });
                    },
            ),
            SettingsTile(
              title: const Text('Export MediaCodec debug log'),
              description: const Text('Save to Download/RustDesk-MC'),
              onPressed: (context) async {
                try {
                  final ok = await gFFI.invokeMethod("export_mc_log");
                  showToast(ok == true
                      ? 'Saved to Download/RustDesk-MC'
                      : 'MediaCodec log export failed');
                } catch (e) {
                  showToast('MediaCodec log export failed: $e');
                }
              },
            ),
          ]),'''
if hw_anchor not in s:
    raise SystemExit("Hardware Codec settings section target not found")
s = s.replace(hw_anchor, hw_new, 1)
settings_page_p.write_text(s)

# A surface-rendered frame has no RGBA payload. Add a lightweight UI notification
# so Flutter clears its "waiting for first image" overlay without fabricating pixels.
s = ui_trait_p.read_text()
trait_anchor = '    fn on_rgba(&self, display: usize, rgba: &mut scrap::ImageRgb);\n'
if trait_anchor not in s:
    raise SystemExit("InvokeUiSession on_rgba target not found")
s = s.replace(
    trait_anchor,
    trait_anchor + '    fn on_surface_frame(&self, _display: usize) {}\n',
    1,
)
ui_trait_p.write_text(s)

s = flutter_rs_p.read_text()
impl_anchor = '''    #[inline]
    #[cfg(any(target_os = "android", target_os = "ios"))]
    fn on_rgba(&self, display: usize, rgba: &mut scrap::ImageRgb) {
        self.on_rgba_soft_render(display, rgba);
    }
'''
surface_impl = '''
    #[inline]
    fn on_surface_frame(&self, display: usize) {
        self.push_event(
            "surface_frame",
            &[("display", &display.to_string())],
            &[],
        );
    }
'''
if impl_anchor not in s:
    raise SystemExit("FlutterHandler mobile on_rgba target not found")
s = s.replace(impl_anchor, impl_anchor + surface_impl, 1)
flutter_rs_p.write_text(s)

s = io_loop_p.read_text()
io_anchor = '''                if pixelbuffer {
                    handler.on_rgba(display, data);
                } else {
                    #[cfg(all(feature = "vram", feature = "flutter"))]
                    handler.on_texture(display, _texture);
                }'''
io_new = '''                if pixelbuffer {
                    handler.on_rgba(display, data);
                } else {
                    #[cfg(all(target_os = "android", feature = "mediacodec"))]
                    if scrap::mediacodec::has_output_surface() {
                        handler.on_surface_frame(display);
                    }
                    #[cfg(all(feature = "vram", feature = "flutter"))]
                    handler.on_texture(display, _texture);
                }'''
if io_anchor not in s:
    raise SystemExit("io_loop video callback target not found")
s = s.replace(io_anchor, io_new, 1)
io_loop_p.write_text(s)

s = model_dart_p.read_text()
event_anchor = '''          if (event != null) {
            await cb(event);
          }'''
event_new = '''          if (event != null) {
            if (event['name'] == 'surface_frame') {
              onEvent2UIRgba();
            }
            await cb(event);
          }'''
if event_anchor not in s:
    raise SystemExit("Flutter event dispatch target not found")
s = s.replace(event_anchor, event_new, 1)
model_dart_p.write_text(s)

print("Applied Android MediaCodec direct-Surface patch v2")
PY2

grep -nF "surface frame rendered" "$MC"
grep -nF "setMediaCodecSurface" "$ANDROID_FFI" "$FFI_KT"
grep -nF "rustdesk/mediacodec_surface" "$MAIN_ACTIVITY" "$REMOTE_PAGE"
grep -nF "Export MediaCodec debug log" "$SETTINGS_PAGE"
grep -nF "on_surface_frame" "$UI_TRAIT" "$FLUTTER_RS" "$IO_LOOP"
grep -nF "surface_frame" "$MODEL_DART"


# Surface lifecycle v3: wait for the real ANativeWindow before session decoder
# creation, rebind MediaCodec when a late/new Surface appears, and stop the old
# MediaCodec before codec switches so Qualcomm/Amlogic resources are released.
CLIENT_RS="$ROOT/src/client.rs"

python3 - "$MC" "$CODEC" "$SURFACE_KT" "$CLIENT_RS" <<'PY3'
from pathlib import Path
import sys

mc_p, codec_p, surface_p, client_p = map(Path, sys.argv[1:])

s = mc_p.read_text()

old = '''        atomic::{AtomicBool, Ordering},
        Mutex, Once,''';
new = '''        atomic::{AtomicBool, AtomicU64, Ordering},
        Mutex, Once,''';
if old not in s:
    raise SystemExit("v3 atomic import target not found")
s = s.replace(old, new, 1)

old = '''static PROBE_ONCE: Once = Once::new();

lazy_static::lazy_static! {''';
new = '''static PROBE_ONCE: Once = Once::new();
static SURFACE_GENERATION: AtomicU64 = AtomicU64::new(0);

lazy_static::lazy_static! {''';
if old not in s:
    raise SystemExit("v3 surface generation insertion target not found")
s = s.replace(old, new, 1)

old = '''pub fn set_output_surface(env: *mut jni::sys::JNIEnv, surface: jni::sys::jobject) {
    if surface.is_null() {
        *OUTPUT_SURFACE.lock().unwrap() = None;
        diag("surface detached");
        return;
    }

    let window = unsafe { NativeWindow::from_surface(env as *mut _, surface as _) };
    match window {
        Some(window) => {
            let width = window.width();
            let height = window.height();
            *OUTPUT_SURFACE.lock().unwrap() = Some(window);
            diag(format!("surface attached {}x{}", width, height));
        }
        None => {
            diag("ANativeWindow_fromSurface failed");
        }
    }
}

pub fn has_output_surface() -> bool {
    OUTPUT_SURFACE.lock().unwrap().is_some()
}

fn current_output_surface() -> Option<NativeWindow> {
    OUTPUT_SURFACE.lock().unwrap().as_ref().cloned()
}''';
new = '''pub fn set_output_surface(env: *mut jni::sys::JNIEnv, surface: jni::sys::jobject) {
    if surface.is_null() {
        *OUTPUT_SURFACE.lock().unwrap() = None;
        let generation = SURFACE_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
        diag(format!("surface detached generation={}", generation));
        return;
    }

    let window = unsafe { NativeWindow::from_surface(env as *mut _, surface as _) };
    match window {
        Some(window) => {
            let width = window.width();
            let height = window.height();
            *OUTPUT_SURFACE.lock().unwrap() = Some(window);
            let generation = SURFACE_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
            diag(format!(
                "surface attached {}x{} generation={}",
                width, height, generation
            ));
        }
        None => {
            diag("ANativeWindow_fromSurface failed");
        }
    }
}

pub fn has_output_surface() -> bool {
    OUTPUT_SURFACE.lock().unwrap().is_some()
}

pub fn output_surface_generation() -> u64 {
    SURFACE_GENERATION.load(Ordering::SeqCst)
}

fn current_output_surface() -> Option<NativeWindow> {
    OUTPUT_SURFACE.lock().unwrap().as_ref().cloned()
}

fn wait_for_output_surface(timeout: Duration) -> Option<NativeWindow> {
    let start = std::time::Instant::now();
    loop {
        if let Some(surface) = current_output_surface() {
            if start.elapsed() > Duration::from_millis(1) {
                diag(format!(
                    "waited {}ms for output surface generation={}",
                    start.elapsed().as_millis(),
                    output_surface_generation()
                ));
            }
            return Some(surface);
        }
        if start.elapsed() >= timeout {
            diag(format!(
                "surface wait timeout after {}ms; using ByteBuffer fallback",
                timeout.as_millis()
            ));
            return None;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}''';
if old not in s:
    raise SystemExit("v3 set_output_surface target not found")
s = s.replace(old, new, 1)

old = '''pub struct MediaCodecDecoder {
    decoder: MediaCodec,
    name: String,
    surface_mode: bool,
    queued_frames: u64,
    rendered_frames: u64,
    no_output_count: u64,
}''';
new = '''pub struct MediaCodecDecoder {
    decoder: MediaCodec,
    name: String,
    format: CodecFormat,
    surface_mode: bool,
    surface_generation: u64,
    queued_frames: u64,
    rendered_frames: u64,
    no_output_count: u64,
}''';
if old not in s:
    raise SystemExit("v3 MediaCodecDecoder struct target not found")
s = s.replace(old, new, 1)

old = '''    pub fn new(format: CodecFormat) -> Option<MediaCodecDecoder> {
        match format {
            CodecFormat::H264 => create_media_codec(H264_MIME_TYPE, MediaCodecDirection::Decoder),
            CodecFormat::H265 => create_media_codec(H265_MIME_TYPE, MediaCodecDirection::Decoder),
            _ => {
                diag(format!("unsupported codec format: {:?}", format));
                None
            }
        }
    }''';
new = '''    pub fn new(format: CodecFormat) -> Option<MediaCodecDecoder> {
        create_media_codec_for_format(format, true, false)
    }''';
if old not in s:
    raise SystemExit("v3 MediaCodecDecoder::new target not found")
s = s.replace(old, new, 1)

old = '''    pub fn decode(&mut self, data: &[u8], rgb: &mut ImageRgb) -> ResultType<bool> {
        self.queued_frames = self.queued_frames.saturating_add(1);

        match self.dequeue_input_buffer(Duration::from_millis(20))? {''';
new = '''    pub fn decode(&mut self, data: &[u8], rgb: &mut ImageRgb) -> ResultType<bool> {
        let generation = output_surface_generation();
        let surface_present = has_output_surface();

        // If this decoder started before SurfaceView was ready, or SurfaceView
        // was destroyed/recreated, bind a fresh MediaCodec to the current
        // ANativeWindow. Stop the old codec first: some vendor codecs reject a
        // second surface decoder while the previous instance is still active.
        if surface_present && self.surface_generation != generation {
            let format = self.format.clone();
            diag(format!(
                "surface generation changed codec={} old={} new={} mode={}; rebinding",
                self.name, self.surface_generation, generation, self.surface_mode
            ));
            let _ = self.decoder.stop();

            if let Some(replacement) = create_media_codec_for_format(format.clone(), false, false) {
                let rebound_surface = replacement.surface_mode;
                *self = replacement;
                diag(format!(
                    "decoder rebound format={:?} surface={} generation={}",
                    format, rebound_surface, self.surface_generation
                ));
            } else if let Some(replacement) =
                create_media_codec_for_format(format.clone(), false, true)
            {
                *self = replacement;
                diag(format!(
                    "surface rebind failed; ByteBuffer fallback format={:?} generation={}",
                    format, self.surface_generation
                ));
            } else {
                bail!("failed to recreate MediaCodec after Surface change");
            }
        }

        if self.surface_mode && !surface_present {
            // SurfaceView can disappear briefly during Android view/layout
            // transitions. Do not feed frames into a decoder bound to a dead
            // ANativeWindow; a new generation will rebind it when Surface returns.
            return Ok(true);
        }

        self.queued_frames = self.queued_frames.saturating_add(1);

        match self.dequeue_input_buffer(Duration::from_millis(20))? {''';
if old not in s:
    raise SystemExit("v3 decode preamble target not found")
s = s.replace(old, new, 1)

old = '''fn create_media_codec(mime: &str, direction: MediaCodecDirection) -> Option<MediaCodecDecoder> {
    let surface = current_output_surface();
    let surface_mode = surface.is_some();
    let preferred = preferred_decoder_name(mime, surface_mode);

    let decoder = preferred
        .as_deref()
        .and_then(MediaCodec::from_codec_name)
        .or_else(|| MediaCodec::from_decoder_type(mime))?;

    let selected_name = preferred.unwrap_or_else(|| format!("auto:{}", mime));
    let media_format = MediaFormat::new();
    media_format.set_str("mime", mime);
    media_format.set_i32("width", 1920);
    media_format.set_i32("height", 1080);
    media_format.set_i32("max-input-size", MAX_INPUT_SIZE);
    if !surface_mode {
        media_format.set_i32("color-format", COLOR_FORMAT_YUV420_PLANAR);
    }

    if let Err(e) = decoder.configure(&media_format, surface.as_ref(), direction) {
        diag(format!(
            "configure failed codec={} mime={} surface={} err={:?}",
            selected_name, mime, surface_mode, e
        ));
        return None;
    }
    if let Err(e) = decoder.start() {
        diag(format!(
            "start failed codec={} mime={} surface={} err={:?}",
            selected_name, mime, surface_mode, e
        ));
        return None;
    }

    diag(format!(
        "decoder started codec={} mime={} surface={} input_max={}",
        selected_name, mime, surface_mode, MAX_INPUT_SIZE
    ));
    Some(MediaCodecDecoder {
        decoder,
        name: selected_name,
        surface_mode,
        queued_frames: 0,
        rendered_frames: 0,
        no_output_count: 0,
    })
}''';
new = '''fn create_media_codec_for_format(
    format: CodecFormat,
    wait_for_surface: bool,
    force_bytebuffer: bool,
) -> Option<MediaCodecDecoder> {
    let mime = match format {
        CodecFormat::H264 => H264_MIME_TYPE,
        CodecFormat::H265 => H265_MIME_TYPE,
        _ => {
            diag(format!("unsupported codec format: {:?}", format));
            return None;
        }
    };

    let surface = if force_bytebuffer {
        None
    } else if wait_for_surface {
        wait_for_output_surface(Duration::from_millis(1500))
    } else {
        current_output_surface()
    };
    let surface_mode = surface.is_some();
    let generation = output_surface_generation();
    let preferred = preferred_decoder_name(mime, surface_mode);

    let decoder = preferred
        .as_deref()
        .and_then(MediaCodec::from_codec_name)
        .or_else(|| MediaCodec::from_decoder_type(mime))?;

    let selected_name = preferred.unwrap_or_else(|| format!("auto:{}", mime));
    let media_format = MediaFormat::new();
    media_format.set_str("mime", mime);
    media_format.set_i32("width", 1920);
    media_format.set_i32("height", 1080);
    media_format.set_i32("max-input-size", MAX_INPUT_SIZE);
    if !surface_mode {
        media_format.set_i32("color-format", COLOR_FORMAT_YUV420_PLANAR);
    }

    if let Err(e) = decoder.configure(&media_format, surface.as_ref(), MediaCodecDirection::Decoder) {
        diag(format!(
            "configure failed codec={} mime={} surface={} generation={} err={:?}",
            selected_name, mime, surface_mode, generation, e
        ));
        return None;
    }
    if let Err(e) = decoder.start() {
        diag(format!(
            "start failed codec={} mime={} surface={} generation={} err={:?}",
            selected_name, mime, surface_mode, generation, e
        ));
        return None;
    }

    diag(format!(
        "decoder started codec={} mime={} surface={} generation={} input_max={}",
        selected_name, mime, surface_mode, generation, MAX_INPUT_SIZE
    ));
    Some(MediaCodecDecoder {
        decoder,
        name: selected_name,
        format,
        surface_mode,
        surface_generation: generation,
        queued_frames: 0,
        rendered_frames: 0,
        no_output_count: 0,
    })
}''';
if old not in s:
    raise SystemExit("v3 create_media_codec target not found")
s = s.replace(old, new, 1)

old = '''            let h264 = MediaCodecDecoder::new(CodecFormat::H264);
            let h265 = MediaCodecDecoder::new(CodecFormat::H265);''';
new = '''            // Startup capability probing must never wait for a remote-session
            // SurfaceView. The actual session decoder waits/rebinds separately.
            let h264 = create_media_codec_for_format(CodecFormat::H264, false, true);
            let h265 = create_media_codec_for_format(CodecFormat::H265, false, true);''';
if old not in s:
    raise SystemExit("v3 startup probe target not found")
s = s.replace(old, new, 1)

mc_p.write_text(s)

# Expose an explicit MediaCodec stop so codec switches free the old vendor
# decoder before configuring the replacement.
s = codec_p.read_text()
anchor = '''    pub fn valid(&self) -> bool {
        self.valid
    }
''';
extra = '''
    #[cfg(feature = "mediacodec")]
    pub fn stop_mediacodec(&mut self) {
        if let Some(decoder) = &mut self.h264_media_codec {
            let _ = decoder.stop();
        }
        if let Some(decoder) = &mut self.h265_media_codec {
            let _ = decoder.stop();
        }
    }
''';
if anchor not in s:
    raise SystemExit("v3 Decoder::valid anchor not found")
s = s.replace(anchor, anchor + extra, 1)
codec_p.write_text(s)

s = client_p.read_text()
old = '''        let luid = Self::get_adapter_luid();
        let format = format.unwrap_or(self.decoder.format());
        self.decoder = Decoder::new(format, luid);''';
new = '''        let luid = Self::get_adapter_luid();
        let format = format.unwrap_or(self.decoder.format());
        #[cfg(feature = "mediacodec")]
        self.decoder.stop_mediacodec();
        self.decoder = Decoder::new(format, luid);''';
if old not in s:
    raise SystemExit("v3 VideoHandler::reset target not found")
s = s.replace(old, new, 1)
client_p.write_text(s)

# surfaceChanged is geometry-only. Re-sending the same Java Surface to Rust on
# every layout change creates artificial generations and needless decoder resets.
s = surface_p.read_text()
old = '''    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        FFI.setMediaCodecSurface(holder.surface)
        MediaCodecSurfaceState.onReady()
        Log.i("RustDeskMC", "MediaCodec Surface changed " + width + "x" + height)
    }''';
new = '''    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        MediaCodecSurfaceState.onReady()
        Log.i("RustDeskMC", "MediaCodec Surface geometry " + width + "x" + height)
    }''';
if old not in s:
    raise SystemExit("v3 surfaceChanged target not found")
s = s.replace(old, new, 1)
surface_p.write_text(s)

print("Applied Android MediaCodec Surface lifecycle patch v3")
PY3

grep -nF "surface generation changed" "$MC"
grep -nF "wait_for_output_surface" "$MC"
grep -nF "stop_mediacodec" "$CODEC" "$CLIENT_RS"
grep -nF "Surface geometry" "$SURFACE_KT"
