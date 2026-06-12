# TODO — Detached BERTopic Dispatch (Ctrl-C / R-crash immunity)

Make the BERTopic pod run survive R-side termination — Ctrl-C in the
R session, R/RStudio crashes, laptop sleep, or laptop ↔ pod network
breakdown.

Not implemented. This file captures the design so the work can be
picked up when the case for it actually appears (i.e. an actual run
gets lost to R or network failure).

Companion to [TODO_BERTopicStageCaching.md](TODO_BERTopicStageCaching.md)
which already mitigates ~most of the same risk class via per-stage
intermediate caching on R2.

## Desired behavior

| Scenario | What should happen |
|---|---|
| `tar_make()` runs to completion, BERTopic finishes | Result loaded, target marked done. **Same as today.** |
| User Ctrl-C in R while BERTopic is mid-fit on the pod | R returns control to user. **BERTopic on the pod keeps running.** |
| User runs `tar_make()` again while pod is still running | tar_make discovers the in-flight run, waits for it, retrieves result. |
| User runs `tar_make()` after BERTopic finished on the pod | Cache hit at the appropriate stage(s); finishes quickly. |
| Outputs already exist locally | Already-completed result loaded immediately; target is up to date. |
| Network drops mid-fit | Same as Ctrl-C — pod-side python keeps going; a later `tar_make()` finds it. |

The user's mental model becomes: *I can run tar_make as many times as
I want — it always converges on the right state, never duplicates
work, never loses work I've already paid for.*

## Why the current behavior doesn't satisfy this

Today's `R/run_bertopic_runpod.R` issues one blocking
`ssh ... 'python ...'` call. The chain:

```
R hosts the ssh client process as its child
  → ssh client opens TCP connection to pod's sshd
    → sshd forks bash -c "...python..."
      → bash exec's python (or forks it)
```

If R dies, Ctrl-C, or network breaks:

```
R's child (ssh client) gets SIGTERM/SIGKILL or the TCP socket dies
  → ssh client disconnects
  → pod's sshd loses the client
  → sshd sends SIGHUP to the bash shell
  → bash forwards SIGHUP to python
  → python dies
```

Stage caching (v0.1.8) softens this: any cache writes that succeeded
before the death survive on R2, so a re-run starts from the latest
cached stage. But the *current* stage's compute is lost.

## What changes for the proposed behavior

Two pieces of code change, plus a couple of operational considerations.

### 1. Pod-side detach — small change (~5 lines)

In the wrapper's `remote_cmd`, wrap the python call to survive
SSH disconnect:

```bash
# Was:
python /opt/run_bertopic_gpu.py ...

# Becomes:
nohup python /opt/run_bertopic_gpu.py ... > /work/python.log 2>&1 &
echo $! > /work/python.pid
echo "dispatched pid=$(cat /work/python.pid)"
```

`nohup` + `&` detaches from the parent shell's controlling terminal,
so SIGHUP from sshd doesn't reach python. The pid file lets later
SSH sessions check whether the same dispatch is still alive.

Output redirected to `/work/python.log` so it's inspectable from
later SSH sessions (replaces the current "stream-back-to-R-stdout"
which dies with the SSH session anyway).

### 2. R-side "running job detection" — moderate change (~30 lines)

Before launching, the wrapper:

1. SSHs in, checks for `/work/python.pid`.
2. If present, reads it and checks `kill -0 <pid>` (does the process
   exist?).
3. If alive, also checks the cfg yaml on the pod (`/work/bertopic_cfg_<run>.yaml`)
   has matching content to current cfg. (Prevents waiting on an
   in-flight run with stale parameters.)
4. If both match: "discovered in-flight run for current cfg, tailing
   log..." — skip dispatch, go straight to wait/poll.
5. Otherwise: fresh dispatch as in step 1.

### 3. R-side "wait but interruptible" — moderate change (~50 lines)

Current code does one big blocking SSH. New code polls every N
seconds in a small loop:

