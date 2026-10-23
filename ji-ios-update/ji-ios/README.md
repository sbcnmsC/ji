# 记 · iOS 版

`ji-app/index.html` 是整个应用，iOS 版只是一个原生外壳（WKWebView），**网页和 App 永远是同一份代码**。

- 打包：推送到 main（改了 `ji-app/`、`ji-ios/`、`project.yml`）会自动跑 `.github/workflows/build-ipa.yml`，在 Releases 里得到 `Ji.ipa`（未签名），用爱思助手 / Sideloadly 签名安装。
- 原生接管的能力：预约本地通知（App 关闭也准时）、系统分享面板（票据图片 / 日历文件 / 备份）、触感反馈、数据镜像备份。
- 照片：不再存进 localStorage，而是存成 Application Support/photos/ 里的文件，记录里只留 `ji://app/photo/<id>.jpg` 短引用；旧照片首次启动自动迁移，不再被引用的照片会自动清理。
- 数据：网页数据在 `ji://app` 这个固定来源下；另有一份镜像在 Application Support/ji-backup.json，localStorage 被清空时会自动恢复。
- 锁定浅色模式（`UIUserInterfaceStyle = Light`）。
