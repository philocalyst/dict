# OMW adaptive ABBA order-bias diagnostic

Status: `omw-adaptive-abba-timed-results`; failures: **0**.

This separate diagnostic does not replace the six-lane paired ledger. It uses the same retained OMW adaptive artifact and fixed plans, with two fresh-process blocks in the exact order `original → current → current → original`.

Ledger: [`simplifying-post-review-omw-adaptive-abba.json`](../runs/simplifying-post-review-omw-adaptive-abba.json), SHA-256 `e809d3f09f28f3b7fabc8dc4647ca687bb11a237a688b02406661763caa9cb85`.
Original binary: `b3287fda7127a58fe8b8f24cb0623f0b6c8875a1777f3ac892de36582680fe88`; current binary: `35db09b6ffe5ced8e6a8dd822a17eaf646b2de80356502a107c33e80287becc0`.

| phase | original median (raw samples, ms) | current median (raw samples, ms) |
| --- | --- | --- |
| fresh process wall | 7522.165 ms (samples: 7684.529, 7359.802, 7970.322, 6997.274) | 7418.793 ms (samples: 7797.280, 7465.457, 7372.129, 7204.461) |
| Archive.open / metadata | 3.448 ms (samples: 3.638, 3.576, 3.244, 3.321) | 3.432 ms (samples: 3.422, 3.434, 3.572, 3.430) |
| exact batch | 0.449 ms (samples: 0.441, 0.458, 0.575, 0.431) | 0.457 ms (samples: 0.463, 0.450, 0.429, 0.493) |
| uncached render batch | 518.331 ms (samples: 550.493, 486.168, 599.971, 462.094) | 506.485 ms (samples: 509.102, 540.101, 492.931, 503.868) |
| uncached snippet batch | 561.013 ms (samples: 543.260, 579.712, 578.765, 463.387) | 516.844 ms (samples: 528.050, 526.722, 506.966, 496.747) |
| mixed-page render | 521.211 ms (samples: 535.077, 507.346, 537.733, 467.491) | 509.528 ms (samples: 517.502, 510.506, 508.551, 507.020) |
| mixed-page snippet | 516.836 ms (samples: 527.189, 506.483, 546.744, 467.004) | 511.496 ms (samples: 527.856, 514.472, 499.680, 508.519) |
| verifyAll after reads | 3906.600 ms (samples: 3965.700, 3847.500, 4244.626, 3755.474) | 3836.574 ms (samples: 4209.595, 3809.093, 3864.056, 3701.681) |

All eight samples must pass the same public-oracle digest, output-count, and Reader-cache validation as the main ledger. This is an order-bias check, not a tuned retry or a replacement result; fresh process still does not mean cold OS cache.
