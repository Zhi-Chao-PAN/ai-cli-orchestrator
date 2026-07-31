<p align="center">
  <img src="https://raw.githubusercontent.com/Zhi-Chao-PAN/ai-cli-orchestrator/main/docs/assets/aiw-hero.svg" alt="AIW 把显式工作单路由到有边界的本地 AI CLI worker，并返回结构化证据" width="100%">
</p>

<h1 align="center">AI CLI Orchestrator</h1>

<p align="center">
  <strong>把你已经在用的 AI CLI，变成有边界、可审计的本地 worker。</strong><br>
  显式路由、原生登录、结构化证据——不接管密钥，也不把编排变成任意 Shell 执行。
</p>

<p align="center">
  <a href="https://github.com/Zhi-Chao-PAN/ai-cli-orchestrator/actions/workflows/ci.yml"><img src="https://github.com/Zhi-Chao-PAN/ai-cli-orchestrator/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI 状态"></a>
  <a href="https://github.com/Zhi-Chao-PAN/ai-cli-orchestrator/releases/latest"><img src="https://img.shields.io/github/v/release/Zhi-Chao-PAN/ai-cli-orchestrator?display_name=tag&amp;sort=semver" alt="最新版本"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Zhi-Chao-PAN/ai-cli-orchestrator" alt="MIT 许可证"></a>
  <img src="https://img.shields.io/badge/platform-Windows-0078D4?logo=windows11&amp;logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE?logo=powershell&amp;logoColor=white" alt="PowerShell 5.1 和 7">
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="#快速开始">快速开始</a> ·
  <a href="#工作原理">工作原理</a> ·
  <a href="#安全模型">安全模型</a> ·
  <a href="#文档导航">文档导航</a>
</p>

AI CLI Orchestrator（`aiw`）是一个面向人类和 Codex 等编排者的通用
Windows PowerShell 调度器。你可以把本地 CLI 实例定义为 **worker**，
把它们组织成有序 **profile**，再把显式任务 **route** 映射到能力要求。
AIW 不保存 provider 凭据；它的通用 schema-v2 执行面不内置隐藏的 provider
偏好。worker 报告成功只代表传输层证据；改动审查和最终验收仍由你或 Codex
负责。

## 为什么选择 AIW

如果你已经订阅了多个 AI CLI 套餐，真正困难的通常不是“有没有模型”，
而是如何稳定地利用它们，同时避免把电脑变成一堆 provider 专用脚本。

- **使用自己的 CLI。** 每个 provider 继续使用原生登录和 profile；AIW
  不保存密钥。
- **显式决定路由。** 先检查能力，再按你声明的 worker 顺序选择；不会暗中
  对提示词进行任务分类。
- **约束每次执行。** 共享总超时、受限输出流、受控临时文件和 Windows
  进程树终止共同约束每次调用。
- **保留结构化证据。** Schema v2 JSON 记录选择、跳过、尝试、失败和清理状态。

AIW 刻意**不做** API 代理、凭据保险箱、自动任务分类器或任意命令执行器。
Schema-v2 配置只能选择经过审查的 adapter，不能定义命令、参数模板、hook、
脚本、任意环境变量表或 provider endpoint。

## 快速开始

### 1. 安装

