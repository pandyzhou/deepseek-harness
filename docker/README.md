# dsh 的 Docker 镜像

这个 fork 在上游代码之外只多了 `docker/` 目录和一个构建流程，用来把
官方发布的 npm 包 `@deepseek-ai/dsh` 做成镜像 `ghcr.io/pandyzhou/dsh`。

和 1Panel 应用商店里的镜像相比：

- 容器里只有 dsh 一个进程，没有 Caddy，也没有内层的 HTTPS。
- 对外是普通的 HTTP，端口 3080，由前面的反向代理负责 HTTPS。
- 登录用 dsh 自带的令牌：没带令牌的访问一律返回 401。每次启动会换一个新令牌，
  登录链接打印在容器日志里。
- 端口只绑在 `127.0.0.1`，只让反向代理访问。

## 使用

参考 `compose.yaml`。启动后用 `docker logs dsh` 找到 `dsh web: https://…/?token=…`
这一行，在浏览器里打开一次，之后浏览器靠 Cookie 保持登录。其他设备可以在登录页
申请配对，由已登录的浏览器在 设置 → 远程连接 里批准。这个链接等同于密码，不要外传。

反向代理要做到三点（上游文档 `docs/user/guide/public-deployments.md`）：原样转发
`Host`、转发 WebSocket 升级请求、对外用 HTTPS。

环境变量：

| 变量 | 作用 |
|---|---|
| `DSH_TRUSTED_HOSTS` | 通过反向代理访问时用的域名，多个用空格隔开 |
| `DSH_PUBLIC_URL` | 访问地址，例如 `https://dsh.example.com/` |
| `DSH_PORT` | 监听端口，默认 3080 |
| `DSH_HOST` | 监听地址，默认是容器自己的第一个地址（dsh 不接受 `0.0.0.0`） |

数据在两个目录里：`/data/dsh`（设置、会话）和 `/workspace`（工作目录）。

## 构建

`.github/workflows/docker-image.yml`：改动 `docker/` 后自动构建，也可以手动运行并
指定 dsh 的版本；不指定时用 npm 上的 `latest`。构建后先把容器跑起来确认网页能
打开，再推送 `版本号` 和 `latest` 两个标签。
