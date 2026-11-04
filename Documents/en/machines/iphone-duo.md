# iPhone Duo displays

Set the display mode of an iPhone Duo (`iPhone19,4`). Stop the machine before changing its configuration.

```sh
vphone-cli vm config duo --display fold
vphone-cli vm config duo --display outer
vphone-cli vm config duo --display inner
```

The choice takes effect on the next launch. Run `vm info duo` to check the saved choice. Other iPhone models reject `--display`.

| Choice | Display | Required guest patches |
| --- | --- | --- |
| `fold` | Fold between the cover and inner displays | Enable the fold display patch. |
| `outer` | Static cover display, 1398×2034 at 460 ppi | Disable the fold display patch. |
| `inner` | Static inner display, 2007×2853 at 460 ppi | Disable the fold display patch and enable the optional inner cutout patch on iOS 27.1. |

The default is `fold`. In that mode, the VM starts on the cover panel and the guest switches displays through `display.posture`.

`vm config --display` changes the saved display configuration. Run `vphone-cli fw patches duo` to check the guest patches, keep existing overrides when changing the selection, and follow the [guest patch update procedure](../../../Research/Firmware/post_creation_patch_changes.md) while the VM is off. The optional patch `system-springboard-exp-inner_cutout` is disabled in `standard` and SystemHook skips it while the fold display library is installed.

See the [Duo verification record](../../../Research/Integration/duo_m5_20261030/README.md) for the configurations and builds tested.
