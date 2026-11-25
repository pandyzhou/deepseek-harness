# dsh 的 Docker 镜像

这个分支（`docker`）在上游代码之外只多了 `docker/` 目录和一个构建流程，用来把
官方发布的 npm 包 `@deepseek-ai/dsh` 做成镜像 `ghcr.io/pandyzhou/dsh`。

和 1Panel 应用商店里的镜像相比：

- 容器里只有 dsh 一个进程，没有 Caddy，也没有内层的 HTTPS。
- 对外是普通的 HTTP，端口 3080，由前面的反向代理负责 HTTPS。
- **镜像里没有登录验证。** dsh 能读写文件、执行命令，所以端口只能绑在
  `127.0.0.1`，并且必须在反向代理上设置密码访问。

## 使用

参考 `compose.yaml`。环境变量：

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
