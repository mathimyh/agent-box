# 005: `-Build` stops the Orca proxy while workers run

Priority: low. Status: open.

## Problem

`agent-box.ps1 -Build` rebuilds the proxy image and removes the proxy container. Running workers cannot send `worker_done` or questions until the next launcher run starts the proxy again. The worker does not get a clear error.

## Proposed fix

After `-Build`, start the proxy again from the new image at once. Or rebuild the proxy only when files in `orca-proxy/` changed.

## Verify

Run `-Build` while a worker runs. The worker can still send `orchestration send`.
