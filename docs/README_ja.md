<div align="right"><strong><a href="./README_ko.md">🇰🇷한국어</a></strong> | <strong>🇯🇵日本語</strong> | <strong><a href="./README_zh.md">🇨🇳中文</a></strong> | <strong><a href="../README.md">🇬🇧English</a></strong></div>

# vphone-cli

PCC リサーチ VM インフラストラクチャを使用し、Apple の Virtualization.framework 経由で仮想 iPhone を起動します。

![poc](./demo.jpeg)

## 前提条件

**ホスト:**

- Apple Silicon
- macOS 15+ (Sequoia)
- Xcode + iOS SDK（ゲストデーモンをクロスコンパイルするため）
- [未署名バイナリでプライベートな PV=3 エンタイトルメントを許可するための SIP/AMFI の緩和](#sipamfi-の緩和)

**依存関係:**

```bash
brew install python@3.13 aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone cmake libusb ipsw zstd
```

## インストール

```bash
brew install zqxwce/tap/vphone-cli
```

## ビルド

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git

./scripts/setup_tools.sh      # 依存関係のインストール、ツールチェーンのサブモジュールのビルド、Python venv の作成
./scripts/build.sh            # vphone-cli のビルド + 署名、.app のバンドル、vphoned のクロスコンパイル

cd .build/vphone-cli.app/Contents/MacOS/
vphone-cli --help
```

## クイックスタート

1 つのコマンドで VM をエンドツーエンドで作成します（ダウンロード → パッチ → DFU 復元 → CFW インストール → 初回起動）:

```bash
vphone-cli vm create myphone -V jb        # -V / --variant

vphone-cli vm launch myphone
```

## コマンド

`vphone-cli vm create` はパイプライン全体を実行します。以下の個別ステップを使うと、手動で操作したり 1 つの段階を再実行したりできます。

### 管理

```bash
vphone-cli vm list                         # VM の一覧表示（スクリプト用に --json）
vphone-cli vm info myphone                  # 1 つの VM を表示
vphone-cli vm new myphone                   # 空のバンドルを作成（cpu/mem/disk オプション）
vphone-cli vm config myphone --cpu 8 --memory 8192
vphone-cli vm clone myphone myphone-2       # 高速 APFS クローン、新しいデバイスアイデンティティ
vphone-cli vm export myphone --out myphone.tzst   # zstd fast by default (--max = xz -9); --out がディレクトリなら <vm>.tzst/.txz を自動命名; 復元ディレクトリ + ステージングファイルをスキップ
vphone-cli vm import myphone.tzst --name restored
vphone-cli vm rename myphone iphone16
vphone-cli vm delete iphone16
```

### VM を手動でビルドする（`vm create` が自動化する処理）

```bash
vphone-cli vm new myphone                              # 1. 空のバンドル
vphone-cli fw prepare myphone --iphone-version 26.1     # 2. IPSW のダウンロード + マージ
vphone-cli fw patch myphone --variant jb                # 3. ブートチェーンにパッチ適用

vphone-cli vm launch myphone --dfu &                    # 4. DFU で起動（バックグラウンド）
vphone-cli restore myphone --get-shsh                   #    SHSH を取得
vphone-cli restore myphone                              #    DFU 復元
vphone-cli vm stop myphone                              #    DFU 起動を停止

vphone-cli cfw install myphone --variant jb             # 5. CFW をインストール（ホストマウント; sudo を要求）
vphone-cli vm launch myphone                            # 6. 初回起動
```

新しい iOS に更新するには、`fw prepare` を IPSW に向けます: `--iphone-source /path/to.ipsw --cloudos-source /path/to.ipsw`。

## リカバリー

- `vphone-cli doctor [<name>]` — ホストの読み取り専用診断。VM 名を指定するとその VM も診断します（ファイル、ロック、ファームウェアトランザクション、復元状態、作成チェックポイント、ホスト制御チャネル）。何も修復しません。`--json` で機械可読な出力を出します。
- `vphone-cli vm stop <name> --force` — 優雅なシャットダウン要求をスキップし、ブートプロセスを直ちに SIGKILL します。
- `vphone-cli fw patch <name> --recover` — パッチを当てずに、中断されたファームウェアトランザクションを復旧します（復旧されたアーカイブ、または保留中のトランザクションがない旨を報告します）。
- `vphone-cli vm create --resume <name>` — 中断された `vm create` をチェックポイントから継続します。`vphone-cli vm create-status <name>` は何も変更せずにチェックポイントを表示します。

オフラインの bundle 操作（`fw prepare`/`fw patch`、`cfw install`、`vm export`/`vm import`、`vm clone`/`vm rename`/`vm delete`）は VM ごとのディレクトリロックを取得し、使用中の VM（実行中の VM、または別のオフライン操作が bundle を保持している場合）に対しては実行を拒否します。このガードに専用のコマンドはありません。

## ファームウェアバリアント

セキュリティバイパスの度合いが段階的に増す 5 つのパッチバリアント — いずれか 1 つを `--variant` に渡します:

| バリアント   | ブートチェーン | CFW       | 備考                                                              |
| ------------ | ----------- | --------- | ----------------------------------------------------------------- |
| `less`       | 4 patches   | 2 phases  | パッチなし — iOS の緩和策を有効なまま維持                          |
| `regular`    | 42 patches  | 10 phases | AMFI/SSV/Img4/TXM バイパス                                        |
| `dev`        | 53 patches  | 12 phases | + TXM エンタイトルメント/デバッグバイパス                          |
| `jb`         | 113 patches | 14 phases | + 完全な脱獄（Sileo、TrollStore を初回起動時に自動インストール）   |
| `exp`        | 141 patches | 18 phases | JB のスーパーセット + VM 検出対策リサーチパッチ                    |

コンポーネントごとの内訳については [`research/0_binary_patch_comparison.md`](../research/0_binary_patch_comparison.md) を参照してください。

上の表の数は、適用されるファームウェアの組み合わせや日付が注記されておらず、集計方法が異なれば数値も異なります。例えば `research/0_binary_patch_comparison.md` の Summary 表は、ブートチェーンの合計を 46/58/117/132（regular/dev/jb/exp）、CFW を含めた総計を 56/70/132/163 と報告しています — これはこの表のバリアント別の数とは異なる集計方法であり、2 つのセットは同一の計測ではなく、混用できません。日付付きの証拠を正とみなしてください: [`research/0_binary_patch_comparison.md`](../research/0_binary_patch_comparison.md) と [`research/firmware_compatibility.md`](../research/firmware_compatibility.md) を参照してください。

## 実行と接続

- **SSH（脱獄）:** `ssh -p 22222 mobile@<vm-ip>`（パスワード `alpine`）
- **SSH（regular/dev）:** `ssh -p 22222 root@<vm-ip>`
- **VNC:** `vnc://<vm-ip>:5901`

## 場所

vphone-cli が生成するものはすべて `~/.vphone/` 以下に置かれます — 署名済みバンドルがポータブルであり続けるよう、リポジトリと `.app` の外に保管されます。`$VPHONE_ROOT` でツリー全体をリダイレクトできます:

| パス              | 内容                                                                                       |
| ----------------- | ------------------------------------------------------------------------------------------ |
| `~/.vphone/`      | ユーザー別データルート — `$VPHONE_ROOT` で場所全体を上書きします。                           |
| `~/.vphone/VMs/`  | VM バンドル — VM ごとに 1 ディレクトリ。これがライブラリです。`$VPHONE_LIBRARY_ROOT` で上書きできます。 |
| `~/.vphone/ipsws/`| ダウンロードされた iPhone + cloudOS の IPSW。キャッシュされ、複数の VM で再利用されます。       |
| `~/.vphone/tools/`| `fw prepare` 中に取得された APFS seal-volume アーティファクト（`apfs_sealvolume_<version>`）のキャッシュ。 |
| `~/.vphone/debs/` | `jb`/`exp` の CFW インストールがゲストに配置する `.deb` パッケージのキャッシュ（Sileo、apt など）。 |
| `~/.vphone/venv/` | 自動的にプロビジョニングされる Python 環境（`$VPHONE_VENV_DIR` で上書き可能）。 |

優先順位: 項目ごとの上書き（`$VPHONE_LIBRARY_ROOT`、`$VPHONE_VENV_DIR`）が `$VPHONE_ROOT` より優先され、`$VPHONE_ROOT` は `~/.vphone` のデフォルトより優先されます。`ipsws/`、`tools/`、`debs/` キャッシュは、常に現在有効なルートの直下に置かれます。

## SIP/AMFI の緩和

**オプション A — SIP を完全に無効化し、boot-arg で AMFI を無効化する（最も緩い）。**

リカバリーモードで（電源ボタン長押し → ターミナル）:

```bash
csrutil disable
csrutil allow-research-guests enable
```

その後 macOS で再起動し、AMFI の boot-arg を設定します（有効化には SIP を完全に無効化する必要があります）:

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"   # 後で再起動
```

**オプション B — SIP を有効なまま（デバッグのみ緩和）にし、amfidont でバイナリを許可リストに追加する**（AMFI はシステム全体で有効なまま）。

リカバリーモードで:

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

その後 macOS で再起動し:

```bash
vphone-amfidont         # ローカルビルドの場合は .build/vphone-cli.app/Contents/Resources/vphone-amfidont
```

## 動作確認済み環境

| ホスト          | iPhone                | CloudOS         |
| --------------- | --------------------- | --------------- |
| Mac16,11 27.0b2 | `17,3_18.6.2_22G100`  | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0_23A341`    | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0.1_23A355`  | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.1_23B85`     | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.3-23D128`   |
| Mac16,12 26.3   | `17,3_26.3.1_23D8133` | `26.3-23D128`   |
| Mac16,11 26.2   | `17,3_26.4_23E246`    | `26.4-23E5207q` |
| Mac16,11 26.2   | `17,3_26.5_23F77`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.5.2_23F84`   | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_26.6_23G71`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.6.1_23G83`   | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A5408d`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5418b`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5424a`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5430a`  | `26.4-23E5207q` |

## サポート範囲

以下は各証拠日付時点での実測範囲であり、すべてのバージョンの組み合わせに対する一般的なサポート保証ではありません。デバイスはすべて `iPhone17,3` です。

**ファームウェア互換性レジストリ（2026-09-09 時点、出典 `research/firmware_compatibility.json`）**
レジストリには 23 件の catalog バージョンペア（正確なビルド番号付き、18.6.2 から 27.0 beta まで）と 4 つの cloudOS イメージ（26.1 = `23B85`、26.2 = ビルド番号未記録、26.3 = `23D128`、26.4 = `23E5207q`）が登録されています。5 つのバリアント（less/regular/dev/jb/exp）は全 23 ペアで code_selectable です（パイプラインに選択して投入可能。パッチや起動の検証は未実施）。パッチバイト検証（patch_verified）は less 1、regular 7、dev 7、jb 10、exp 7 の組み合わせをカバーします。実機能力検証（capability_verified）: jb 3 組み合わせ（27.0 系列 `24A5380h`/`24A5390f`/`24A5408d`、うち `24A5408d` は `--frida`）、exp 1 組み合わせ（26.6.1/`23G83` rig-baseline）。regular/dev バリアントには完全な実機起動の証拠はまだありません。

**エンドツーエンド証拠マトリクス（2026-09-17 時点、出典 `research/f1_support_matrix_2026-09-17.md`）**
今回はステップごと（S1 作成から S12 EXP 専用まで）に 2 つの組み合わせを検証しました:

- P: 26.1/`23B85` + cloudOS 26.1/`23B85`、5 つのバリアント。
- N: 26.6.1/`23G82`（非 catalog ビルド、ローカルパスで指定）+ cloudOS 26.4/`23E5207q`、jb と exp（`--frida`）。

作成段階のパッチレコード数: regular 58、dev 70、jb 152、exp 178、less 26（P グループ）；jb-frida 157、exp-frida 183（N グループ）。既知の制限 L1–L3 と未解決の問題 O1–O3 は合格として数えず、別途追跡します（`research/f1_known_limits_2026-09-17.json` を参照）。L の組み合わせ（18.6.2/`22G100`）は今回対象外で、IPSW をダウンロードせず、全ステップを未実行として記録しています。

各集計方法のパッチ数（ブートチェーン/総計/歴史的なメソッド数）は方法によって数値が異なります。方法の注記については `research/0_binary_patch_comparison.md` と `research/firmware_compatibility.md` の第 5 節を参照してください。

## FAQ

**`zsh: killed ./vphone-cli`** — AMFI/デバッグ制限がバイパスされていません。[前提条件](#前提条件) を参照してください（`amfi_get_out_of_my_way=1` または `amfidont`）。

**`Virtualization is not available on this hardware`** — お使いの Mac 自体が VM です。PV=3 ゲスト起動はネストできません。ネストされていない macOS 15+ ホストを使用してください。

**「Press home to continue」で止まる** — VNC で接続し、右クリック（2 本指クリック）してホームボタンをシミュレートします。

**システムアプリがインストールできない** — iOS のセットアップ中に、地域として日本や EU を選ばないでください（VM が満たせない追加の規制チェックが入ります）。例えば United States を選択してください。

**アプリが起動時に `EXC_GUARD` / `GUARD_TYPE_MACH_PORT` でクラッシュする** — `vphone-cli fw patch <name> --variant <v> --force-exc-guard` で再パッチし、再度復元/インストールしてください（[#291](https://github.com/Lakr233/vphone-cli/issues/291)）。iOS 18 ベースでは常に有効です。

**`.ipa`/`.tipa` をインストールする** — 実行中の VM の Install メニューを使用します（ドラッグ&ドロップまたはファイルピッカー）。

**`cfw install` がシステムバイナリ（例: `Campo`）の再署名中に停止し、メモリが際限なく増加する** — `ldid-procursus` の `2.1.5-procursus7`（現在の Homebrew `stable`）までの既知の不具合: `bytes(uint64_t)` がゼロガードなしで `__builtin_clzll(0)` を呼び出し、これは未定義動作であり、このビルドでは `0` 長に解決され、符号なしループカウンタがアンダーフローします — `ldid` は終了せず、増大するバッファに 1 バイトずつ書き込み続けます。整数値がちょうど `0` の値を含む *あらゆる* entitlements plist で発生します（一部の実際の Apple システムバイナリがこれを持ちます）。上流では修正済みですが、まだ tagged release に入っていません。ソースから再ビルドしてください: `brew install --HEAD ldid-procursus && brew link --overwrite ldid-procursus`。すでに遭遇している場合は、まず停止した `ldid` プロセスを終了してください（`sudo kill -9 <pid>`）。

## 自動化

`vphone-cli` はプログラムによる制御のためにホスト制御ソケット（`<bundle>/vphone.sock`）を公開します — スクリーンショット、タッチ、スワイプ、ハードウェアキー、クリップボード — 各アクションは AI 駆動の E2E テスト用にインラインのスクリーンショットを返します。それをラップする MCP サーバーについては [vphone-mcp](https://github.com/pluginslab/vphone-mcp) を参照してください。

`--headless`（VM ウィンドウなし）で VM を起動した場合、能力スナップショットは `screen_available=false` を報告し、画面に依存するコマンド — スクリーンショット、タッチ、スワイプ — は使用できません。ハードウェアキーとクリップボードは引き続き使用できます。

## 謝辞

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
