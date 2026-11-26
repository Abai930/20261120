# 3D campus map rendering report

Date: 2026-11-27

## Current build

- [`index.html`](index.html): 50,236 bytes (49.1 KiB). The page has no generated JavaScript bundle; MapLibre GL and Firebase are loaded from their CDNs, so this is the HTML size rather than the complete transfer size.
- The custom building silhouette renderer reuses its per-building typed buffers, rejects buildings outside the view, and batches facade fills. Static inspection found no app-owned array or object creation in that renderer's per-frame callback. This does not measure allocations inside Chrome or MapLibre.
- Six fixed-view screenshots are 2560×1440: [`pose-01`](artifacts/performance/pose-01-2560x1440.png), [`pose-02`](artifacts/performance/pose-02-2560x1440.png), [`pose-03`](artifacts/performance/pose-03-2560x1440.png), [`pose-04`](artifacts/performance/pose-04-2560x1440.png), [`pose-05`](artifacts/performance/pose-05-2560x1440.png), [`pose-06`](artifacts/performance/pose-06-2560x1440.png).
- The scripted 60-second fly-through recording is [`flythrough.webm`](artifacts/performance/flythrough.webm) (26,288 bytes).

## Performance measurement

The clean 60-second timing pass ran without video recording at a 2560×1440 WebGL canvas. The available computer rendered on Intel Iris Xe Graphics using Headless Chrome 158.0. The requested RTX 5070 Ti and Chrome 157 were not available, so this is not a measurement on the target system.

| Metric | Measured | Requested limit |
| --- | ---: | ---: |
| Frame time average | 107.95 ms | ≤ 11 ms GPU average |
| Frame time P99 | 166.90 ms | — |
| Frame time maximum | 467.00 ms | no frame > 16.7 ms |
| Frames over 16.7 ms | 557 / 557 | 0 |
| GPU time average | 41.29 ms | ≤ 11 ms |
| GPU time P99 | 58.57 ms | — |
| GPU time maximum | 64.40 ms | — |

The timing gate did not pass on this machine. The requested target hardware has not been tested, so its gate status is unverified. These numbers are from the no-recording 60-second pass; `metrics.json` and the CSV files in this folder are from the separate recording pass and include recording overhead.

## Visual review

The separate visual critic found no above-minor defects in the stills. The final view-6 framing adjustment removed the previously reported top-edge building crop. The critic could not decode the WebM in its review environment, so motion-only shimmer and popping remain unverified.
