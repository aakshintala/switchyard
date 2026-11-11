# Real pi continuation latency

Recorded 2026-11-11 with pi 1.5.0 in RPC mode. Each `.stdout` is the unmodified byte stream received from pi; its `.timings.tsv` sidecar has one UTC and monotonic receive timestamp per stdout line. The `.argv` files preserve the RPC argument shape used by the session host (`--mode rpc --model ... --session-id ... --session-dir ... --append-system-prompt ...`).

The recorder started the first prompt with `Your instructions are in your system prompt. Begin.` It sent the steer with `streamingBehavior: "steer"` after the second assistant `message_start` in the post-tool trials, and after the first assistant `message_start` in the early-steer trial. The queue update and RPC response both confirmed `queued` before the measured `turn_end` in all three traces. The next raw pi `turn_start` followed that `turn_end` by:

| Model | Trace | `turn_end` receive time | next `turn_start` receive time | Gap |
| --- | --- | --- | --- | ---: |
| `opencode-go/beam-free` | `continuation-beam-free-early-steer` | 1.559657333 s | 1.559804042 s | 0.146709 ms |
| `opencode-go/beam-free` | `continuation-beam-free-post-tool` | 2.422093166 s | 2.422200458 s | 0.107292 ms |
| `openai/gpt-6-luna` | `continuation-gpt-6-luna-post-tool` | 3.857878708 s | 3.857976542 s | 0.097834 ms |

The largest measured gap was 0.146709 ms. The 30 s `PI_CONTINUATION_WAIT` is 204,486 times that gap (29.999853291 s of additional margin). The `gpt-6-luna` run took 5.782 s from process start through `agent_settled`, versus 3.175 s for the comparable post-tool `beam-free` run; the continuation event still followed its turn end within 0.098 ms. No `compaction_start` event occurred. A forced compaction was not attempted: the available models have large contexts, and manufacturing a context-sized prompt would add substantial unrelated input without improving this boundary measurement.

## Event-layer limitation

These traces measure pi's raw internal `turn_end` to `turn_start` boundary while the steer remains in pi's steering queue. In pi 1.5.0, the next internal `turn_start` occurs before the queued user message is delivered, and the queue is cleared before `agent_settled`; there is no second top-level `agent_start` in these normal queued-steer traces. The session `Wire` parser maps top-level `agent_start` to host `TurnStarted` and intentionally ignores internal `turn_start` events. Thus the traces establish the RPC continuation boundary and its timing, but do not exercise the supervisor's exceptional post-`agent_settled` wait for a new host-level `TurnStarted`. The parser test records this distinction rather than treating the internal event as a host event.

An earlier `opencode-go/muse-spark-1.3-contributor` attempt returned HTTP 402 (insufficient balance), so the free `beam-free` model was used for repeated trials. An `openai/gpt-4.1-mini` attempt returned HTTP 400 (`model_not_found` for the configured ChatGPT account); the `openai/gpt-6-luna` RPC trace succeeded.
