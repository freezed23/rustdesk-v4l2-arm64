#!/usr/bin/env bash
set -euo pipefail

RUSTDESK_DIR="${1:-rustdesk}"
HWCODEC_COMMIT="778df1f99597722473b29443bac22ae6c23946fe"

cd "$RUSTDESK_DIR"

python3 - <<'PY'
from pathlib import Path
p = Path('res/vcpkg/ffmpeg/portfile.cmake')
s = p.read_text()
s = s.replace('--disable-v4l2-m2m \\\n', '--enable-v4l2-m2m \\\n', 1)
needle = '--enable-decoder=h264 \\\n--enable-decoder=hevc \\\n'
extra = (
    '--enable-decoder=h264 \\\n'
    '--enable-decoder=hevc \\\n'
    '--enable-decoder=h264_v4l2m2m \\\n'
    '--enable-decoder=hevc_v4l2m2m \\\n'
    '--enable-decoder=vp9_v4l2m2m \\\n'
    '--enable-decoder=vp8_v4l2m2m \\\n'
)
if 'hevc_v4l2m2m' not in s:
    if needle not in s:
        raise SystemExit('FFmpeg decoder insertion point not found')
    s = s.replace(needle, extra, 1)
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
            codecs.extend(vec![
                CodecInfo {
                    name: "h264_v4l2m2m".to_owned(),
                    format: H264,
                    hwdevice: AV_HWDEVICE_TYPE_NONE,
                    priority: Priority::Best as _,
                    ..Default::default()
                },
                CodecInfo {
                    name: "hevc_v4l2m2m".to_owned(),
                    format: H265,
                    hwdevice: AV_HWDEVICE_TYPE_NONE,
                    priority: Priority::Best as _,
                    ..Default::default()
                },
                CodecInfo {
                    name: "vp9_v4l2m2m".to_owned(),
                    format: VP9,
                    hwdevice: AV_HWDEVICE_TYPE_NONE,
                    priority: Priority::Best as _,
                    ..Default::default()
                },
                CodecInfo {
                    name: "vp8_v4l2m2m".to_owned(),
                    format: VP8,
                    hwdevice: AV_HWDEVICE_TYPE_NONE,
                    priority: Priority::Best as _,
                    ..Default::default()
                },
            ]);
        }

