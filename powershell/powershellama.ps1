<#
.SYNOPSIS
    PowerSheLLaMa - PowerShell + AI agent. Prefix with , to talk to the AI.
#>

$SHELLAMA_API = if ($env:SHELLAMA_API) { $env:SHELLAMA_API } elseif ($env:ANSIBLE_TOOLS_API) { $env:ANSIBLE_TOOLS_API } else { "http://192.168.1.229:5000" }
$SHELLAMA_MODEL = if ($env:SHELLAMA_MODEL) { $env:SHELLAMA_MODEL } elseif ($env:ANSIBLE_TOOLS_MODEL) { $env:ANSIBLE_TOOLS_MODEL } else { "auto" }
$SHELLAMA_API_KEY = if ($env:SHELLAMA_API_KEY) { $env:SHELLAMA_API_KEY } else { "" }
$SHELLAMA_CONV_ID = [guid]::NewGuid().ToString()
$TRIGGER = ","
$Quiet = $false
$MaxRounds = 10

# Session usage tracking
$script:SessionTokens = 0
$script:SessionRequests = 0
$script:SessionElapsed = 0.0
$script:LastOutput = ''

$CYAN = "`e[36m"
$YELLOW = "`e[33m"
$GRAY = "`e[90m"
$DIM = "`e[2m"
$RESET = "`e[0m"
$HAL = "🔴 "

$SystemPrompt = @"
You are an AI assistant running inside a PowerShell session.
Current directory: {0}

You have five tools available. Use the appropriate fenced block for each:

## 1. Run PowerShell commands
``````powershell
Get-ChildItem
``````

## 2. Read files
``````file_read
path/to/file.ps1
``````

## 3. Write files (create new or replace entire file)
``````file_write path/to/file.ps1
content goes here
``````

## 4. Edit files (targeted search-and-replace in existing files)
``````file_edit path/to/file.ps1
<<<< SEARCH
exact lines to find
====
replacement lines
>>>> END
``````

## 5. Web search
``````web_search
your search query here
``````

IMPORTANT:
- Use ``````file_read instead of Get-Content for reading files
- Use ``````file_edit for modifying existing files — safer than rewriting
- Use ``````file_write only for creating new files or complete rewrites
- Use ``````web_search when you need to look up docs, APIs, or error messages
- Use ``````powershell for everything else
- ONLY use these five block types for actions you want executed
- For code examples, use other language tags or no tag
- When you have enough info, give your final answer as plain text with no tool blocks
- Keep commands short and focused
- If a command fails, try a different approach
- Never run destructive commands without the user explicitly asking
"@

function Show-Banner {
    Write-Host "${CYAN}shellama${RESET} - PowerShell + AI agent"
    Write-Host "${GRAY}backend: $SHELLAMA_API | model: $SHELLAMA_MODEL${RESET}"
    Write-Host ""
    Write-Host "  ${YELLOW},${RESET}  <prompt>       agentic chat        ${YELLOW},,${RESET} <prompt>       quiet chat"
    Write-Host "  ${YELLOW},explain${RESET}  <file>  explain any file     ${YELLOW},generate${RESET} <desc>  generate code"
    Write-Host "  ${YELLOW},analyze${RESET}  <path>  analyze files/dirs   ${YELLOW},img${RESET} <prompt>     generate image"
    Write-Host "  ${YELLOW},save${RESET}  <file>     save last output     ${YELLOW},mode${RESET}             toggle do/chat"
    Write-Host "  ${YELLOW},session${RESET}          save/load sessions   ${YELLOW},context${RESET}          manage context files"
    Write-Host "  ${YELLOW},models${RESET}           select model         ${YELLOW},tokens${RESET}           session usage"
    Write-Host "  ${YELLOW},quiet${RESET}            toggle quiet         ${YELLOW},list${RESET}             all services"
    Write-Host ""
}

function Start-LlamaSpinner {
    $script:SpinnerRunning = $true
    $script:SpinnerRunspace = [runspacefactory]::CreateRunspace()
    $script:SpinnerRunspace.Open()
    $script:SpinnerRunspace.SessionStateProxy.SetVariable('host', $Host)
    $script:SpinnerRunspace.SessionStateProxy.SetVariable('running', [ref]$script:SpinnerRunning)
    $ps = [powershell]::Create().AddScript({
        $frames = @("  🦙     ", "  🦙 .   ", "  🦙 ..  ", "  🦙 ... ")
        $i = 0
        while ($running.Value) {
            $host.UI.Write("`r$($frames[$i % $frames.Count])")
            Start-Sleep -Milliseconds 300
            $i++
        }
        $host.UI.Write("`r                    `r")
    })
    $ps.Runspace = $script:SpinnerRunspace
    $script:SpinnerHandle = $ps.BeginInvoke()
    $script:SpinnerPS = $ps
}

