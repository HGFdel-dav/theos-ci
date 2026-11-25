# ParallelX alpha455 + clone0.114｜内容探针全覆盖 + 首次开窗补排（本地候选）

## 授权
用户本轮明确批准推送、监控CI至结束及DEB/源码独立验包。不包含设备操作、安装、注销或重启。

## 已知证据
- FluxDO 第一次开窗探针：stage0 `sourceW=0`（真实内容尺寸尚未到达），0.9s 那次 layoutHost 就在“尺寸未知”下跑完，之后不再重排 → 内容按未缩放渲染。
- 第二次开窗 `sourceW=390` 已有值 → 正常。与用户“只有第一次偶发”的描述一致。
- 窗口外框与画布一直一致（mismatch=0），问题在内容层。

## 改动（仅 `Common/PXWindowMemory.m`）
1. 探针升级为四层：`cardW/H`（外框）、`canvasW/H`（容器）、`hostW/H`（真正承载 App 界面的层）、`sourceW/H`，外加 `scale`、`expectScale`、`ta`（host 变换）、`clip`（内容超出外框）、`canvasMismatch`、`scaleMismatch`。
2. 持续监测：开窗后 1 秒一次（前 30 秒），随后 5 秒一次（约 8 分钟）；**仅状态变化时写入**，健康窗口不产生日志。窗口关闭/失效即停止。
3. 作者每次 `layoutHost` 之后也记一条（stage 3），可直接看到“重排时用的是多大的画布/源尺寸”。
4. **首次开窗补排**：`setSourceSize:` 收到有效的真实尺寸后，若该窗口的 source 尺寸此前未知，则调用一次作者自己的 `layoutHost` 并按新尺寸记录（`content_relaid_after_source_size`），不再改动任何内容排版代码。

未改：内容排版逻辑本身、记忆格式/路径/schema、保存规则、方向、分身/付款、vendor、设置面板。

## 本地检查
- 201 项测试：184 实跑通过、17 项 Apple runtime 跳过；守卫更新为四层字段、采样频率与补排逻辑。
- `tools/validate.py` 与 `--pinned-vendor`：均 `ALL LOCAL CHECKS PASSED`。

## 风险与未验证
- 未做完整 Apple 编译、未出 DEB、未安装、未真机。
- 补排只在“首次收到有效 source 尺寸”时触发一次；若某些 App 从不发布 source 尺寸，则不会补排（探针会显示 `sourceW=0`）。
- 采样最长约 8 分钟；更晚发生的偶发不会主动采样，但作者每次 layoutHost 与每次 frame 写入仍会记录。
- 探针字段均为尺寸/枚举，不含内容、名称或账号。

## 证据
`evidence/01-VALIDATE.log`、`02-VALIDATE-PINNED.log`、`03-UNIT.log`；FluxDO 113 探针原始记录见 `ParallelX-alpha455-clone0113-20261125/research/readonly-fluxdo/`。
