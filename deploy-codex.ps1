<#
Codex CLI 一键部署脚本（Windows PowerShell 5.1+ / PowerShell 7+）
Version: 1.2.0

参数优先级: 环境变量 > 交互输入 > 默认值
与 deploy-codex.sh 对齐: auth 模式 / provider / 功能开关 / 配置保留 / restore / dry-run / uninstall
#>

[CmdletBinding()]
param(
    [Alias('h')]
    [switch]$Help,

    [Alias('V')]
    [switch]$Version,

    [Alias('r')]
    [switch]$Restore,

    [Alias('d')]
    [switch]$DryRun,

    [Alias('u')]
    [switch]$Uninstall,

    [switch]$NonInteractive
)

# 该脚本支持 irm <url> | iex。禁止在中止时直接 exit，以免关闭调用者的终端。
$script:ABORT_SENTINEL = '__DEPLOY_CODEX_ABORT__'
$script:SCRIPT_VERSION = '1.2.0'
$script:SCRIPT_URL = 'https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.ps1'
$script:INSTALL_CMD = "irm $($script:SCRIPT_URL) | iex"

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Blue
}

function Write-Ok {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Stop-Deployment {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Fail $Message
    throw $script:ABORT_SENTINEL
}

function Show-Usage {
    Write-Host @"
Codex CLI 一键部署脚本 v$($script:SCRIPT_VERSION)

一行命令安装并配置 (终端内可交互提问):
  $($script:INSTALL_CMD)
  或加环境变量完全非交互 (适合 CI):
  `$env:CODEX_API_KEY='sk-xxxx'; `$env:CODEX_BASE_URL='https://your.proxy'; $($script:INSTALL_CMD)

选项:
  -h, -Help           显示本帮助
  -V, -Version        显示脚本版本
  -r, -Restore        用最近一次备份恢复配置
  -d, -DryRun         只生成配置, 不安装 Node/npm/codex
  -u, -Uninstall      卸载: 移除配置目录、备份, 并尝试 npm uninstall -g
  -NonInteractive     强制使用非交互模式

参数通过环境变量传入(优先级: 环境变量 > 交互输入 > 默认值):
  CODEX_API_KEY / OPENAI_API_KEY  必填, API Key
  CODEX_BASE_URL                  必填, API 代理地址
  CODEX_MODEL                     模型名, 默认 gpt-5.5
  CODEX_REVIEW_MODEL              审查模型, 默认 gpt-5.5
  CODEX_REASONING_EFFORT          推理强度, 默认 xhigh
  CODEX_WIRE_API                  responses / chat, 默认 responses
  CODEX_PROVIDER                  model_provider 名称, 默认 OpenAI
  CODEX_AUTH_STYLE                api_key | bearer | both, 默认 api_key
  CODEX_GOALS                     features.goals, 默认 true
  CODEX_DISABLE_RESPONSE_STORAGE  默认 true
  CODEX_NETWORK_ACCESS            默认 enabled
  CODEX_HOME                      Codex 配置目录, 默认 %USERPROFILE%\.codex
  CODEX_PRESERVE_EXTRA            保留 plugins/marketplaces (1/0), 默认 1
  NPM_REGISTRY                    npm 镜像源, 如 https://registry.npmmirror.com
  KEEP_BACKUPS                    配置备份保留份数, 默认 5
  CODEX_UNINSTALL_CONFIRM         非交互卸载时设为 1 确认删除
"@
}

function ConvertFrom-SecureInput {
    param([Parameter(Mandatory = $true)][Security.SecureString]$SecureValue)

    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Read-DeploymentInput {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [switch]$Secret
    )

    try {
        if ($Secret) {
            $secureValue = Read-Host $Prompt -AsSecureString
            try {
                return ConvertFrom-SecureInput -SecureValue $secureValue
            }
            finally {
                if ($null -ne $secureValue) {
                    $secureValue.Dispose()
                }
            }
        }

        return Read-Host $Prompt
    }
    catch {
        Stop-Deployment '无法读取输入 (非交互环境), 已取消部署, 未修改任何文件'
    }
}

function Get-DeploymentParameter {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$DefaultValue = '',
        [switch]$Secret,
        [Parameter(Mandatory = $true)][bool]$IsInteractive
    )

    $environmentValue = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not [string]::IsNullOrEmpty($environmentValue)) {
        return $environmentValue
    }

    if ($IsInteractive) {
        $hint = ''
        if (-not [string]::IsNullOrEmpty($DefaultValue)) {
            $hint = " [默认: $DefaultValue]"
        }

        $value = Read-DeploymentInput -Prompt "$Message$hint$(if ($Secret) { ' (输入不回显)' } else { '' })" -Secret:$Secret
        if (-not $Secret -and [string]::IsNullOrEmpty($value)) {
            $value = $DefaultValue
        }

        if ([string]::IsNullOrEmpty($value) -and [string]::IsNullOrEmpty($DefaultValue)) {
            Stop-Deployment '必填项为空, 已取消部署'
        }
        return $value
    }

    if ([string]::IsNullOrEmpty($DefaultValue)) {
        Stop-Deployment "非交互模式且未设置环境变量 $Name, 请用 `$env:${Name}='...' 后运行 deploy-codex.ps1"
    }
    return $DefaultValue
}