function Stop-LlamaSpinner {
    if ($script:SpinnerPS) {
        $script:SpinnerRunning = $false
        try { $script:SpinnerPS.EndInvoke($script:SpinnerHandle) } catch {}
        $script:SpinnerPS.Dispose()
        $script:SpinnerRunspace.Close()
        $script:SpinnerPS = $null
        Write-Host -NoNewline "`r                    `r"
    }
}

function Invoke-AIChat {
    param([string]$Message)
    try {
        $body = @{ message = $Message; model = $SHELLAMA_MODEL } | ConvertTo-Json
        $resp = Invoke-RestMethod -Uri "$SHELLAMA_API/chat" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 3600
        return $resp
    } catch [System.Management.Automation.PipelineStoppedException] {
        # Ctrl+C pressed — stop backend
        try { Invoke-RestMethod -Uri "$SHELLAMA_API/stop-all" -Method Post -TimeoutSec 5 | Out-Null } catch {}
        return @{ error = "cancelled" }
    } catch [System.OperationCanceledException] {
        try { Invoke-RestMethod -Uri "$SHELLAMA_API/stop-all" -Method Post -TimeoutSec 5 | Out-Null } catch {}
        return @{ error = "cancelled" }
    } catch {
        return @{ error = $_.Exception.Message }
    }
}

function Invoke-AISimple {
    param([string]$Endpoint, [hashtable]$Payload, [string]$ResultKey)
    try {
        if (-not $Quiet) { Start-LlamaSpinner }
        $body = $Payload | ConvertTo-Json
        $resp = Invoke-RestMethod -Uri "$SHELLAMA_API$Endpoint" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 3600
        if (-not $Quiet) { Stop-LlamaSpinner }
        if ($resp.error) { Write-Host "shellama: $($resp.error)" -ForegroundColor Red; return }
        $script:SessionTokens += [int]($resp.total_tokens)
        $script:SessionRequests += 1
        $script:SessionElapsed += [double]($resp.elapsed)
        $script:LastOutput = $resp.$ResultKey
        Write-Host "${CYAN}$($resp.$ResultKey)${RESET}"
        Write-Host "${GRAY}[$($resp.elapsed)s | $($resp.total_tokens) tokens | $SHELLAMA_MODEL]${RESET}"
    } catch [System.Management.Automation.PipelineStoppedException] {
        Stop-LlamaSpinner
        Write-Host "`n${GRAY}cancelled - stopping backend...${RESET}"
        try { Invoke-RestMethod -Uri "$SHELLAMA_API/stop-all" -Method Post -TimeoutSec 5 | Out-Null } catch {}
    } catch {
        Stop-LlamaSpinner
        Write-Host "shellama: $_" -ForegroundColor Red
    }
}

# --- Helper functions for structured tools, permissions, context, sessions, compact ---

function Invoke-FileRead {
    param([string]$Path)
    $resolved = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Get-Location) $Path }
    try {
        $lines = Get-Content $resolved -ErrorAction Stop
        $numbered = for ($i = 0; $i -lt $lines.Count; $i++) { "{0,4} | {1}" -f ($i+1), $lines[$i] }
        return ($numbered -join "`n")
    } catch { return "Error: $_" }
}

function Invoke-FileWrite {
    param([string]$Path, [string]$Content)
    $resolved = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Get-Location) $Path }
    try {
        $dir = [IO.Path]::GetDirectoryName($resolved)
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $resolved -Value $Content -Encoding UTF8 -NoNewline
        $lineCount = ($Content.Split("`n")).Count
        return "Wrote $lineCount lines to $resolved"
    } catch { return "Error: $_" }
}

function Invoke-FileEdit {
    param([string]$Path, [string]$EditContent)
    $resolved = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Get-Location) $Path }
    try { $original = Get-Content $resolved -Raw -ErrorAction Stop } catch { return "Error reading ${Path}: $_" }
    $edits = [regex]::Matches($EditContent, '<<<< SEARCH\n(.*?)\n====\n(.*?)\n>>>> END', 'Singleline')
    if ($edits.Count -eq 0) { return "Error: no valid SEARCH/REPLACE blocks found" }
    $result = $original; $applied = 0; $failed = @()
    foreach ($m in $edits) {
        $search = $m.Groups[1].Value; $replace = $m.Groups[2].Value
        if ($result.Contains($search)) { $result = $result.Remove($result.IndexOf($search), $search.Length).Insert($result.IndexOf($search), $replace); $applied++ }
        else { $failed += $search.Substring(0, [math]::Min(60, $search.Length)) -replace "`n","\\n" }
    }
    if ($applied -eq 0) { return "Error: none of $($edits.Count) edits matched. File unchanged." }
    Set-Content -Path $resolved -Value $result -Encoding UTF8 -NoNewline
    $msg = "Applied $applied/$($edits.Count) edits to $resolved"
    if ($failed.Count -gt 0) { $msg += "`nFailed: $($failed -join '; ')" }
    return $msg
}

