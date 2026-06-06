# 贡献指南 · Contributing to OurWorlds

OurWorlds 是一个用 **Godot 4.6 + 纯 GDScript** 从零实现的 3D 体素创造沙盒研究项目，
亮点是可由**自带的本地 OpenClaw agent** 自主游玩（建造 / 探索 / 修复地标）。欢迎贡献！

## 环境

- **Godot 4.6.x**（命令行 `godot` 在 PATH 中）
- 可选：**Node.js ≥ 18**（用于构建 `agent-bridge-mcp`）、本地 **OpenClaw**（仅当你要让 agent 接入时）

## 运行

- 编辑器：用 Godot 打开本工程，按 F5。
- 命令行：`godot --path .`
- agent 接入模式：`bash run_with_agent.sh`（开放 `127.0.0.1:OW_AGENT_PORT` 桥）

## 自检（提交前必跑）

```bash
bash tests/run_all.sh        # 全部 headless 逻辑自检，必须全绿
```

渲染类截图测试需要显示（**不要**加 `--headless`）：

```bash
godot --path . --script res://tests/shot_quality.gd
```

## 代码风格

- GDScript：**Tab 缩进**；尽量写全类型标注；沿用现有命名（私有成员 `_lower_snake`）。
- 每个脚本职责单一、可单独测；新增功能尽量配一个 `tests/test_*.gd`。
- 不引入第三方体素库——本项目刻意从第一性原理从零实现。

## 提交 PR

1. 从 `main` 切出分支。
2. `bash tests/run_all.sh` 全绿。
3. 改动聚焦、提交信息清晰。
4. 涉及 agent 桥协议的改动，请同步更新 [`docs/agent-bridge-contract.md`](docs/agent-bridge-contract.md)。

## 许可

贡献即表示同意你的代码以 **MIT** 许可证发布（见 [LICENSE](LICENSE)）。
