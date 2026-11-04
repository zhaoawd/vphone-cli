# 虚拟机手册

[English](../en/README.md) · 中文 · [日本語](../ja/README.md) · [한국어](../ko/README.md)

## 虚拟机

| 页面 | 用途 |
| --- | --- |
| [创建与运行](machines/create-and-run.md) | 在终端中创建、启动和停止虚拟机 |
| [启动 ROM](machines/boot-roms.md) | 在 OpenAVB/OpenSEP 与 Apple 的 ROM 之间切换 |
| [自动化 API](machines/automation-api.md) | 可选的本机 HTTP 和 WebSocket 接口 |
| [设备名称与时钟](machines/device-name-and-clock.md) | 客户机从虚拟机名称和 Mac 时钟获取哪些信息 |
| [iPhone Duo 显示屏](machines/iphone-duo.md) | 配置折叠模式或静态显示屏 |

## 存储与备份

| 页面 | 用途 |
| --- | --- |
| [资料库与备份](storage/library-and-backups.md) | 虚拟机和缓存的存放位置、克隆与导出 |
| [快照](storage/snapshots.md) | 保存已停止虚拟机的磁盘，并还原到该状态 |
| [模板](storage/templates.md) | 一次恢复，供多台虚拟机复用 |
| [构建模板](storage/template-building.md) | 把虚拟机制作成模板，以及查找模板 |
| [共享磁盘空间](storage/sharing-disk-space.md) | 对分别恢复的虚拟机使用 `vm rebase` |
| [批量创建虚拟机](storage/many-machines.md) | 从 plist 运行 `vm create-bulk` |