'''
if 'hevc_v4l2m2m' not in s:
    if marker not in s:
        raise SystemExit('hwcodec insertion point not found')
    s = s.replace(marker, insert + marker, 1)

probe_marker = '''                Ok(mut decoder) => {
                    debug!("Decoder {} created successfully", codec.name);
                    let data = match codec.format {
'''
probe_replacement = '''                Ok(mut decoder) => {
                    debug!("Decoder {} created successfully", codec.name);
                    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
                    if codec.name.ends_with("_v4l2m2m") {
                        debug!(
                            "Accepting {} after successful device initialization; skipping synthetic packet probe",
                            codec.name
                        );
                        res.push(codec);
                        continue;
                    }
                    let data = match codec.format {
'''
if 'ends_with("_v4l2m2m")' not in s:
    if probe_marker not in s:
        raise SystemExit('hwcodec decoder probe insertion point not found')
    s = s.replace(probe_marker, probe_replacement, 1)
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

# Extend RustDesk's HwRamDecoder selector to VP8/VP9 as well as H264/H265.
python3 - <<'PY'
from pathlib import Path
p = Path('libs/scrap/src/common/hwcodec.rs')
s = p.read_text()
old1 = '''        match format {
            CodecFormat::H264 => {
                if let Some(v) = soft.h264 {
                    info = Some(v);
                }
            }
            CodecFormat::H265 => {
                if let Some(v) = soft.h265 {
                    info = Some(v);
                }
            }
            _ => {}
        }
'''
new1 = '''        match format {
            CodecFormat::VP8 => {
                if let Some(v) = soft.vp8 {
                    info = Some(v);
                }
            }
            CodecFormat::VP9 => {
                if let Some(v) = soft.vp9 {
                    info = Some(v);
                }
            }
            CodecFormat::H264 => {
                if let Some(v) = soft.h264 {
                    info = Some(v);
                }
            }
            CodecFormat::H265 => {
                if let Some(v) = soft.h265 {
                    info = Some(v);
                }
            }
            _ => {}
        }
'''
old2 = '''            match format {
                CodecFormat::H264 => {
                    if let Some(v) = best.h264 {
                        info = Some(v);
                    }
                }
                CodecFormat::H265 => {
                    if let Some(v) = best.h265 {
                        info = Some(v);
                    }
                }
                _ => {}
            }
'''
new2 = '''            match format {
                CodecFormat::VP8 => {
                    if let Some(v) = best.vp8 {
                        info = Some(v);
                    }
                }
                CodecFormat::VP9 => {
                    if let Some(v) = best.vp9 {
                        info = Some(v);
                    }
                }
                CodecFormat::H264 => {
                    if let Some(v) = best.h264 {
                        info = Some(v);
                    }
                }
                CodecFormat::H265 => {
                    if let Some(v) = best.h265 {
                        info = Some(v);
                    }
                }
                _ => {}
            }
'''
if old1 not in s or old2 not in s:
    raise SystemExit('HwRamDecoder selector block not found')
s = s.replace(old1, new1, 1).replace(old2, new2, 1)
p.write_text(s)
PY

# Route VP8/VP9 through V4L2M2M first, with existing libvpx as fallback.
python3 - <<'PY'
from pathlib import Path
p = Path('libs/scrap/src/common/codec.rs')
s = p.read_text()
repls = []
repls.append(('''    #[cfg(feature = "hwcodec")]
    h264_ram: Option<HwRamDecoder>,
    #[cfg(feature = "hwcodec")]
    h265_ram: Option<HwRamDecoder>,
''', '''    #[cfg(feature = "hwcodec")]
    vp8_ram: Option<HwRamDecoder>,
    #[cfg(feature = "hwcodec")]
    vp9_ram: Option<HwRamDecoder>,
    #[cfg(feature = "hwcodec")]
    h264_ram: Option<HwRamDecoder>,
    #[cfg(feature = "hwcodec")]
    h265_ram: Option<HwRamDecoder>,
'''))
repls.append(('''        #[cfg(feature = "hwcodec")]
        let (mut h264_ram, mut h265_ram) = (None, None);
''', '''        #[cfg(feature = "hwcodec")]
        let (mut vp8_ram, mut vp9_ram, mut h264_ram, mut h265_ram) =
            (None, None, None, None);
'''))
repls.append(('''            CodecFormat::VP8 => {
                match VpxDecoder::new(VpxDecoderConfig {
                    codec: VpxVideoCodecId::VP8,
                }) {
                    Ok(v) => vp8 = Some(v),
                    Err(e) => log::error!("create VP8 decoder failed: {}", e),
                }
                valid = vp8.is_some();
            }
''', '''            CodecFormat::VP8 => {
                #[cfg(feature = "hwcodec")]
                if enable_hwcodec_option() {
                    match HwRamDecoder::new(format) {
                        Ok(v) => vp8_ram = Some(v),
                        Err(e) => log::info!("create VP8 hw ram decoder unavailable: {}", e),
                    }
                    valid = vp8_ram.is_some();
                }
                if !valid {
                    match VpxDecoder::new(VpxDecoderConfig {
                        codec: VpxVideoCodecId::VP8,
                    }) {
                        Ok(v) => vp8 = Some(v),
                        Err(e) => log::error!("create VP8 decoder failed: {}", e),
                    }
                    valid = vp8.is_some();
                }
            }
'''))
repls.append(('''            CodecFormat::VP9 => {
                match VpxDecoder::new(VpxDecoderConfig {
                    codec: VpxVideoCodecId::VP9,
                }) {
                    Ok(v) => vp9 = Some(v),
                    Err(e) => log::error!("create VP9 decoder failed: {}", e),
                }
                valid = vp9.is_some();
            }
''', '''            CodecFormat::VP9 => {
                #[cfg(feature = "hwcodec")]
                if enable_hwcodec_option() {
                    match HwRamDecoder::new(format) {
                        Ok(v) => vp9_ram = Some(v),
                        Err(e) => log::info!("create VP9 hw ram decoder unavailable: {}", e),
                    }
                    valid = vp9_ram.is_some();
                }
                if !valid {
                    match VpxDecoder::new(VpxDecoderConfig {
                        codec: VpxVideoCodecId::VP9,
                    }) {
                        Ok(v) => vp9 = Some(v),
                        Err(e) => log::error!("create VP9 decoder failed: {}", e),
                    }
                    valid = vp9.is_some();
                }
            }
'''))
repls.append(('''            vp8,
            vp9,
            av1,
            #[cfg(feature = "hwcodec")]
            h264_ram,
''', '''            vp8,
            vp9,
            av1,
            #[cfg(feature = "hwcodec")]
            vp8_ram,
            #[cfg(feature = "hwcodec")]
            vp9_ram,
            #[cfg(feature = "hwcodec")]
            h264_ram,
'''))
repls.append(('''            video_frame::Union::Vp8s(vp8s) => {
                if let Some(vp8) = &mut self.vp8 {
                    Decoder::handle_vpxs_video_frame(vp8, vp8s, rgb, chroma)
                } else {
                    bail!("vp8 decoder not available");
                }
            }
''', '''            video_frame::Union::Vp8s(vp8s) => {
                #[cfg(feature = "hwcodec")]
                if let Some(decoder) = &mut self.vp8_ram {
                    *chroma = Some(Chroma::I420);
                    return Decoder::handle_hwram_video_frame(decoder, vp8s, rgb, &mut self.i420);
                }
                if let Some(vp8) = &mut self.vp8 {
                    Decoder::handle_vpxs_video_frame(vp8, vp8s, rgb, chroma)
                } else {
                    bail!("vp8 decoder not available");
                }
            }
'''))
repls.append(('''            video_frame::Union::Vp9s(vp9s) => {
                if let Some(vp9) = &mut self.vp9 {
                    Decoder::handle_vpxs_video_frame(vp9, vp9s, rgb, chroma)
                } else {
                    bail!("vp9 decoder not available");
                }
            }
''', '''            video_frame::Union::Vp9s(vp9s) => {
                #[cfg(feature = "hwcodec")]
                if let Some(decoder) = &mut self.vp9_ram {
                    *chroma = Some(Chroma::I420);
                    return Decoder::handle_hwram_video_frame(decoder, vp9s, rgb, &mut self.i420);
                }
                if let Some(vp9) = &mut self.vp9 {
                    Decoder::handle_vpxs_video_frame(vp9, vp9s, rgb, chroma)
                } else {
                    bail!("vp9 decoder not available");
                }
            }
'''))
for old, new in repls:
    if old not in s:
        raise SystemExit('codec.rs patch block not found:\n' + old[:120])
    s = s.replace(old, new, 1)
p.write_text(s)
PY

cargo update -p hwcodec

echo '===== V4L2M2M PATCH SUMMARY ====='
grep -nE 'v4l2-m2m|h264_v4l2m2m|hevc_v4l2m2m|vp9_v4l2m2m|vp8_v4l2m2m' res/vcpkg/ffmpeg/portfile.cmake
grep -nE 'h264_v4l2m2m|hevc_v4l2m2m|vp9_v4l2m2m|vp8_v4l2m2m|skipping synthetic packet probe' hwcodec-local/src/ffmpeg_ram/decode.rs
grep -n -A55 'pub fn try_get(format: CodecFormat)' libs/scrap/src/common/hwcodec.rs | head -70
grep -nE 'vp8_ram|vp9_ram|create VP8 hw|create VP9 hw' libs/scrap/src/common/codec.rs
grep -A3 '\[dependencies.hwcodec\]' libs/scrap/Cargo.toml
cargo tree -p scrap --features hwcodec | grep -A2 -B2 hwcodec
