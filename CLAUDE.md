# CLAUDE.md

Notes for working on this fork of Embrace. Focused on things that are not obvious from
reading the code — particularly the audio graph invariants and how to debug it.

## Build

```
xcodebuild -project Embrace.xcodeproj -scheme Embrace -configuration Release build CODE_SIGNING_ALLOWED=NO
```

Targets: `Embrace` (product name `CloseEmbrace`), `CrashPad`, `EmbraceWorker`. Configurations:
Debug, Profile, Release, Submission.

Release distribution is archive + export with the **Developer ID Application** certificate —
the project is configured for *Apple Development*, which cannot be notarised, so the export
step is what upgrades the signature. `Build/Archive.sh` is an Xcode archive post-action that
does export → notarise → staple → `scp` to a server. It needs `Private/Archive.plist`
(`team-id`, `certificate`, `keychain-profile`, `upload-to`, `public-url`), which is not in the
repo. Note its last step **publishes the build**; don't run it casually.

## The audio graph

Render order, built in `-[HugAudioEngine _reconnectGraph]`:

```
source input block  ->  AUNewTimePitch  ->  effect units  ->  meter/limiter block  ->  output
```

**The invariant that keeps getting broken:** everything *above* the time-pitch unit is called
with however many frames that unit decides to pull, which is `ceil(deviceBuffer * rate)` —
**more than the device buffer whenever the rate is above 1.0**. Anything upstream must be
sized with `HugGetMaxInternalFrameCount()` (`HugAudioSettings.h`), not with the device buffer
size. That covers the pre-gain ramper, the stereo field, and the source's scratch buffers.
Everything *below* the unit (volume ramper, level meters, limiter) sees exactly the device
buffer size.

Other non-obvious wiring:

- The volume ramper runs **before** the limiter, so the volume slider decides whether the
  limiter engages at all. Below roughly 0.90 it never does.
- Status packets are timestamped with the moment their audio will be *heard* and held by
  `-_readRingBuffers` until then. `downstreamLatency` (time-pitch + effects) is added so
  end-of-track is not reported early.
- **`[AUNewTimePitch latency]` is not the real latency.** It reports 85.3 ms at 96 kHz, but
  the unit's actual delay grows while the rate is off 1.0 (about 2800 frames per minute at
  1.02, saturating at 28592 frames = 298 ms; 0.97 pins there too, 0.98 settles at 7188) and
  is kept when the rate returns to 1.0. Only `-reset` restores it. Track changes therefore
  wait for *observed* silence (`silentRenderCount`, measured ahead of the volume ramper)
  rather than for `downstreamLatency` to elapse.
- The rate and the effect bypass for a track travel with the file into `-playAudioFile:` and
  are applied only after that drain, while every unit is processing silence. Nothing else
  should write to the units at a track boundary; `-updatePlaybackRate:` is for live ramps.
- `-[AUAudioUnit reset]` is only safe when the output unit is stopped, i.e. in
  `-_reallyStopHardware`. The hardware keeps running for 30 seconds after `-stopPlayback`.

## Debugging the engine

**`downstream latency is N ms` in the log fingerprints the time-pitch unit's configured
sample rate.** AUNewTimePitch reports 92.9 ms at 44.1 kHz, 85.3 at 48/96 kHz, 42.7 at
192 kHz, plus each effect's latency. If that number does not change across a sample rate
switch, the units were not reconfigured.

**Standalone harnesses are the fastest way to answer audio questions.** The `Hug*` primitives
have few dependencies and link against a test `main` directly:

```
clang -fobjc-arc -I Source -include Source/Prefix.pch \
  -framework Foundation -framework AppKit -framework Accelerate -framework AudioToolbox \
  -o t t.m Source/HugLimiter.m
```

`HugLimiter.m`, `HugLinearRamper.m`, `Utils.m` link cleanly. `Track.m` and the controllers do
not — too many dependencies. For constants defined in a file that won't link, grep the
definitions into a stub rather than retyping them, so the test uses the real values.

Audio units can be probed directly for latency, pull sizes, buffer contract and CPU without
running the app. Build buffer-overflow tests with `-fsanitize=address`.

**Logs:** `~/Library/Application Support/CloseEmbrace/Logs/`. Per-track analysis (including
`trackLoudness` and `trackPeak`) is in `.../Tracks/` as plists — useful for reasoning about
real gain staging rather than synthetic assumptions.

## Gotchas found the hard way

- **`AudioConverterFillComplexBuffer` rewrites `mDataByteSize`** on its output buffers to the
  amount produced. Any buffer reused across renders must have its capacity restored first,
  otherwise it shrinks to whatever the first call requested and later, larger requests are
  silently short-filled — leaving stale audio in the tail.
- **Reconfigure guards must compare bus formats,** not just `renderResourcesAllocated` and
  `maximumFramesToRender`. A sample rate change leaves both of those untouched, so a unit will
  happily keep running at the wrong rate.
- **AUNewTimePitch is transparent at rate 1.0** (measured bit-accurate: peak −0.00 dB). This
  masks misconfiguration — a unit stuck at the wrong sample rate sounds perfect until the
  speed moves off normal and the phase vocoder starts working from the wrong numbers.
- **AUNewTimePitch overshoots peaks when speeding up** — up to +3.5 dB at +3% on dense tonal
  material — because it rewrites phase relationships between partials. Energy is unchanged;
  crest factor is not. Percussive material goes the other way and loses peak. This trips the
  emergency limiter, whose decay doubles on re-trigger up to 16 seconds, so it must be reset
  between tracks.
- **`[nil caseInsensitiveCompare:]` returns 0, which is `NSOrderedSame`.** A nil genre
  compares equal to everything. Length-check first.
- Menu items created in `AppDelegate` are validated by **`AppDelegate`**, not by the
  controller that implements the action. Validation must be forwarded explicitly.

## The deployment target this fork is used with

Worth knowing because it exercises paths most setups never touch:

- **Mono, 96 kHz ALAC** files, played on an external DAC at 96 or **192 kHz**, hog mode on,
  4096-frame buffers. Mono plus a sample rate mismatch is the rarest path in `HugAudioSource`
  — the input block converts into a reused scratch buffer instead of the unit's own. If
  something sounds wrong, look there first.
- A third-party EQ (Acon Digital Equalize 2) is in the effect chain, contributing ~20 ms of
  latency that is constant across sample rates.
- Tango transfers are normalised close to full scale: peaks 0.70–1.00 with 0–3 dB of native
  headroom, loudness −25.6 to −10.9 LUFS. Consequently the peak guard in
  `-_updateLoudnessAndPreAmp` pins many tracks at exactly 0 dBFS, leaving nothing for
  downstream overshoot, and Match Loudness cannot fully equalise them — the ceiling caps the
  boost the quiet ones need.

## Conventions

Match the surrounding style: two blank lines between methods, `-` prefixed private methods,
`s`-prefixed file-static C functions, `Hug*` for the audio layer (portable, no AppKit).
Comments explain *why*, and are used sparingly.
