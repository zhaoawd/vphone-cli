# vphone-cli 上游增量审阅包

核对日期：2026-10-14。

基线（不包含）：`2d21d21fbdd4f51f013616273ceda9b35a3e0789`  
目标（包含）：`8a75092013eda87a4e30ed029b72028cb9279ac4`，本轮读取到的 main HEAD / 2.9.4。

## 文件与使用顺序

| 文件 | 用途 |
|---|---|
| `report.md` | 完整功能增量、风险、原 47 项任务映射、整合批次、验收矩阵和 194 条提交附录 |
| `plan_delta.md` | 建议追加的 T47–T60 执行卡片；保留旧任务编号与历史状态 |
| `commits.csv` | 194 行提交台账，UTF-8 BOM；每条含分类、中文概要、来源及关联任务 |
| `commits.json` | 同一台账的结构化版本，并明确统计来源和未执行项 |
| `plan_delta.json` | 14 个建议任务的结构化定义、依赖、验收与恢复单位 |
| `audit_upstream.py` | 在已有完整 Git 对象的仓库上导出完整差异、提交元数据及 merge 审阅资料 |
| `audit_self_test.json` | 审计程序的临时 Git 样本测试结果，不是 vphone-cli 或 VM 测试结果 |
| `sha256sums.txt` | 包内文件 SHA-256 校验值（不包含校验文件自身） |

## 证据边界

公开 GitHub 历史逐页枚举 194 条新增记录，其中 51 条为 merge 记录、143 条为其他记录；发布页计数做了交叉核对。台账按公开列表从新到旧排列，不是 cherry-pick 执行顺序。

本轮读取了关键 PR、提交、固定目标文档和两端 daemon 依赖锁，但没有取得可执行完整 Git 审计的上游对象，也没有读取用户实时 fork。因此本包不包含未经证实的全范围文件数、增删行数、完整 Git patch，亦不表示每个 merge 的冲突解决已被审查。本地功能覆盖、代码合并、构建、macOS/VM 验收均未执行。

源仓库在后续继续前移时，应另建新范围，不把新提交混入这一冻结范围。旧 47 项的完成事实和未完成项均不由本附录重新判定。

## 补齐 Git 审计

程序要求 Python 3.9+、Git、非 shallow 仓库，且两个固定提交及完整祖先对象已存在。它不 fetch、不 checkout、不修改分支、不 merge、不操作 VM；审计输出必须放在输入仓库外的全新目录。它是开发审计工具，不是产品运行时依赖。

```bash
python3 audit_upstream.py \
  --repo /path/to/vphone-cli \
  --out /tmp/vphone-audit-20261014-8a75092
```

程序会输出 `audit.json`、端点完整 binary/full-index patch、变更文件与 numstat、逐提交完整 SHA/父关系/作者与提交日期/文件表、每个 merge 相对各父提交的 diff，以及可用时的 remerge-diff。它会将附带台账逐条解析为 Git 对象，检查范围是否一致。

只有 `audit.json` 为 completed 才表示程序完成；`observed_ledger_reconciliation.json` 的 `exact_set_match` 才表示 194 条枚举与实际 Git 范围一致。如果字段为 false 或不存在，先检查未解析对象、遗漏或越界，不强行保留旧数字。空 remerge-diff 不等于已证明 merge 没有独立解决内容，仍需人工审查。

附带自测使用临时仓库验证了合并父关系、重命名、Unicode/空格文件名、二进制 patch、台账集合对账和拒绝危险输出路径等行为；没有在真实上游或用户仓库运行。
