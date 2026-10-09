# 归档范围

本目录仅保留源码、脚本、公开签名证据、运行JSON及其中stdout/stderr的原样提取、精确harness崩溃报告、摘要、清理记录与manifest。stable对象库、app、可执行文件和framework二进制仍保留在/tmp原物，没有复制至本目录。stdout/stderr提取来源为同stem JSON中的原始字符串。

源码TransportHarness.swift开头的prepared-only注释保留编译时原文；最终状态由summary.json及实际编译/签名/矩阵证据确定。legacy-v1-source和proposed plist仅prepared_not_executed，未构建、签名或注册。

manifest.json记录本目录除manifest自身之外全部文件的大小与SHA256；其自身摘要保存在/tmp父目录evidence-manifest-verification.json中，并由verify-archive.py独立重算全部条目。