# Permission tiers
$script:ReadonlyPatterns = @(
    '^(Get-ChildItem|gci|ls|dir)(\s|$)', '^Get-Content\s', '^Get-Item\s', '^Test-Path\s',
    '^Get-Location$', '^pwd$', '^whoami$', '^hostname$',
    '^Get-Process', '^Get-Service', '^Get-Date$', '^Get-Host$',
    '^Get-Command\s', '^Get-Help\s', '^Get-Module', '^Get-Variable',
    '^\$env:', '^\$PSVersionTable', '^\$Host',
    '^git\s+(status|log|diff|show|branch|tag|remote)',
    '^Select-String\s', '^Measure-Object', '^Sort-Object', '^Where-Object',
    '^Write-Host\s', '^Write-Output\s', '^echo\s',
    '^curl\s', '^Invoke-WebRequest\s.*-Method\s+Get',
    '^systemctl\s+status', '^docker\s+(ps|images|inspect|logs)'
)
$script:BlockedPatterns = @(
    'Remove-Item\s+.*-Recurse.*-Force', 'Remove-Item\s+.*-Force.*-Recurse',
    'Format-Volume', 'Clear-Disk', 'Initialize-Disk',
    'Stop-Computer', 'Restart-Computer',
    'git\s+push\s+.*--force', 'git\s+push\s+-f\b',
    'git\s+reset\s+--hard', 'git\s+clean\s+-[a-zA-Z]*f',
    'rm\s+-rf\s', 'del\s+/[sS]\s+/[qQ]',
    'Invoke-Expression.*\|\s*iex', 'iex\s*\(.*Invoke-WebRequest'
)

function Get-CmdPermission {
    param([string]$Cmd)
    foreach ($p in $script:BlockedPatterns) { if ($Cmd -match $p) { return 'block' } }
    foreach ($p in $script:ReadonlyPatterns) { if ($Cmd -match $p) { return 'allow' } }
    return 'prompt'
}

# Context files
$script:ContextFile = Join-Path $HOME '.shellama/context.json'

function Get-ContextPaths {
    if (Test-Path $script:ContextFile) {
        try { return (Get-Content $script:ContextFile -Raw | ConvertFrom-Json) } catch {}
    }
    return @()
}

function Save-ContextPaths { param($Paths)
    $dir = [IO.Path]::GetDirectoryName($script:ContextFile)
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Paths | ConvertTo-Json | Set-Content $script:ContextFile -Encoding UTF8
}

function Get-ContextBlock {
    $paths = Get-ContextPaths
    if (-not $paths -or $paths.Count -eq 0) { return '' }
    $parts = @()
    foreach ($p in $paths) {
        $resolved = if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path (Get-Location) $p }
        try {
            $content = Get-Content $resolved -Raw -ErrorAction Stop
            $parts += "--- CONTEXT FILE: $p ---`n$content`n--- END ---"
        } catch { $parts += "--- CONTEXT FILE: $p ---`n(error: $_)`n--- END ---" }
    }
    return ($parts -join "`n`n")
}

function Invoke-ContextCmd { param([string]$Sub)
    if ($Sub.StartsWith('add ')) {
        $file = $Sub.Substring(4).Trim()
        $resolved = if ([IO.Path]::IsPathRooted($file)) { $file } else { Join-Path (Get-Location) $file }
        if (-not (Test-Path $resolved)) { Write-Host "shellama: ${file}: not found" -ForegroundColor Red; return }
        $paths = @(Get-ContextPaths)
        $store = try { [IO.Path]::GetRelativePath((Get-Location), $resolved) } catch { $resolved }
        if ($store -in $paths) { Write-Host "shellama: already in context" -ForegroundColor Red; return }
        $paths += $store
        Save-ContextPaths $paths
        Write-Host "context added: $store" -ForegroundColor Cyan
    } elseif ($Sub -match '^(remove|rm)\s+(.+)') {
        $file = $Matches[2].Trim()
        $paths = @(Get-ContextPaths)
        $paths = @($paths | Where-Object { $_ -ne $file })
        Save-ContextPaths $paths
        Write-Host "context removed: $file" -ForegroundColor Cyan
    } elseif ($Sub -eq 'clear') {
        Save-ContextPaths @()
        Write-Host "context cleared" -ForegroundColor Cyan
    } else {
        $paths = Get-ContextPaths
        if (-not $paths -or $paths.Count -eq 0) { Write-Host "shellama: no context files (use ,context add <file>)" -ForegroundColor DarkGray; return }
        foreach ($p in $paths) {
            $resolved = if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path (Get-Location) $p }
            $size = if (Test-Path $resolved) { (Get-Item $resolved).Length } else { 0 }
            Write-Host "  $p  ($size bytes)" -ForegroundColor Yellow
        }
    }
}

