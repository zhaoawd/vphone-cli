# iPhone Duo のディスプレイ

iPhone Duo（`iPhone19,4`）の表示モードを設定します。設定を変更する前に仮想マシンを停止してください。

```sh
vphone-cli vm config duo --display fold
vphone-cli vm config duo --display outer
vphone-cli vm config duo --display inner
```

次回の起動から適用されます。`vm info duo` で保存済みの設定を確認できます。他の iPhone モデルでは `--display` は使えません。

| 選択肢 | ディスプレイ | 必要なゲストパッチ |
| --- | --- | --- |
| `fold` | 外側と内側のディスプレイを切り替える | 折りたたみ表示パッチを有効にします。 |
| `outer` | 固定の外側ディスプレイ、1398×2034、460 ppi | 折りたたみ表示パッチを無効にします。 |
| `inner` | 固定の内側ディスプレイ、2007×2853、460 ppi | 折りたたみ表示パッチを無効にし、iOS 27.1 でオプションの内側ディスプレイのカットアウトパッチを有効にします。 |

既定は `fold` です。このモードでは外側ディスプレイで起動し、ゲストが `display.posture` で切り替えます。

`vm config --display` は保存済みの表示設定を変更します。`vphone-cli fw patches duo` でゲストパッチを確認し、選択を変更するときは既存の上書き指定を保持してください。仮想マシンを停止した状態で[ゲストパッチの更新手順](../../../Research/Firmware/post_creation_patch_changes.md)に従います。オプションの `system-springboard-exp-inner_cutout` は `standard` では無効です。折りたたみ表示ライブラリがインストールされている間、SystemHook はこのパッチを読み込みません。

検証済みの構成とビルドは [Duo の検証記録](../../../Research/Integration/duo_m5_20261030/README.md)をご覧ください。
