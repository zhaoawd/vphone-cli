# 仮想マシンマニュアル

[English](../en/README.md) · [中文](../zh/README.md) · 日本語 · [한국어](../ko/README.md)

## マシン

| ページ | 内容 |
| --- | --- |
| [作成と実行](machines/create-and-run.md) | ターミナルでの仮想マシンの作成、起動、停止 |
| [ブート ROM](machines/boot-roms.md) | OpenAVB/OpenSEP と Apple の ROM の切り替え |
| [自動化 API](machines/automation-api.md) | 任意で有効にできるローカルの HTTP と WebSocket インターフェース |
| [デバイス名と時計](machines/device-name-and-clock.md) | ゲストが仮想マシン名と Mac の時計から受け取るもの |
| [iPhone Duo のディスプレイ](machines/iphone-duo.md) | 折りたたみモードまたは固定ディスプレイを設定する |

## ストレージとバックアップ

| ページ | 内容 |
| --- | --- |
| [ライブラリとバックアップ](storage/library-and-backups.md) | 仮想マシンとキャッシュの保存場所、複製と書き出し |
| [スナップショット](storage/snapshots.md) | 停止中の仮想マシンのディスクを保存し、その状態に戻す |
| [テンプレート](storage/templates.md) | 1 回の復元を複数の仮想マシンで再利用する |
| [テンプレートの作成](storage/template-building.md) | 仮想マシンをテンプレートにする方法とテンプレートの検索 |
| [ディスク容量の共有](storage/sharing-disk-space.md) | 別々に復元した仮想マシンに使う `vm rebase` |
| [複数マシンの一括作成](storage/many-machines.md) | plist から実行する `vm create-bulk` |