# Session save/load
$script:SessionsDir = Join-Path $HOME '.shellama/sessions'

function Invoke-SessionCmd { param([string]$Sub)
    if ($Sub.StartsWith('save')) {
        $name = $Sub.Substring(4).Trim()
        if (-not $name) { $name = $SHELLAMA_CONV_ID.Substring(0,8) }
        if (-not (Test-Path $script:SessionsDir)) { New-Item -ItemType Directory -Path $script:SessionsDir -Force | Out-Null }
        $data = @{ conversation_id=$SHELLAMA_CONV_ID; model=$SHELLAMA_MODEL; tokens=$script:SessionTokens;
                   requests=$script:SessionRequests; elapsed=$script:SessionElapsed; cwd=(Get-Location).Path;
                   saved_at=[int](Get-Date -UFormat %s) }
        $data | ConvertTo-Json | Set-Content (Join-Path $script:SessionsDir "$name.json") -Encoding UTF8
        Write-Host "session saved: $name" -ForegroundColor Cyan
    } elseif ($Sub.StartsWith('load')) {
        $name = $Sub.Substring(4).Trim()
        if (-not (Test-Path $script:SessionsDir)) { Write-Host "shellama: no saved sessions" -ForegroundColor Red; return }
        $files = Get-ChildItem $script:SessionsDir -Filter *.json | Sort-Object LastWriteTime -Descending
        if ($files.Count -eq 0) { Write-Host "shellama: no saved sessions" -ForegroundColor Red; return }
        if ($name) {
            $pick = $files | Where-Object { $_.BaseName -like "*$name*" } | Select-Object -First 1
            if (-not $pick) { Write-Host "shellama: no session matching '$name'" -ForegroundColor Red; return }
        } else {
            for ($i=0; $i -lt [math]::Min($files.Count,20); $i++) {
                Write-Host "  $($i+1)) $($files[$i].BaseName)" -ForegroundColor Yellow
            }
            $choice = Read-Host "Load [1-$([math]::Min($files.Count,20))]"
            if (-not $choice -or -not ($choice -match '^\d+$')) { Write-Host "cancelled"; return }
            $pick = $files[[int]$choice - 1]
        }
        $meta = Get-Content $pick.FullName -Raw | ConvertFrom-Json
        $script:SHELLAMA_CONV_ID = $meta.conversation_id
        $script:SessionTokens = $meta.tokens
        $script:SessionRequests = $meta.requests
        $script:SessionElapsed = $meta.elapsed
        Write-Host "loaded session: $($pick.BaseName) ($($meta.requests) reqs, $($meta.tokens) tokens)" -ForegroundColor Cyan
    } else {
        if (-not (Test-Path $script:SessionsDir)) { Write-Host "shellama: no saved sessions" -ForegroundColor Red; return }
        $files = Get-ChildItem $script:SessionsDir -Filter *.json | Sort-Object LastWriteTime -Descending
        if ($files.Count -eq 0) { Write-Host "shellama: no saved sessions" -ForegroundColor Red; return }
        foreach ($f in $files) {
            $meta = Get-Content $f.FullName -Raw | ConvertFrom-Json
            Write-Host "  $($f.BaseName)  [$($meta.requests) reqs | $($meta.tokens) tok | $($meta.model)]" -ForegroundColor Yellow
        }
    }
}

# Auto-compact
$script:CompactThreshold = 24000

function Invoke-AutoCompact {
    param([string]$Conversation, [string]$SystemPrompt, [bool]$IsQuiet)
    if ($Conversation.Length -lt $script:CompactThreshold) { return $Conversation }
    $afterSystem = $Conversation.Substring($SystemPrompt.Length)
    $turns = [regex]::Split($afterSystem, '(?=\n\n(?:User:|Assistant:|Tool output:|Command output:))')
    if ($turns.Count -le 4) { return $Conversation }
    $toSummarize = ($turns[0..($turns.Count-5)]) -join ''
    $toKeep = ($turns[($turns.Count-4)..($turns.Count-1)]) -join ''
    $summaryPrompt = "Summarize this conversation history concisely. Keep key facts, decisions, files modified, current task state:`n`n$toSummarize"
    $resp = Invoke-AIChat -Message $summaryPrompt
    if (-not $resp -or $resp.error) { return $Conversation }
    if (-not $IsQuiet) { Write-Host "${GRAY}[compacted: $($Conversation.Length) -> $($SystemPrompt.Length + $resp.response.Length + $toKeep.Length + 50) chars]${RESET}" }
    return "$SystemPrompt`n`nConversation summary (earlier turns):`n$($resp.response)`n`n$toKeep"
}