要求：Windows PowerShell 5.1 或 PowerShell 7、Git，以及至少一个由你独立
安装、独立登录的[受支持 CLI](#已审查的-adapter)。Git 也用于通过独立
worktree 隔离写入任务。

~~~powershell
$ErrorActionPreference = 'Stop'
$repoRoot = Join-Path (Get-Location) 'ai-cli-orchestrator'
if (Test-Path -LiteralPath $repoRoot) {
  throw "拒绝替换已有路径：$repoRoot"
}
git clone https://github.com/Zhi-Chao-PAN/ai-cli-orchestrator.git $repoRoot
if ($LASTEXITCODE -ne 0) {
  throw "git clone 失败，退出码：$LASTEXITCODE"
}
Set-Location -LiteralPath $repoRoot
.\install.ps1 -AddToPath -InstallCodexSkill

$aiwPath = Join-Path $env:LOCALAPPDATA 'aiw\bin\aiw.ps1'
& $aiwPath catalog -Json
~~~

`-AddToPath` 只影响新终端；本流程继续使用显式 `$aiwPath`，因此无需重启
即可完成。`catalog` 只是本地探针，不会联系模型服务。

### 2. 创建显式配置

全新安装默认拒绝执行：不会复制维护者配置，也不会虚构 provider 顺序。
从经过审查的示例开始，只保留你实际使用的 CLI：

~~~powershell
$repoRoot = (Resolve-Path '.').Path
$aiwPath = Join-Path $env:LOCALAPPDATA 'aiw\bin\aiw.ps1'
$configDirectory = Join-Path $env:USERPROFILE '.aiw'
$configPath = Join-Path $configDirectory 'config.json'
New-Item -ItemType Directory -Force $configDirectory | Out-Null
if (Test-Path -LiteralPath $configPath) {
  throw "拒绝覆盖已有配置：$configPath"
}
Copy-Item (Join-Path $repoRoot 'examples\profiles\supported-clis.example.json') $configPath
~~~

编辑复制后的文件，成组删除不使用的 worker/profile/route，并在需要时替换
模型占位值。首次运行前先验证：

~~~powershell
$aiwPath = Join-Path $env:LOCALAPPDATA 'aiw\bin\aiw.ps1'
$configPath = Join-Path $env:USERPROFILE '.aiw\config.json'
& $aiwPath config -Action validate -ConfigPath $configPath -Json
~~~

该示例包含彼此独立的 Claude Code、Google Antigravity 和 MiniMax worker，
但不设置默认选择。组合它们前请阅读
[profile 指南](https://github.com/Zhi-Chao-PAN/ai-cli-orchestrator/blob/main/examples/profiles/README.md)。

### 3. 派发有边界的工作单

所有非简单或多行任务都应使用 UTF-8 prompt 文件。仓库提供了
[工作单模板](WORK_ORDER_TEMPLATE.md)，用于明确目标、允许范围、禁止项和
验收命令。

把模板复制到仓库之外，编辑工作单，检查已配置的 worker ID，然后在最后一条
命令中替换 `<worker-id>`：

~~~powershell
$repoRoot = (Resolve-Path '.').Path
$aiwPath = Join-Path $env:LOCALAPPDATA 'aiw\bin\aiw.ps1'
$promptPath = Join-Path $env:TEMP 'aiw-work-order.md'
if (Test-Path -LiteralPath $promptPath) {
  throw "拒绝覆盖已有工作单：$promptPath"
}
Copy-Item (Join-Path $repoRoot 'WORK_ORDER_TEMPLATE.md') $promptPath
notepad.exe $promptPath

& $aiwPath status -OutputSchema 2 -Json
& $aiwPath run -Worker '<worker-id>' -PromptFile $promptPath -Mode read -WorkingDirectory $repoRoot -Json
~~~

每次调用只能选择一个 worker、profile 或 route。第一个 worker 验证健康后，
可参考
[profile 指南](https://github.com/Zhi-Chao-PAN/ai-cli-orchestrator/blob/main/examples/profiles/README.md)
把它组合为有序 profile 和显式 route。

如果既没有 selector，也没有配置默认项，`run` 会返回
`SELECTION_REQUIRED`，绝不会暗中选择某个 provider。

## 工作原理

~~~mermaid
flowchart TD
    A[人类或 Codex] -->|有边界的工作单| B[Route 与能力要求]
    B --> C[按 profile 顺序筛选 worker]
    C --> D[已审查 adapter 与原生 CLI]
    D --> E[Schema v2 结果]
~~~

| 概念 | 含义 |
| --- | --- |
| **Adapter** | 随 AIW 版本发布的版本化源代码，把稳定请求翻译为一次经过审查的 CLI 调用。 |
| **Worker** | 某个 adapter 的具名本地实例，包含模型、可执行文件路径、原生 profile 引用和能力子集。 |
| **Profile** | 由你声明的有序 worker 列表，以及范围很窄的只读 fallback 策略。顺序属于用户，不属于 AIW 默认值。 |
| **Route** | 显式任务类别，选择一个 profile，并声明所需能力和允许模式；route 不理解或分类提示词语义。 |

选择过程是确定性的：解析 selector，合并 route/mode 要求，排除不可用或
能力不匹配的 worker，保留剩余 profile 顺序，并在同一个总超时预算内运行。

`read` 是副作用上限，不等于隐式请求 `workspace.read`。写入始终需要显式
`-Mode write`。任何 write worker 启动后，AIW 都不会自动启动第二个 worker。

## 已审查的 adapter

**`claude-code/v1` — Claude Code**
最大已审查能力：`text.reason`、`workspace.read`、`workspace.write`；prompt
通过标准输入传输。兼容 endpoint 必须隔离在原生 Claude profile 中。
[官方 CLI 参考](https://code.claude.com/docs/en/cli-usage)。

**`antigravity/v1` — Google Antigravity CLI（`agy`）**
最大已审查能力：`text.reason`、`context.long`、`workspace.read`、
`workspace.write`；prompt 通过受控临时文件传输。
[官方文档](https://www.antigravity.google/docs/cli/using)。

**`minimax-cli/v1` — MiniMax CLI（`mmx`）**
最大已审查能力：`text.reason`、`quota.read`；prompt 通过受控临时 JSON
文件传输。[官方 CLI 指南](https://platform.minimaxi.com/docs/token-plan/minimax-cli)。

以上是 v0.3 已审查的执行面。“provider-neutral”并不表示“允许 JSON 运行
任意命令”。新增 provider 必须提交经过审查、带版本的 source adapter 和
确定性测试。MiniMax 当前没有已审查的 workspace 能力，因此不能满足仓库
读写 route。

维护者自己的 Google → MiniMax → 方舟 Coding → 方舟 Agent → DeepSeek 按量
策略仅作为可选
[showcase](https://github.com/Zhi-Chao-PAN/ai-cli-orchestrator/blob/main/examples/showcases/README.md)
保存，不会被安装，也不会成为默认选择。

## 安全模型

AIW 用于收紧编排风险，但不会声称自己能够隔离恶意本地 binary、原生
provider profile、hook 或 plugin；它们仍属于可信本地依赖。

- Provider 凭据继续保存在各 CLI 的原生存储中。AIW JSON 中绝不能放 key、
  token、cookie、密码或 authorization 值。
- Schema v2 只接受策略数据。未知字段、疑似密钥字段、命令、脚本、任意
  endpoint、能力越权和不安全 launcher 都会失败关闭。
- 非简单 prompt 通过 UTF-8 stdin 或 AIW 拥有的临时文件传输，不进入
  provider argv。Schema-v2 工作单上限为 1 MiB。
- stdout 与 stderr 始终分离。有效 JSON stdout 会成为结构化输出，其他
  stdout 保留为文本；provider stderr 不会出现在公开 diagnostics 中。
- 每条输出流上限为 16 MiB。溢出返回 `output_limit` / `OUTPUT_LIMIT`，
  终止 Windows 进程树，并且不公开已捕获的 provider 输出。
- 超时和 root 进程正常完成都会关闭受控进程树；临时文件与环境覆盖会被
  防护并清理。
- `doctor -OutputSchema 2` 只解析已批准 executable，并检查受支持的原生
  profile 目录是否存在；它不会打开 profile、检查凭据或 hook，也不证明
  真实登录可用。
- worker 自报成功绝不是最终验收。你仍需要检查文件、diff、测试和任务专用证据。

启用 write route 或第三方原生 profile 前，请先阅读完整的
[安全与信任边界](SECURITY.md)。

## 配置与兼容性

通用 v2 配置形状刻意保持精简：

~~~json
{
  "schemaVersion": 2,
  "defaultRoute": null,
  "defaultProfile": null,
  "workers": {},
  "profiles": {},
  "routes": {}
}
~~~

`defaultRoute` 和 `defaultProfile` 最多设置一个。配置查找顺序为显式
`-ConfigPath`、`AIW_CONFIG_PATH`、用户级 AIW 路径；仓库本地配置永远
不会被自动加载。

旧版 v0.2 alias（`status`、`doctor`、`ark`、`agent`、`google`、
`minimax`、`quota`）和 schema-v1 envelope 继续受支持。通用 v2 `run`
不会静默归一化 v1 文件。冻结的兼容层仍保留历史模型默认值、Ark fallback 和
旧 MiniMax endpoint 字段，但它们都不会成为通用 v2 默认值。v1 配置必须
显式、非破坏地迁移：

~~~powershell
aiw config -Action migrate `
  -ConfigPath 'C:\path\to\v1-config.json' `
  -Destination 'C:\path\to\new-v2-config.json' `
  -Json
~~~

迁移不会修改源文件，也不会覆盖已经存在的目标文件。

## 文档导航

| 你的需求 | 从这里开始 |
| --- | --- |
| 配置单个 CLI 或组合 profile | [Profile 示例](https://github.com/Zhi-Chao-PAN/ai-cli-orchestrator/blob/main/examples/profiles/README.md) |
| 借鉴维护者的付费套餐策略 | [可选 showcase](https://github.com/Zhi-Chao-PAN/ai-cli-orchestrator/blob/main/examples/showcases/README.md) |
| 编写有边界的任务 | [工作单模板](WORK_ORDER_TEMPLATE.md) |
| 查看精确的 v0.3 契约 | [通用编排规格](https://github.com/Zhi-Chao-PAN/ai-cli-orchestrator/blob/main/docs/specs/v0.3-generic-orchestration.md) |
| 理解信任边界或报告漏洞 | [安全策略](SECURITY.md) |
| 新增 adapter 或修改运行时 | [贡献指南](CONTRIBUTING.md) |
| 阅读英文首页 | [English](README.md) |

## 验证、升级与卸载

以下命令需要在源码 checkout 或 Release 解压目录中运行；它们不会被复制到
已安装的应用目录：

~~~powershell
# 确定性回归测试与安装生命周期测试
.\tests\ai-workers.tests.ps1
.\tests\install-lifecycle.tests.ps1

# 升级 AIW 管理的安装；保留已有用户配置
.\install.ps1 -Force -AddToPath -InstallCodexSkill

# 受 marker 保护的卸载；默认保留用户配置
.\uninstall.ps1
~~~

CI 会在 Windows PowerShell 5.1 与 PowerShell 7 下运行完整测试和疑似凭据
文本扫描。发布验收还要求在全新 Codex 任务中核对安装文件 hash、全局 skill
发现，并完成一次有边界的只读调用，最终明确给出 `COLD_START_PASS` 或有
证据支持的失败。

## 参与贡献

欢迎贡献经过审查的新 adapter、确定性滥用测试、更清晰的示例和文档改进。
提交 pull request 前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)；执行面修改
所需证据会比普通配置示例更严格。

如果 AIW 能帮助你利用已有 CLI 套餐，同时不隐藏路由决策、不削弱权限边界，
欢迎为仓库点一个 Star——这会帮助更多 Windows 智能体开发者发现它。

## 许可证

MIT，详见 [LICENSE](LICENSE)。