```r
while (TRUE) {
  status <- ssh_cmd_with_status(c(
    "test -f /work/python.pid",
    "kill -0 $(cat /work/python.pid) 2>/dev/null && echo running",
    "test -f /work/out/<expected_path>/topic_info.parquet && echo done",
    "tail -n 5 /work/python.log"
  ))
  if (status$done)    break
  if (!status$alive)  stop("python exited but output not present — check /work/python.log")
  Sys.sleep(30)
}
# Download outputs
```

Each poll is a small independent SSH session. Ctrl-C between polls
just kills the polling loop — the pod-side python keeps going.

### 4. Pod-side python log capture — already there in v0.1.6+

`PYTHONUNBUFFERED=1` is already set in v0.1.6+. So
`/work/python.log` will accumulate per-line output even with the
detached process.

## What stage caching already gives (don't underestimate this)

| Ctrl-C / crash timing | Wall-time lost | What's preserved on R2 |
|---|---|---|
| During UMAP fit | ~30-60 min | nothing — UMAP not yet cached |
| Between UMAP and HDBSCAN | 0 | UMAP cache ✓ |
| During HDBSCAN fit | ~10-30 min | UMAP cache ✓ |
| Between HDBSCAN and c-TF-IDF | 0 | UMAP + HDBSCAN ✓ |
| During c-TF-IDF | ~2-5 min | UMAP + HDBSCAN ✓ |
| After c-TF-IDF cache write | 0 | all three caches ✓ — next dispatch ~5 min |

So the **worst-case loss with Ctrl-C today is ~30-60 min** (one stage's
compute). v0.1.9 would shrink that to "zero loss".

## Cost-benefit

| Risk class | Mitigated by v0.1.8 stage caching | Mitigated by v0.1.9 detached dispatch |
|---|---|---|
| R crashes mid-fit | ✗ — lose current stage's compute | ✓ — pod keeps running, R re-attaches |
| Network drops mid-fit | ✗ — same | ✓ |
| Laptop sleep / disconnect | ✗ — same | ✓ |
| User intentional Ctrl-C to free terminal | ✗ — kills pod work | ✓ |
| Pod evicted by RunPod | n/a — both lose work | n/a |
| OOM kill of python | n/a — both lose work | n/a |

v0.1.9 covers exactly the "R or network breakdown OR user-Ctrl-C"
class. Stage caching already covers "I want to retry without redoing
earlier stages".

## Effort estimate

| Piece | Hours |
|---|---|
| Pod-side detach (5 lines in wrapper) | 0.5 |
| R-side running-job detection | 1-2 |
| R-side polling-with-resumability | 2-4 |
| Testing edge cases (death mid-cache-write, partial outputs, stale pid file, pod terminated) | 2-3 |
| Documentation + CHANGES entry | 0.5 |
| **Total** | **~1 working day** |

No image rebuild required — all changes are in the R wrapper and the
in-pod working files (pid + log under `/work/`). Image stays at
v0.1.8.

## When this becomes worth doing

| Trigger | Action |
|---|---|
| First time an actual run is lost to R crash / network breakdown | Implement. The pain is real and the design is ready. |
| Workflow becomes "dispatch and walk away for the day", needing laptop sleep / movement to not interrupt | Implement. Quality-of-life win. |
| Multi-author coordination where one person dispatches and another monitors | Implement. The decoupling matters. |
| TCAC's current "one run before submission" cadence with manual presence | Defer. Pain point hasn't materialised. |

## Out-of-scope clarifications

This TODO does **not** solve:

- **Pod eviction** by RunPod (host-side failures): pod state including
  `/work/python.pid` is gone; need fresh dispatch.
- **Python crashes** (OOM, segfault): pod is alive but python isn't;
  poll detects this and fresh dispatch is required.
- **Multi-tenant coordination**: nothing prevents two `tar_make()`
  invocations from different machines from dispatching the same run
  simultaneously. If that matters, add a "lock" file on R2.

## File touch list (when implementing)

- `R/run_bertopic_runpod.R` — main logic restructure.
- `docker/bertopic-runpod/CHANGES.md` — note v0.1.9 wrapper change (image
  unchanged).
- `NEXT_STEPS.md` — move from optional to done.
- This file — delete or rename to `TD_DetachedDispatch.md`.