function Invoke-AIAgent {
    param([string]$Query, [bool]$IsQuiet = $false)

    $system = $SystemPrompt -f (Get-Location).Path
    # Inject context files
    $ctx = Get-ContextBlock
    if ($ctx) { $system += "`n`nThe user has attached these files as context:`n`n$ctx" }
    $conversation = "$system`n`nUser: $Query"
    $totalTokens = 0
    $totalElapsed = 0

    for ($round = 0; $round -lt $MaxRounds; $round++) {
        if (-not $IsQuiet) { Start-LlamaSpinner }
        $resp = Invoke-AIChat -Message $conversation
        if (-not $IsQuiet) { Stop-LlamaSpinner }

        if ($resp.error) { Write-Host "shellama: $($resp.error)" -ForegroundColor Red; return }

        $response = $resp.response
        $tokens = if ($resp.total_tokens) { $resp.total_tokens } else { 0 }
        $elapsed = if ($resp.elapsed) { $resp.elapsed } else { 0 }
        $totalTokens += $tokens
        $totalElapsed += $elapsed
        $script:SessionTokens += [int]$tokens
        $script:SessionRequests += 1
        $script:SessionElapsed += [double]$elapsed

        # Extract all tool blocks
        $toolBlocks = @()
        foreach ($m in [regex]::Matches($response, '```(powershell|file_read|file_write\s*\S*|file_edit\s*\S*|web_search)\n(.*?)```', 'Singleline')) {
            $tag = $m.Groups[1].Value
            $content = $m.Groups[2].Value
            if ($tag -eq 'powershell') { $toolBlocks += @{type='ps'; data=$content.Trim()} }
            elseif ($tag -eq 'file_read') {
                foreach ($line in $content.Trim().Split("`n")) {
                    $p = $line.Trim()
                    if ($p) { $toolBlocks += @{type='read'; data=$p} }
                }
            } elseif ($tag -match '^file_edit') {
                $path = if ($tag -match 'file_edit\s+(.+)') { $Matches[1] } else { '' }
                $toolBlocks += @{type='edit'; data=@($path, $content)}
            } elseif ($tag -eq 'web_search') {
                $toolBlocks += @{type='search'; data=$content.Trim()}
            } else {
                $path = if ($tag -match 'file_write\s+(.+)') { $Matches[1] } else { '' }
                $toolBlocks += @{type='write'; data=@($path, $content)}
            }
        }

        if ($toolBlocks.Count -eq 0) {
            $script:LastOutput = $response
            if (-not $IsQuiet) {
                Write-Host "${CYAN}$response${RESET}"
                Write-Host "${GRAY}[$($round + 1) round$(if($round){'s'}) | $([math]::Round($totalElapsed,1))s | $totalTokens tokens | $SHELLAMA_MODEL]${RESET}"
            } else { Write-Host $response }
            return
        }

        if (-not $IsQuiet) {
            $parts = [regex]::Split($response, '```(?:powershell|file_read|file_write\s*\S*)\n.*?```', 'Singleline')
            foreach ($part in $parts) { $part = $part.Trim(); if ($part) { Write-Host "${CYAN}$part${RESET}" } }
            Write-Host "${GRAY}[round $($round + 1) | $([math]::Round($elapsed,1))s | $tokens tokens]${RESET}"
        }

        # Execute tool blocks
        $cmdOutputs = @()
        foreach ($block in $toolBlocks) {
            if ($block.type -eq 'search') {
                Write-Host "${YELLOW}┌─ 🔍 search: $($block.data)${RESET}"
                try {
                    $q = [uri]::EscapeDataString($block.data)
                    $html = Invoke-WebRequest -Uri "https://html.duckduckgo.com/html/?q=$q" -UserAgent 'Mozilla/5.0' -TimeoutSec 10 -UseBasicParsing
                    $matches2 = [regex]::Matches($html.Content, 'class="result__a"[^>]*>(.*?)</a>')
                    $out = ($matches2 | Select-Object -First 5 | ForEach-Object { ($_.Groups[1].Value -replace '<[^>]+>','').Trim() }) -join "`n"
                    if (-not $out) { $out = "(no results)" }
                } catch { $out = "Search error: $_" }
                if (-not $IsQuiet) { Write-Host "${DIM}$out${RESET}" }
                $cmdOutputs += "[search: $($block.data)]`n$out"
            }
            elseif ($block.type -eq 'read') {
                Write-Host "${YELLOW}┌─ 📖 read: $($block.data)${RESET}"
                $output = Invoke-FileRead $block.data
                $lines = $output.Split("`n")
                if ($lines.Count -gt 20 -and -not $IsQuiet) {
                    Write-Host "${DIM}$($lines[0..9] -join "`n")`n   ... ($($lines.Count) lines total) ...${RESET}"
                } elseif (-not $IsQuiet) { Write-Host "${DIM}$output${RESET}" }
                $cmdOutputs += "[read $($block.data)]`n$output"
            }
            elseif ($block.type -eq 'write') {
                $path = $block.data[0]; $content = $block.data[1]
                $lineCount = ($content.Split("`n")).Count
                Write-Host "${YELLOW}┌─ ✏️  write: $path ($lineCount lines)${RESET}"
                if (-not $IsQuiet) {
                    $preview = ($content.Split("`n") | Select-Object -First 5) -join "`n"
                    Write-Host "${DIM}  $preview${RESET}"
                    $answer = Read-Host "${YELLOW}└─ Write? [y/N/q]${RESET}"
                    if ($answer -eq 'q') { return }
                    if ($answer -ne 'y') { $cmdOutputs += "[write $path]`n(skipped by user)"; Write-Host "${GRAY}   (skipped)${RESET}"; continue }
                }
                $output = Invoke-FileWrite $path $content
                Write-Host "${DIM}$output${RESET}"
                $cmdOutputs += "[write $path]`n$output"
            }
            elseif ($block.type -eq 'edit') {
                $path = $block.data[0]; $editContent = $block.data[1]
                $edits = [regex]::Matches($editContent, '<<<< SEARCH\n(.*?)\n====\n(.*?)\n>>>> END', 'Singleline')
                Write-Host "${YELLOW}┌─ 📝 edit: $path ($($edits.Count) change$(if($edits.Count -ne 1){'s'}))${RESET}"
                if (-not $IsQuiet) {
                    foreach ($e in ($edits | Select-Object -First 3)) {
                        $sp = ($e.Groups[1].Value.Split("`n")[0]).Substring(0, [math]::Min(60, $e.Groups[1].Value.Split("`n")[0].Length))
                        $rp = ($e.Groups[2].Value.Split("`n")[0]).Substring(0, [math]::Min(60, $e.Groups[2].Value.Split("`n")[0].Length))
                        Write-Host "${DIM}  - $sp${RESET}"; Write-Host "${DIM}  + $rp${RESET}"
                    }
                    $answer = Read-Host "${YELLOW}└─ Apply? [y/N/q]${RESET}"
                    if ($answer -eq 'q') { return }
                    if ($answer -ne 'y') { $cmdOutputs += "[edit $path]`n(skipped)"; Write-Host "${GRAY}   (skipped)${RESET}"; continue }
                }
                $output = Invoke-FileEdit $path $editContent
                Write-Host "${DIM}$output${RESET}"
                $cmdOutputs += "[edit $path]`n$output"
            }
            else { # powershell
                $cmd = $block.data
                $perm = Get-CmdPermission $cmd
                if ($perm -eq 'block') {
                    Write-Host "`e[31m┌─ ⛔ BLOCKED: $cmd`e[0m"
                    Write-Host "`e[31m└─ Destructive command blocked.`e[0m"
                    $cmdOutputs += "PS> $cmd`n(BLOCKED: destructive command not allowed)"
                    continue
                }
                Write-Host "${YELLOW}┌─ PS> $cmd${RESET}"
                if ($perm -eq 'prompt' -and -not $IsQuiet) {
                    $answer = Read-Host "${YELLOW}└─ Run? [y/N/q]${RESET}"
                    if ($answer -eq 'q') { return }
                    if ($answer -ne 'y') { $cmdOutputs += "PS> $cmd`n(skipped by user)"; Write-Host "${GRAY}   (skipped)${RESET}"; continue }
                }
                try {
                    $output = Invoke-Expression $cmd 2>&1 | Out-String
                    $output = $output.Trim()
                    if ($output) { if ($IsQuiet) { Write-Host $output } else { Write-Host "${DIM}$output${RESET}" } }
                    $cmdOutputs += "PS> $cmd`n$output"
                } catch {
                    $err = $_.Exception.Message
                    Write-Host "Error: $err" -ForegroundColor Red
                    $cmdOutputs += "PS> $cmd`nError: $err"
                }
            }
        }

        $results = $cmdOutputs -join "`n`n"
        $conversation += "`n`nAssistant: $response`n`nTool output:`n$results`n`nContinue. If you have enough information, give your final answer as plain text without any tool blocks."

        # Auto-compact
        $conversation = Invoke-AutoCompact $conversation $system $IsQuiet
    }
    Write-Host "${GRAY}[max rounds reached | $([math]::Round($totalElapsed,1))s | $totalTokens tokens]${RESET}"
}

