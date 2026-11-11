# MindTheStep

> In London they say *mind the gap*. In Taiwan's arcades, you have to mind the step.

MindTheStep turns a LiDAR iPhone, clipped to a cane or worn on the chest, into an early-warning sensor for step-ups and drop-offs 0.3–2.5 m ahead. It warns with haptics and a short voice cue. Everything runs on-device in real time, with no cloud required.

Built at c0mpiled-18 (YC Startup School Hackathon, Taipei, 2026-11-11) for YC's RFS **AI for the Aging Population**.

## How it works

1. ARKit `sceneDepth` (single-frame LiDAR depth, high-confidence points only)
2. Unproject to gravity-aligned world space and keep a 60 cm corridor ahead of the user
3. Build a ground reference from the nearest visible ground, discarding walls and objects
4. Bin the ground into 5 cm slices and look for abrupt height jumps ≥ 8 cm with support on both sides
5. Report gentle slopes as ramps (no alert). Ground that disappears early is **UNKNOWN**, never "safe".
6. Confirm the hazard over 3 of 5 frames, then fire haptics immediately, followed by a short voice cue
7. Diagnostics panel shows real depth fps, processing time, alert latency, tracking and confidence

## Run

```bash
xcodegen generate
open MindTheStep.xcodeproj
```

Requires an iPhone with LiDAR (12 Pro or later).

## Status

This is a hackathon prototype, **not a validated mobility aid**. Do not rely on it for independent navigation.
