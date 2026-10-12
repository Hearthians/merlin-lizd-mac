# TmuxHub for Windows

Windows 版是仅远程客户端：它使用 Windows 自带的 OpenSSH 连接 Linux/Unix 主机上的
tmux、Herdr 和 Slurm，并在独立控制台中打开交互终端。不安装本机 tmux，不依赖兼容层，
也不在应用内嵌终端。

## 要求

- Windows 10 19041 或更新版本，x64。
- 从源码构建或运行安装脚本需要
  [.NET 8 SDK x64](https://dotnet.microsoft.com/download/dotnet/8.0)；仅运行已发布程序需要
  .NET 8 Desktop Runtime x64。
- Windows “OpenSSH Client” 可选功能，默认程序路径为
  `C:\Windows\System32\OpenSSH\ssh.exe`。
- 远端已安装 tmux；如使用 Herdr 页面，远端还需已有可连接的 Herdr 服务。
- 建议先在普通控制台运行一次 `ssh <目标>`，完成主机密钥确认与密钥/Agent 认证。

主机库读取 `%USERPROFILE%\.ssh\config` 以及其中的 `Include`。端口、用户名、私钥、
ProxyJump 等连接细节继续由 OpenSSH 配置管理。

## 构建和测试

在 `D:\lizd` 下的仓库根目录运行：

```powershell
.\windows\build.ps1
```

脚本还会运行 `TmuxHub.Windows.Tests` 中的离线测试。只构建时可使用：

```powershell
.\windows\build.ps1 -SkipTests
```

也可直接运行测试程序：

```powershell
dotnet run --project .\windows\TmuxHub.Windows.Tests\TmuxHub.Windows.Tests.csproj
```

测试不连接真实 SSH 主机，覆盖目标与 tmux 标识校验、稳定会话名哈希、tmux 列表解析、
Windows SSH `Include`、状态持久化，以及本地/远端参数边界。

## 安装

```powershell
.\windows\install.ps1
```

安装脚本先构建并测试，然后将 framework-dependent `win-x64` 版本发布到
`windows\publish`，并生成固定入口：

```text
D:\lizd\app\TmuxHub.lnk
```

它不会向桌面、开始菜单或系统目录写入文件。已单独运行过测试时，可以执行：

```powershell
.\windows\install.ps1 -SkipTests
```

发布为 framework-dependent，目标机器必须安装 .NET 8 Desktop Runtime x64。

## 使用

1. 从左侧选择 SSH config 中的主机，或添加 `host`、`user@host`、IPv4/IPv6 目标。
2. 在 tmux 页刷新会话，或输入安全的会话名后创建/接入；齿轮按钮可幂等应用 TmuxHub
   配置段，并在修改前备份原文件。
3. Herdr 页只连接已有终端；Slurm 页可查看队列、启动交互环境，以及连接或安全取消
   TmuxHub 创建的任务。
4. 三角按钮会启动独立的 `ssh.exe` 控制台；关闭 TmuxHub 或终端只断开 SSH，不终止
   tmux/Herdr，也不会取消 Slurm 作业。
   在该控制台按 `Ctrl+V`（或 `Ctrl+Shift+V`）时，TmuxHub 会把 Windows 剪贴板中的
   Unicode 文本直接写入当前 SSH 控制台；内容不会保存或记录。剪贴板为图片时，会先
   转为 PNG，经独立 SFTP 通道上传到远端 `~/.tmuxhub/attachments/`，再插入远端路径。
   富文本同时包含文字和图片时优先粘贴文字。
5. tmux 复制模式中的选区通过 OSC 52 写入 Windows 剪贴板。首次升级后需在 tmux 页
   点一次配置按钮以更新远端配置；也可按住 `Shift` 用终端原生选区，再按
   `Ctrl+Shift+C` 复制。
6. 终止 tmux 和取消 Slurm 属于显式远端操作；Slurm 取消前会重新核对 Job ID、owner、
   job name 和 comment。

应用状态保存在 `%LOCALAPPDATA%\TmuxHub\state.json`。Slurm 资源默认值和 TmuxHub
启动凭据会保存在这里；私钥、密码、SSH 配置内容和远端命令输出不会写入该状态文件。

## 安全边界和限制

- `ssh.exe` 使用绝对路径启动，参数保持独立，不经过 `cmd.exe` 或 PowerShell。
- 后台查询使用 `BatchMode=yes` 和超时；交互认证只出现在独立 SSH 控制台。
- SSH 目标拒绝前导 `-`、空白、控制字符和 shell 元字符；tmux 会话名限制为
  1–64 个安全字符。
- Windows 版不保存 SSH 密码。使用 OpenSSH 私钥、配置和 Windows ssh-agent。
- 剪贴板桥接仅在对应 SSH 控制台位于前台时响应，不监控其他按键或窗口。图片使用临时
  本地 PNG，传输结束即删除；上传使用 `BatchMode=yes`，不会在隐藏窗口索取密码。
- OSC 52 只允许远端写入本地剪贴板，不允许远端读取；终端仍可在设置中禁用 OSC 52。
- 当前每次操作建立独立 SSH 连接，不依赖 ControlMaster。
- 用户的 SSH config 是受信任的 OpenSSH 配置边界；其中的 `ProxyCommand`、
  `Match exec` 等规则可能启动用户配置的本地程序。
- 当前版本不提供本机 shell、本机 tmux 或内嵌 PTY。
- 后台 Slurm 刷新需要 SSH key / ssh-agent 能够非交互登录；需要密码时先用 SSH Shell
  完成登录配置。