function Invoke-AIImage {
    param([string]$Prompt)
    $imageModel = if ($env:AI_IMAGE_MODEL) { $env:AI_IMAGE_MODEL } else { "sdxl-turbo" }
    $steps = if ($imageModel -match "turbo") { 4 } else { 20 }
    try {
        Start-LlamaSpinner
        $body = @{ prompt = $Prompt; image_model = $imageModel; steps = $steps; width = 512; height = 512 } | ConvertTo-Json
        $resp = Invoke-RestMethod -Uri "$SHELLAMA_API/generate-image" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 3600
        Stop-LlamaSpinner
        if ($resp.error) { Write-Host "shellama: $($resp.error)" -ForegroundColor Red; return }
        $script:SessionRequests += 1
        $script:SessionElapsed += [double]($resp.elapsed)
        $outfile = "generated_$([int](Get-Date -UFormat %s)).png"
        [IO.File]::WriteAllBytes("$PWD\$outfile", [Convert]::FromBase64String($resp.image))
        Write-Host "${CYAN}$(Resolve-Path $outfile)${RESET}"
        Write-Host "${GRAY}[$($resp.elapsed)s | $($resp.model) | $($resp.steps) steps]${RESET}"
    } catch [System.Management.Automation.PipelineStoppedException] {
        Stop-LlamaSpinner
        Write-Host "`n${GRAY}cancelled - stopping backend...${RESET}"
        try { Invoke-RestMethod -Uri "$SHELLAMA_API/stop-all" -Method Post -TimeoutSec 5 | Out-Null } catch {}
    } catch {
        Stop-LlamaSpinner
        Write-Host "shellama: $_" -ForegroundColor Red
    }
}

