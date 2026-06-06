# 公网部署（Cloudflare Tunnel）— M3

把本机跑的 OurWorlds 通过 **Cloudflare Tunnel** 暴露到你自己的二级域名，别人就能直接用浏览器进、或下载 Mac App 连。无需公网 IP、无需开端口、TLS 由 Cloudflare 边缘自动签。

```
浏览器/Mac App ──https/wss──▶ Cloudflare 边缘 ──加密隧道──▶ 你本机 cloudflared ──▶ localhost:8060 (网页站)
                                                                              └─▶ localhost:8971 (游戏服务器, WebSocket)
```

## 一次性准备（这些是你要做的，我无法替你操作账号/DNS）

> ⚠️ 下面带 **[你来做]** 的步骤涉及你的 Cloudflare 账号、域名、DNS——按安全约束我不碰这些。其余配置/脚本我已写好。

1. **[你来做]** 有一个挂在 Cloudflare 上的域名（在 Cloudflare 买的，或把已有域名的 NS 指到 Cloudflare）。
2. 装 `cloudflared`：`brew install cloudflared`
3. **[你来做]** 登录授权：`cloudflared tunnel login`（浏览器里选你的域名授权）。
4. **[你来做]** 建隧道：`cloudflared tunnel create ourworlds` → 记下输出的 **Tunnel ID** 和凭证文件路径（`~/.cloudflared/<ID>.json`）。
5. 填配置：把 `deploy/cloudflared-config.example.yml` 复制为 `deploy/cloudflared-config.yml`，把 `<TUNNEL_ID>`、凭证路径、`<你的域名>` 都替换好。
6. **[你来做]** 绑两个二级域名到隧道（建 DNS 记录）：
   ```bash
   cloudflared tunnel route dns ourworlds ourworlds.<你的域名>        # 网页客户端
   cloudflared tunnel route dns ourworlds play.ourworlds.<你的域名>   # 游戏服务器(WebSocket)
   ```

## 每次上线

```bash
# 0) 先导出过网页版（产出 build/web）
bash packaging/build_web.sh    # 导完会顺手起本地站；本地测完 Ctrl+C 即可

# 1) 起本地的"游戏服务器 + 网页站"
bash deploy/run-public.sh

# 2) 另开一个终端，起隧道
cloudflared tunnel --config deploy/cloudflared-config.yml run
```

## 别人怎么进

- **浏览器（免下载）**：打开
  `https://ourworlds.<你的域名>/?connect=wss://play.ourworlds.<你的域名>`
  （`?connect=` 让网页端自动连游戏服务器；把这条链接发给别人即可。）
- **Mac App（更顺）**：见 [`../packaging/README.md`](../packaging/README.md) 导出/签名；App 里用「联机」菜单(按 N) 填 `wss://play.ourworlds.<你的域名>` 加入。

## 说明 / 限制（当前阶段）

- WebSocket：Cloudflare 隧道对 http(s) 服务透明支持 WS 升级；客户端用 `wss://`（边缘 TLS）。
- 账号/登录：本阶段是"凭链接进同一个世界"，**还没有账号系统**——注册/密码 + Google/GitHub/Twitter 登录是 **M4**（见 `docs/superpowers/specs/2026-06-06-goal-online-platform.md`）。
- 安全：公开前请加限流/举报/封禁/备份/监控（**M6**）。当前建议**邀请制**（只把链接发给信任的人），世界服务器对所有输入已做基础校验（距离/边界/频率）。
- 多线程网页版需要 COOP/COEP 跨源隔离响应头——`serve_web.py` 已带；经 Cloudflare 透传不受影响。
