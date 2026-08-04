# INC-2026-0120 — GPU inference host degraded after an NVIDIA driver mismatch

**Severity:** SEV2  |  **Status:** Resolved
**Opened:** 2026-09-02 13:40 UTC  |  **Resolved:** 2026-09-02 15:20 UTC  |  **Duration:** 1h 40m
**Services affected:** ml-inference (vLLM), model-gateway
**Detection:** Inference 500s + 'CUDA driver version is insufficient' errors; Splunk GPU dashboard flagged the node.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
An unattended OS upgrade bumped the kernel and broke the NVIDIA driver/CUDA match on a GPU node, taking model inference offline until the driver was rebuilt.

## Timeline
- **13:20** — Unattended-upgrades installs a new kernel and reboots the GPU node.
- **13:40** — vLLM fails to start: 'CUDA driver version is insufficient'; inference 500s.
- **14:10** — Node cordoned; traffic shifted to a healthy GPU node (added latency).
- **14:55** — NVIDIA DKMS driver rebuilt against the new kernel; nvidia-smi healthy.
- **15:20** — vLLM back in service; node uncordoned.

## Root cause
Automatic kernel upgrades ran on a GPU node; the DKMS NVIDIA driver did not rebuild, so CUDA libraries no longer matched the running kernel.

## Resolution
Rebuilt the NVIDIA driver via DKMS, pinned the kernel, and disabled unattended kernel upgrades on GPU nodes.

## Impact
Reduced inference capacity and elevated latency for ~1h40m; requests served by remaining GPU nodes.

## Action items
- Pin kernels and disable unattended upgrades on GPU hosts.
- Add a pre-service CUDA/driver health gate.
- Keep N+1 GPU capacity for driver maintenance.

**Tags:** gpu, ml-inference, drivers, reliability