function Invoke-AIAnalyze {
    param([string[]]$Paths)
    [array]$filesData = @()
    foreach ($p in $Paths) {
        if (Test-Path $p -PathType Container) {
            Get-ChildItem $p -Recurse -File | ForEach-Object {
                try { $filesData += @{ path = $_.FullName; content = (Get-Content $_.FullName -Raw) } } catch {}
            }
        } elseif (Test-Path $p) {
            try { $filesData += @{ path = (Resolve-Path $p).Path; content = (Get-Content $p -Raw) } } catch {}
        } else {
            Write-Host "shellama: ${p}: not found" -ForegroundColor Red
        }
    }
    if ($filesData.Count -eq 0) { Write-Host "shellama: no readable files found" -ForegroundColor Red; return }
    Write-Host "${GRAY}Analyzing $($filesData.Count) file$(if($filesData.Count -ne 1){'s'})...${RESET}"
    Invoke-AISimple -Endpoint "/analyze" -Payload @{ files = @($filesData); model = $SHELLAMA_MODEL } -ResultKey "analysis"
}

function Show-Services {
    Write-Host "${CYAN}Available services (prefix with ,):${RESET}"
    Write-Host "  ${YELLOW},${RESET}  <prompt>       agentic chat        ${YELLOW},,${RESET} <prompt>       quiet chat"
    Write-Host "  ${YELLOW},explain${RESET}  <file>  explain any file     ${YELLOW},generate${RESET} <desc>  generate code"
    Write-Host "  ${YELLOW},analyze${RESET}  <path>  analyze files/dirs   ${YELLOW},img${RESET} <prompt>     generate image"
    Write-Host "  ${YELLOW},list${RESET}             all services         ${YELLOW},models${RESET}           select model"
    Write-Host "  ${YELLOW},mode${RESET}             toggle do/chat       ${YELLOW},quiet${RESET}            toggle quiet"
}

function Select-Model {
    try {
        $resp = Invoke-RestMethod -Uri "$SHELLAMA_API/models" -TimeoutSec 10
        $models = $resp.models
    } catch {
        Write-Host "shellama: $_" -ForegroundColor Red; return
    }
    if ($models.Count -eq 0) { Write-Host "shellama: no models available" -ForegroundColor Red; return }
    Write-Host "${CYAN}Available models:${RESET}"
    for ($i = 0; $i -lt $models.Count; $i++) {
        $m = $models[$i]
        $sizeGb = [math]::Round($m.size / 1GB, 1)
        $current = if ($m.name -eq $SHELLAMA_MODEL) { " <- current" } else { "" }
        Write-Host "  ${YELLOW}$($i+1)${RESET}) $($m.name) (${sizeGb}GB)$current"
    }
    $choice = Read-Host "${GRAY}Select [1-$($models.Count)]${RESET}"
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $models.Count) {
        $script:SHELLAMA_MODEL = $models[[int]$choice - 1].name
        Write-Host "model: $SHELLAMA_MODEL"
    } else {
        Write-Host "cancelled"
    }
}

