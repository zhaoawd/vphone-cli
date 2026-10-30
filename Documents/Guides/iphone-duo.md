# iPhone Duo display choices

This integration adds optional static display configuration to the upstream
fold model. The default remains `fold`. Firmware-free validation is recorded
in [the integration record](../../Research/Integration/duo_m5_20261030/README.md);
runtime acceptance of the integrated bundle is pending.

```zsh
vphone-cli vm config lab --display fold
vphone-cli vm config lab --display outer
vphone-cli vm config lab --display inner
```

The configuration applies at the next start. `vm info` describes the saved
display choice. Other iPhone models reject this option.

| Choice | Configured display | Required guest selection |
| --- | --- | --- |
| `fold` | Cover panel, 1398x2034 at 460 ppi | Fold display enabled. |
| `outer` | Static cover, 1398x2034 at 460 ppi | Fold display disabled. |
| `inner` | Static inner render size, 2007x2853 at 460 ppi | Fold display disabled; optional inner cutout patch enabled on iOS 27.1. |

Changing `--display` saves screen configuration; it does not change or deploy
guest patches. Inspect `vphone-cli fw patches lab` and follow
[post-creation patch changes](../../Research/Firmware/post_creation_patch_changes.md)
to reconcile selection with the guest while the VM is off. `fw set-patches`
replaces manual overrides, so retain the machine's preset and other choices
when constructing that command.

The static-inner compatibility patch is
`system-springboard-exp-inner_cutout`. It is off in `standard` and limited to
iOS 27.1. Its historical evidence concerns a single static main screen; it
does not establish folding behavior or compatibility with the latest device
tree. SystemHook skips it when the fold display library is installed.

Keep static-mode acceptance on disposable copies until the pending VM checks
are complete. Current upstream fold rendering is retained; the older local
previous-frame hold is preserved in source history for A/B evaluation.
