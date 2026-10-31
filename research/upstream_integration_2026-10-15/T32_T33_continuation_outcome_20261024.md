# T32/T33 续验结果（2026-10-24）

原生结果：`failed`。离线验收通过：`false`。

完整阶段事务：

```json
{
  "regular": {
    "on": "20261024T044848Z-v8ovSVP3",
    "off": "20261024T064924Z-hG5gtVTI",
    "reapplied": "20261024T081630Z-kbuBz8Io"
  },
  "exp": {}
}
```

独立收尾复核了源备份10项完整内容和身份、571项计划输入、94项执行输入、12项无关磁盘身份及目标无附件。root私有写前备份依据原生执行器最终完整读回报告；收尾程序没有重新读取该私有目录。

原生错误：`Command '['/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.a84f5889b159/VPhone.bundle/Contents/MacOS/vphone-cli', 'cfw', 'install', 't33q-20261024', '--library-root', '/Users/kolar/github/vphone-cli/.build', '--variant', 'exp', '--qualify-origin', '--keep-artifacts', '--work-parent', '/private/tmp', '--spoof-build', '23Z999999']' returned non-zero exit status 1.`。按计划失败停止，没有重试或回滚。

本轮VMStarts=0、securityWindows=0。真实显示、AA.gl、应用消费及补丁运行效果仍待验收，整项accepted=false。旧失败和原始证据保持。

证据：`research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023/continuation-outcome-20261024/manifest.json`。
