# sheLLaMa shared PowerShell config — sourced by shellama.ps1 and GUI files
$script:SHELLAMA_API = if ($env:SHELLAMA_API) { $env:SHELLAMA_API } else { "http://192.168.1.229:5000" }
$script:SHELLAMA_MODEL = if ($env:SHELLAMA_MODEL) { $env:SHELLAMA_MODEL } else { "auto" }
$script:SHELLAMA_API_KEY = if ($env:SHELLAMA_API_KEY) { $env:SHELLAMA_API_KEY } else { "" }
$script:SHELLAMA_CONV_ID = if ($env:SHELLAMA_CONV_ID) { $env:SHELLAMA_CONV_ID } else { [guid]::NewGuid().ToString() }
$script:SHELLAMA_DOWNLOAD_DIR = if ($env:SHELLAMA_DOWNLOAD_DIR) { $env:SHELLAMA_DOWNLOAD_DIR } else { "" }
$script:SHELLAMA_SYSTEM_PROMPT = @"
You are an AI assistant running inside a PowerShell session.
Current directory: {0}

You have three tools available. Use the appropriate fenced block for each:

## 1. Run PowerShell commands
``````powershell
Get-ChildItem
``````

## 2. Read files
``````file_read
path/to/file.ps1
``````

## 3. Write files
``````file_write path/to/file.ps1
content goes here
``````

IMPORTANT:
- Use ``````file_read instead of Get-Content for reading files
- Use ``````file_write instead of Set-Content for creating/editing files
- Use ``````powershell for everything else
- ONLY use these three block types for actions you want executed
- For code examples, use other language tags or no tag
- When you have enough info, give your final answer as plain text with no tool blocks
- Keep commands short and focused
- Never run destructive commands without the user explicitly asking
"@

function Get-ShellamaHeaders {
    $headers = @{ "Content-Type" = "application/json" }
    if ($script:SHELLAMA_API_KEY) { $headers["X-API-Key"] = $script:SHELLAMA_API_KEY }
    return $headers
}
