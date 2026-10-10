# B35：T08 启动激活与完整产物

范围：继续 T08；研究副本和源维护授权延续，5 GiB 停止阈值保留。源目前运行，准备期间不停止源。

## 已完成

- 默认构建仍打包 classic regular/less；现代 API 候选保持隔离，不替换旧 CFW 的 256 字节相机组件。
- 实际现代 daemon 启动函数只修复链接和 firmware 记录，未加载 RootHide LaunchDaemons。
- 核对固定上游启动加载实现与 IcliKit 0.7.16 的服务加载/RootHide 路径处理。
- 启动恢复红测试 4 项失败，最终绿测试 4 项通过；相关回归 22 项通过。
- RootHide 启动恢复修复及固定物理根 plist 准备完成；API_ONLY 条件保持。
- 隔离 API 候选、默认完整签名 app 和六项现代组件构建及静态检查通过。
- 新宿主 --help 退出 -9，精确日志 AMFI -424；单 CDHash 驱动 --check 通过，尚未执行。
- 源仍 healthy，研究副本停机；本轮未暂停监测或停止源。

## 待办

- 新宿主 CDHash `62026af109b33fdd468c2c2df2fcdb4211136bf0` 的临时 AMFI 批准及管理员执行。
- 研究副本只读 CFW 分类和匹配现代 guest 组合的适用迁移步骤；sudo -n 因需要密码未执行。
- 真实冷启动 RootHide 自动激活和 daemon/组件运行来源核对。
- 默认现代 daemon 打包与跨模块整体验收；当前默认仍 classic，不计为默认现代产物完成。
