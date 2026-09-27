# TmuxHub for macOS

TmuxHub 是一个原生 macOS SSH 终端管理器，支持 tmux 和 Herdr。它直接使用系统
OpenSSH、`~/.ssh/config`、SSH Agent 和目标主机上的终端服务，不依赖任何云平台 CLI，
也不保存私钥或平台 token。用户可以按主机选择是否把 SSH 密码安全保存到
macOS 钥匙串，作为密钥认证失败后的回退。

原 Merlin 平台版本完整保存在 `merlin` 分支；当前分支包含通用 SSH 终端
功能。

## 功能

- 把 `~/.ssh/config`（含递归 `Include`）作为可搜索主机库，而不是把每个目标都塞进侧边栏。
- 侧边栏只显示用户固定的主机和最近 7 天成功连通过的 6 个目标；手动添加会自动固定。
- 裸 IPv4/IPv6 地址默认从主机库首页隐藏，但仍可搜索、手动添加和正常连接。
- 快捷连接优先回到已有标签；首次连接使用稳定的默认 tmux 会话名，主动新建才生成新会话。
- 浏览、创建、接入、重命名和批量终止本机或远端 tmux 会话。
- 在主机详情或本机页面一键应用 tmux 快捷配置，自动备份并保留其他设置。
- 浏览本机或远端 Herdr 工作区、Agent 和终端，直接打开所选终端。
- 远程终端由 tmux 或 Herdr 托管；关闭 App 标签只断开 SSH，远端任务继续运行。
- SSH 断开后可以原地重连同一个 tmux 会话或 Herdr 终端。
- 使用 App 自己的 OpenSSH ControlMaster 复用连接，加快刷新与 tmux 操作。
- 每个主机可选密码回退；默认仍优先使用 SSH config、私钥和 SSH Agent。
- 查看主机和后台连接不会自动弹出钥匙串授权；需要时在主机详情手动授权使用已存密码。
- 可以把同一会话安全地交给 macOS Terminal.app 打开。
- 保存本地标签和 tmux 身份，tmux 改名后仍能正确关联会话。
- 拖入文件、粘贴 Finder 文件或 ⌘V 截图，传输完成后把可访问路径插入当前终端。
- 附件栏提供缩略图、状态、取消、重试、复制路径和手动插入；始终不自动按 Enter。

## 钥匙串授权

主机详情只查询是否有已存密码，不读取密码内容。后台连接只使用已获许可的密码；若 macOS
需要新的访问许可，可在主机详情的「密码回退」中点击「授权使用已存密码」。系统弹窗要求
输入的是 Mac 登录钥匙串密码。保存、更新和移除密码也是主动操作，可能需要系统授权。

成功授权的密码只在当前 App 进程的内存中复用；更新或移除密码会同步更新这份缓存。
取消授权会保留原密码，后台不会再次弹窗；可以稍后手动重试。

目前本地构建使用 ad-hoc 签名，不同版本的程序身份可能改变，因此更新后可能需要重新
点击授权。「始终允许」针对当前受信任的程序身份，不能保证跨 ad-hoc 构建沿用。
若要让系统在升级后稳定识别同一程序，分发流程应使用固定的代码签名身份。

## 一键配置 tmux

选择目标主机，在「tmux 快捷配置」卡片点击「一键配置 tmux」。本机页面也有同一入口。
目标主机需已安装 tmux；远程操作复用 App 的 SSH 连接和认证设置。

- 前缀改为 Ctrl+A，连按两次向终端发送 Ctrl+A；启用鼠标选择、切换和滚动。
- 状态栏黑底白字，普通面板边框绿色、活动边框红色。
- 新窗口和面板从 1 编号，终端类型为 `screen-256color`。
- 在目标用户的 `~/.tmux.conf` 中添加或更新独立配置段；若已有 XDG 配置且没有
  `~/.tmux.conf`，则更新现有 XDG 文件。保留其他配置和符号链接。
- 修改前在原文件旁保存 `.tmuxhub-backup.<随机后缀>` 备份，完成后显示完整路径。
  重复应用相同配置不会增加配置段或生成新备份。
- 正在运行的默认 tmux 服务会立即加载这组设置，现有任务继续运行；编号和终端类型
  用于新建窗口、面板或会话。尚未运行 tmux 时，下次启动自动生效。
- 若配置已保存但当前服务加载失败，界面会单独提示，可再次点击重试。

