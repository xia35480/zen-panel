# zen-panel — zen-console 的 GitHub Actions 部署模板

这个仓库把本地 `zen-console` 控制台整包搬到 GitHub Actions 上跑：

- 面板本体：`bin/zen-console-linux-amd64`（前端已 embed，无需 Node）
- 网关模板：`template/` `template-warp/` `template-vpngate/`（面板自己建节点时用）
- 入口：`.github/workflows/panel.yml`；生命周期：`scripts/run-panel.sh`
- 公网入口：Cloudflare 命名隧道回源 `http://localhost:8081`
- 状态：加密快照存 Release `panel-state` 的 `state.bin`，每 5 分钟覆盖、交班前强制一次
- 时长：单班 5 小时（18000s），到点自动 dispatch 下一班；job 硬顶 340 分钟

## 需要的 Secrets

| 名称 | 说明 |
|---|---|
| `CF_TUNNEL_TOKEN` | Cloudflare 命名隧道 token（该隧道的 Public Hostname 需指向 `http://localhost:8081`） |
| `PANEL_TOKEN` | 面板控制面口令（登录 `/login` 用） |
| `ZEN_API_KEY` | `/v1` 数据面口令（OpenAI 兼容客户端用） |
| `PANEL_STATE_KEY` | 状态快照加密口令；更换后旧快照作废 |
| `ZEN_ACCOUNTS_JSON` | PAT 列表：`[{"label":"main","token":"ghp_..."}]` |

## 需要的 Variables

| 名称 | 说明 |
|---|---|
| `ZEN_PUBLIC_HOST` | 面板域名，例如 `panel.example.com` |
| `PANEL_PORT` | 可选，默认 `8081`（必须与隧道 Public Hostname 的回源端口一致） |

## 用法

1. 配好上面的 secrets / variables。
2. Actions → `zen-panel` → Run workflow；或等 cron。
3. 打开 `https://<ZEN_PUBLIC_HOST>/login`，输入 `PANEL_TOKEN`。
4. 数据面：`base_url=https://<ZEN_PUBLIC_HOST>/v1`，`api_key=<ZEN_API_KEY>`。

## 本地控制

本地面板（`zen-console.exe`）的「远端面板」页可以登记这个部署：
填 `https://<ZEN_PUBLIC_HOST>` + `PANEL_TOKEN`，之后可直接嵌入操作、强制快照、重启/停止、推送新模板。

## 排障

- 502/404：run 已结束，或隧道回源端口与 `PANEL_PORT` 不一致。
- 401：`PANEL_TOKEN` 不匹配；`/v1` 401 则是 `ZEN_API_KEY` 不匹配。
- 状态没恢复：Release `panel-state` 不存在，或 `PANEL_STATE_KEY` 与加密时不同。
- 公网自检失败但本地正常：隧道未注册 / Public Hostname 未指向 `localhost:8081`。
