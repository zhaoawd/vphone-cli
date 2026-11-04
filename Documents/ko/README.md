# 가상 머신 설명서

[English](../en/README.md) · [中文](../zh/README.md) · [日本語](../ja/README.md) · 한국어

## 머신

| 페이지 | 내용 |
| --- | --- |
| [가상 머신 생성 및 실행](machines/create-and-run.md) | 터미널에서 가상 머신 만들기, 시작, 중지 |
| [부트 ROM](machines/boot-roms.md) | OpenAVB/OpenSEP와 Apple ROM 사이의 전환 |
| [자동화 API](machines/automation-api.md) | 선택적으로 사용하는 로컬 HTTP 및 WebSocket 인터페이스 |
| [기기 이름과 시계](machines/device-name-and-clock.md) | 게스트가 가상 머신 이름과 Mac의 시계에서 가져오는 것 |
| [iPhone Duo 디스플레이](machines/iphone-duo.md) | 접이식 모드 또는 고정 디스플레이 설정 |

## 저장소와 백업

| 페이지 | 내용 |
| --- | --- |
| [보관함과 백업](storage/library-and-backups.md) | 가상 머신과 캐시의 위치, 복제와 내보내기 |
| [스냅샷](storage/snapshots.md) | 중지된 가상 머신의 디스크를 저장하고 되돌리기 |
| [템플릿](storage/templates.md) | 한 번의 복원으로 여러 가상 머신 만들기 |
| [템플릿 만들기](storage/template-building.md) | 가상 머신을 템플릿으로 만들고 템플릿 찾기 |
| [디스크 공간 공유](storage/sharing-disk-space.md) | 따로 복원한 가상 머신을 위한 `vm rebase` |
| [여러 머신 만들기](storage/many-machines.md) | plist로 `vm create-bulk` 실행 |