如需恢复，可用显示的备份文件替换对应配置文件，并在方便时重启 tmux。
该入口管理默认 tmux 服务；通过自定义 socket 或 `-f` 启动的独立服务需自行加载配置。

## Herdr 工作区

在侧边栏主机行点击 Herdr 图标，或在主机详情的「Herdr 工作区」中点击「浏览工作区」，即可按
会话、工作区浏览现有终端。点击 Agent 或终端会直接打开对应的终端标签；已有标签
会被选中。列表在打开时读取最新状态，也可手动刷新。

- 目标主机需要已安装并运行支持 `api snapshot` 和 `terminal attach` 的 Herdr；
  已使用 Herdr 0.9.0 验证。本机和远程连接均可使用。
- TmuxHub 使用 Herdr 官方直接连接命令，不需要再套一层 tmux。
- 每个标签保存服务器会话名和稳定的 terminal ID。切换 Herdr 焦点或移动 pane
  不会把附件传给另一个 Agent；原终端不存在时需要重新选择。
- Herdr 未提供工作目录时仍可打开终端，但附件操作会提示目录不可用；未提供
  Agent 会话标识时，上传结果会保留为「就绪」，由你点击插入。
- 关闭标签只断开连接。也可按 Ctrl+B、再按 q 断开；输入 Ctrl+B 本身需连按两次。
- Herdr 同一终端仅允许一个直接控制客户端。如果已有客户端占用，连接会显示错误；
  请先断开原客户端，再重连。TmuxHub 不自动接管控制权。
- 本版只接入现有工作区和终端；创建、停止工作区仍在 Herdr 中操作。