function Confirm-ApiKey {
    param(
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [Parameter(Mandatory = $true)][bool]$IsInteractive
    )

    $validatedKey = $ApiKey
    if ($validatedKey -cmatch '"|`|\$') {
        Stop-Deployment 'API Key 不能包含双引号、反引号或 $ 字符, 已取消部署, 未修改任何文件'
    }

    if ($validatedKey -cnotmatch '^sk-') {
        Write-Warn 'API Key 未以 sk- 开头 (部分代理密钥格式不同)'
        if ($IsInteractive) {
            $confirm = Read-DeploymentInput -Prompt '  仍要继续? [y/N]'
            if ($confirm -cnotmatch '^[Yy]$') {
                Stop-Deployment '已取消部署 (未修改任何文件)'
            }
        }
        else {
            Write-Warn "非交互模式将继续使用非 sk- 前缀密钥: $(Get-MaskedKey -Key $validatedKey)"
        }
    }

    return $validatedKey
}

function Get-MaskedKey {
    param([Parameter(Mandatory = $true)][string]$Key)

    $visibleLength = [Math]::Min(8, $Key.Length)
    return $Key.Substring(0, $visibleLength) + '********'
}

function Get-MaskedUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    if ($Url -cmatch '^(https?://)([^/@:]+):[^/@]+@(.*)$') {
        return $Matches[1] + $Matches[2] + ':***@' + $Matches[3]
    }
    return $Url
}

function ConvertTo-ConfigString {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    return $Value.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace("`r", '\r').Replace("`t", '\t')
}

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Protect-FileForCurrentUser {
    param([Parameter(Mandatory = $true)][string]$Path)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity -or $null -eq $identity.User) {
        Stop-Deployment "无法获取当前用户身份, 无法设置文件权限: $Path"
    }

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleAll($rule)
    }

    $currentUserRule = New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList @(
        $identity.User,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($currentUserRule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-NodeVersionInfo {
    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $nodeCommand) {
        return $null
    }

    $versionText = (& $nodeCommand.Source --version 2>$null | Out-String).Trim()
    if ($versionText -cmatch '^v?([0-9]+)') {
        return [PSCustomObject]@{
            Text  = $versionText
            Major = [int]$Matches[1]
        }
    }

    return [PSCustomObject]@{
        Text  = $(if ([string]::IsNullOrEmpty($versionText)) { '未知' } else { $versionText })
        Major = 0
    }
}

function Install-NodeIfNeeded {
    $minimumMajor = 20
    $nodeVersion = Get-NodeVersionInfo
    if ($null -ne $nodeVersion -and $nodeVersion.Major -ge $minimumMajor) {
        Write-Ok "已安装 Node.js $($nodeVersion.Text), 跳过"
        return
    }

    if ($null -ne $nodeVersion) {
        Write-Warn "Node.js 版本过低 ($($nodeVersion.Text)), 将通过 winget 安装 Node.js LTS"
    }
    else {
        Write-Info '未找到 Node.js, 将通过 winget 安装 Node.js LTS...'
    }

    $wingetCommand = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -eq $wingetCommand) {
        Stop-Deployment '未找到 winget, 请先安装“应用安装程序”(App Installer), 或手动安装 Node.js 20+'
    }

    & $wingetCommand.Source install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Stop-Deployment "winget 安装 Node.js 失败, 退出代码: $LASTEXITCODE"
    }

    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $nodeVersion = Get-NodeVersionInfo
    if ($null -eq $nodeVersion) {
        Stop-Deployment 'Node.js 安装失败或尚未加入 PATH, 请重新打开 PowerShell 后重试'
    }
    if ($nodeVersion.Major -lt $minimumMajor) {
        Write-Warn "Node.js 版本仍低于 20 ($($nodeVersion.Text)), 将继续尝试部署"
    }
    else {
        Write-Ok "Node.js 安装完成: $($nodeVersion.Text)"
    }
}

