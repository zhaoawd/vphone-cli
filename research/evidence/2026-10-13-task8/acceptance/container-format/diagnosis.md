# Task 8 容器格式比较

两份输入的完整 IMG4 摘要与既有提交后读回记录一致。解码 payload 摘要均与既有 proof 一致。

| 对象 | 基线 | 安装后 v7 |
| --- | --- | --- |
| IMG4 字节数 | 43997230 | 43996897 |
| IM4P 字节数 | 43991410 | 43991077 |
| description | 'KernelManagement_host-487.0.4' | 'kernelcache' |
| 压缩类型 | NONE | NONE |
| payload octet 字节数 | 43991040 | 43991040 |
| 额外 IM4P 子元素数 | 1 | 0 |
| 额外 IM4P 子元素类型 | PAYP | 无 |
| IMG4 尾部子元素数 | 1 | 1 |

基线的额外 IM4P 子元素为 315 字节的 PAYP；安装后该元素不存在。两份 payload octet 字节完全相同，四个 IM4P 基础字段中仅 description 不同。description 缩短 18 字节，PAYP 减少 315 字节，与总尺寸减少 333 字节一致。

两份 IMG4 尾部均仅含 IM4M，其 raw 字节摘要一致；均无 IM4R。

完整字段、子元素 tag、长度和摘要见 [comparison.json](comparison.json)。

该结果仅记录容器差异。启动异常原因未查明；容器差异与启动异常的因果关系尚未验证。
