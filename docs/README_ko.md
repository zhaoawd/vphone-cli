<div align="right"><strong>🇰🇷한국어</strong> | <strong><a href="./README_ja.md">🇯🇵日本語</a></strong> | <strong><a href="./README_zh.md">🇨🇳中文</a></strong> | <strong><a href="../README.md">🇬🇧English</a></strong></div>

# vphone-cli

PCC 리서치 VM 인프라를 사용하여 Apple의 Virtualization.framework로 가상 iPhone을 부팅합니다.

![poc](./demo.jpeg)

## 사전 요구 사항

**호스트:**

- Apple Silicon
- macOS 15+ (Sequoia)
- Xcode + iOS SDK (게스트 데몬 크로스 컴파일용)
- [서명되지 않은 바이너리로 private PV=3 권한을 허용하기 위한 SIP/AMFI 완화](#sipamfi-완화)

**의존성:**

```bash
brew install python@3.13 aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone cmake libusb ipsw zstd
```

## 설치

```bash
brew install zqxwce/tap/vphone-cli
```

## 빌드

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git

./scripts/setup_tools.sh      # 의존성 설치, 툴체인 서브모듈 빌드, Python venv 생성
./scripts/build.sh            # vphone-cli 빌드 및 서명, .app 번들 생성, vphoned 크로스 컴파일

cd .build/vphone-cli.app/Contents/MacOS/
vphone-cli --help
```

## 빠른 시작

하나의 명령으로 VM을 처음부터 끝까지 생성합니다 (다운로드 → 패치 → DFU 복원 → CFW 설치 → 첫 부팅):

```bash
vphone-cli vm create myphone -V jb        # -V / --variant

vphone-cli vm launch myphone
```

## 명령어

`vphone-cli vm create`는 전체 파이프라인을 실행합니다; 아래 개별 단계들을 사용하면 수동으로 진행하거나 한 단계만 다시 실행할 수 있습니다.

### 관리

```bash
vphone-cli vm list                         # VM 목록 표시 (스크립팅용 --json)
vphone-cli vm info myphone                  # VM 하나 표시
vphone-cli vm new myphone                   # 빈 번들 생성 (cpu/mem/disk 옵션)
vphone-cli vm config myphone --cpu 8 --memory 8192
vphone-cli vm clone myphone myphone-2       # 빠른 APFS 복제, 새로운 기기 식별자
vphone-cli vm export myphone --out myphone.tzst   # zstd fast by default (--max = xz -9); --out 이 디렉토리면 <vm>.tzst/.txz 자동 명명; restore 디렉토리 + 스테이징 파일 건너뜀
vphone-cli vm import myphone.tzst --name restored
vphone-cli vm rename myphone iphone16
vphone-cli vm delete iphone16
```

### VM 수동 빌드 (`vm create`가 자동화하는 작업)

```bash
vphone-cli vm new myphone                              # 1. 빈 번들
vphone-cli fw prepare myphone --iphone-version 26.1     # 2. IPSW 다운로드 + 병합
vphone-cli fw patch myphone --variant jb                # 3. 부트 체인 패치

vphone-cli vm launch myphone --dfu &                    # 4. DFU로 부팅 (백그라운드)
vphone-cli restore myphone --get-shsh                   #    SHSH 가져오기
vphone-cli restore myphone                              #    DFU 복원
vphone-cli vm stop myphone                              #    DFU 부팅 중지

vphone-cli cfw install myphone --variant jb             # 5. CFW 설치 (호스트 마운트; sudo 요청)
vphone-cli vm launch myphone                            # 6. 첫 부팅
```

최신 iOS로 업데이트하려면 `fw prepare`를 IPSW로 지정하세요: `--iphone-source /path/to.ipsw --cloudos-source /path/to.ipsw`.

## 복구

- `vphone-cli doctor [<name>]` — 호스트에 대한 읽기 전용 진단이며, VM 이름을 지정하면 해당 VM도 진단합니다(파일, 잠금, 펌웨어 트랜잭션, 복원 상태, 생성 체크포인트, 호스트 제어 채널). 아무것도 복구하지 않습니다; `--json`은 기계 판독 가능한 출력을 냅니다.
- `vphone-cli vm stop <name> --force` — 정상 종료 요청을 건너뛰고 부팅 프로세스를 즉시 SIGKILL합니다.
- `vphone-cli fw patch <name> --recover` — 패치 없이 중단된 펌웨어 트랜잭션을 복구합니다(복구된 아카이브를 보고하거나 대기 중인 트랜잭션이 없음을 알립니다).
- `vphone-cli vm create --resume <name>` — 중단된 `vm create`를 체크포인트에서 이어갑니다; `vphone-cli vm create-status <name>`는 아무것도 변경하지 않고 체크포인트를 출력합니다.

오프라인 bundle 작업(`fw prepare`/`fw patch`, `cfw install`, `vm export`/`vm import`, `vm clone`/`vm rename`/`vm delete`)은 VM별 디렉터리 잠금을 획득하며, 사용 중인 VM(실행 중인 VM 또는 다른 오프라인 작업이 bundle을 보유 중인 경우)에 대해서는 실행을 거부합니다. 이 보호에는 별도의 명령이 없습니다.

## 펌웨어 변형

보안 우회 수준이 점점 강해지는 5가지 패치 변형이 있습니다 — 하나를 `--variant`에 전달하세요:

| 변형         | 부트 체인   | CFW       | 참고                                                            |
| ------------ | ----------- | --------- | --------------------------------------------------------------- |
| `less`       | 4 patches   | 2 phases  | Patchless — iOS 완화 기능을 활성 상태로 유지                    |
| `regular`    | 42 patches  | 10 phases | AMFI/SSV/Img4/TXM 우회                                          |
| `dev`        | 53 patches  | 12 phases | + TXM 권한/디버그 우회                                          |
| `jb`         | 113 patches | 14 phases | + 전체 탈옥 (Sileo, TrollStore가 첫 부팅 시 자동 설치)          |
| `exp`        | 141 patches | 18 phases | JB 상위 집합 + VM 탐지 방지 연구 패치                           |

컴포넌트별 상세 분류는 [`research/0_binary_patch_comparison.md`](../research/0_binary_patch_comparison.md)를 참조하세요.

위 표의 수치에는 적용되는 펌웨어 조합이나 날짜가 표기되어 있지 않으며, 집계 방법이 다르면 수치도 달라집니다. 예를 들어 `research/0_binary_patch_comparison.md`의 Summary 표는 부트 체인 합계를 46/58/117/132(regular/dev/jb/exp), CFW를 포함한 총계를 56/70/132/163으로 보고합니다 — 이는 이 표의 변형별 수치와는 다른 집계 방법이며, 두 세트는 동일한 측정이 아니고 혼용할 수 없습니다. 날짜가 표기된 증거를 기준으로 삼으세요: [`research/0_binary_patch_comparison.md`](../research/0_binary_patch_comparison.md)와 [`research/firmware_compatibility.md`](../research/firmware_compatibility.md)를 참조하세요.

## 실행 및 연결

- **SSH (탈옥):** `ssh -p 22222 mobile@<vm-ip>` (비밀번호 `alpine`)
- **SSH (regular/dev):** `ssh -p 22222 root@<vm-ip>`
- **VNC:** `vnc://<vm-ip>:5901`

## 위치

vphone-cli가 생성하는 모든 것은 `~/.vphone/` 아래에 있습니다 — 서명된 번들이 이식 가능하도록 저장소와 `.app` 외부에 보관됩니다. `$VPHONE_ROOT`로 전체 트리를 리디렉션할 수 있습니다:

| 경로              | 내용                                                                                       |
| ----------------- | ------------------------------------------------------------------------------------------ |
| `~/.vphone/`      | 사용자별 데이터 루트 — `$VPHONE_ROOT`로 전체 위치를 재정의합니다.                            |
| `~/.vphone/VMs/`  | VM 번들 — VM마다 하나의 디렉터리. 라이브러리이며, `$VPHONE_LIBRARY_ROOT`로 재정의할 수 있습니다. |
| `~/.vphone/ipsws/`| 다운로드된 iPhone + cloudOS IPSW, 캐시되어 여러 VM에서 재사용됩니다.                          |
| `~/.vphone/tools/`| `fw prepare` 중에 가져온 APFS seal-volume 아티팩트(`apfs_sealvolume_<version>`) 캐시.         |
| `~/.vphone/debs/` | `jb`/`exp` CFW 설치가 게스트에 넣는 `.deb` 패키지 캐시 (Sileo, apt 등).                       |
| `~/.vphone/venv/` | 자동으로 프로비저닝되는 Python 환경 (`$VPHONE_VENV_DIR`로 재정의). |

우선순위: 항목별 재정의(`$VPHONE_LIBRARY_ROOT`, `$VPHONE_VENV_DIR`)가 `$VPHONE_ROOT`보다 우선하고, `$VPHONE_ROOT`는 `~/.vphone` 기본값보다 우선합니다. `ipsws/`, `tools/`, `debs/` 캐시는 항상 현재 활성 루트 바로 아래에 위치합니다.

## SIP/AMFI 완화

**방법 A — SIP를 완전히 비활성화한 후, boot-arg로 AMFI를 비활성화 (가장 관대).**

복구 모드에서 (전원 버튼 길게 누르기 → 터미널):

```bash
csrutil disable
csrutil allow-research-guests enable
```

그런 다음 macOS로 재부팅하고 AMFI boot-arg를 설정합니다 (적용되려면 SIP가 완전히 꺼져 있어야 합니다):

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"   # 이후 재부팅
```

**방법 B — SIP 유지 (디버그만 완화), 그런 다음 amfidont로 바이너리를 허용 목록에 추가** (AMFI는 시스템 전체에서 활성 상태 유지).

복구 모드에서:

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

그런 다음 macOS로 재부팅하고:

```bash
vphone-amfidont         # 로컬 빌드의 경우 .build/vphone-cli.app/Contents/Resources/vphone-amfidont
```

## 테스트 환경

| 호스트          | iPhone                | CloudOS         |
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

## 지원 범위

다음은 각 증거 날짜 기준의 실측 범위이며, 모든 버전 조합에 대한 일반적인 지원 보장이 아닙니다. 기기는 모두 `iPhone17,3`입니다.

**펌웨어 호환성 레지스트리 (2026-09-09 기준, 출처 `research/firmware_compatibility.json`)**
레지스트리에는 23개의 catalog 버전 페어링(정확한 빌드 번호 포함, 18.6.2부터 27.0 beta까지)과 4개의 cloudOS 이미지(26.1 = `23B85`, 26.2 = 빌드 번호 미기록, 26.3 = `23D128`, 26.4 = `23E5207q`)가 등록되어 있습니다. 다섯 가지 변형(less/regular/dev/jb/exp)은 23개 페어링 전체에서 code_selectable입니다(파이프라인에 선택 투입 가능; 패치나 부팅 검증은 수행하지 않음). 패치 바이트 검증(patch_verified)은 less 1, regular 7, dev 7, jb 10, exp 7 조합을 포함합니다. 실기기 능력 검증(capability_verified): jb 3개 조합(27.0 계열 `24A5380h`/`24A5390f`/`24A5408d`, 그중 `24A5408d`는 `--frida`), exp 1개 조합(26.6.1/`23G83` rig-baseline). regular/dev 변형은 아직 완전한 실기기 부팅 증거가 없습니다.

**엔드투엔드 증거 매트릭스 (2026-09-17 기준, 출처 `research/f1_support_matrix_2026-09-17.md`)**
이번 회차에서는 단계별(S1 생성부터 S12 EXP 전용까지)로 두 조합을 검증했습니다:

- P: 26.1/`23B85` + cloudOS 26.1/`23B85`, 다섯 가지 변형.
- N: 26.6.1/`23G82`(비 catalog 빌드, 로컬 경로로 지정) + cloudOS 26.4/`23E5207q`, jb와 exp(`--frida`).

생성 단계 패치 레코드 수: regular 58, dev 70, jb 152, exp 178, less 26(P 그룹); jb-frida 157, exp-frida 183(N 그룹). 알려진 제한 L1–L3과 미해결 문제 O1–O3은 통과로 계산하지 않고 별도로 추적합니다(`research/f1_known_limits_2026-09-17.json` 참조). L 조합(18.6.2/`22G100`)은 이번 회차에서 제외되었고, IPSW를 다운로드하지 않았으며 모든 단계를 미실행으로 기록합니다.

각 집계 방법의 패치 수(부트 체인/총계/과거 메서드 수)는 방법에 따라 수치가 다릅니다; 방법 설명은 `research/0_binary_patch_comparison.md`와 `research/firmware_compatibility.md` 5절을 참조하세요.

## FAQ

**`zsh: killed ./vphone-cli`** — AMFI/디버그 제한이 우회되지 않았습니다; [사전 요구 사항](#사전-요구-사항)을 참조하세요 (`amfi_get_out_of_my_way=1` 또는 `amfidont`).

**`Virtualization is not available on this hardware`** — Mac 자체가 VM입니다; PV=3 게스트 부팅은 중첩할 수 없습니다. 중첩되지 않은 macOS 15+ 호스트를 사용하세요.

**"Press home to continue"에서 멈춤** — VNC로 접속하여 우클릭(두 손가락 클릭)으로 홈 버튼을 시뮬레이션하세요.

**시스템 앱이 설치되지 않음** — iOS 초기 설정 시 지역으로 일본이나 EU를 선택하지 마세요 (VM이 충족할 수 없는 추가 규제 검사가 있습니다); 예를 들어 United States를 선택하세요.

**앱이 실행 시 `EXC_GUARD` / `GUARD_TYPE_MACH_PORT`로 충돌** — `vphone-cli fw patch <name> --variant <v> --force-exc-guard`로 다시 패치한 다음, 다시 복원/설치하세요 ([#291](https://github.com/Lakr233/vphone-cli/issues/291)). iOS 18 베이스에서는 항상 켜져 있습니다.

**`.ipa`/`.tipa` 설치** — 실행 중인 VM의 Install 메뉴를 사용하세요 (드래그 앤 드롭 또는 파일 선택기).

**`cfw install`이 시스템 바이너리(예: `Campo`) 재서명 중 멈추고 메모리가 무한정 증가함** — `2.1.5-procursus7`(현재 Homebrew `stable`)까지의 `ldid-procursus` 알려진 버그: `bytes(uint64_t)`가 제로 가드 없이 `__builtin_clzll(0)`을 호출하며, 이는 정의되지 않은 동작이고, 이 빌드에서는 `0` 길이로 해석되어 부호 없는 루프 카운터가 언더플로합니다 — `ldid`가 종료하지 않고 커지는 버퍼에 한 번에 1바이트씩 계속 씁니다. 정수 값이 정확히 `0`인 값을 포함하는 *모든* entitlements plist에서 발생합니다(일부 실제 Apple 시스템 바이너리가 이를 가지고 있습니다). 업스트림에서는 수정되었으나 아직 tagged release에 포함되지 않았습니다; 소스에서 다시 빌드하세요: `brew install --HEAD ldid-procursus && brew link --overwrite ldid-procursus`. 이미 발생했다면 먼저 멈춘 `ldid` 프로세스를 종료하세요(`sudo kill -9 <pid>`).

## 자동화

`vphone-cli`는 프로그래밍 방식 제어를 위한 호스트 제어 소켓(`<bundle>/vphone.sock`)을 노출합니다 — 스크린샷, 터치, 스와이프, 하드웨어 키, 클립보드 — 각 동작은 AI 주도 E2E 테스트를 위해 인라인 스크린샷을 반환합니다. 이를 감싸는 MCP 서버는 [vphone-mcp](https://github.com/pluginslab/vphone-mcp)를 참조하세요.

`--headless`(VM 창 없음)로 VM을 시작하면 능력 스냅샷이 `screen_available=false`를 보고하며, 화면에 의존하는 명령 — 스크린샷, 터치, 스와이프 — 은 사용할 수 없습니다; 하드웨어 키와 클립보드는 계속 사용할 수 있습니다.

## 감사의 말

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