function Test-GeneratedConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigTempPath,
        [Parameter(Mandatory = $true)][string]$AuthTempPath
    )

    try {
        $authRaw = Get-Content -LiteralPath $AuthTempPath -Raw -Encoding UTF8
        $parsedAuth = $authRaw | ConvertFrom-Json
        if ($null -eq $parsedAuth) {
            throw 'auth.json 解析结果为空'
        }

        $apiKeyProperty = $parsedAuth.PSObject.Properties['OPENAI_API_KEY']
        if ($null -eq $apiKeyProperty -or -not ($apiKeyProperty.Value -is [string]) -or [string]::IsNullOrEmpty($apiKeyProperty.Value)) {
            throw 'auth.json 缺少非空字符串 OPENAI_API_KEY'
        }

        $configRaw = Get-Content -LiteralPath $ConfigTempPath -Raw -Encoding UTF8
        $requiredPatterns = @(
            '(?m)^model_provider\s*=\s*".+"\s*$',
            '(?m)^model\s*=\s*".+"\s*$',
            '(?m)^network_access\s*=\s*".+"\s*$',
            '(?m)^\[model_providers\.[^\]]+\]\s*$'
        )
        foreach ($pattern in $requiredPatterns) {
            if ($configRaw -cnotmatch $pattern) {
                throw "config.toml 缺少预期配置项: $pattern"
            }
        }
    }
    catch {
        Remove-Item -LiteralPath $ConfigTempPath, $AuthTempPath -Force -ErrorAction SilentlyContinue
        Stop-Deployment "生成的配置校验失败, 原文件未被修改: $($_.Exception.Message)"
    }
}

function Write-CodexConfigurationAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$AuthPath,
        [Parameter(Mandatory = $true)][string]$ConfigContent,
        [Parameter(Mandatory = $true)][string]$AuthContent
    )

    $configTempPath = "$ConfigPath.tmp"
    $authTempPath = "$AuthPath.tmp"
    Remove-Item -LiteralPath $configTempPath, $authTempPath -Force -ErrorAction SilentlyContinue

    $configCommitted = $false
    try {
        Write-Utf8NoBomFile -Path $configTempPath -Content $ConfigContent
        Write-Utf8NoBomFile -Path $authTempPath -Content $AuthContent
        Protect-FileForCurrentUser -Path $configTempPath
        Protect-FileForCurrentUser -Path $authTempPath
        Test-GeneratedConfiguration -ConfigTempPath $configTempPath -AuthTempPath $authTempPath

        Move-Item -LiteralPath $configTempPath -Destination $ConfigPath -Force
        $configCommitted = $true
        Move-Item -LiteralPath $authTempPath -Destination $AuthPath -Force
    }
    catch {
        Remove-Item -LiteralPath $configTempPath, $authTempPath -Force -ErrorAction SilentlyContinue
        if ($_.Exception.Message -eq $script:ABORT_SENTINEL) {
            throw
        }
        if ($configCommitted) {
            Stop-Deployment "写入 auth.json 失败；config.toml 已替换，请从最新备份恢复: $($_.Exception.Message)"
        }
        Stop-Deployment "写入配置失败, 原文件未被修改: $($_.Exception.Message)"
    }

    Protect-FileForCurrentUser -Path $ConfigPath
    Protect-FileForCurrentUser -Path $AuthPath
}


function Get-EnvOrDefault {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$DefaultValue = ''
    )
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrEmpty($value)) {
        return $DefaultValue
    }
    return $value
}

function Get-PreservedExtraSections {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return ''
    }

    $lines = Get-Content -LiteralPath $ConfigPath -Encoding UTF8
    $keep = $false
    $buf = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -cmatch '^\[(plugins|marketplaces)') {
            $keep = $true
        }
        if ($keep) {
            [void]$buf.Add($line)
        }
    }
    return ($buf -join "`n")
}

function Restore-CodexBackup {
    param(
        [Parameter(Mandatory = $true)][string]$CodexDir,
        [Parameter(Mandatory = $true)][bool]$IsInteractive
    )

    $parent = Split-Path -Parent $CodexDir
    if ([string]::IsNullOrEmpty($parent)) { $parent = '.' }
    $prefix = (Split-Path -Leaf $CodexDir) + '.bak.'
    $backups = @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($prefix) } |
        Sort-Object LastWriteTime -Descending)

    if ($backups.Count -eq 0) {
        Stop-Deployment "未找到任何备份 ($CodexDir.bak.*), 无需恢复"
    }

    $latest = $backups[0]
    Write-Host
    Write-Info "将用以下备份恢复: $($latest.FullName)"
    if ($IsInteractive) {
        $confirm = Read-DeploymentInput -Prompt '确认恢复? [Y/n]'
        if ([string]::IsNullOrEmpty($confirm)) { $confirm = 'Y' }
        if ($confirm -cnotmatch '^[Yy]$') {
            Stop-Deployment '已取消恢复'
        }
    }

    if (-not (Test-Path -LiteralPath $CodexDir -PathType Container)) {
        New-Item -ItemType Directory -Path $CodexDir -Force | Out-Null
    }

    $srcConfig = Join-Path $latest.FullName 'config.toml'
    $srcAuth = Join-Path $latest.FullName 'auth.json'
    $dstConfig = Join-Path $CodexDir 'config.toml'
    $dstAuth = Join-Path $CodexDir 'auth.json'

    if (Test-Path -LiteralPath $srcConfig -PathType Leaf) {
        Copy-Item -LiteralPath $srcConfig -Destination $dstConfig -Force
        Protect-FileForCurrentUser -Path $dstConfig
    }
    if (Test-Path -LiteralPath $srcAuth -PathType Leaf) {
        Copy-Item -LiteralPath $srcAuth -Destination $dstAuth -Force
        Protect-FileForCurrentUser -Path $dstAuth
    }

    Write-Ok "已从 $($latest.FullName) 恢复配置"
}


