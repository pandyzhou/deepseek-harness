# DSH 酒馆的 Docker 镜像

`docker-tavern/` 目录和它的构建流程把 [DSH 酒馆](https://github.com/flizzywine/dsh-tavern)
的命令行版做成镜像 `ghcr.io/pandyzhou/dsh-tavern`。容器启动后打开的就是酒馆界面。

它和 `docker/` 里的 dsh 镜像是两个独立的镜像：酒馆的命令行版只认它自己锁定的那一版
DeepSeek Harness，所以自带一份，不和原版 dsh 共用。两个都想用就各跑一个容器。

## 镜像里有什么

- 构建时运行酒馆官方的安装脚本，固定在一个提交上，把装好的结果打包放进镜像。镜像
  下载约 440 MB。
- 容器第一次启动时把它解包到数据目录 `/data`，约 1.7 GB。之后它就是一份标准的命令行
  版安装：程序、人物卡、聊天、设置都在数据目录里，酒馆页面里的“检查更新”照常可用。
- 服务由官方启动器启动，入口脚本守着它：服务退出，容器跟着退出，交给 Docker 重启；
  在页面里更新或用命令重启服务时，容器不动。
- 对外是普通的 HTTP，端口 3081，由前面的反向代理负责 HTTPS。
- 登录用 DSH 自带的令牌：没带令牌的访问返回 401。

## 使用

参考 `compose.yaml`。启动后在 `docker logs dsh-tavern` 里找“登录链接”一行，在浏览器里
打开。这个链接等同于密码，不要外传。

- 登录状态记在浏览器的 Cookie 里，有效期 30 天，容器重启后仍然有效。
- Cookie 是签发给具体域名的，换一个域名访问要重新用链接登录。
- 服务每次启动换一个新令牌，新的登录链接会再打印一次。

进去之后还要做两件事才能玩：

1. 左侧栏底部的 设置 → 模型 里填服务地址、API 密钥和模型名。
2. 导入一张人物卡（PNG 或 JSON），新建游玩。

反向代理要做到三点：原样转发 `Host`、转发 WebSocket 升级请求、对外用 HTTPS。上传的
人物卡和素材可能很大，请求体的大小上限也要放宽。

环境变量：

| 变量 | 作用 |
|---|---|
| `DSH_PUBLIC_URL` | 通过反向代理访问的地址，例如 `https://tavern.example.com/`。它的域名会被加进可信列表，登录链接也按它打印 |
| `DSH_TRUSTED_HOSTS` | 另外还要用到的域名，多个用空格隔开；不是 80 或 443 端口时写成 `域名:端口` |
| `DSH_TAVERN_PORT` | 监听端口，默认 3081 |
| `DSH_TAVERN_BIND` | 监听地址，默认是容器自己的第一个地址（服务不接受 `0.0.0.0`） |

用没列进可信列表的域名访问时，页面能打开、也能登录，但之后的请求都会被服务以 403
拒绝。

## 数据

全部在 `/data` 一个目录里：

- `/data/dsh-tavern/profile-data`：人物卡、聊天、插件
- `/data/dsh-tavern/settings.yaml`、`/data/dsh-tavern/.credentials.yaml`：设置和密钥
- `/data/dsh-tavern/profiles/tavern/cordis.patch.yml`：模型和服务商
- 其余是程序本身（酒馆、它的 DSH、依赖）和包管理器的缓存，丢了可以再装回来

## 更新和修复

- **更新酒馆**：用酒馆页面里的“检查更新”，或者
  `docker exec dsh-tavern dsh-tavern update`。更新走官方安装脚本，装的是上游主分支的
  最新提交。
- **换新镜像**：只更新系统、Node 和启动脚本。数据目录里已经装好的酒馆不会被换掉，
  镜像自带的那一份只在数据目录里没有酒馆时放进去。
- **修复**：程序文件坏了的时候，停掉容器后执行
  `docker run --rm -v "$PWD/data:/data" ghcr.io/pandyzhou/dsh-tavern repair`，把镜像自带
  的程序放回去。人物卡、聊天、设置和密钥不动；之后可以再在页面里更新。程序文件缺失
  时，容器启动时也会自动这样做；更新到一半容器被停掉的，下次启动会先退回更新前的版本。
- **其他命令**：`docker exec dsh-tavern dsh-tavern status` 查看状态和当前的登录地址，
  `restart` 重启服务。`stop` 之后容器会随之退出。
- **镜像自带的版本**：
  `docker run --rm --entrypoint cat ghcr.io/pandyzhou/dsh-tavern /opt/dsh-tavern/seed.json`。

## 安全

酒馆把 Agent 的权限全部打开，执行命令不再询问，所以拿到登录链接的人等于能在容器里
执行任意命令。上游的文档只建议在可信内网或 VPN 里使用命令行版。放到公网域名后面时：

- 端口只绑在 `127.0.0.1`，只让反向代理访问；
- 建议在反向代理上再加一层密码；
- 容器里的 Agent 能改的只有容器和数据目录里的东西。

## 构建

`.github/workflows/docker-tavern-image.yml`：改动 `docker-tavern/` 后自动构建，也可以
手动运行并指定酒馆的提交号；不指定时用上游主分支当前的提交。

构建后先把容器按部署的方式跑起来（`smoke-test.sh`），全部通过才推送。检查的内容：

- 没有令牌进不去，登录后打开的是酒馆，服务不以 root 身份运行；
- 给出的域名放行，没给出的域名、别的站点发起的请求被拒绝；
- 重启后数据和登录状态都在，不会重新解包；
- 用命令重启服务、在容器里更新酒馆时，容器不动，更新后数据还在；
- 服务异常退出后容器退出；上一个容器留下的锁和记录不妨碍启动；更新中断后能退回；
- 程序文件缺失时自动放回，`repair` 命令同样有效；
- 在宿主机目录和 Docker 卷上都能完成首次启动。

推送两个标签：`酒馆版本-提交号前七位` 和 `latest`。

## 来源和许可

- 酒馆：[flizzywine/dsh-tavern](https://github.com/flizzywine/dsh-tavern)，AGPL-3.0。镜像
  里是它未经改动的代码，所用的提交号写在镜像标签和 `/opt/dsh-tavern/seed.json` 里。
- DeepSeek Harness：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)，MIT。
- 其余依赖来自 npm，许可随各自的包。