# Main loop
$script:AgentMode = $true
Show-Banner

while ($true) {
    $prompt = "${HAL}PS $($executionContext.SessionState.Path.CurrentLocation)> "
    $line = Read-Host -Prompt $prompt
    if ($null -eq $line) { break }
    $line = $line.Trim()
    if (-not $line) { continue }

    if ($line -in @('exit', 'quit', 'logout')) { break }

    if ($line.StartsWith(",,")) {
        $query = $line.Substring(2).Trim()
        if ($query) { Invoke-AIAgent -Query $query -IsQuiet $true }
    }
    elseif ($line.StartsWith(",")) {
        $query = $line.Substring(1).Trim()
        if (-not $query) { continue }

        if ($query -in @('list', 'help')) { Show-Services }
        elseif ($query -eq 'models') { Select-Model }
        elseif ($query -eq 'quiet') { $Quiet = -not $Quiet; Write-Host "quiet mode: $(if($Quiet){'on'}else{'off'})" }
        elseif ($query -eq 'mode') {
            $script:AgentMode = -not $script:AgentMode
            $modeName = if ($script:AgentMode) { "do (agentic - AI runs commands)" } else { "chat (AI responds only)" }
            Write-Host "mode: $modeName"
        }
        elseif ($query -eq 'tokens') { Write-Host "${CYAN}Session usage: $($script:SessionRequests) requests | $($script:SessionTokens) tokens | $([math]::Round($script:SessionElapsed,1))s${RESET}" }
        elseif ($query.StartsWith('save ')) {
            $file = $query.Substring(5).Trim()
            if (-not $script:LastOutput) { Write-Host "shellama: nothing to save (no AI output yet)" -ForegroundColor Red }
            else {
                $content = $script:LastOutput.Trim()
                if ($content -match '(?s)^```\w*\n(.*?)```$') { $content = $Matches[1] }
                Set-Content -Path $file -Value $content -Encoding UTF8
                Write-Host "saved: $file ($($content.Length) chars)"
            }
        }
        elseif ($query -eq 'session' -or $query.StartsWith('session ')) {
            Invoke-SessionCmd ($query.Substring(7).Trim())
        }
        elseif ($query -eq 'context' -or $query.StartsWith('context ')) {
            Invoke-ContextCmd ($query.Substring(7).Trim())
        }
        elseif ($query.StartsWith('img ')) { Invoke-AIImage -Prompt $query.Substring(4).Trim() }
        elseif ($query.StartsWith('analyze ')) { Invoke-AIAnalyze -Paths ($query.Substring(8).Trim() -split '\s+') }
        elseif ($query.StartsWith('explain ')) {
            $file = $query.Substring(8).Trim()
            if (-not (Test-Path $file)) { Write-Host "shellama: ${file}: not found" -ForegroundColor Red; continue }
            $content = Get-Content $file -Raw
            $ext = [IO.Path]::GetExtension($file).ToLower()
            if ($ext -in @('.yml', '.yaml')) {
                Invoke-AISimple -Endpoint "/explain" -Payload @{ playbook = $content; model = $SHELLAMA_MODEL } -ResultKey "explanation"
            } else {
                Invoke-AISimple -Endpoint "/explain-code" -Payload @{ code = $content; model = $SHELLAMA_MODEL } -ResultKey "explanation"
            }
        }
        elseif ($query.StartsWith('generate ')) {
            $desc = $query.Substring(9).Trim()
            if ($desc -match 'ansible|playbook|shell command') {
                Invoke-AISimple -Endpoint "/generate" -Payload @{ commands = $desc; model = $SHELLAMA_MODEL } -ResultKey "playbook"
            } else {
                Invoke-AISimple -Endpoint "/generate-code" -Payload @{ description = $desc; model = $SHELLAMA_MODEL } -ResultKey "code"
            }
        }
        else {
            if ($script:AgentMode) {
                Invoke-AIAgent -Query $query -IsQuiet $Quiet
            } else {
                $resp = Invoke-AIChat -Message $query
                if ($resp -and $resp.response) {
                    $script:LastOutput = $resp.response
                    Write-Host "`n$($resp.response)`n"
                }
            }
        }
    }
    else {
        # Regular PowerShell command
        try { Invoke-Expression $line } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    }
}
