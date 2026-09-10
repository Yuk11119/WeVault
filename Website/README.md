# WeVault 官网与未公证测试渠道

2026-09-09 经用户授权上线：<https://wevault.online/>。
下载入口：<https://wevault.online/download/>；版本源：<https://wevault.online/updates/beta.json>。
公开反馈地址由用户提供为 `yuk11119yx@gmail.com`。未发送测试邮件，未把邮箱配置写成收件联调通过。

## 当前发布记录

- 版本：0.7.2 / build 9，macOS 14+，arm64 + x86_64。
- 文件：`WeVault-0.7.2-9-macos-universal.zip`。
- SHA-256：`530a6b446dc916928a2c0be131847cd8cadda7bbc653de7084016e34210c2f7e`。
- 渠道：`public-unnotarized-beta`，ad-hoc 签名，没有 Developer ID 或 Apple 公证。独立于工程预览和正式公证流程。
- DNS：阿里云 `wevault.online`，新增 `@ A 8.133.187.255`，默认线路，TTL 10 分钟。原有 9 条 API/邮件记录保留，共 10 条。
- 服务：独立 Nginx 站点 `/etc/nginx/sites-available/wevault-site`，不变更 API 服务或数据库。
- 站点目录：`/var/www/wevault-site/releases/0.7.2-9`，`/var/www/wevault-site/current` 指向该目录。
- HTTPS：独立 Let's Encrypt 证书，签发时到期日 2026-12-08；`certbot.timer` 已启用。续期使用 `/var/www/certbot`，站点证书续期后 hook 检查并 reload Nginx。
- 本地静态产物：`.build/website-0.7.2-9`。只部署该目录内容，源码、私钥、应用索引和测试夹具不上传。

## 已验证与未验证

3 项网站测试、6 项既有分发测试通过。网站生成器拒绝未完成、工程预览、隔离应用、错误版本源及校验失败的 ZIP；输出目录拒绝覆盖。

本机通过公网 HTTPS 重新下载 ZIP 和校验文件，SHA-256、解包、`codesign --verify --deep --strict` 与双架构检查通过。首页、下载、隐私、版本页、CSS、SVG、版本 JSON 与本地产物逐字节一致；HTTP 跳转 HTTPS，未知路径及隐藏路径不可读取。原 API 公网 `/healthz` 仍返回正常。

浏览器验证了线上页面及手机尺寸下载布局，没有水平溢出。完整长截图工具有拼接重复问题，不作为额外页面重复的证据。

尚未完成：干净机器 Gatekeeper 安装、Intel 实机、旧安装升级与钥匙串授权迁移、真实原生邮件草稿、应用内真实版本源全状态联调。没有运行公开应用接触用户数据，没有启用自动任务或释放真实文件。云端账号目前需要邀请。

## 下次构建

使用新的单调递增 build，并先更新 `release-notes.txt`。Python 3.11+；在 macOS 安装 Swift/Xcode 工具后：

```sh
WEVAULT_VERSION=0.7.3 WEVAULT_BUILD=10 \
WEVAULT_FEEDBACK_EMAIL=yuk11119yx@gmail.com \
WEVAULT_UPDATE_FEED_URL=https://wevault.online/updates/beta.json \
Scripts/package-public-beta.sh
python3 Website/build.py --release .build/public-beta/0.7.3-10 --output .build/website-0.7.3-10
python3 -m unittest discover -s Tests/WebsiteTests -v
python3 -m unittest discover -s Tests/PackagingTests -v
```

不要复用版本目录，不要发布含 `BUILD-INCOMPLETE.txt` 的目录，不要移除工程预览的 `NOT-FOR-DISTRIBUTION.txt`。网站生成器校验 ZIP 摘要与内部 plist；真实代码签名/架构由打包和公网下载验收检查，测试中的 ZIP 替身不等于这些检查。

## 部署与回退

通过现有受信 SSH 连接，将完整网站输出复制到新的 `/var/www/wevault-site/releases/<版本-build>`；先校验服务器上的 ZIP。部署不需要改 API、邮箱 DNS 或运行应用。

首次部署先安装 `deploy/wevault-site-http.conf`，执行 `nginx -t`、reload，使用现有 ACME 账号运行 `certbot certonly --webroot -w /var/www/certbot -d wevault.online --non-interactive`。成功后安装 `deploy/wevault-site.conf`，再次检查并 reload。续期脚本 `deploy/reload-wevault-site.sh` 以 755 安装到 `/etc/letsencrypt/renewal-hooks/deploy/reload-wevault-site`；仅为该域名证书触发 reload。

后续上线前，把历史 `downloads/` 中的旧版本文件保留到新站点目录，并验证没有覆盖同名不同内容的文件。记录旧 `current` 目标，创建临时链接指向新目录后，在同一文件系统用 `mv -T` 原子替换 `current`。下载文件及版本 JSON 随站点一起切换，不先单独发布版本源。已有 Nginx 配置不变时无需 reload。

发布后检查 HTTPS 证书、四个页面、版本源、实际公网 ZIP 摘要及 API 健康。失败时以同样方式把 `current` 指回之前的完整版本目录；保留发布目录供诊断，不清理应用索引、钥匙串或云端数据。未来启用正式 Developer ID 公证时，使用原有 `Scripts/package-beta.sh` 流程并单独完成验收，不能把本渠道改称已公证。
