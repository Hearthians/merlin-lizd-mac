# TmuxHub for macOS

TmuxHub 是一个原生 macOS SSH/tmux 会话管理器。它直接使用系统
OpenSSH、`~/.ssh/config`、SSH Agent 和远端 `tmux`，不依赖任何云平台 CLI，
也不保存密码、私钥或平台 token。

原 Merlin 平台版本完整保存在 `merlin` 分支；当前分支只包含通用 SSH/tmux
功能。

## 功能

- 自动读取 `~/.ssh/config` 中的具体 `Host`，并递归读取 `Include` 文件。
- 支持手动添加 alias、hostname、IP、`user@host` 和 IPv6 目标。
- 浏览、创建、接入、重命名和批量终止本机或远端 tmux 会话。
- 每个远程终端都由 tmux 托管；关闭 App 标签只断开 SSH，远端任务继续运行。
- SSH 断开后可以原地重连同一个 tmux 会话。
- 使用 App 自己的 OpenSSH ControlMaster 复用连接，加快刷新与 tmux 操作。
- 可以把同一会话安全地交给 macOS Terminal.app 打开。
- 保存本地标签和 tmux 身份，tmux 改名后仍能正确关联会话。

## 要求

- macOS 14 或更新版本
- Apple Command Line Tools，Swift 6
- 本机 `/usr/bin/ssh`
- 远端已安装 `tmux`
- 推荐配置 SSH Agent 或非交互式认证，以便会话列表可以后台刷新

示例 SSH 配置：

```sshconfig
Host prod
    HostName 203.0.113.10
    User deploy
    IdentityFile ~/.ssh/id_ed25519

Include ~/.ssh/conf.d/*.conf
```

通配符 `Host *` 仍会作为 OpenSSH 规则生效，但不会作为可连接主机显示在侧边栏。

## 开发

```sh
./scripts/test.sh
/usr/bin/swift build
/usr/bin/swift run TmuxHub
```

测试使用本地 fake process，不会连接或修改真实 SSH 主机。

完成认证配置后，可对指定主机执行一个会自动清理的真实 tmux 生命周期测试：

```sh
./scripts/live-ssh-test.sh user@example.com
```

脚本使用唯一会话名验证创建、结构化发现、重命名和终止，并在异常退出时尝试清理。

## 打包

```sh
./scripts/package-app.sh
open "dist/TmuxHub.app"
```

脚本会构建 release product、组装 `.app` 并做本地 ad-hoc 签名。分发给其他
Mac 前仍需使用 Developer ID 签名并公证。

## 安全边界

- 所有本地命令都以 executable + argv 表示，不拼接本地 shell 命令。
- SSH 目标拒绝空白、控制字符、shell 元字符和前导 `-`，避免 option 注入。
- tmux 会话名限制为 1–64 个安全字符。
- 后台 SSH 查询使用 `BatchMode=yes` 和超时；交互终端仍由 OpenSSH 正常处理认证。
- Control socket 位于当前用户专属的 `/tmp/tmuxhub-<uid>`，退出时清理。
- 只有用户明确选择“终止 tmux”时才会执行 `kill-session`。

SwiftTerm 1.14.0 vendored 在 `Vendor/SwiftTerm`，其中保留了让 Metal shader
进入标准 app resource 路径的小型打包补丁。
