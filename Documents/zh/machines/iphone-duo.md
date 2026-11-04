# iPhone Duo 显示屏

为 iPhone Duo（`iPhone19,4`）设置显示模式。修改配置前先停止虚拟机。

```sh
vphone-cli vm config duo --display fold
vphone-cli vm config duo --display outer
vphone-cli vm config duo --display inner
```

设置在下次启动时生效。运行 `vm info duo` 查看已保存的选项。其他 iPhone 机型不支持 `--display`。

| 选项 | 显示屏 | 所需的客户机补丁 |
| --- | --- | --- |
| `fold` | 在外屏和内屏之间折叠切换 | 启用折叠显示补丁。 |
| `outer` | 静态外屏，1398×2034，460 ppi | 禁用折叠显示补丁。 |
| `inner` | 静态内屏，2007×2853，460 ppi | 禁用折叠显示补丁，并在 iOS 27.1 上启用可选的内屏挖孔补丁。 |

默认模式为 `fold`。虚拟机以外屏启动，客户机通过 `display.posture` 切换显示屏。

`vm config --display` 修改已保存的显示配置。运行 `vphone-cli fw patches duo` 检查客户机补丁，变更选择时保留其他覆盖项，并在虚拟机关闭时按[客户机补丁更新流程](../../../Research/Firmware/post_creation_patch_changes.md)应用。可选补丁 `system-springboard-exp-inner_cutout` 在 `standard` 中默认关闭。安装折叠显示库时，SystemHook 不加载该补丁。

已验证的配置和构建版本见 [Duo 验证记录](../../../Research/Integration/duo_m5_20261030/README.md)。
