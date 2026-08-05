<#
Codex CLI 一键部署脚本（Windows PowerShell 5.1+ / PowerShell 7+）

参数优先级: 环境变量 > 交互输入 > 默认值
#>

[CmdletBinding()]
param(
    [Alias('h')]
    [switch]$Help,

    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$exitCode = 0
$CODEX_API_KEY = $null

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
    throw [System.InvalidOperationException]::new($Message)
}

function Show-Usage {
    Write-Host @'
用法: powershell -ExecutionPolicy Bypass -File deploy-codex.ps1 [选项]

选项:
  -h, -Help          显示本帮助
  -NonInteractive   强制使用非交互模式

参数通过环境变量传入(优先级: 环境变量 > 交互输入 > 默认值):
  CODEX_API_KEY          必填, API Key
  CODEX_BASE_URL         必填, API 代理地址
  CODEX_MODEL            模型名, 默认 gpt-5.5
  CODEX_REVIEW_MODEL     审查模型, 默认 gpt-5.5
  CODEX_REASONING_EFFORT 推理强度, 默认 xhigh
  CODEX_WIRE_API         responses / chat, 默认 responses
  NPM_REGISTRY           npm 镜像源, 如 https://registry.npmmirror.com
'@
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

        if ($Secret) {
            $secureValue = Read-Host "$Message$hint (输入不回显)" -AsSecureString
            try {
                $value = ConvertFrom-SecureInput -SecureValue $secureValue
            }
            finally {
                $secureValue.Dispose()
            }
        }
        else {
            $value = Read-Host "$Message$hint"
            if ([string]::IsNullOrEmpty($value)) {
                $value = $DefaultValue
            }
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
    [IO.File]::WriteAllText($Path, $Content, $encoding)
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

    $currentUserRule = [Security.AccessControl.FileSystemAccessRule]::new(
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

try {
    if ($Help) {
        Show-Usage
        exit 0
    }

    $defaultModel = 'gpt-5.5'
    $defaultReviewModel = 'gpt-5.5'
    $defaultReasoningEffort = 'xhigh'
    $defaultWireApi = 'responses'

    if ([string]::IsNullOrEmpty($env:USERPROFILE)) {
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

    $codexDir = Join-Path $env:USERPROFILE '.codex'
    $configPath = Join-Path $codexDir 'config.toml'
    $authPath = Join-Path $codexDir 'auth.json'

    $stdinIsRedirected = $true
    try {
        $stdinIsRedirected = [Console]::IsInputRedirected
    }
    catch {
        $stdinIsRedirected = $true
    }
    $hostWasStartedNonInteractive = [Environment]::CommandLine -match '(?i)(?:^|\s)-(?:NonInteractive|noni)(?:\s|$)'
    $isInteractive = (-not $stdinIsRedirected) -and (-not $NonInteractive) -and (-not $hostWasStartedNonInteractive)

    Write-Host
    Write-Info '=========== Codex 配置参数 ==========='
    $CODEX_API_KEY = Get-DeploymentParameter -Name 'CODEX_API_KEY' -Message '  API Key (OPENAI_API_KEY)' -Secret -IsInteractive $isInteractive
    $CODEX_BASE_URL = Get-DeploymentParameter -Name 'CODEX_BASE_URL' -Message '  代理地址 (base_url)' -IsInteractive $isInteractive
    $CODEX_MODEL = Get-DeploymentParameter -Name 'CODEX_MODEL' -Message '  模型 (model)' -DefaultValue $defaultModel -IsInteractive $isInteractive
    $CODEX_REVIEW_MODEL = Get-DeploymentParameter -Name 'CODEX_REVIEW_MODEL' -Message '  审查模型 (review_model)' -DefaultValue $defaultReviewModel -IsInteractive $isInteractive
    $CODEX_REASONING_EFFORT = Get-DeploymentParameter -Name 'CODEX_REASONING_EFFORT' -Message '  推理强度 (reasoning_effort)' -DefaultValue $defaultReasoningEffort -IsInteractive $isInteractive
    $CODEX_WIRE_API = Get-DeploymentParameter -Name 'CODEX_WIRE_API' -Message '  wire_api (responses/chat)' -DefaultValue $defaultWireApi -IsInteractive $isInteractive
    $NPM_REGISTRY = [Environment]::GetEnvironmentVariable('NPM_REGISTRY', 'Process')
    if ($null -eq $NPM_REGISTRY) {
        $NPM_REGISTRY = ''
    }

    if ($CODEX_WIRE_API -cnotmatch '^(responses|chat)$') {
        Stop-Deployment "wire_api 仅支持 responses 或 chat, 当前值: $CODEX_WIRE_API"
    }
    if ($CODEX_BASE_URL -cnotmatch '^https?://') {
        Stop-Deployment "base_url 必须是 http(s):// 开头的地址, 当前值: $(Get-MaskedUrl -Url $CODEX_BASE_URL)"
    }
    if ($CODEX_API_KEY -cnotmatch '^sk-') {
        Write-Warn 'API Key 不以 sk- 开头, 请确认是否为有效密钥'
    }

    Write-Host
    Write-Info '配置摘要:'
    Write-Host "  目标用户    : $targetUser"
    Write-Host "  API Key     : $(Get-MaskedKey -Key $CODEX_API_KEY)"
    Write-Host "  base_url    : $(Get-MaskedUrl -Url $CODEX_BASE_URL)"
    Write-Host "  model       : $CODEX_MODEL"
    Write-Host "  review_model: $CODEX_REVIEW_MODEL"
    Write-Host "  effort      : $CODEX_REASONING_EFFORT"
    Write-Host "  wire_api    : $CODEX_WIRE_API"
    if (-not [string]::IsNullOrEmpty($NPM_REGISTRY)) {
        Write-Host "  npm 镜像    : $NPM_REGISTRY"
    }
    Write-Host

    if ($isInteractive) {
        $confirmation = Read-Host '确认以上配置并开始部署? [Y/n]'
        if ([string]::IsNullOrEmpty($confirmation)) {
            $confirmation = 'Y'
        }
        if ($confirmation -cnotmatch '^[Yy]$') {
            Stop-Deployment '用户取消部署'
        }
    }

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
        $backupPrefix = (Split-Path -Leaf $codexDir) + '.bak.*'
        $oldBackups = @(Get-ChildItem -LiteralPath $backupParent -Directory | Where-Object { $_.Name -like $backupPrefix } | Sort-Object Name -Descending | Select-Object -Skip 5)
        foreach ($oldBackup in $oldBackups) {
            Remove-Item -LiteralPath $oldBackup.FullName -Recurse -Force
        }
    }

    $escapedModel = ConvertTo-ConfigString -Value $CODEX_MODEL
    $escapedReviewModel = ConvertTo-ConfigString -Value $CODEX_REVIEW_MODEL
    $escapedReasoningEffort = ConvertTo-ConfigString -Value $CODEX_REASONING_EFFORT
    $escapedBaseUrl = ConvertTo-ConfigString -Value $CODEX_BASE_URL
    $escapedWireApi = ConvertTo-ConfigString -Value $CODEX_WIRE_API
    $escapedApiKey = ConvertTo-ConfigString -Value $CODEX_API_KEY

    $configContent = @"
model_provider = "OpenAI"
model = "$escapedModel"
review_model = "$escapedReviewModel"
model_reasoning_effort = "$escapedReasoningEffort"
disable_response_storage = true
network_access = "enabled"

[model_providers.OpenAI]
name = "OpenAI"
base_url = "$escapedBaseUrl"
wire_api = "$escapedWireApi"
requires_openai_auth = true

[features]
goals = true
"@
    $authContent = @"
{
  "OPENAI_API_KEY": "$escapedApiKey"
}
"@

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        Write-Utf8NoBomFile -Path $configPath -Content ''
    }
    if (-not (Test-Path -LiteralPath $authPath -PathType Leaf)) {
        Write-Utf8NoBomFile -Path $authPath -Content ''
    }
    Protect-FileForCurrentUser -Path $configPath
    Protect-FileForCurrentUser -Path $authPath
    Write-Utf8NoBomFile -Path $configPath -Content $configContent
    Write-Utf8NoBomFile -Path $authPath -Content $authContent
    Protect-FileForCurrentUser -Path $configPath
    Protect-FileForCurrentUser -Path $authPath
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
    if ($null -eq $codexCommand) {
        Stop-Deployment 'codex 未在 PATH 中, 请检查 npm 全局 bin 目录'
    }
    $codexPath = $codexCommand.Source

    Write-Host
    Write-Ok '============ 部署完成 ============'
    Write-Host "  用户 : $targetUser"
    Write-Host "  命令 : $codexPath"
    Write-Host "  配置 : $configPath"
    Write-Host "  密钥 : $authPath"
    Write-Host
    Write-Host '  直接运行:  codex'
    Write-Host '=================================='
}
catch {
    $exitCode = 1
    Write-Fail $_.Exception.Message
}
finally {
    $CODEX_API_KEY = $null
    $escapedApiKey = $null
    $authContent = $null
}

exit $exitCode

<#
运行方式:
  1. 交互式:
     powershell -ExecutionPolicy Bypass -File deploy-codex.ps1

  2. 非交互式（环境变量 + 管道）:
     $env:CODEX_API_KEY="sk-xxxx"; $env:CODEX_BASE_URL="https://your.proxy"; "" | powershell -NonInteractive -ExecutionPolicy Bypass -File deploy-codex.ps1
#>
