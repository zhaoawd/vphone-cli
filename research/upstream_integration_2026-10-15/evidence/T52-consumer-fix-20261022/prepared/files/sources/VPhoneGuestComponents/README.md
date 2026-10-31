# Isolated guest component candidates

Sources are pinned to upstream 2.0.8 (`9d218dedf58d4b19db5e51c8b584c1f14a96eee3`).
Run `make guest_components_build` at the repository root to build six signed arm64e dylibs into `.build/guest-components-v2/stage` and record their hashes. This target does not install, bundle, or activate them. `make test_guest_components` runs the host loader-link, camera data-plane and audio algorithm tests; the fast test runner includes these checks.

| Component | Candidate artifact | Minimum build target |
| --- | --- | --- |
| Camera app hook | `camfix/libcamfix.dylib` | iOS 26.0 |
| Camera daemon hook | `vcamcaptured/libvcamcaptured.dylib` | iOS 26.0 |
| Location app hook | `locationfix/libvlocation.dylib` | iOS 26.0 |
| Launchd hook | `launchhook/launchdhook-vphone.dylib` | iOS 26.0 |
| Process injection | `systemhook/SystemHook-vphone.dylib` | iOS 26.0 |
| GPU compiler plugin | `gpu/libAppleParavirtCompilerPluginIOGPUFamily.dylib` | iOS 26.1 |

The compiler plugin is built from source. No Apple GPU driver is included. Minimum deployment targets and signature checks do not establish guest compatibility or runtime loading.

The candidate camera protocol has a 64-byte publish header. The local classic camera uses a 256-byte header, generation and presentation identity, and a separate observation receipt. These artifacts cannot replace the classic camera payloads. ABI integration and real app acceptance remain pending.

The fixed upstream README lists `vpregister`, but that revision's Makefile and source tree do not produce it. It is not part of this candidate manifest. Source provenance and local build adaptations are recorded in `dependencies/guest-components-pins.json`. The repository MIT license applies; original source and GPU provenance notes are retained.

## Audio algorithm integration

The ring, clock, PCM protocol, converter, high-pass filter and latency tracker
sources are pinned separately to `2d21d21fbdd4f51f013616273ceda9b35a3e0789` in
`dependencies/virtio-sound-pins.json`. The local latency-period rounding uses
quotient and remainder to avoid overflowing uint64 before saturating to uint32.
Four upstream host harnesses and the local boundary regression run through
`make test_guest_components`. `scripts/check_virtio_sound.py` checks their
recorded source hashes using the existing regular-file and symlink guards.

These sources do not produce or add a HAL driver to the six-component stage.
The HAL plugin, VirtualAudio routes, DeviceTree/kernel requirements, capture
lifetime, microphone permissions and host latency synchronization are not
integrated here. Algorithm tests at 44.1/48 kHz do not establish guest playback,
recording, duplex operation or any device/firmware compatibility.