参考：[Herdr 直接终端连接](https://herdr.dev/docs/cli-reference/#direct-terminal-attach)。

## 给 agent CLI 添加附件

把一个或多个文件拖到终端，或在截图后按 ⌘V。普通文字仍按原样粘贴；也可以
使用终端底部的「添加文件」和「粘贴截图」按钮。

- 远程会话：通过独立 SFTP 通道复用已认证的 SSH ControlMaster，上传到当前
  tmux pane 或所选 Herdr 终端工作目录的 `.tmuxhub/attachments/<唯一 ID>/`。服务器须开启 SFTP。
- 本机文件：直接引用原路径；剪贴板截图转为 PNG 并保存到上述附件目录。
- 目录按钮可为会话指定一个已存在的绝对路径，作为 `.tmuxhub/attachments` 的父目录。
- 文件完整上传后才插入路径。如果期间输入文字、切换标签、离开终端焦点，或检测到
  pane、前台程序、工作目录改变，附件会保留为「就绪」，由你点击插入。
- 支持每批 32 个普通文件，单个最大 100 MiB。不接收文件夹、软件包、符号链接或
  带控制字符的路径；请先自行打包。最多保留 100 条附件记录。
- 附件队列在当前 App 运行期间跨重连保留；关闭标签或退出 App 会取消传输。
  移除记录不会删除已保存或上传的附件。取消或失败可能在唯一目录中留下未完成文件。
  本机剪贴板暂存会在移除记录或关闭标签时清理；异常退出后的缓存可能保留。

这是通用的**文件传输 + 路径粘贴**，不是某个 agent 的专有图片协议。是否能把路径
识别为原生图片附件取决于 CLI；也可告诉 agent「读取这张图片」。若 agent 运行在
容器或权限受限的工作区中，请把附件目录设为它能访问的挂载路径。
附件目录不会自动加入 `.gitignore`；可按需忽略 `.tmuxhub/attachments/`。

## 打开终端文件链接

终端中的 HTTP 等常规 URL 可以直接点击打开。形如
`temp_output/r256/model/38.ply`、`./result.png` 或绝对路径的文件链接，需要按住 **⌘ Command
并右键点击**才会下载或打开。普通左键、⌘+左键、普通右键和拖动选中文字都不会触发文件操作。
`ls` 彩色、多列输出中的带扩展名裸文件名（如 `rec_helmet.ply`、`rec_helmet.glb`、
`ovoxel_helmet_visualization.png`、`ovoxel_helmet.vxz`、`render_ovox.log`）同样支持，
按点击时终端的当前工作目录定位文件，不限制为特定扩展名：

- 远程 SSH/tmux 标签会先按点击瞬间的 pane 工作目录解析相对路径。若 agent 管理器
  的工作区与 pane 目录不同，TmuxHub 会在主目录下常见的一、二级工作区布局中按完整
  相对路径查找，并且只接受唯一结果。随后弹出 macOS 保存面板选择本地位置；面板默认
  打开 `~/Downloads/_tmuxhub_download/`，并通过现有 SSH ControlMaster 的独立 SFTP
  通道下载。
- 本机标签中的文件路径直接使用默认 App 打开。
- Herdr 标签始终按所选终端的实际工作目录解析文件；不存在时直接提示失败，
  不会搜索其他工作区代替。
- 下载先写入所选目录中的唯一临时文件，成功后再替换最终文件；取消、失败或关闭标签
  会清理临时文件。选择已有文件时，macOS 保存面板会先要求确认覆盖。下载完成后
  TmuxHub 会立即用系统默认应用打开文件。

## 要求

- macOS 14 或更新版本
- Apple Command Line Tools，Swift 6
- 本机 `/usr/bin/ssh`
- 目标主机已安装所需后端：`tmux` 或 Herdr
- 推荐配置 SSH Agent；也可以在主机详情中保存密码，以便会话列表后台刷新

示例 SSH 配置：

```sshconfig
Host prod
    HostName 203.0.113.10
    User deploy
    IdentityFile ~/.ssh/id_ed25519

Include ~/.ssh/conf.d/*.conf
```

通配符 `Host *` 仍会作为 OpenSSH 规则生效，但不会作为可连接主机显示在侧边栏。
建议把稳定、易读的名称写在 `Host`，把可能变化的 IP、端口和跳板规则写在该条目的
`HostName`、`Port` 和 `ProxyJump` 中。`Host prod 203.0.113.10` 会被 OpenSSH 视为两个
可连接名称；若只想在 TmuxHub 中看到 `prod`，请只写 `Host prod`。

## 开发

```sh
./scripts/test.sh
./scripts/test-attachments-ui.sh
./scripts/test-display-ui.sh
./scripts/test-links-ui.sh
/usr/bin/swift build
/usr/bin/swift run TmuxHub
```

默认测试包含本地 fake process、临时文件和本机 SFTP 协议往返，不连接真实 SSH
主机。AppKit smoke test 使用私有剪贴板，不会替换系统剪贴板。
显示测试会在已连接的 Retina / 普通显示器之间移动独立测试窗口，检查文字单元格、
分隔线、光标和终端网格是否同步；只有一种缩放比例时会跳过。

完成认证配置后，可对指定主机执行一个会自动清理的真实 tmux 生命周期测试：

```sh
./scripts/live-ssh-test.sh user@example.com
```

脚本使用唯一会话名验证创建、结构化发现、重命名和终止，并在异常退出时尝试清理。

附件真实联调（仅对你授权的主机运行；创建并清理唯一的临时目录和 tmux 会话）：

```sh
TMUXHUB_LIVE_ATTACHMENT_HOST=user@example.com ./scripts/test.sh
```

Herdr 真实联调使用独立的临时命名会话及目录，并在结束时清理：

```sh
TMUXHUB_LIVE_HERDR_HOST=user@example.com ./scripts/test.sh
```

## 打包

```sh
./scripts/package-app.sh
open "dist/TmuxHub.app"
```

脚本会构建 release product、组装 `.app` 并做本地 ad-hoc 签名。分发给其他
Mac 前仍需使用 Developer ID 签名并公证。

## 安全边界

- 所有进程都以 executable + argv 启动；tmux 配置使用固定脚本，路径以参数传入，
  远程执行时对整个脚本做 shell 引用。
- SSH 目标拒绝空白、控制字符、shell 元字符和前导 `-`，避免 option 注入。
- tmux 会话名限制为 1–64 个安全字符。
- 未配置密码时，后台 SSH 查询使用 `BatchMode=yes` 和超时。
- 配置密码后，OpenSSH 仍先尝试公钥，再通过随 App 签名的 AskPass helper
  获取本次连接所需密码；密码不进入 argv、日志或 SSH 配置。
- 密码只作为对应 SSH 目标的 macOS 钥匙串项目持久化，可随时在主机详情移除。
- Control socket 位于当前用户专属的 `/tmp/tmuxhub-<uid>`，退出时清理。
- 只有用户明确选择“终止 tmux”时才会执行 `kill-session`。

SwiftTerm 1.14.0 vendored 在 `Vendor/SwiftTerm`，其中保留了让 Metal shader
进入标准 app resource 路径的小型打包补丁。
