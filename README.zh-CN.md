# AI CLI Orchestrator

AI CLI Orchestrator（`aiw`）是一个通用的 Windows PowerShell 调度器：
它把受支持的本地 AI CLI 定义成有边界、可命名的 worker；Codex 或人工
始终负责划定任务边界、审查改动和最终验收。

AIW 不保存任何 provider 凭据。每个 CLI 继续使用自己的原生登录或凭据
存储。

## 为什么使用 AIW

每个人购买的套餐、账号和模型偏好都不一样，因此 AIW 不内置统一的
provider 顺序，也不会读取提示词后自动猜任务类型。你需要显式定义
worker，把它们组成有序 profile，再把具体 task route 映射到能力要求。
能力检查始终优先于 profile 顺序。

维护者自己的套餐组合仅保留为可选
[showcase](https://github.com/Zhi-Chao-PAN/ai-cli-orchestrator/blob/main/examples/showcases/README.md)，不会被安装或默认选中。

## 环境要求

- Windows PowerShell 5.1 或 PowerShell 7
- 至少一个由 adapter catalog 支持、且已独立安装和登录的 CLI
- 写入任务建议使用 Git worktree 隔离

## 安装

~~~powershell
Set-Location path\to\ai-cli-orchestrator
.\install.ps1 -AddToPath -InstallCodexSkill
~~~

修改用户 `PATH` 后需要重开终端。不修改 `PATH` 时可直接调用：

~~~powershell
& (Join-Path $env:LOCALAPPDATA 'aiw\bin\aiw.ps1') catalog -Json
~~~

全新的 v0.3 安装不会复制任何个人配置；升级会保留已有的 schema v1 或
v2 用户配置。

确认安装目标后，可使用以下命令升级已有的 AIW 安装：

~~~powershell
.\install.ps1 -Force -AddToPath -InstallCodexSkill
~~~

`-Force` 仅接受带有有效 AIW ownership marker 的现有安装。升级会保留
`$env:USERPROFILE\.aiw\config.json`；若需要替换非 AIW 管理的 Codex skill，
安装器会先创建带时间戳的备份。

## 从通用配置开始

先查看本版本内置的已审查 adapter；该命令不会调用模型服务：

~~~powershell
aiw catalog -Json
~~~

创建一个显式、默认拒绝的 v2 配置，再只加入你实际使用的 worker：

~~~powershell
$configDirectory = Join-Path $env:USERPROFILE '.aiw'
New-Item -ItemType Directory -Force $configDirectory
Copy-Item .\config.example.json (Join-Path $configDirectory 'config.json')

aiw config -Action validate -ConfigPath (Join-Path $configDirectory 'config.json') -Json
~~~

`config.example.json` 故意把 `workers`、`profiles` 和 `routes` 留空。
[`examples/profiles/supported-clis.example.json`](https://github.com/Zhi-Chao-PAN/ai-cli-orchestrator/blob/main/examples/profiles/supported-clis.example.json)
提供了三个 adapter 互相独立的单 worker 示例；只复制符合本机环境的定义，
并替换模型占位值。

完成配置后，可显式选择 worker、profile 或 route：

~~~powershell
aiw run -Worker  '<worker-id>'  -PromptFile 'C:\work\task.md' -Mode read -WorkingDirectory 'C:\repo' -Json
aiw run -Profile '<profile-id>' -PromptFile 'C:\work\task.md' -Mode read -WorkingDirectory 'C:\repo' -Json
aiw run -Route   '<route-id>'   -PromptFile 'C:\work\task.md' -WorkingDirectory 'C:\repo' -Json
~~~

复杂或多行任务统一使用 UTF-8 `PromptFile`。可从
[WORK_ORDER_TEMPLATE.md](WORK_ORDER_TEMPLATE.md) 开始，明确目标、允许范围、
禁止项和验收命令。

## 四个核心概念

| 概念 | 含义 |
| --- | --- |
| Adapter | 随 AIW 版本发布并经过审查的实现代码，负责把稳定请求翻译成某个 CLI 的调用。JSON 不能定义 adapter 或 shell 命令。 |
| Worker | 某个 adapter 的具名本地实例，包含模型、可执行文件路径、原生 profile 引用和能力子集。 |
| Profile | 有序 worker ID 列表及受限的只读 fallback 策略。顺序由用户决定，不属于 AIW 默认值。 |
| Route | 显式任务类别，引用一个 profile，并声明所需能力和允许模式。Route 不进行提示词分类。 |

模型属于 worker 定义，而不是 `run` 参数。这样同一个 CLI 的不同账号或模型
可以分别命名和复现。

## 已审查的 adapter catalog

| Adapter ID | CLI | 最大已审查能力 | 提示词传输 | 官方依据 |
| --- | --- | --- | --- | --- |
| `claude-code/v1` | Claude Code，以及通过隔离原生 Claude profile 接入的兼容端点 | `text.reason`、`workspace.read`、`workspace.write` | 标准输入 | [Claude Code CLI 参考](https://code.claude.com/docs/en/cli-usage) |
| `antigravity/v1` | Google Antigravity CLI（`agy`） | `text.reason`、`context.long`、`workspace.read`、`workspace.write` | 受控临时文件 | [Antigravity CLI 文档](https://www.antigravity.google/docs/cli/using) |
| `minimax-cli/v1` | MiniMax CLI（`mmx`） | `text.reason`、`quota.read` | 受控临时 JSON 文件 | [MiniMax CLI 指南](https://platform.minimaxi.com/docs/token-plan/minimax-cli) |

这些链接描述上游 CLI；本仓库的 adapter 代码与测试才定义 AIW 支持的调用
面。新增 provider 必须随版本提交并审查 source adapter。配置文件不能提供
命令、参数模板、脚本、hook、任意环境变量表或远程 adapter URL。

v2 只允许少量 adapter 专用设置：

- `claude-code/v1`：可选 `configDirectory`，指向可信的原生 profile；
- `antigravity/v1`：不开放配置目录覆盖；AIW 始终启用原生 sandbox，且只
  注册规范化 workspace 与受控工作单目录；
- `minimax-cli/v1`：必须设置 `region`（`cn` 或 `global`），可选
  `configDirectory` 并映射为 `MMX_CONFIG_DIR`。区域会映射到代码内固定端点，
  配置不能提交任意 URL。

MiniMax adapter 没有已审查的 workspace 能力，不能满足仓库读取或写入
route。

### 输出解码与诊断

AIW 把 worker stdout 视为不可信负载：有效 JSON stdout 会被解码为结构化
`output`，否则保留为原始 stdout 文本。Claude Code 与 MiniMax adapter 会向原生
CLI 请求 JSON 输出；Antigravity 请求文本输出。这些请求不是“只能是 JSON”的协议
要求，stdout 不是有效 JSON 时不会被转成协议失败。

AIW 不会把 stderr 当作 provider 输出解析，也不会在结果 envelope 中公开 provider
stderr。worker 写入 stderr 时，公开 `diagnostics` 只会给出通用的“已隐藏”提示；
自动化应依赖结构化的 `failureKind`、`error` 与 attempt 元数据，而不是 provider
诊断原文。

## 配置 schema v2

中性配置形状如下：

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

`defaultRoute` 和 `defaultProfile` 最多设置一个。既没有显式 selector，也
没有配置默认值时，`run` 返回 `SELECTION_REQUIRED`，不会暗中采用某个
provider 顺序。

配置查找顺序为显式 `-ConfigPath`、`AIW_CONFIG_PATH`、用户级 AIW 路径。
AIW 绝不会自动加载仓库内配置。显式配置中的相对路径以配置文件所在目录为
基准。任何显式 v2 配置（包括空 inventory）都会关闭隐式 worker discovery。
无配置时的 discovery 只在内存中进行，不写文件、不调用模型，也不会虚构
凭据、模型、profile、route 或优先级。

`catalog` 与 schema-2 inventory 不要求预先配置。没有配置时，`status -OutputSchema 2`
与 `doctor -OutputSchema 2` 可以报告 `PATH` 上发现的已审查
可执行文件，但不会选择默认 worker、profile、route、模型或 MiniMax region。只有
当已发现 worker 的已审查能力足够时才可显式选择它；profile、route 与 MiniMax
通用执行都需要显式 v2 配置。

每次投入使用前都应验证：

~~~powershell
aiw config -Action validate -ConfigPath 'C:\path\to\config.json' -Json
~~~

校验器会拒绝未知字段、疑似密钥字段、命令/参数字段、能力越权、未知
adapter、失效引用、不安全 launcher、任意端点、超限配置，以及默认写入的
route。AIW 配置中绝不能放 Key、Token、Cookie、密码或 Authorization 值。

Schema-2 inventory 与 doctor 是本地探针，不是认证或服务可用性检查。对于已配置
worker，`doctor -OutputSchema 2` 会解析已审查 executable；当 adapter 支持
`configDirectory` 时，它只检查该原生 profile 目录是否存在。它不会打开 profile
文件、运行 hook、检查凭据或联系 provider。被选择但不存在的 profile 会在启动
provider 前以 `PROFILE_DIRECTORY_INVALID` 失败；若所有已启用的已配置 worker 都
不可用，doctor 使用 `CONFIGURED_WORKERS_UNAVAILABLE`。

## 选择与 fallback

解析过程完全确定：

1. 解析显式 worker、profile、route 或配置默认值；
2. 合并 route、mode 和调用方追加的能力要求；
3. 排除禁用、不可用、launcher 不兼容或能力不足的 worker；
4. 保留剩余 worker 的 profile 顺序，并共享一个总超时预算。

`read` 是副作用上限，不等于隐式请求 `workspace.read`。纯推理 route 可以只
要求 `text.reason`；仓库 route 必须显式要求 `workspace.read`。即使 route
允许写入，调用方仍必须显式传入 `-Mode write`。

Fallback 被严格限制：

- `-Worker` 与 `-NoFallback` 不会跨 worker；
- 只有 profile 的只读 fallback allowlist 中列出的失败类型才可能继续；
- 权限拒绝、策略/配置/能力错误、不安全 launcher 与 wrapper 错误永不
  fallback；
- timeout fallback 必须显式允许，只能用于只读，并且要求进程树已确认终止、
  总预算仍有剩余；
- 任意写 worker 一旦启动，就不会启动第二个 worker。

能力不匹配产生的是静态 skip，不计为 attempt；schema v2 结果会保留这些
记录，便于审计选择过程。

## 安全与信任边界

- schema-v2 工作单最大 1 MiB，调用方只能进一步收紧；legacy facade 仅为
  v0.2 参数兼容保留历史 16 MiB 范围；
- 提示词正文不会进入 provider argv 或任意环境变量；
- `.exe` 和 `.ps1` 使用固定路径与参数数组；普通 `.cmd`/`.bat` 默认拒绝，
  仅精确匹配已审查的 MiniMax npm shim 例外，其提示词仍保留在临时文件；
- stdout 与 stderr 分开；有效 JSON stdout 成为结构化输出，其他 stdout 保留为
  原始文本。provider stderr 既不解析也不公开，非空 stderr 只会产生通用的已隐藏
  诊断；
- 每条输出流上限为 16 MiB；超时或输出溢出都会终止 Windows 进程树并返回结构化
  证据。溢出时 v2 返回 `output_limit`、`error.code: OUTPUT_LIMIT`、
  `outputLimitExceeded: true`、退出码 `1`，且不保留 provider 捕获输出；
- 临时目录随机命名、检查 AIW namespace，并在使用后清理；
- 如果执行后的环境恢复或临时文件清理失败，`attempts` 仍保留真实 child 退出码，
  同时返回 `cleanupFailed: true` 与 `wrapper_error`，且绝不触发 fallback；
- 不能把权限绕过或全局文件授权当成修复手段。

用户级 AIW 配置、用户 `PATH`、已安装 provider binary 和 provider 原生
profile 都属于可信本地依赖。原生 profile 可能包含以用户权限执行的 hook
或 plugin；AIW 不声称能隔离恶意 profile，也不对被替换的同名 binary 做
完整性证明。因此应通过 inventory/doctor 输出检查最终路径与来源。

并发写 worker 必须使用不同 Git worktree。尚未检查当前工作区前，不能把
部分写入交给另一个模型继续。

完整安全边界与漏洞报告方式见 [SECURITY.md](SECURITY.md)。

## 结果契约

新命令 `run`、`catalog`、`config` 使用 schema v2 envelope，稳定记录
selection、attempt、skip、timeout、failure、output 和 diagnostics。常见执行
失败类型包括 `permission_denied`、`authentication`、
`quota_or_rate_limit`、`process_exit`、`timeout`、
`stream_drain_timeout`、`output_limit` 和 `wrapper_error`。

所有公开 schema-v2 结果都包含顶层 `productVersion`，其唯一来源是仓库根目录的
`version.json`。schema-v1 兼容 envelope 保持不变，不增加该字段。

退出码：成功为 `0`；已启动 worker 的最终失败为 `1`；请求、配置、选择或
preflight 错误为 `2`；最终进程超时为 `124`；输出流排空超时为 `125`。
`output_limit` 属于已启动 worker 的失败，因此公开退出码为 `1`。provider 子进程
退出码保留在 attempt 中。Worker 自报成功只是传输证据，不是最终验收。

## v0.2 兼容与迁移

旧的 `status`、`doctor`、`ark`、`agent`、`google`、`minimax`、`quota`
命令及 schema v1 envelope 在 v0.3 中继续支持，且没有移除日期。历史默认值
只存在于兼容 facade，不是 v2 路由默认值。

v0.3 对旧结果有一项刻意的安全加固：原始 provider stderr 会替换为通用的“已隐藏”
诊断，避免 work order 或类似凭据的回显通过 schema-v1 diagnostics 泄露。除此之外，
旧 envelope 结构、默认值、命令行为和退出行为都由 golden 测试保持兼容。

schema v1 配置仍可由该兼容 facade 使用。通用 `run` 与 schema-2 的
route/profile 选择不会在内存中静默归一化 v1 文件：必须先显式迁移。带
`-OutputSchema 2` 的 `status` 或 `doctor` 会报告 legacy provenance 与迁移提示，
但不会改写源文件或虚构 v2 worker。

把 v1 转成可编辑的 v2 新文件：

~~~powershell
aiw config -Action migrate `
  -ConfigPath 'C:\path\to\v1-config.json' `
  -Destination 'C:\path\to\new-v2-config.json' `
  -Json
~~~

目标文件已存在时迁移会失败；迁移不写入凭据、不改源文件，也不会静默修改
现有安装。完成后先验证并检查生成的 worker，再按自己的方案添加 profile
和 route。

## 可选维护者 showcase

[`examples/showcases/maintainer-paid-plans.example.json`](https://github.com/Zhi-Chao-PAN/ai-cli-orchestrator/blob/main/examples/showcases/maintainer-paid-plans.example.json)
记录了某位维护者的 Google → MiniMax → 方舟 Coding → 方舟 Agent →
DeepSeek 按量方案。它只是展示数据，不是推荐或默认值。仓库 route 仍会因
MiniMax 缺少 workspace 能力而跳过它；两个方舟 Coding worker 展示了如何
把模型优先级变成 profile 数据。

Showcase 中的方舟与 DeepSeek worker 依赖隔离的 Claude Code 原生 profile。
请以 provider 当前官方接入文档为准，例如
[火山方舟](https://console.volcengine.com/ark/region:cn-beijing/docs/82379/1928261?lang=zh)
与 [DeepSeek Anthropic API 指南](https://api-docs.deepseek.com/guides/anthropic_api/)。
凭据和端点 URL 不能复制到 AIW JSON。套餐、模型与配额可能变化，套用前必须
逐项检查。

## 验证、卸载与贡献

~~~powershell
.\tests\ai-workers.tests.ps1
.\ai-workers.ps1 catalog -Json
.\ai-workers.ps1 config -Action validate -ConfigPath .\config.example.json -Json
~~~

真实服务 smoke 之前必须先通过确定性测试。发布验收还包括 PowerShell 5.1
与 7，以及一个全新独立 Codex 任务：核对安装 hash、全局 skill discovery，
并执行一次有边界的只读调用，最终明确给出 `COLD_START_PASS` 或有证据的失败。

卸载器受安装 marker 保护，且默认保留用户配置：

~~~powershell
.\uninstall.ps1
~~~

只有确实需要删除时才使用 skill/config 删除开关。开发规范与 adapter 准入
要求见 [CONTRIBUTING.md](CONTRIBUTING.md)，安全报告见
[SECURITY.md](SECURITY.md)。许可证为 MIT，详见 [LICENSE](LICENSE)。