function Uninstall-CodexDeployment {
    param(
        [Parameter(Mandatory = $true)][string]$CodexDir,
        [Parameter(Mandatory = $true)][bool]$IsInteractive
    )

    Write-Host
    Write-Info '=========== 卸载 Codex 部署 ==========='
    Write-Host "  配置目录 : $CodexDir"

    $parent = Split-Path -Parent $CodexDir
    if ([string]::IsNullOrEmpty($parent)) { $parent = '.' }
    $prefix = (Split-Path -Leaf $CodexDir) + '.bak.'
    $backups = @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($prefix) })
    Write-Host "  备份份数 : $($backups.Count)"

    $codexCmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -ne $codexCmd) {
        Write-Host "  codex    : $($codexCmd.Source)"
    }
    else {
        Write-Host '  codex    : (未在 PATH 中找到)'
    }
    Write-Host

    if ($IsInteractive) {
        $confirm = Read-DeploymentInput -Prompt '确认卸载? 将删除配置目录与备份, 并尝试 npm uninstall -g @openai/codex [y/N]'
        if ($confirm -cnotmatch '^[Yy]$') {
            Stop-Deployment '已取消卸载'
        }
    }
    else {
        $confirmEnv = [Environment]::GetEnvironmentVariable('CODEX_UNINSTALL_CONFIRM', 'Process')
        if ($confirmEnv -ne '1' -and $confirmEnv -ne 'yes') {
            Stop-Deployment '非交互卸载请设置 CODEX_UNINSTALL_CONFIRM=1'
        }
    }

    if (Test-Path -LiteralPath $CodexDir -PathType Container) {
        Remove-Item -LiteralPath $CodexDir -Recurse -Force
        Write-Ok "已删除 $CodexDir"
    }
    else {
        Write-Warn "配置目录不存在: $CodexDir"
    }

    foreach ($bak in $backups) {
        Remove-Item -LiteralPath $bak.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "已删除备份 $($bak.FullName)"
    }

    $npmCommand = Get-Command npm -ErrorAction SilentlyContinue
    if ($null -ne $npmCommand) {
        Write-Info '尝试 npm uninstall -g @openai/codex ...'
        $saved = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $null = & $npmCommand.Source @('uninstall', '-g', '@openai/codex') 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Ok '已卸载 npm 全局包 @openai/codex'
            }
            else {
                Write-Warn 'npm uninstall 失败或包未安装, 可手动执行: npm uninstall -g @openai/codex'
            }
        }
        finally {
            $ErrorActionPreference = $saved
        }
    }
    else {
        Write-Warn '未找到 npm, 跳过全局包卸载'
    }

    $codexCmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -ne $codexCmd) {
        Write-Warn "PATH 中仍能找到 codex: $($codexCmd.Source) (可能是其他安装方式, 请手动删除)"
    }

    Write-Host
    Write-Ok '============ 卸载完成 ============'
}

