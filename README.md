# RustDesk 1.4.9 ARM64 V4L2M2M build

Experimental RustDesk 1.4.9 ARM64 Linux build for Amlogic S905X / S912 running Armbian.

Goal:

- Enable FFmpeg V4L2 M2M support in RustDesk's bundled FFmpeg.
- Add `h264_v4l2m2m` as a Linux AArch64 hardware decoder candidate in `rustdesk-org/hwcodec`.
- Produce an ARM64 `.deb` using the upstream RustDesk Linux ARM64 build flow.

Validated target hardware before this build:

- `/dev/video0` provided by `meson-vdec`
- `h264_v4l2m2m` successfully decodes H.264 through the Amlogic Video Decoder
- Mesa GPU acceleration works on Mali-450 (S905X) and Mali-T820/Panfrost (S912)

This repository does not vendor the full RustDesk source. GitHub Actions checks out the pinned RustDesk 1.4.9 source and applies the V4L2M2M patches during the build.
