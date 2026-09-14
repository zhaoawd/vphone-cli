# 在 Codex 中阅读 Markdown

预览器已迁移为用户级工具。其他项目也可调用，不需要复制脚本或使用项目虚拟环境。

## 日常使用

直接告诉 Codex“预览这份 Markdown”或“生成报告后打开阅读预览”。用户级 `markdown-preview` 技能负责调用命令，取得地址，再在当前任务右侧浏览器面板打开。已有页面会自动刷新，不必重复打开。

新技能需要被当前 Codex 会话发现；如果现有会话尚未加载，可直接要求读取 `~/.codex/skills/markdown-preview/SKILL.md` 后执行。

命令行只需一步，自动启动或复用后台服务，并返回含 `url` 的 JSON：

```sh
md-preview /absolute/path/report.md
```

服务默认允许读取该文档所在目录中的非隐藏 Markdown。需要在同一项目内浏览跨目录的相对链接时，可显式指定项目根目录：

```sh
md-preview /absolute/project/research/report.md --root /absolute/project
```

本项目保留兼容入口：

```sh
make preview_docs DOC=research/project_status_2026-09-11.md
```

命令本身不操作 Codex 界面；Codex 调用浏览器工具打开返回的 URL。这两步由技能串联，无需用户复制地址。普通 `.md` 文件链接仍使用 Codex 文件面板，没有拦截或修改应用行为。

## 服务行为

- 所有项目复用同一个用户级后台进程，监听 `127.0.0.1` 的空闲端口。
- 首次预览按需启动，之后复用；不需要保持终端窗口，不配置开机自启。
- 页面每 1.5 秒检查文档摘要，内容变化后刷新并尝试恢复滚动位置。
- 服务停止后，下次命令自动重启。重启会产生新地址，旧页面需要重新打开。
- `md-preview --status` 查看状态；`md-preview --stop` 停止服务。
- 注册目录保存在用户状态目录中；服务仅提供注册范围内的 Markdown，排除 `TODO.md`、隐藏相对路径以及超过 8 MiB 的文件。符号链接解析后仍须位于注册目录内。

支持目录、表格、列表、代码块、删除线和明暗配色。Mermaid 保留代码块，图片和源码链接尚未提供。原始 HTML 不执行，运行时不上传文档、不使用外部 CDN。

## 安装位置

| 内容 | 位置 |
| --- | --- |
| 全局命令 | `~/.local/bin/md-preview` |
| 程序与独立 Python 环境 | `~/.local/share/codex-markdown-preview` |
| 状态、注册目录与服务日志 | `~/.local/state/codex-markdown-preview` |
| Codex 技能 | `~/.codex/skills/markdown-preview/SKILL.md` |

这是当前用户的本机安装，不会随仓库克隆自动安装到其他电脑。仓库内已移除旧预览脚本及其依赖文件，Makefile 入口仅调用全局命令。
