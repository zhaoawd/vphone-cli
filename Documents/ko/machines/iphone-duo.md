# iPhone Duo 디스플레이

iPhone Duo(`iPhone19,4`)의 디스플레이 모드를 설정합니다. 설정을 바꾸기 전에 가상 머신을 중지하세요.

```sh
vphone-cli vm config duo --display fold
vphone-cli vm config duo --display outer
vphone-cli vm config duo --display inner
```

다음에 시작할 때 적용됩니다. `vm info duo`로 저장된 설정을 확인하세요. 다른 iPhone 모델에서는 `--display`를 사용할 수 없습니다.

| 선택 | 디스플레이 | 필요한 게스트 패치 |
| --- | --- | --- |
| `fold` | 외부와 내부 디스플레이 전환 | 접이식 디스플레이 패치를 켭니다. |
| `outer` | 고정 외부 디스플레이, 1398×2034, 460 ppi | 접이식 디스플레이 패치를 끕니다. |
| `inner` | 고정 내부 디스플레이, 2007×2853, 460 ppi | 접이식 디스플레이 패치를 끄고 iOS 27.1에서 선택 사항인 내부 디스플레이 컷아웃 패치를 켭니다. |

기본 모드는 `fold`입니다. 외부 디스플레이에서 부팅한 뒤 게스트가 `display.posture`로 디스플레이를 전환합니다.

`vm config --display`는 저장된 디스플레이 설정을 변경합니다. `vphone-cli fw patches duo`로 게스트 패치를 확인하고, 패치 선택을 변경할 때 기존 재정의 설정을 유지하세요. 가상 머신을 끈 상태에서 [게스트 패치 업데이트 절차](../../../Research/Firmware/post_creation_patch_changes.md)를 따르세요. 선택 사항인 `system-springboard-exp-inner_cutout` 패치는 `standard`에서 꺼져 있습니다. 접이식 디스플레이 라이브러리가 설치되어 있으면 SystemHook이 이 패치를 로드하지 않습니다.

검증한 구성과 빌드는 [Duo 검증 기록](../../../Research/Integration/duo_m5_20261030/README.md)을 참고하세요.
