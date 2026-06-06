# examples — 直接驱动 AgentBridge 的参考脚本

这些是**可选**的参考/调试脚本，演示如何不经 MCP、直接通过 TCP（`127.0.0.1:OW_AGENT_PORT`，NDJSON）驱动游戏里的 agent 桥。生产用法请走上一层目录的 MCP 服务器 + OpenClaw。

先用 `bash ../../run_with_agent.sh` 启动游戏并进入一个世界，再运行下列脚本：

| 脚本 | 作用 | 运行 |
|---|---|---|
| `smoke.mjs` | 最小连通性烟雾测试 | `node smoke.mjs` |
| `opc_voxel_runner.py` | 独立驱动循环：OpenClaw 当大脑做决策、本脚本执行；自带 home 半径护栏 + 自愈巡检 | `python3 opc_voxel_runner.py` |
| `demo_drive.py` | 简单的脚本化建造演示 | `python3 demo_drive.py` |
| `debug_think.py` | 单次 observe→think 调试 | `python3 debug_think.py` |
| `verify_avatar.py` | 校验 agent avatar 出现/移动 | `python3 verify_avatar.py` |

依赖本地 OpenClaw 的脚本通过环境变量读取路径：

- `OPENCLAW_MJS` — 你的 `openclaw.mjs` 路径（默认 `~/.openclaw/openclaw.mjs`）
- `OW_AGENT_PORT` — agent 桥端口（默认 `8970`）

> 这些脚本按「能用就行」维护，不属于受支持的产品接口。
