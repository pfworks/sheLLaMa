# sheLLaMa PowerShell integration — dot-source this in your $PROFILE
# Usage: . /path/to/shellama/powershell/shellama.ps1
#   or add to $PROFILE: . C:\path\to\shellama\powershell\shellama.ps1
#
# Gives you , commands in your real PowerShell session:
#   , <prompt>          agentic chat (AI runs commands)
#   ,, <prompt>         quiet mode (output only)
#   ,explain <file>     explain any file
#   ,generate <desc>    generate code/playbook
#   ,analyze <paths>    analyze files/dirs
#   ,img <prompt>       generate image
#   ,save <file>        save last AI output
#   ,session            save/load/list sessions
#   ,context            manage context files
#   ,vision <img>       send image to AI
#   ,test [model|all]   benchmark models
#   ,models             select model
#   ,tokens             session usage
#   ,list               show commands

# Load shared config
. "$PSScriptRoot\shellama-config.ps1"
$script:SessionTokens = 0
$script:SessionRequests = 0
$script:SessionElapsed = 0.0
$script:MaxRounds = 10
$script:LastOutput = ''

function Invoke-ShellamaChat {
    param([string]$Message, [string]$Model = $script:SHELLAMA_MODEL)
    $body = @{ message = $Message; model = $Model; conversation_id = $script:SHELLAMA_CONV_ID } | ConvertTo-Json -Depth 10
    $headers = Get-ShellamaHeaders
    try {
        $resp = Invoke-RestMethod -Uri "$($script:SHELLAMA_API)/chat" -Method Post -Body $body -Headers $headers -TimeoutSec 3600
        return $resp
    } catch {
        Write-Host "shellama: $_" -ForegroundColor Red
        return $null
    }
}