function Invoke-DeployCodexMain {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    $CODEX_API_KEY = $null
    $escapedApiKey = $null
    $authContent = $null

    try {
        if ($Help) {
            Show-Usage
            return
        }
        if ($Version) {
            Write-Host "deploy-codex $($script:SCRIPT_VERSION)"
            return
        }

        $defaultModel = 'gpt-5.5'
        $defaultReviewModel = 'gpt-5.5'
        $defaultReasoningEffort = 'xhigh'
        $defaultWireApi = 'responses'
        $defaultProvider = 'OpenAI'
        $defaultAuthStyle = 'api_key'
        $defaultGoals = 'true'
        $defaultDisableStorage = 'true'
        $defaultNetworkAccess = 'enabled'

        if ([string]::IsNullOrEmpty($env:CODEX_HOME) -and [string]::IsNullOrEmpty($env:USERPROFILE)) {
            Stop-Deployment '未找到 USERPROFILE, 无法确定当前用户的家目录'
        }

        $targetIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ($null -ne $targetIdentity -and -not [string]::IsNullOrEmpty($targetIdentity.Name)) {
            $targetUser = $targetIdentity.Name
        }
        elseif (-not [string]::IsNullOrEmpty($env:USERNAME)) {
            $targetUser = $env:USERNAME
        }
        else {
            Stop-Deployment '无法确定当前 Windows 用户'
        }

        $codexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
        $configPath = Join-Path $codexDir 'config.toml'
        $authPath = Join-Path $codexDir 'auth.json'

        $hostWasStartedNonInteractive = [Environment]::CommandLine -match '(?i)(?:^|\s)-(?:NonInteractive|NonI)(?:\s|$)'
        $isInteractive = (-not $NonInteractive) -and (-not $hostWasStartedNonInteractive)

        if ($Restore -and $Uninstall) {
            Stop-Deployment '不能同时指定 -Restore 与 -Uninstall'
        }
        if ($Restore -and $DryRun) {
            Stop-Deployment '不能同时指定 -Restore 与 -DryRun'
        }
        if ($Uninstall -and $DryRun) {
            Stop-Deployment '不能同时指定 -Uninstall 与 -DryRun'
        }

        if ($Restore) {
            Restore-CodexBackup -CodexDir $codexDir -IsInteractive $isInteractive
            return
        }
        if ($Uninstall) {
            Uninstall-CodexDeployment -CodexDir $codexDir -IsInteractive $isInteractive
            return
        }

        # OPENAI_API_KEY 作为 CODEX_API_KEY 别名
        if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('CODEX_API_KEY', 'Process')) -and
            -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'Process'))) {
            [Environment]::SetEnvironmentVariable('CODEX_API_KEY', $env:OPENAI_API_KEY, 'Process')
        }

        Write-Host
        Write-Info '=========== Codex 配置参数 ==========='
        $CODEX_API_KEY = Get-DeploymentParameter -Name 'CODEX_API_KEY' -Message '  API Key (OPENAI_API_KEY)' -Secret -IsInteractive $isInteractive
        $CODEX_BASE_URL = Get-DeploymentParameter -Name 'CODEX_BASE_URL' -Message '  代理地址 (base_url)' -IsInteractive $isInteractive
        $CODEX_MODEL = Get-DeploymentParameter -Name 'CODEX_MODEL' -Message '  模型 (model)' -DefaultValue $defaultModel -IsInteractive $isInteractive
        $CODEX_REVIEW_MODEL = Get-DeploymentParameter -Name 'CODEX_REVIEW_MODEL' -Message '  审查模型 (review_model)' -DefaultValue $defaultReviewModel -IsInteractive $isInteractive
        $CODEX_REASONING_EFFORT = Get-DeploymentParameter -Name 'CODEX_REASONING_EFFORT' -Message '  推理强度 (reasoning_effort)' -DefaultValue $defaultReasoningEffort -IsInteractive $isInteractive
        $CODEX_WIRE_API = Get-DeploymentParameter -Name 'CODEX_WIRE_API' -Message '  wire_api (responses/chat)' -DefaultValue $defaultWireApi -IsInteractive $isInteractive

        $CODEX_PROVIDER = Get-EnvOrDefault -Name 'CODEX_PROVIDER' -DefaultValue $defaultProvider
        $CODEX_AUTH_STYLE = Get-EnvOrDefault -Name 'CODEX_AUTH_STYLE' -DefaultValue $defaultAuthStyle
        $CODEX_GOALS = Get-EnvOrDefault -Name 'CODEX_GOALS' -DefaultValue $defaultGoals
        $CODEX_DISABLE_RESPONSE_STORAGE = Get-EnvOrDefault -Name 'CODEX_DISABLE_RESPONSE_STORAGE' -DefaultValue $defaultDisableStorage
        $CODEX_NETWORK_ACCESS = Get-EnvOrDefault -Name 'CODEX_NETWORK_ACCESS' -DefaultValue $defaultNetworkAccess
        $PRESERVE_EXTRA = Get-EnvOrDefault -Name 'CODEX_PRESERVE_EXTRA' -DefaultValue '1'
        $keepBackupsRaw = Get-EnvOrDefault -Name 'KEEP_BACKUPS' -DefaultValue '5'
        $keepBackups = 5
        [void][int]::TryParse($keepBackupsRaw, [ref]$keepBackups)
        if ($keepBackups -lt 1) { $keepBackups = 5 }

        if ($isInteractive) {
            $CODEX_PROVIDER = Get-DeploymentParameter -Name 'CODEX_PROVIDER' -Message '  provider 名称' -DefaultValue $CODEX_PROVIDER -IsInteractive $true
            $CODEX_AUTH_STYLE = Get-DeploymentParameter -Name 'CODEX_AUTH_STYLE' -Message '  auth 写入方式 (api_key/bearer/both)' -DefaultValue $CODEX_AUTH_STYLE -IsInteractive $true
        }

        $NPM_REGISTRY = [Environment]::GetEnvironmentVariable('NPM_REGISTRY', 'Process')
        if ($null -eq $NPM_REGISTRY) {
            $NPM_REGISTRY = ''
        }

        $CODEX_API_KEY = Confirm-ApiKey -ApiKey $CODEX_API_KEY -IsInteractive $isInteractive
        if ($CODEX_WIRE_API -cnotmatch '^(responses|chat)$') {
            Stop-Deployment "wire_api 仅支持 responses 或 chat, 当前值: $CODEX_WIRE_API"
        }
        if ($CODEX_BASE_URL -cnotmatch '^https?://') {
            Stop-Deployment "base_url 必须是 http(s):// 开头的地址, 当前值: $(Get-MaskedUrl -Url $CODEX_BASE_URL)"
        }
        if ($CODEX_AUTH_STYLE -cnotmatch '^(api_key|bearer|both)$') {
            Stop-Deployment "CODEX_AUTH_STYLE 仅支持 api_key / bearer / both, 当前值: $CODEX_AUTH_STYLE"
        }
        if ($CODEX_PROVIDER -cnotmatch '^[A-Za-z][A-Za-z0-9_-]*$') {
            Stop-Deployment "CODEX_PROVIDER 仅允许字母开头的 [A-Za-z0-9_-], 当前值: $CODEX_PROVIDER"
        }
        if ($CODEX_GOALS -cnotmatch '^(true|false)$') {
            Stop-Deployment "CODEX_GOALS 仅支持 true/false, 当前值: $CODEX_GOALS"
        }
        if ($CODEX_DISABLE_RESPONSE_STORAGE -cnotmatch '^(true|false)$') {
            Stop-Deployment "CODEX_DISABLE_RESPONSE_STORAGE 仅支持 true/false, 当前值: $CODEX_DISABLE_RESPONSE_STORAGE"
        }

        Write-Host
        Write-Info '配置摘要:'
        Write-Host "  目标用户    : $targetUser"
        Write-Host "  配置目录    : $codexDir"
        Write-Host "  API Key     : $(Get-MaskedKey -Key $CODEX_API_KEY)"
        Write-Host "  base_url    : $(Get-MaskedUrl -Url $CODEX_BASE_URL)"
        Write-Host "  model       : $CODEX_MODEL"
        Write-Host "  review_model: $CODEX_REVIEW_MODEL"
        Write-Host "  effort      : $CODEX_REASONING_EFFORT"
        Write-Host "  wire_api    : $CODEX_WIRE_API"
        Write-Host "  provider    : $CODEX_PROVIDER"
        Write-Host "  auth_style  : $CODEX_AUTH_STYLE"
        Write-Host "  goals       : $CODEX_GOALS"
        Write-Host "  no_storage  : $CODEX_DISABLE_RESPONSE_STORAGE"
        Write-Host "  network     : $CODEX_NETWORK_ACCESS"
        if (-not [string]::IsNullOrEmpty($NPM_REGISTRY)) {
            Write-Host "  npm 镜像    : $NPM_REGISTRY"
        }
        Write-Host

        if ($isInteractive) {
            $confirmPrompt = if ($DryRun) {
                '确认以上配置并仅写入配置文件 (dry-run)? [Y/n]'
            } else {
                '确认以上配置并开始部署? [Y/n]'
            }
            $confirmation = Read-DeploymentInput -Prompt $confirmPrompt
            if ([string]::IsNullOrEmpty($confirmation)) {
                $confirmation = 'Y'
            }
            if ($confirmation -cnotmatch '^[Yy]$') {
                Stop-Deployment '用户取消部署'
            }
        }

        if (-not $DryRun) {
        Install-NodeIfNeeded

        $npmCommand = Get-Command npm -ErrorAction SilentlyContinue
        if ($null -eq $npmCommand) {
            Stop-Deployment '未找到 npm, 请先安装 npm 或重新安装 Node.js'
        }

        Write-Info '通过 npm 全局安装 @openai/codex ...'
        $npmArguments = @('install', '-g', '--no-audit', '--no-fund', '@openai/codex')
        if (-not [string]::IsNullOrEmpty($NPM_REGISTRY)) {
            $npmArguments += "--registry=$NPM_REGISTRY"
        }

        $savedErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $npmOutput = @(& $npmCommand.Source @npmArguments 2>&1)
            $npmExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }
        if ($npmExitCode -ne 0) {
            foreach ($outputLine in $npmOutput) {
                Write-Host ([string]$outputLine) -ForegroundColor Red
            }
            Stop-Deployment 'npm 安装 codex 失败, 请检查网络/镜像源 (国内网络可设置 NPM_REGISTRY=https://registry.npmmirror.com)'
        }

        $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
        if ($null -eq $codexCommand) {
            Stop-Deployment 'codex 未在 PATH 中, 请检查 npm 全局 bin 目录'
        }
        $codexVersion = (& $codexCommand.Source --version 2>$null | Out-String).Trim()
        if ([string]::IsNullOrEmpty($codexVersion)) {
            $codexVersion = 'installed'
        }
        Write-Ok "Codex 安装完成: $codexVersion"
        }
        else {
            Write-Info 'dry-run: 跳过 Node / npm / codex 安装, 仅生成配置'
        }

        Write-Info "写入配置到 $codexDir ..."
        if (-not (Test-Path -LiteralPath $codexDir -PathType Container)) {
            New-Item -ItemType Directory -Path $codexDir -Force | Out-Null
        }

        if ((Test-Path -LiteralPath $configPath -PathType Leaf) -or (Test-Path -LiteralPath $authPath -PathType Leaf)) {
            $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
            $backupDir = "$codexDir.bak.$timestamp"
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            if (Test-Path -LiteralPath $configPath -PathType Leaf) {
                Copy-Item -LiteralPath $configPath -Destination $backupDir -Force
                Protect-FileForCurrentUser -Path (Join-Path $backupDir 'config.toml')
            }
            if (Test-Path -LiteralPath $authPath -PathType Leaf) {
                Copy-Item -LiteralPath $authPath -Destination $backupDir -Force
                Protect-FileForCurrentUser -Path (Join-Path $backupDir 'auth.json')
            }
            Write-Ok "已备份旧配置到 $backupDir"

            $backupParent = Split-Path -Parent $codexDir
            if ([string]::IsNullOrEmpty($backupParent)) {
                $backupParent = '.'
            }
            $backupPrefix = (Split-Path -Leaf $codexDir) + '.bak.*'
            $oldBackups = @(Get-ChildItem -LiteralPath $backupParent -Directory | Where-Object { $_.Name -like $backupPrefix } | Sort-Object Name -Descending | Select-Object -Skip $keepBackups)
            foreach ($oldBackup in $oldBackups) {
                Remove-Item -LiteralPath $oldBackup.FullName -Recurse -Force
            }
        }

        $preservedExtra = ''
        if ($PRESERVE_EXTRA -eq '1') {
            $preservedExtra = Get-PreservedExtraSections -ConfigPath $configPath
            if (-not [string]::IsNullOrEmpty($preservedExtra)) {
                Write-Info '将保留已有 plugins/marketplaces 配置段'
            }
        }

        $escapedModel = ConvertTo-ConfigString -Value $CODEX_MODEL
        $escapedReviewModel = ConvertTo-ConfigString -Value $CODEX_REVIEW_MODEL
        $escapedReasoningEffort = ConvertTo-ConfigString -Value $CODEX_REASONING_EFFORT
        $escapedBaseUrl = ConvertTo-ConfigString -Value $CODEX_BASE_URL
        $escapedWireApi = ConvertTo-ConfigString -Value $CODEX_WIRE_API
        $escapedApiKey = ConvertTo-ConfigString -Value $CODEX_API_KEY
        $escapedProvider = ConvertTo-ConfigString -Value $CODEX_PROVIDER
        $escapedNetwork = ConvertTo-ConfigString -Value $CODEX_NETWORK_ACCESS

        $configLines = New-Object System.Collections.Generic.List[string]
        [void]$configLines.Add("model_provider = `"$escapedProvider`"")
        [void]$configLines.Add("model = `"$escapedModel`"")
        [void]$configLines.Add("review_model = `"$escapedReviewModel`"")
        [void]$configLines.Add("model_reasoning_effort = `"$escapedReasoningEffort`"")
        [void]$configLines.Add("disable_response_storage = $CODEX_DISABLE_RESPONSE_STORAGE")
        [void]$configLines.Add("network_access = `"$escapedNetwork`"")
        [void]$configLines.Add('')
        [void]$configLines.Add("[model_providers.$escapedProvider]")
        [void]$configLines.Add("name = `"$escapedProvider`"")
        [void]$configLines.Add("base_url = `"$escapedBaseUrl`"")
        [void]$configLines.Add("wire_api = `"$escapedWireApi`"")
        [void]$configLines.Add('requires_openai_auth = true')
        if ($CODEX_AUTH_STYLE -eq 'bearer' -or $CODEX_AUTH_STYLE -eq 'both') {
            [void]$configLines.Add("experimental_bearer_token = `"$escapedApiKey`"")
        }
        [void]$configLines.Add('')
        [void]$configLines.Add('[features]')
        [void]$configLines.Add("goals = $CODEX_GOALS")
        if (-not [string]::IsNullOrEmpty($preservedExtra)) {
            [void]$configLines.Add('')
            [void]$configLines.Add('# --- preserved from previous config ---')
            foreach ($extraLine in ($preservedExtra -split "`n")) {
                [void]$configLines.Add($extraLine)
            }
        }
        $configContent = ($configLines -join "`n") + "`n"

        $authContent = @(
            '{',
            "  `"OPENAI_API_KEY`": `"$escapedApiKey`"",
            '}'
        ) -join "`n"
        $authContent += "`n"

        Write-CodexConfigurationAtomically -ConfigPath $configPath -AuthPath $authPath -ConfigContent $configContent -AuthContent $authContent
        Write-Ok '权限设置完成'

        Write-Info '配置预览(auth.json, 密钥已打码):'
        Write-Host '{'
        Write-Host "  `"OPENAI_API_KEY`": `"$(Get-MaskedKey -Key $CODEX_API_KEY)`""
        Write-Host '}'

        try {
            Invoke-WebRequest -Uri $CODEX_BASE_URL -Method Get -UseBasicParsing -TimeoutSec 8 | Out-Null
            Write-Ok "代理地址可达: $(Get-MaskedUrl -Url $CODEX_BASE_URL)"
        }
        catch {
            Write-Warn "代理地址探测无响应(可能是正常的): $(Get-MaskedUrl -Url $CODEX_BASE_URL)"
        }

        $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
        if (-not $DryRun) {
            if ($null -eq $codexCommand) {
                Stop-Deployment 'codex 未在 PATH 中, 请检查 npm 全局 bin 目录'
            }
        }
        $codexPath = if ($null -ne $codexCommand) { $codexCommand.Source } else { '(未安装)' }

        Write-Host
        if ($DryRun) {
            Write-Ok '============ dry-run 完成 (未安装软件包) ============'
            Write-Host "  版本 : deploy-codex v$($script:SCRIPT_VERSION)"
            Write-Host "  用户 : $targetUser"
            Write-Host "  配置 : $configPath"
            Write-Host "  密钥 : $authPath"
            Write-Host
            Write-Host '  正式部署请去掉 -DryRun 重新运行'
            Write-Host '  恢复备份 : deploy-codex.ps1 -Restore'
            Write-Host '  卸载清理 : deploy-codex.ps1 -Uninstall'
            Write-Host '===================================================='
        }
        else {
            Write-Ok '============ 部署完成 ============'
            Write-Host "  版本 : deploy-codex v$($script:SCRIPT_VERSION)"
            Write-Host "  用户 : $targetUser"
            Write-Host "  命令 : $codexPath"
            Write-Host "  配置 : $configPath"
            Write-Host "  密钥 : $authPath"
            Write-Host
            Write-Host '  直接运行:  codex'
            Write-Host '  恢复备份 : deploy-codex.ps1 -Restore'
            Write-Host '  卸载清理 : deploy-codex.ps1 -Uninstall'
            Write-Host '=================================='
        }
    }
    finally {
        $CODEX_API_KEY = $null
        $escapedApiKey = $null
        $authContent = $null
    }
}

# 入口调度器: 文件执行时返回退出码；irm | iex 时只返回，不关闭调用者终端。
try {
    Invoke-DeployCodexMain
    if (-not [string]::IsNullOrEmpty($PSCommandPath)) {
        exit 0
    }
    return
}
catch {
    if ($_.Exception.Message -ne $script:ABORT_SENTINEL) {
        throw
    }
    if (-not [string]::IsNullOrEmpty($PSCommandPath)) {
        exit 1
    }
    return
}

<#
运行方式 (一行命令, 终端内可交互提问):
  irm https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.ps1 | iex

或下载后运行:
  powershell -ExecutionPolicy Bypass -File deploy-codex.ps1
  pwsh -File deploy-codex.ps1 -Version
  pwsh -File deploy-codex.ps1 -DryRun
  pwsh -File deploy-codex.ps1 -Restore
  pwsh -File deploy-codex.ps1 -Uninstall

非交互式 (环境变量 + -NonInteractive):
  $env:CODEX_API_KEY="sk-xxxx"; $env:CODEX_BASE_URL="https://your.proxy"
  $env:CODEX_AUTH_STYLE="both"; $env:CODEX_PROVIDER="custom"
  powershell -NonInteractive -ExecutionPolicy Bypass -File deploy-codex.ps1
#>
