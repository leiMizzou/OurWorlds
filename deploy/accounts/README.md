# 账号 + 社交登录（Nakama）— M4（脚手架）

让玩家上来先**注册/登录**（邮箱密码，或 Google / GitHub / Twitter），再进世界；云端存档、世界列表也走这里。仿真仍在 Godot 世界服务器——Nakama 只管账号/会话/票/存档。

```
玩家 ──登录(Nakama HTTP :7350)──▶ 拿到 session + 入场票
     ──带票连 Godot 世界服务器(wss)──▶ 服务器校验票 → 放行进场
```

## 起后端（本地）
```bash
cd deploy/accounts
# 先把 nakama-config.yml 里的 CHANGE_ME 改成随机强密钥
docker compose up -d          # Nakama:7350(API)/7351(控制台) + Postgres
```

## 社交登录——你要做的（外部 OAuth 应用注册，我无法替你注册/拿密钥）

> ⚠️ 下面每条都要用**你自己的**开发者账号注册一个 OAuth 应用，拿到 client id/secret 后回填。按安全约束我不替你注册、不碰密钥。

- **Google**（Nakama 原生支持，最省事）：在 [Google Cloud Console] 建 OAuth 2.0 客户端 → 拿 `client_id`。客户端取 Google `id_token` → Nakama `AuthenticateGoogle`。
- **GitHub**：在 GitHub → Settings → Developer settings → OAuth Apps 建应用 → `client_id`/`client_secret` + 回调 URL。GitHub 非 Nakama 原生，走**自定义 OAuth**：网页/服务端用 code 换 GitHub token、取用户 id → Nakama `AuthenticateCustom("github:<id>")`。
- **Twitter/X**：在 X Developer Portal 建 OAuth 2.0 应用 → `client_id`/`client_secret` + 回调。同样走 `AuthenticateCustom("twitter:<id>")`。
- **邮箱密码**：Nakama 原生 `AuthenticateEmail`，无需外部应用。

回调/重定向 URL 用你的 Cloudflare 二级域名（见 [`../README.md`](../README.md)），如 `https://ourworlds.<你的域名>/auth/github/callback`。

## 现状与下一步（诚实说明）
- ✅ 已就位：账号后端 docker-compose + 配置模板 + 本文档（你可以现在就去注册上面几个 OAuth 应用，与我并行）。
- ⏭ 待我做（M4 实现）：游戏内/网页登录界面、Nakama Godot SDK 接入、登录→入场票→Godot 世界服务器校验票的握手、云存档读写。这部分是代码（`.gd` + 可能的 Nakama 运行时模块），会在 M4 实现阶段做，需要上面的 OAuth client id/secret 才能端到端跑通社交登录。
- 设计依据见 [`../../docs/superpowers/specs/2026-06-03-online-multiplayer-design.md`](../../docs/superpowers/specs/2026-06-03-online-multiplayer-design.md) §3/§7 与 [`../../docs/superpowers/specs/2026-06-06-goal-online-platform.md`](../../docs/superpowers/specs/2026-06-06-goal-online-platform.md)。
