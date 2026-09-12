---
name: kernel-analysis-vphone600
description: Look up symbols and analyze vphone600 kernels or kernel patches in this repository.
---

# Kernel Analysis Vphone600

Use evidence for the requested `vphone600` kernel. This dataset does not establish behavior for other kernel targets.

## Select the Relevant Evidence

- **Symbol/address lookup:** Use available matching data in `research/kernel_info`. Read [kernel-info-queries.md](references/kernel-info-queries.md) for read-only queries, portable path resolution, and missing-data handling. Source checkout is unnecessary for a lookup alone.
- **Behavior or release/research comparison:** Inspect the relevant binary and symbol evidence for each kernel. Consult `research/reference/xnu` for source semantics when needed; record the source revision and its relationship to the target kernel version. If the relationship is unverified, label the source mapping as inference.
- **Patch analysis:** Inspect the current patcher and its relevant research record, then verify anchors and control flow against the target image. Follow the kernel patcher guardrails in repository `AGENTS.md`, including the restricted `patch_bsd_init_auth` reveal flow. Exported symbols may assist analysis but must not become a patcher's runtime dependency.

## Missing Evidence

- Check only the resources required by the task. The database is an index of symbol JSON files, not a substitute for their contents; stored paths may belong to another checkout.
- If symbol data is absent or does not match, report the missing resource and which conclusions it prevents. Continue analysis supported by the available image or source without inventing symbol names or transferring addresses between kernels.
- Obtain missing XNU source only when needed for the requested analysis. Select an appropriate tag or commit from `https://github.com/apple-oss-distributions/xnu`; do not automatically clone the latest revision. Record version uncertainty if matching public source is unavailable.

## Findings

- Identify the kernel (`kernelcache.release.vphone600` or `kernelcache.research.vphone600`), artifact path, and build/version when available.
- Include exact symbol names and addresses when supported; distinguish virtual addresses from file offsets.
- Distinguish observed binary behavior, symbol-dataset evidence, source-based inference, and unverified behavior. Do not claim coverage beyond the inspected artifacts.