function Invoke-ShellamaAgent {
    param([string]$Query, [switch]$Quiet)
    $system = $script:SHELLAMA_SYSTEM_PROMPT -f (Get-Location)
    $ctx = Get-ShellamaContextBlock
    if ($ctx) { $system += "`n`nThe user has attached these files as context:`n`n$ctx" }
    $conversation = "$system`n`nUser: $Query"
    $totalTokens = 0; $totalElapsed = 0

    for ($round = 0; $round -lt $script:MaxRounds; $round++) {
        $resp = Invoke-ShellamaChat -Message $conversation
        if (-not $resp -or $resp.error) {
            if ($resp.error) { Write-Host "Error: $($resp.error)" -ForegroundColor Red }
            return
        }
        $response = $resp.response
        $tokens = if ($resp.total_tokens) { $resp.total_tokens } else { 0 }
        $elapsed = if ($resp.elapsed) { $resp.elapsed } else { 0 }
        $totalTokens += $tokens; $totalElapsed += $elapsed
        $script:SessionTokens += $tokens; $script:SessionRequests++; $script:SessionElapsed += $elapsed

        # Extract tool blocks
        $toolBlocks = @()
        foreach ($m in [regex]::Matches($response, '```(powershell|file_read|file_write\s*\S*|file_edit\s*\S*|web_search)\n(.*?)```', 'Singleline')) {
            $tag = $m.Groups[1].Value; $content = $m.Groups[2].Value
            if ($tag -eq 'powershell') { $toolBlocks += @{type='ps'; data=$content.Trim()} }
            elseif ($tag -eq 'file_read') { foreach ($l in $content.Trim().Split("`n")) { $p=$l.Trim(); if($p){$toolBlocks += @{type='read';data=$p}} } }
            elseif ($tag -match '^file_edit') { $path=if($tag -match 'file_edit\s+(.+)'){$Matches[1]}else{''}; $toolBlocks += @{type='edit';data=@($path,$content)} }
            elseif ($tag -eq 'web_search') { $toolBlocks += @{type='search';data=$content.Trim()} }
            else { $path = if($tag -match 'file_write\s+(.+)'){$Matches[1]}else{''}; $toolBlocks += @{type='write';data=@($path,$content)} }
        }

        if ($toolBlocks.Count -eq 0) {
            $script:LastOutput = $response
            if ($Quiet) { Write-Host $response } else {
                Write-Host $response -ForegroundColor Cyan
                Write-Host "[$($round + 1) round$(if($round){'s'}) | $([math]::Round($totalElapsed,1))s | $totalTokens tokens | $($script:SHELLAMA_MODEL)]" -ForegroundColor DarkGray
            }
            return
        }

        if (-not $Quiet) {
            $parts = [regex]::Split($response, '```(?:powershell|file_read|file_write\s*\S*|file_edit\s*\S*|web_search)\n.*?```', 'Singleline')
            foreach ($part in $parts) { $part = $part.Trim(); if ($part) { Write-Host $part -ForegroundColor Cyan } }
            Write-Host "[round $($round + 1) | $([math]::Round($elapsed,1))s | $tokens tokens]" -ForegroundColor DarkGray
        }

        $cmdOutputs = @()
        foreach ($block in $toolBlocks) {
            if ($block.type -eq 'search') {
                Write-Host "┌─ 🔍 search: $($block.data)" -ForegroundColor Yellow
                try { $q=[uri]::EscapeDataString($block.data); $html=Invoke-WebRequest -Uri "https://html.duckduckgo.com/html/?q=$q" -UserAgent 'Mozilla/5.0' -TimeoutSec 10 -UseBasicParsing; $ms=[regex]::Matches($html.Content,'class="result__a"[^>]*>(.*?)</a>'); $out=($ms|Select-Object -First 5|ForEach-Object{($_.Groups[1].Value -replace '<[^>]+>','').Trim()}) -join "`n"; if(-not $out){$out="(no results)"} } catch { $out="Search error: $_" }
                if(-not $Quiet){Write-Host $out -ForegroundColor DarkGray}
                $cmdOutputs += "[search: $($block.data)]`n$out"
            }
            elseif ($block.type -eq 'read') {
                Write-Host "┌─ 📖 read: $($block.data)" -ForegroundColor Yellow
                $resolved = if([IO.Path]::IsPathRooted($block.data)){$block.data}else{Join-Path(Get-Location)$block.data}
                try { $out=(Get-Content $resolved -ErrorAction Stop|ForEach-Object -Begin{$i=1} -Process{"{0,4} | {1}" -f $i++,$_}) -join "`n" } catch { $out="Error: $_" }
                if(-not $Quiet){$lines=$out.Split("`n"); if($lines.Count -gt 20){Write-Host ($lines[0..9]-join"`n") -ForegroundColor DarkGray; Write-Host "   ... ($($lines.Count) lines)" -ForegroundColor DarkGray}else{Write-Host $out -ForegroundColor DarkGray}}
                $cmdOutputs += "[read $($block.data)]`n$out"
            } elseif ($block.type -eq 'write') {
                $path=$block.data[0]; $content=$block.data[1]; $lc=($content.Split("`n")).Count
                Write-Host "┌─ ✏️  write: $path ($lc lines)" -ForegroundColor Yellow
                if (-not $Quiet) {
                    ($content.Split("`n")|Select-Object -First 5)|ForEach-Object{Write-Host "  $_" -ForegroundColor DarkGray}
                    $answer = Read-Host "└─ Write? [y/N/q]"
                    if($answer -eq 'q'){return}
                    if($answer -ne 'y'){$cmdOutputs += "[write $path]`n(skipped)"; Write-Host "   (skipped)" -ForegroundColor DarkGray; continue}
                }
                $resolved = if([IO.Path]::IsPathRooted($path)){$path}else{Join-Path(Get-Location)$path}
                $dir=[IO.Path]::GetDirectoryName($resolved); if($dir -and -not(Test-Path $dir)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
                Set-Content -Path $resolved -Value $content -Encoding UTF8 -NoNewline
                Write-Host "Wrote $lc lines to $resolved" -ForegroundColor DarkGray
                $cmdOutputs += "[write $path]`nWrote $lc lines to $resolved"
            } elseif ($block.type -eq 'edit') {
                $path=$block.data[0]; $editContent=$block.data[1]
                $edits=[regex]::Matches($editContent,'<<<< SEARCH\n(.*?)\n====\n(.*?)\n>>>> END','Singleline')
                Write-Host "┌─ 📝 edit: $path ($($edits.Count) change$(if($edits.Count-ne 1){'s'}))" -ForegroundColor Yellow
                if (-not $Quiet) {
                    foreach($e in ($edits|Select-Object -First 3)){Write-Host "  - $($e.Groups[1].Value.Split("`n")[0].Substring(0,[math]::Min(60,$e.Groups[1].Value.Split("`n")[0].Length)))" -ForegroundColor DarkGray; Write-Host "  + $($e.Groups[2].Value.Split("`n")[0].Substring(0,[math]::Min(60,$e.Groups[2].Value.Split("`n")[0].Length)))" -ForegroundColor DarkGray}
                    $answer = Read-Host "└─ Apply? [y/N/q]"
                    if($answer -eq 'q'){return}
                    if($answer -ne 'y'){$cmdOutputs += "[edit $path]`n(skipped)"; Write-Host "   (skipped)" -ForegroundColor DarkGray; continue}
                }
                $resolved = if([IO.Path]::IsPathRooted($path)){$path}else{Join-Path(Get-Location)$path}
                try{$orig=Get-Content $resolved -Raw -ErrorAction Stop}catch{$cmdOutputs += "[edit $path]`nError: $_"; Write-Host "Error: $_" -ForegroundColor Red; continue}
                $res=$orig; $app=0
                foreach($e in $edits){$s=$e.Groups[1].Value;$r=$e.Groups[2].Value; if($res.Contains($s)){$res=$res.Remove($res.IndexOf($s),$s.Length).Insert($res.IndexOf($s),$r);$app++}}
                if($app -eq 0){$cmdOutputs += "[edit $path]`nNo edits matched"; Write-Host "No edits matched" -ForegroundColor Red; continue}
                Set-Content -Path $resolved -Value $res -Encoding UTF8 -NoNewline
                Write-Host "Applied $app/$($edits.Count) edits to $resolved" -ForegroundColor DarkGray
                $cmdOutputs += "[edit $path]`nApplied $app/$($edits.Count) edits"
            } else {
                $cmd = $block.data
                $perm = Get-ShellCmdPermission $cmd
                if ($perm -eq 'block') { Write-Host "┌─ ⛔ BLOCKED: $cmd" -ForegroundColor Red; $cmdOutputs += "PS> $cmd`n(BLOCKED)"; continue }
                Write-Host "┌─ PS> $cmd" -ForegroundColor Yellow
                if ($perm -eq 'prompt' -and -not $Quiet) {
                    $answer = Read-Host "└─ Run? [y/N/q]"
                    if($answer -eq 'q'){return}
                    if($answer -ne 'y'){$cmdOutputs += "PS> $cmd`n(skipped)"; Write-Host "   (skipped)" -ForegroundColor DarkGray; continue}
                }
                try { $output=Invoke-Expression $cmd 2>&1|Out-String; if($output.Trim()){if($Quiet){Write-Host $output.Trim()}else{Write-Host $output.Trim() -ForegroundColor DarkGray}}; $cmdOutputs += "PS> $cmd`n$output" }
                catch { Write-Host "Error: $_" -ForegroundColor Red; $cmdOutputs += "PS> $cmd`nError: $_" }
            }
        }
        $results = $cmdOutputs -join "`n`n"
        $conversation += "`n`nAssistant: $response`n`nTool output:`n$results`n`nContinue. If you have enough information, give your final answer as plain text without any tool blocks."
        # Auto-compact
        if ($conversation.Length -gt 24000) {
            $afterSys = $conversation.Substring($system.Length)
            $turns = [regex]::Split($afterSys, '(?=\n\n(?:User:|Assistant:|Tool output:))')
            if ($turns.Count -gt 4) {
                $toSum = ($turns[0..($turns.Count-5)]) -join ''
                $toKeep = ($turns[($turns.Count-4)..($turns.Count-1)]) -join ''
                $sr = Invoke-ShellamaChat -Message "Summarize concisely. Keep key facts, decisions, files modified:`n`n$toSum"
                if ($sr -and -not $sr.error) {
                    Write-Host "[compacted]" -ForegroundColor DarkGray
                    $conversation = "$system`n`nConversation summary:`n$($sr.response)`n`n$toKeep"
                }
            }
        }
    }
    Write-Host "[max rounds reached | $([math]::Round($totalElapsed,1))s | $totalTokens tokens]" -ForegroundColor DarkGray
}

function Invoke-ShellamaSimple {
    param([string]$Endpoint, [hashtable]$Body, [string]$ResultKey)
    $json = $Body | ConvertTo-Json -Depth 10
    $headers = Get-ShellamaHeaders
    try {
        $resp = Invoke-RestMethod -Uri "$($script:SHELLAMA_API)$Endpoint" -Method Post -Body $json -Headers $headers -TimeoutSec 3600
        if ($resp.error) { Write-Host "shellama: $($resp.error)" -ForegroundColor Red; return }
        $script:SessionTokens += ($resp.total_tokens -as [int])
        $script:SessionRequests++
        $script:SessionElapsed += ($resp.elapsed -as [double])
        $script:LastOutput = $resp.$ResultKey
        Write-Host $resp.$ResultKey -ForegroundColor Cyan
        Write-Host "[$($resp.elapsed)s | $($resp.total_tokens) tokens | $($script:SHELLAMA_MODEL)]" -ForegroundColor DarkGray
    } catch {
        Write-Host "shellama: $_" -ForegroundColor Red
    }
}

# Permission tiers
$script:_BlockedPats = @('Remove-Item\s+.*-Recurse.*-Force','Format-Volume','Clear-Disk','Stop-Computer','Restart-Computer','git\s+push\s+.*--force','git\s+push\s+-f\b','git\s+reset\s+--hard','git\s+clean\s+-[a-zA-Z]*f','rm\s+-rf\s','Invoke-Expression.*\|\s*iex')
$script:_ReadonlyPats = @('^(Get-ChildItem|gci|ls|dir)(\s|$)','^Get-Content\s','^Get-Item\s','^Test-Path\s','^Get-Location$','^pwd$','^whoami$','^Get-Process','^Get-Service','^Get-Date$','^Get-Command\s','^Get-Help\s','^\$env:','^\$PSVersionTable','^git\s+(status|log|diff|show|branch|tag|remote)','^Select-String\s','^Write-Host\s','^Write-Output\s','^curl\s','^systemctl\s+status','^docker\s+(ps|images|inspect|logs)')

function Get-ShellCmdPermission { param([string]$Cmd)
    foreach($p in $script:_BlockedPats){if($Cmd -match $p){return 'block'}}
    foreach($p in $script:_ReadonlyPats){if($Cmd -match $p){return 'allow'}}
    return 'prompt'
}

# Context files
$script:_ContextFile = Join-Path $HOME '.shellama/context.json'
function Get-ShellamaContextBlock {
    if (-not (Test-Path $script:_ContextFile)) { return '' }
    try { $paths = Get-Content $script:_ContextFile -Raw | ConvertFrom-Json } catch { return '' }
    if (-not $paths -or $paths.Count -eq 0) { return '' }
    $parts = @()
    foreach ($p in $paths) {
        $resolved = if([IO.Path]::IsPathRooted($p)){$p}else{Join-Path(Get-Location)$p}
        try { $c = Get-Content $resolved -Raw -ErrorAction Stop; $parts += "--- CONTEXT FILE: $p ---`n$c`n--- END ---" }
        catch { $parts += "--- CONTEXT FILE: $p ---`n(error: $_)`n--- END ---" }
    }
    return ($parts -join "`n`n")
}

function ,context {
    $sub = $args -join ' '
    if ($sub.StartsWith('add ')) {
        $file = $sub.Substring(4).Trim()
        $resolved = if([IO.Path]::IsPathRooted($file)){$file}else{Join-Path(Get-Location)$file}
        if (-not (Test-Path $resolved)) { Write-Host "shellama: ${file}: not found" -ForegroundColor Red; return }
        $paths = @(); if(Test-Path $script:_ContextFile){try{$paths=@(Get-Content $script:_ContextFile -Raw|ConvertFrom-Json)}catch{}}
        $store = try{[IO.Path]::GetRelativePath((Get-Location),$resolved)}catch{$resolved}
        if ($store -in $paths) { Write-Host "already in context" -ForegroundColor Red; return }
        $paths += $store
        $dir=[IO.Path]::GetDirectoryName($script:_ContextFile); if(-not(Test-Path $dir)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
        $paths|ConvertTo-Json|Set-Content $script:_ContextFile -Encoding UTF8
        Write-Host "context added: $store" -ForegroundColor Cyan
    } elseif ($sub -match '^(remove|rm)\s+(.+)') {
        $file=$Matches[2].Trim(); $paths=@(); if(Test-Path $script:_ContextFile){try{$paths=@(Get-Content $script:_ContextFile -Raw|ConvertFrom-Json)}catch{}}
        $paths=@($paths|Where-Object{$_ -ne $file})
        $paths|ConvertTo-Json|Set-Content $script:_ContextFile -Encoding UTF8
        Write-Host "context removed: $file" -ForegroundColor Cyan
    } elseif ($sub -eq 'clear') {
        @()|ConvertTo-Json|Set-Content $script:_ContextFile -Encoding UTF8
        Write-Host "context cleared" -ForegroundColor Cyan
    } else {
        if(-not(Test-Path $script:_ContextFile)){Write-Host "no context files (use ,context add <file>)" -ForegroundColor DarkGray; return}
        try{$paths=@(Get-Content $script:_ContextFile -Raw|ConvertFrom-Json)}catch{Write-Host "no context files" -ForegroundColor DarkGray; return}
        if($paths.Count -eq 0){Write-Host "no context files (use ,context add <file>)" -ForegroundColor DarkGray; return}
        foreach($p in $paths){$resolved=if([IO.Path]::IsPathRooted($p)){$p}else{Join-Path(Get-Location)$p}; $sz=if(Test-Path $resolved){(Get-Item $resolved).Length}else{0}; Write-Host "  $p  ($sz bytes)" -ForegroundColor Yellow}
    }
}

function ,session {
    $sub = $args -join ' '
    $sessDir = Join-Path $HOME '.shellama/sessions'
    if ($sub.StartsWith('save')) {
        $name = $sub.Substring(4).Trim(); if(-not $name){$name=$script:SHELLAMA_CONV_ID.Substring(0,8)}
        if(-not(Test-Path $sessDir)){New-Item -ItemType Directory -Path $sessDir -Force|Out-Null}
        @{conversation_id=$script:SHELLAMA_CONV_ID;model=$script:SHELLAMA_MODEL;tokens=$script:SessionTokens;requests=$script:SessionRequests;elapsed=$script:SessionElapsed;cwd=(Get-Location).Path;saved_at=[int](Get-Date -UFormat %s)}|ConvertTo-Json|Set-Content(Join-Path $sessDir "$name.json") -Encoding UTF8
        Write-Host "session saved: $name" -ForegroundColor Cyan
    } elseif ($sub.StartsWith('load')) {
        $name=$sub.Substring(4).Trim()
        if(-not(Test-Path $sessDir)){Write-Host "no saved sessions" -ForegroundColor Red; return}
        $files=Get-ChildItem $sessDir -Filter *.json|Sort-Object LastWriteTime -Descending
        if($files.Count -eq 0){Write-Host "no saved sessions" -ForegroundColor Red; return}
        if($name){$pick=$files|Where-Object{$_.BaseName -like "*$name*"}|Select-Object -First 1; if(-not $pick){Write-Host "no match" -ForegroundColor Red; return}}
        else{for($i=0;$i -lt [math]::Min($files.Count,20);$i++){Write-Host "  $($i+1)) $($files[$i].BaseName)" -ForegroundColor Yellow}; $c=Read-Host "Load"; if(-not($c -match '^\d+$')){return}; $pick=$files[[int]$c-1]}
        $meta=Get-Content $pick.FullName -Raw|ConvertFrom-Json
        $script:SHELLAMA_CONV_ID=$meta.conversation_id; $script:SessionTokens=$meta.tokens; $script:SessionRequests=$meta.requests; $script:SessionElapsed=$meta.elapsed
        Write-Host "loaded: $($pick.BaseName) ($($meta.requests) reqs)" -ForegroundColor Cyan
    } else {
        if(-not(Test-Path $sessDir)){Write-Host "no saved sessions" -ForegroundColor Red; return}
        $files=Get-ChildItem $sessDir -Filter *.json|Sort-Object LastWriteTime -Descending
        if($files.Count -eq 0){Write-Host "no saved sessions" -ForegroundColor Red; return}
        foreach($f in $files){$m=Get-Content $f.FullName -Raw|ConvertFrom-Json; Write-Host "  $($f.BaseName)  [$($m.requests) reqs | $($m.tokens) tok]" -ForegroundColor Yellow}
    }
}

# Mode toggle: do (agentic, default) or chat
$script:ShellamaMode = "do"

# Define , commands as functions
function , {
    $query = $args -join ' '
    if (-not $query) { Write-Host "Usage: , <prompt>  |  ,mode to toggle (current: $($script:ShellamaMode))"; return }
    if ($script:ShellamaMode -eq "do") {
        Invoke-ShellamaAgent -Query $query
    } else {
        $resp = Invoke-ShellamaChat -Message $query -Model $script:SHELLAMA_MODEL
        if ($resp -and $resp.response) {
            $script:LastOutput = $resp.response
            Write-Host "`n$($resp.response)`n"
        }
    }
}
function ,, { Invoke-ShellamaAgent -Query ($args -join ' ') -Quiet }

function ,mode {
    if ($script:ShellamaMode -eq "chat") {
        $script:ShellamaMode = "do"
        Write-Host "mode: do (agentic - AI runs commands)"
    } else {
        $script:ShellamaMode = "chat"
        Write-Host "mode: chat (AI responds only)"
    }
}

function ,explain {
    $file = $args[0]
    if (-not $file -or -not (Test-Path $file)) { Write-Host "Usage: ,explain <file>" -ForegroundColor Red; return }
    $content = Get-Content $file -Raw
    $ext = [IO.Path]::GetExtension($file).ToLower()
    if ($ext -in @('.yml', '.yaml')) {
        Invoke-ShellamaSimple "/explain" @{ playbook = $content; model = $script:SHELLAMA_MODEL } "explanation"
    } else {
        Invoke-ShellamaSimple "/explain-code" @{ code = $content; model = $script:SHELLAMA_MODEL } "explanation"
    }
}

function ,generate {
    $desc = $args -join ' '
    if ($desc -match 'ansible|playbook|shell command') {
        Invoke-ShellamaSimple "/generate" @{ commands = $desc; model = $script:SHELLAMA_MODEL } "playbook"
    } else {
        Invoke-ShellamaSimple "/generate-code" @{ description = $desc; model = $script:SHELLAMA_MODEL } "code"
    }
}

function ,analyze {
    $filesData = @()
    foreach ($p in $args) {
        if (Test-Path $p -PathType Container) {
            Get-ChildItem $p -Recurse -File | ForEach-Object {
                try { $filesData += @{ path = $_.FullName; content = (Get-Content $_.FullName -Raw) } } catch {}
            }
        } elseif (Test-Path $p) {
            try { $filesData += @{ path = (Resolve-Path $p).Path; content = (Get-Content $p -Raw) } } catch {}
        } else { Write-Host "${p}: not found" -ForegroundColor Red }
    }
    if ($filesData.Count -eq 0) { Write-Host "No readable files found" -ForegroundColor Red; return }
    Write-Host "Analyzing $($filesData.Count) file$(if($filesData.Count -ne 1){'s'})..." -ForegroundColor DarkGray
    Invoke-ShellamaSimple "/analyze" @{ files = @($filesData); model = $script:SHELLAMA_MODEL } "analysis"
}

function ,img {
    $prompt = $args -join ' '
    $im = if ($env:AI_IMAGE_MODEL) { $env:AI_IMAGE_MODEL } else { "sdxl-turbo" }
    $st = if ($im -match "turbo") { 4 } else { 20 }
    $body = @{ prompt = $prompt; image_model = $im; steps = $st; width = 512; height = 512 } | ConvertTo-Json
    try {
        $resp = Invoke-RestMethod -Uri "$($script:SHELLAMA_API)/generate-image" -Method Post -Body $body -Headers (Get-ShellamaHeaders) -TimeoutSec 3600
        if ($resp.image) {
            $dlDir = if ($env:SHELLAMA_DOWNLOAD_DIR) { $env:SHELLAMA_DOWNLOAD_DIR } else { $PWD }
            if (!(Test-Path $dlDir)) { New-Item -ItemType Directory -Path $dlDir -Force | Out-Null }
            $defaultFile = "$dlDir\generated_$([int](Get-Date -UFormat %s)).png"
            $custom = Read-Host "Save as [$defaultFile]"
            $outfile = if ($custom) { $custom } else { $defaultFile }
            $outDir = [IO.Path]::GetDirectoryName($outfile)
            if ($outDir -and !(Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
            [IO.File]::WriteAllBytes($outfile, [Convert]::FromBase64String($resp.image))
            Write-Host "Saved: $outfile" -ForegroundColor Cyan
        }
    } catch { Write-Host "shellama: $_" -ForegroundColor Red }
}

function ,test {
    $testArgs = $args -join ' '
    $body = @{ model = if ($testArgs) { $testArgs } else { "all" } } | ConvertTo-Json
    try {
        $resp = Invoke-RestMethod -Uri "$($script:SHELLAMA_API)/test" -Method Post -Body $body -Headers (Get-ShellamaHeaders) -TimeoutSec 3600
        if ($resp.error) { Write-Host "shellama: $($resp.error)" -ForegroundColor Red; return }
        if ($resp.skipped) { Write-Host "Skipped (too large): $($resp.skipped -join ', ')" -ForegroundColor DarkGray }
        $results = $resp.results | Where-Object { -not $_.error }
        if ($results.Count -eq 0) { Write-Host "No results"; return }
        Write-Host ("{0,-30} {1,7} {2,7} {3,7} {4,7} {5,7}" -f "Model","Time","Prompt","Reply","Total","tok/s") -ForegroundColor Cyan
        foreach ($r in ($results | Sort-Object elapsed)) {
            Write-Host ("{0,-30} {1,6:F1}s {2,7} {3,7} {4,7} {5,6:F1}" -f $r.model,$r.elapsed,$r.prompt_tokens,$r.response_tokens,$r.total_tokens,$r.tok_per_sec)
        }
        if ($resp.cloud_costs) {
            Write-Host "`nCloud cost estimate ($($resp.pricing_source)):" -ForegroundColor Cyan
            foreach ($c in $resp.cloud_costs) {
                Write-Host ("{0,-25} `${1,8:F6}" -f $c.provider,$c.total_cost)
            }
            Write-Host "`nLocal models: `$0.00" -ForegroundColor DarkGray
        }
    } catch { Write-Host "shellama: $_" -ForegroundColor Red }
}

function ,models {
    try {
        $resp = Invoke-RestMethod -Uri "$($script:SHELLAMA_API)/models" -Headers (Get-ShellamaHeaders) -TimeoutSec 10
        $models = $resp.models
        Write-Host "Available models:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $models.Count; $i++) {
            $current = if ($models[$i].name -eq $script:SHELLAMA_MODEL) { " <- current" } else { "" }
            Write-Host "  $($i+1)) $($models[$i].name)$current" -ForegroundColor Yellow
        }
        $choice = Read-Host "Select [1-$($models.Count)]"
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $models.Count) {
            $script:SHELLAMA_MODEL = $models[[int]$choice - 1].name
            Write-Host "model: $($script:SHELLAMA_MODEL)"
        }
    } catch { Write-Host "shellama: $_" -ForegroundColor Red }
}

function ,tokens { Write-Host "Session usage: $($script:SessionRequests) requests | $($script:SessionTokens) tokens | $([math]::Round($script:SessionElapsed,1))s" -ForegroundColor Cyan }

function ,save {
    $file = $args -join ' '
    if (-not $file) { Write-Host "Usage: ,save <filename>" -ForegroundColor Red; return }
    if (-not $script:LastOutput) { Write-Host "shellama: nothing to save (no AI output yet)" -ForegroundColor Red; return }
    $content = $script:LastOutput.Trim()
    if ($content -match '(?s)^```\w*\n(.*?)```$') { $content = $Matches[1] }
    Set-Content -Path $file -Value $content -Encoding UTF8
    Write-Host "saved: $file ($($content.Length) chars)"
}

function ,list {
    Write-Host ",  <prompt>       agentic chat" -ForegroundColor Yellow
    Write-Host ",,  <prompt>      quiet mode" -ForegroundColor Yellow
    Write-Host ",explain  <file>  explain any file" -ForegroundColor Yellow
    Write-Host ",generate <desc>  generate code" -ForegroundColor Yellow
    Write-Host ",analyze  <path>  analyze files/dirs" -ForegroundColor Yellow
    Write-Host ",img <prompt>     generate image" -ForegroundColor Yellow
    Write-Host ",save <file>      save last output" -ForegroundColor Yellow
    Write-Host ",session          save/load sessions" -ForegroundColor Yellow
    Write-Host ",context          manage context files" -ForegroundColor Yellow
    Write-Host ",test [model]     benchmark models" -ForegroundColor Yellow
    Write-Host ",models           select model" -ForegroundColor Yellow
    Write-Host ",mode             toggle do/chat" -ForegroundColor Yellow
    Write-Host ",tokens           session usage" -ForegroundColor Yellow
    Write-Host ",exit             unload sheLLaMa" -ForegroundColor Yellow
}

function ,help { ,list }

# Add HAL eye to prompt
# Save original prompt
$script:_OriginalPrompt = (Get-Command prompt).ScriptBlock
function prompt { "🔴 $(Get-Location)> " }

function ,exit {
    # Restore original prompt
    Set-Item Function:\prompt $script:_OriginalPrompt
    # Remove all , functions
    ',', ',,', ',explain', ',generate', ',analyze', ',img', ',save', ',session', ',context', ',test', ',models', ',tokens', ',list', ',help', ',exit' | ForEach-Object {
        Remove-Item "Function:\$_" -ErrorAction SilentlyContinue
    }
    Remove-Variable _OriginalPrompt -Scope Script -ErrorAction SilentlyContinue
    Write-Host "sheLLaMa unloaded" -ForegroundColor DarkGray
}

Write-Host "sheLLaMa loaded — type ,list for commands (,exit to unload)" -ForegroundColor DarkGray
