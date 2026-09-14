#Requires -Version 5.1
<#
    pr-review.ps1 - fetch a pull request for review, and post the review back
    as line-anchored comments through the GitHub REST API.

      pr-review.ps1 fetch --pr <N> [--config <file>] [--host H] [--repo O/R]
                          [--no-diff] [--no-annotate] [--max-diff-lines N]

      pr-review.ps1 post  --pr <N> --comments <file> [--config <file>]
                          [--event COMMENT|APPROVE|REQUEST_CHANGES]
                          [--body <text> | --body-file <file>]
                          [--commit-id <sha>] [--no-verify-paths] [--dry-run]

    Windows PowerShell 5.1 or PowerShell 7. The GitHub CLI (gh) is the only
    external dependency - all JSON is handled by PowerShell itself.

    config.json only has to name the host and repo. Diff limits, path
    exclusions and review conventions are optional overrides of the defaults
    below. Command-line flags win over the config; the config wins over the
    defaults.

    `post` writes to GitHub. Run it with --dry-run first and show the payload.
#>

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# gh emits UTF-8; make sure Windows PowerShell reads it as such.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$EXIT_USAGE      = 1
$EXIT_DEPENDENCY = 2
$EXIT_AUTH       = 3
$EXIT_NOT_FOUND  = 4
$EXIT_INPUT      = 5
$EXIT_API        = 6

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$DefaultHost         = 'sgithub.fr.world.socgen'   # (change it to org host name here)
$DefaultMaxDiffLines = 800
$DefaultEvent        = 'COMMENT'

# Generated, vendored and binary files, skipped unless fetch.excludePaths
# overrides this list in the config.
$DefaultExcludePatterns = @(
    '*.lock', 'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'poetry.lock',
    'Cargo.lock', 'go.sum', 'composer.lock', 'Gemfile.lock',
    '*.min.js', '*.min.css', '*.map', '*.snap', '*.svg', '*.png', '*.jpg', '*.pdf',
    'dist/*', 'build/*', 'vendor/*', 'node_modules/*', '*/generated/*',
    '*.pb.go', '*_pb2.py'
)

$State = [ordered]@{
    Command      = ''
    ConfigPath   = ''
    PrNumber     = ''
    GhHost       = ''
    Repo         = ''
    MaxDiffLines = $null
    IncludeDiff  = $null
    CommentsFile = ''
    Event        = ''
    Body         = ''
    BodyFile     = ''
    CommitId     = ''
    VerifyPaths  = $true
    Annotate     = $true
    DryRun       = $false
    Profile      = ''
    ConfigFile   = ''
    Effective    = $null
    Exclude      = @()
    TmpDir       = ''
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Log  { param([string]$Message) [Console]::Error.WriteLine("[INFO] $Message") }
function Write-Warn { param([string]$Message) [Console]::Error.WriteLine("[WARN] $Message") }

function Stop-WithError {
    param([int]$Code, [string]$Tag, [string]$Message)
    [Console]::Error.WriteLine("${Tag}: $Message")
    Exit-Script $Code
}

function Exit-Script {
    param([int]$Code)
    if ($State.TmpDir -and (Test-Path -LiteralPath $State.TmpDir)) {
        Remove-Item -LiteralPath $State.TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    [Console]::Out.Flush()
    [Console]::Error.Flush()
    exit $Code
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Show-Usage {
@'
Usage:
  pr-review.ps1 fetch --pr <NUMBER> [options]
  pr-review.ps1 post  --pr <NUMBER> --comments <FILE> [options]

Common options:
  --config <FILE>          config.json to use (default: alongside this script)
  --profile <NAME>         apply a named profile from the config's "profiles" block
  --host <HOST>            GitHub host; defaults to github.host from the config
  --repo <OWNER/REPO>      target repository; a clone URL or web link also works
  -h, --help               show this message

  --pr accepts 7, #7, or a full pull request URL. A URL supplies the host and
  repository too, so --host and --repo become unnecessary.

fetch options:
  --no-diff                metadata only, skip the unified diff
  --no-annotate            emit a plain unified diff instead of a line-numbered one
  --max-diff-lines <N>     truncate the diff at N lines (0 = unlimited)

post options:
  --comments <FILE>        JSON array of line-anchored comments
  --event <EVENT>          COMMENT (default), APPROVE or REQUEST_CHANGES
  --body <TEXT>            review summary shown above the inline comments
  --body-file <FILE>       read the summary from a file instead
  --commit-id <SHA>        default: current head commit of the PR
  --no-verify-paths        skip checking comment paths and lines against the diff
  --dry-run                print the payload without posting

Comment entry format:
  { "path": "src/app.ts", "line": 42, "side": "RIGHT", "body": "..." }
  Optional: "start_line" and "start_side" for a multi-line range.

Exit codes:
  1 usage   2 missing dependency   3 auth   4 not found   5 bad input   6 API error
'@ | ForEach-Object { [Console]::Error.WriteLine($_) }
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

function Read-Arguments {
    param([string[]]$Arguments)

    if ($Arguments.Count -eq 0) { Show-Usage; Exit-Script $EXIT_USAGE }

    switch ($Arguments[0]) {
        'fetch'  { $State.Command = 'fetch' }
        'post'   { $State.Command = 'post' }
        '-h'     { Show-Usage; Exit-Script 0 }
        '--help' { Show-Usage; Exit-Script 0 }
        default  {
            Show-Usage
            Stop-WithError $EXIT_USAGE 'UNKNOWN_COMMAND' "'$($Arguments[0])' is not a command. Expected 'fetch' or 'post'."
        }
    }

    $i = 1
    while ($i -lt $Arguments.Count) {
        $flag = $Arguments[$i]
        $needsValue = $true
        switch -CaseSensitive ($flag) {
            '--pr'             { $State.PrNumber     = $Arguments[$i + 1] }
            '-p'               { $State.PrNumber     = $Arguments[$i + 1] }
            '--config'         { $State.ConfigPath   = $Arguments[$i + 1] }
            '--profile'        { $State.Profile      = $Arguments[$i + 1] }
            '--host'           { $State.GhHost       = $Arguments[$i + 1] }
            '--repo'           { $State.Repo         = $Arguments[$i + 1] }
            '-r'               { $State.Repo         = $Arguments[$i + 1] }
            '--max-diff-lines' { $State.MaxDiffLines = $Arguments[$i + 1] }
            '--comments'       { $State.CommentsFile = $Arguments[$i + 1] }
            '--comments-file'  { $State.CommentsFile = $Arguments[$i + 1] }
            '--event'          { $State.Event        = $Arguments[$i + 1] }
            '--body'           { $State.Body         = $Arguments[$i + 1] }
            '--body-file'      { $State.BodyFile     = $Arguments[$i + 1] }
            '--commit-id'      { $State.CommitId     = $Arguments[$i + 1] }
            '--no-diff'        { $State.IncludeDiff = $false; $needsValue = $false }
            '--no-annotate'    { $State.Annotate    = $false; $needsValue = $false }
            '--no-verify-paths'{ $State.VerifyPaths = $false; $needsValue = $false }
            '--dry-run'        { $State.DryRun      = $true;  $needsValue = $false }
            '-h'               { Show-Usage; Exit-Script 0 }
            '--help'           { Show-Usage; Exit-Script 0 }
            default {
                Show-Usage
                Stop-WithError $EXIT_USAGE 'UNKNOWN_ARGUMENT' "'$flag' is not a recognised option."
            }
        }
        if ($needsValue) {
            if ($i + 1 -ge $Arguments.Count) {
                Stop-WithError $EXIT_USAGE 'MISSING_VALUE' "'$flag' expects a value."
            }
            $i += 2
        } else {
            $i += 1
        }
    }
}

function Split-RepoUrl {
    param([string]$Url)
    $rest = $Url -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', ''
    $parts = $rest.Split('/')
    if ($parts.Count -lt 3) { return $null }
    $owner = $parts[1]
    $name  = $parts[2] -replace '\.git$', ''
    return [pscustomobject]@{ Host = $parts[0]; Repo = "$owner/$name" }
}

function Resolve-Targets {
    if ($State.PrNumber -like '*://*') {
        $url = ($State.PrNumber -split '\?')[0]
        $url = ($url -split '#')[0]
        $rest = $url -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', ''
        if ($rest -notmatch '^([^/]+)/([^/]+)/([^/]+)/pulls?/([0-9]+)') {
            Stop-WithError $EXIT_INPUT 'INVALID_PR_URL' "'$($State.PrNumber)' is not a pull request URL."
        }
        if (-not $State.GhHost) { $State.GhHost = $Matches[1] }
        if (-not $State.Repo)   { $State.Repo   = "$($Matches[2])/$($Matches[3])" }
        $State.PrNumber = $Matches[4]
    } else {
        $State.PrNumber = $State.PrNumber -replace '^#', ''
    }

    if ($State.Repo -like '*://*') {
        $parsed = Split-RepoUrl $State.Repo
        if (-not $parsed) {
            Stop-WithError $EXIT_INPUT 'INVALID_REPO_URL' "'$($State.Repo)' is not a repository URL."
        }
        if (-not $State.GhHost) { $State.GhHost = $parsed.Host }
        $State.Repo = $parsed.Repo
    } elseif ($State.Repo -match '^git@([^:]+):(.+)$') {
        if (-not $State.GhHost) { $State.GhHost = $Matches[1] }
        $State.Repo = $Matches[2] -replace '\.git$', ''
    }
}

# ---------------------------------------------------------------------------
# Prerequisites and the gh wrapper
# ---------------------------------------------------------------------------

function Test-Requirements {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Stop-WithError $EXIT_DEPENDENCY 'GH_NOT_FOUND' 'the GitHub CLI is not installed or not in PATH.'
    }
}

# Runs gh against the configured host and hands back stdout, stderr and the
# exit code instead of throwing, so callers can classify the failure.
function Invoke-Gh {
    param([string[]]$Arguments)

    $errFile = Join-Path $State.TmpDir ("gh-{0}.err" -f ([guid]::NewGuid().ToString('N')))
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $env:GH_HOST = $State.GhHost
    $stdout = & gh @Arguments 2> $errFile
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous

    $stderr = ''
    if (Test-Path -LiteralPath $errFile) {
        $stderr = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        Out      = ($stdout | Out-String)
        Lines    = @($stdout)
        Err      = ([string]$stderr)
        ExitCode = $code
    }
}

function Stop-OnGhError {
    param([string]$ErrorText)
    if ($ErrorText -match '(?i)could not resolve|http 404|not found') {
        Stop-WithError $EXIT_NOT_FOUND 'PR_NOT_FOUND' "PR #$($State.PrNumber) not found in $($State.Repo) on $($State.GhHost)."
    } elseif ($ErrorText -match '(?i)http 401|http 403|permission|forbidden') {
        Stop-WithError $EXIT_AUTH 'GH_AUTH_ERROR' "insufficient permissions for $($State.Repo) on $($State.GhHost)."
    } else {
        Stop-WithError $EXIT_API 'GH_API_ERROR' $ErrorText
    }
}

function Test-Authentication {
    $result = Invoke-Gh @('auth', 'status', '--hostname', $State.GhHost)
    if ($result.ExitCode -ne 0) {
        Stop-WithError $EXIT_AUTH 'GH_AUTH_FAILED' "not authenticated to $($State.GhHost). Run: gh auth login --hostname $($State.GhHost)"
    }
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function Read-JsonFile {
    param([string]$Path, [string]$Tag)
    try {
        $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if (-not $text -or -not $text.Trim()) { return [pscustomobject]@{} }
        return ($text | ConvertFrom-Json)
    } catch {
        Stop-WithError $EXIT_INPUT $Tag "'$Path' is not valid JSON."
    }
}

function Test-IsObject {
    param($Value)
    return ($null -ne $Value -and $Value -is [psobject] -and -not ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])))
}

function Test-HasProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [string]) { return $false }
    $properties = $Object.PSObject.Properties
    if ($null -eq $properties) { return $false }
    return ($null -ne $properties[$Name])
}

function Get-Property {
    param($Object, [string]$Name)
    if (-not (Test-HasProperty $Object $Name)) { return $null }
    return $Object.PSObject.Properties[$Name].Value
}

# Objects merge key by key; anything else - arrays included - replaces wholesale,
# so an overriding excludePaths list is taken exactly as written.
function Merge-Object {
    param($Base, $Overlay)

    if ($null -eq $Overlay) { return $Base }
    if ($null -eq $Base) { return $Overlay }
    if (-not (Test-IsObject $Base) -or -not (Test-IsObject $Overlay)) { return $Overlay }

    $merged = [ordered]@{}
    foreach ($property in $Base.PSObject.Properties) { $merged[$property.Name] = $property.Value }
    foreach ($property in $Overlay.PSObject.Properties) {
        if ($merged.Contains($property.Name)) {
            $merged[$property.Name] = Merge-Object $merged[$property.Name] $property.Value
        } else {
            $merged[$property.Name] = $property.Value
        }
    }
    return [pscustomobject]$merged
}

function Remove-Property {
    param($Object, [string[]]$Names)
    if (-not (Test-IsObject $Object)) { return $Object }
    $kept = [ordered]@{}
    foreach ($property in $Object.PSObject.Properties) {
        if ($Names -notcontains $property.Name) { $kept[$property.Name] = $property.Value }
    }
    return [pscustomobject]$kept
}

function Resolve-ConfigFile {
    if ($State.ConfigPath) {
        if (-not (Test-Path -LiteralPath $State.ConfigPath -PathType Leaf)) {
            Stop-WithError $EXIT_INPUT 'CONFIG_NOT_FOUND' "'$($State.ConfigPath)' does not exist."
        }
        $State.ConfigFile = (Resolve-Path -LiteralPath $State.ConfigPath).Path
        return
    }

    if ($env:PR_REVIEW_CONFIG -and (Test-Path -LiteralPath $env:PR_REVIEW_CONFIG -PathType Leaf)) {
        $State.ConfigFile = (Resolve-Path -LiteralPath $env:PR_REVIEW_CONFIG).Path
        return
    }

    foreach ($candidate in @(
        (Join-Path $ScriptDir 'config.json'),
        (Join-Path (Split-Path -Parent $ScriptDir) 'config.json'),
        (Join-Path (Get-Location).Path 'pr-review.config.json')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $State.ConfigFile = (Resolve-Path -LiteralPath $candidate).Path
            return
        }
    }

    $State.ConfigFile = ''
}

# Layers, lowest precedence first: the committed config, the selected profile,
# then config.local.json sitting beside it. review.teamRulesAdd is the one
# exception to "arrays replace": it appends to the inherited rules, so a team
# can extend the baseline without restating it.
function Build-EffectiveConfig {
    $base  = [pscustomobject]@{}
    $local = [pscustomobject]@{}

    if ($State.ConfigFile) {
        $base = Read-JsonFile $State.ConfigFile 'INVALID_CONFIG'
        $localFile = Join-Path (Split-Path -Parent $State.ConfigFile) 'config.local.json'
        if (Test-Path -LiteralPath $localFile -PathType Leaf) {
            $local = Read-JsonFile $localFile 'INVALID_LOCAL_CONFIG'
            Write-Log "Overlay: $localFile"
        }
    }

    if (-not $State.Profile) { $State.Profile = [string]$env:PR_REVIEW_PROFILE }
    if (-not $State.Profile) { $State.Profile = [string](Get-Property $base 'defaultProfile') }

    $selected = [pscustomobject]@{}
    if ($State.Profile) {
        $profiles = Get-Property $base 'profiles'
        $candidate = Get-Property $profiles $State.Profile
        if ($null -eq $candidate) {
            Stop-WithError $EXIT_INPUT 'PROFILE_NOT_FOUND' "'$($State.Profile)' is not defined under `"profiles`" in the config."
        }
        $selected = $candidate
        Write-Log "Profile: $($State.Profile)"
    }

    $root = Remove-Property $base @('profiles', 'defaultProfile')
    $merged = Merge-Object (Merge-Object $root $selected) $local

    $rules = @()
    $rules += @(Get-Property (Get-Property $merged 'review') 'teamRules')
    $rules += @(Get-Property (Get-Property $selected 'review') 'teamRulesAdd')
    $rules += @(Get-Property (Get-Property $local 'review') 'teamRulesAdd')
    $rules = @($rules | Where-Object { $null -ne $_ })

    $review = Get-Property $merged 'review'
    if (Test-IsObject $review) {
        $review = Remove-Property $review @('teamRulesAdd')
        if ($rules.Count -gt 0) {
            $review = Merge-Object $review ([pscustomobject]@{ teamRules = $rules })
        }
        $merged = Merge-Object (Remove-Property $merged @('review')) ([pscustomobject]@{ review = $review })
    }

    $State.Effective = $merged
}

function Get-ConfigValue {
    param([string]$Path, $Fallback)
    $node = $State.Effective
    foreach ($segment in $Path.Split('.')) {
        $node = Get-Property $node $segment
        if ($null -eq $node) { return $Fallback }
    }
    if ($node -is [string] -and -not $node) { return $Fallback }
    return $node
}

function Import-Configuration {
    Resolve-ConfigFile

    if ($State.ConfigFile) {
        Write-Log "Config: $($State.ConfigFile)"
    } else {
        Write-Warn 'No config.json found - using built-in defaults.'
    }

    Build-EffectiveConfig

    if (-not $State.GhHost)              { $State.GhHost      = [string](Get-ConfigValue 'github.host' $DefaultHost) }
    if (-not $State.Repo)                { $State.Repo        = [string](Get-ConfigValue 'github.repo' '') }
    if (-not $State.Event)               { $State.Event       = [string](Get-ConfigValue 'review.defaultEvent' $DefaultEvent) }
    if ($null -eq $State.MaxDiffLines)   { $State.MaxDiffLines = Get-ConfigValue 'fetch.maxDiffLines' $DefaultMaxDiffLines }
    if ($null -eq $State.IncludeDiff)    { $State.IncludeDiff  = Get-ConfigValue 'fetch.includeDiff' $true }

    $State.MaxDiffLines = [int]$State.MaxDiffLines
    $State.IncludeDiff  = [bool]$State.IncludeDiff

    # An explicit excludePaths replaces the built-in list, including when it is
    # empty, which is how exclusion is switched off. Absent means "use defaults".
    $fetchSection = Get-ConfigValue 'fetch' $null
    if (Test-HasProperty $fetchSection 'excludePaths') {
        $State.Exclude = @(@(Get-Property $fetchSection 'excludePaths') | Where-Object { $_ })
    } else {
        $State.Exclude = $DefaultExcludePatterns
    }

    if (-not $State.Repo -or $State.Repo -eq 'OWNER/REPO') {
        Stop-WithError $EXIT_INPUT 'REPO_NOT_CONFIGURED' 'set github.repo in config.json or pass --repo OWNER/REPO.'
    }
    if ($State.Repo -notlike '*/*') {
        Stop-WithError $EXIT_INPUT 'INVALID_REPO' "'$($State.Repo)' is not in OWNER/REPO form."
    }
}

function Test-PrNumber {
    if (-not $State.PrNumber) {
        Stop-WithError $EXIT_USAGE 'MISSING_PR_NUMBER' '--pr is required.'
    }
    if ($State.PrNumber -notmatch '^[0-9]+$') {
        Stop-WithError $EXIT_USAGE 'INVALID_PR_NUMBER' "'$($State.PrNumber)' is not a positive integer."
    }
}

function Test-PathExcluded {
    param([string]$Path)
    $leaf = $Path.Split('/')[-1]
    foreach ($pattern in $State.Exclude) {
        if ($Path -like $pattern -or $leaf -like $pattern) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Diff shaping
#
# The annotated form carries the new-file line number on every line that has
# one, so a reviewer never has to derive it from a hunk header. Removed lines
# keep no number because they do not exist in the new file.
# ---------------------------------------------------------------------------

function ConvertTo-AnnotatedDiff {
    param([string[]]$DiffLines, [string[]]$Excluded, [bool]$Annotate)

    $output = New-Object System.Collections.Generic.List[string]
    $skip = $false
    $inHunk = $false
    $lineNumber = 0

    foreach ($line in $DiffLines) {
        if ($line -like 'diff --git *') {
            $marker = $line.IndexOf(' b/')
            $current = if ($marker -ge 0) { $line.Substring($marker + 3) } else { '' }
            $skip = $Excluded -contains $current
            $inHunk = $false
            if (-not $skip) { $output.Add($line) }
            continue
        }
        if ($skip) { continue }
        if (-not $Annotate) { $output.Add($line); continue }
        if ($line -like '@@ *') {
            if ($line -match '\+([0-9]+)') { $lineNumber = [int]$Matches[1] }
            $inHunk = $true
            $output.Add($line)
            continue
        }
        # Everything between "diff --git" and the first hunk is git's extended
        # header - index, mode, rename and ---/+++ lines - and is not content.
        if (-not $inHunk) { continue }
        if ($line -like '\*') { continue }
        if (-not $line) { $output.Add('') ; continue }

        $tag  = $line.Substring(0, 1)
        $body = $line.Substring(1)
        if ($tag -eq '+') {
            $output.Add(('+{0,6} | {1}' -f $lineNumber, $body)); $lineNumber++
        } elseif ($tag -eq '-') {
            $output.Add(('-       | {0}' -f $body))
        } else {
            $output.Add((' {0,6} | {1}' -f $lineNumber, $body)); $lineNumber++
        }
    }

    return $output.ToArray()
}

# Every "path<TAB>line" pair that can legally carry a RIGHT-side comment.
function Get-RightLineIndex {
    param([string[]]$DiffLines)

    $index = New-Object 'System.Collections.Generic.HashSet[string]'
    $current = ''
    $inHunk = $false
    $lineNumber = 0

    foreach ($line in $DiffLines) {
        if ($line -like 'diff --git *') {
            $marker = $line.IndexOf(' b/')
            $current = if ($marker -ge 0) { $line.Substring($marker + 3) } else { '' }
            $inHunk = $false
            continue
        }
        if ($line -like '@@ *') {
            if ($line -match '\+([0-9]+)') { $lineNumber = [int]$Matches[1] }
            $inHunk = $true
            continue
        }
        if (-not $inHunk) { continue }
        if ($line -like '\*') { continue }
        if ($line -like '-*') { continue }
        [void]$index.Add("$current`t$lineNumber")
        $lineNumber++
    }

    return $index
}

# ---------------------------------------------------------------------------
# fetch
# ---------------------------------------------------------------------------

$PrFields = 'number,url,title,state,isDraft,author,baseRefName,headRefName,headRefOid,createdAt,updatedAt,mergedAt,body,additions,deletions,changedFiles,files,labels,assignees,reviewRequests,statusCheckRollup,reviews'

function Get-PullRequest {
    $result = Invoke-Gh @('pr', 'view', $State.PrNumber, '--repo', $State.Repo, '--json', $PrFields)
    if ($result.ExitCode -ne 0) { Stop-OnGhError $result.Err }
    try {
        return ($result.Out | ConvertFrom-Json)
    } catch {
        Stop-WithError $EXIT_API 'GH_API_ERROR' 'the GitHub CLI returned output that is not valid JSON.'
    }
}

function Get-PullRequestDiff {
    $result = Invoke-Gh @('pr', 'diff', $State.PrNumber, '--repo', $State.Repo)
    if ($result.ExitCode -ne 0) { return $null }
    return @($result.Lines)
}

function Invoke-Fetch {
    Test-PrNumber
    Test-Authentication

    Write-Log "Repo: $($State.Repo) | PR: #$($State.PrNumber) | Host: $($State.GhHost)"

    $pr = Get-PullRequest
    Write-Log 'Metadata fetched'

    $files = @(Get-Property $pr 'files')
    $excluded = @($files | Where-Object { $_ -and (Test-PathExcluded $_.path) } | ForEach-Object { $_.path })
    if ($excluded.Count -gt 0) {
        Write-Log "Excluding $($excluded.Count) file(s) matched by fetch.excludePaths"
    }

    $diffIncluded  = $false
    $diffTruncated = $false
    $diffLineCount = 0
    $diffContent   = $null

    if ($State.IncludeDiff) {
        $raw = Get-PullRequestDiff
        if ($null -eq $raw) {
            Write-Warn 'Could not fetch the diff; returning metadata only.'
        } else {
            $annotated = ConvertTo-AnnotatedDiff -DiffLines $raw -Excluded $excluded -Annotate $State.Annotate
            $diffIncluded = $true
            $diffLineCount = $annotated.Count

            if ($State.MaxDiffLines -gt 0 -and $diffLineCount -gt $State.MaxDiffLines) {
                $annotated = $annotated[0..($State.MaxDiffLines - 1)]
                $diffTruncated = $true
                Write-Log "Diff truncated to $($State.MaxDiffLines) of $diffLineCount reviewable lines"
            } else {
                Write-Log "Diff fetched - $diffLineCount reviewable lines"
            }
            $diffContent = ($annotated -join "`n")
        }
    }

    $checkStates = @(@(Get-Property $pr 'statusCheckRollup') | Where-Object { $_ } | ForEach-Object {
        $value = if (Get-Property $_ 'conclusion') { Get-Property $_ 'conclusion' }
                 elseif (Get-Property $_ 'state') { Get-Property $_ 'state' }
                 else { 'UNKNOWN' }
        ([string]$value).ToUpperInvariant()
    })

    $overall =
        if ($checkStates.Count -eq 0) { 'NONE' }
        elseif ($checkStates | Where-Object { $_ -in @('FAILURE', 'ERROR', 'TIMED_OUT') }) { 'FAILURE' }
        elseif ($checkStates | Where-Object { $_ -in @('PENDING', 'IN_PROGRESS', 'QUEUED') }) { 'PENDING' }
        elseif (-not (@($checkStates | Where-Object { $_ -notin @('SUCCESS', 'NEUTRAL', 'SKIPPED') }).Count)) { 'SUCCESS' }
        else { 'MIXED' }

    $failing = @(@(Get-Property $pr 'statusCheckRollup') | Where-Object {
        $conclusion = Get-Property $_ 'conclusion'
        if (-not $conclusion) { $conclusion = Get-Property $_ 'state' }
        ([string]$conclusion).ToUpperInvariant() -in @('FAILURE', 'ERROR', 'TIMED_OUT')
    } | ForEach-Object {
        $name = Get-Property $_ 'name'
        if ($name) { $name } else { Get-Property $_ 'context' }
    })

    $reviews = @(Get-Property $pr 'reviews')

    $payload = [ordered]@{
        host        = $State.GhHost
        repo        = $State.Repo
        number      = $pr.number
        url         = $pr.url
        title       = $pr.title
        state       = $pr.state
        isDraft     = $pr.isDraft
        author      = $(if ((Get-Property $pr 'author') -and $pr.author.login) { $pr.author.login } else { 'unknown' })
        baseRef     = $pr.baseRefName
        headRef     = $pr.headRefName
        headSha     = $pr.headRefOid
        createdAt   = $pr.createdAt
        updatedAt   = $pr.updatedAt
        mergedAt    = (Get-Property $pr 'mergedAt')
        description = [string](Get-Property $pr 'body')
        stats       = [ordered]@{
            additions    = $pr.additions
            deletions    = $pr.deletions
            changedFiles = $pr.changedFiles
        }
        labels              = @(@(Get-Property $pr 'labels') | Where-Object { $_ } | ForEach-Object { $_.name })
        assignees           = @(@(Get-Property $pr 'assignees') | Where-Object { $_ } | ForEach-Object { $_.login })
        reviewRequestedFrom = @(@(Get-Property $pr 'reviewRequests') | Where-Object { $_ } | ForEach-Object {
            $login = Get-Property $_ 'login'
            if ($login) { $login } else { Get-Property $_ 'name' }
        })
        changedFiles = @($files | Where-Object { $_ } | ForEach-Object {
            [ordered]@{
                path      = $_.path
                status    = $(if ($_.additions -gt 0 -and $_.deletions -eq 0) { 'added' }
                              elseif ($_.additions -eq 0 -and $_.deletions -gt 0) { 'deleted' }
                              else { 'modified' })
                additions = $_.additions
                deletions = $_.deletions
                excluded  = ($excluded -contains $_.path)
            }
        })
        excludedFiles = $excluded
        checks = [ordered]@{ overall = $overall; failing = $failing }
        reviewSummary = [ordered]@{
            approved         = @($reviews | Where-Object { $_ -and $_.state -eq 'APPROVED' }).Count
            changesRequested = @($reviews | Where-Object { $_ -and $_.state -eq 'CHANGES_REQUESTED' }).Count
            commented        = @($reviews | Where-Object { $_ -and $_.state -eq 'COMMENTED' }).Count
        }
        existingReviews = @($reviews | Where-Object { $_ } | ForEach-Object {
            [ordered]@{
                author      = $(if ((Get-Property $_ 'author') -and $_.author.login) { $_.author.login } else { 'unknown' })
                state       = $_.state
                body        = [string](Get-Property $_ 'body')
                submittedAt = (Get-Property $_ 'submittedAt')
            }
        })
        reviewConfig = $(
            $review = Get-ConfigValue 'review' $null
            if ($null -eq $review) { [pscustomobject]@{} } else { $review }
        )
        diff = [ordered]@{
            included   = $diffIncluded
            truncated  = $diffTruncated
            annotated  = ($diffIncluded -and $State.Annotate)
            lineNumberHint = $(if ($diffIncluded -and $State.Annotate) {
                'Each line is prefixed with its line number in the NEW file. Use that number directly as "line"; lines marked - have no number and cannot be commented on with side RIGHT.'
            } else { $null })
            reviewableLines = $diffLineCount
            maxLines        = $State.MaxDiffLines
            content         = $diffContent
        }
    }

    ([pscustomobject]$payload | ConvertTo-Json -Depth 20)
}

# ---------------------------------------------------------------------------
# post
# ---------------------------------------------------------------------------

function Read-Comments {
    try {
        $text = Get-Content -LiteralPath $State.CommentsFile -Raw -Encoding UTF8
    } catch {
        Stop-WithError $EXIT_INPUT 'INVALID_JSON' "'$($State.CommentsFile)' could not be read."
    }

    # ConvertFrom-Json unwraps a one-element array, so the top-level shape has
    # to be checked on the text before it is parsed.
    if (-not $text -or -not $text.TrimStart().StartsWith('[')) {
        Stop-WithError $EXIT_INPUT 'INVALID_COMMENTS_FORMAT' "'$($State.CommentsFile)' must hold a top-level JSON array."
    }

    try {
        $list = @($text | ConvertFrom-Json)
    } catch {
        Stop-WithError $EXIT_INPUT 'INVALID_JSON' "'$($State.CommentsFile)' is not valid JSON."
    }

    if ($list.Count -eq 0) {
        Stop-WithError $EXIT_INPUT 'EMPTY_COMMENTS' "'$($State.CommentsFile)' contains no comments."
    }

    $problems = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $list.Count; $i++) {
        $c = $list[$i]
        $path       = Get-Property $c 'path'
        $line       = Get-Property $c 'line'
        $body       = Get-Property $c 'body'
        $side       = Get-Property $c 'side'
        $startSide  = Get-Property $c 'start_side'
        $startLine  = Get-Property $c 'start_line'

        if (-not ($path -is [string]) -or -not $path) { $problems.Add("entry ${i}: missing or non-string `"path`"") }
        if ($null -eq $line -or -not ($line -is [int] -or $line -is [long] -or $line -is [double])) { $problems.Add("entry ${i}: missing or non-numeric `"line`"") }
        if (-not ($body -is [string]) -or -not $body) { $problems.Add("entry ${i}: missing or empty `"body`"") }
        if ($null -ne $side -and $side -notin @('LEFT', 'RIGHT')) { $problems.Add("entry ${i}: `"side`" must be LEFT or RIGHT") }
        if ($null -ne $startSide -and $startSide -notin @('LEFT', 'RIGHT')) { $problems.Add("entry ${i}: `"start_side`" must be LEFT or RIGHT") }
        if ($null -ne $startLine) {
            if (-not ($startLine -is [int] -or $startLine -is [long] -or $startLine -is [double])) {
                $problems.Add("entry ${i}: `"start_line`" must be numeric")
            } elseif ($null -ne $line -and $startLine -gt $line) {
                $problems.Add("entry ${i}: `"start_line`" must not be greater than `"line`"")
            }
        }
        if ($null -ne (Get-Property $c 'subject_type')) {
            $problems.Add("entry ${i}: file-level comments are not supported inside a batch review; fold that finding into --body")
        }
    }

    if ($problems.Count -gt 0) {
        [Console]::Error.WriteLine("INVALID_COMMENT_ENTRY: $($problems.Count) problem(s) in $($State.CommentsFile) - nothing was posted.")
        foreach ($problem in $problems) { [Console]::Error.WriteLine($problem) }
        Exit-Script $EXIT_INPUT
    }

    Write-Log "Validated $($list.Count) comment(s)"
    return $list
}

function Test-CommentsAgainstDiff {
    param($Comments)

    $pr = Get-PullRequest
    $changed = @(@(Get-Property $pr 'files') | Where-Object { $_ } | ForEach-Object { $_.path })

    $unknown = @($Comments | ForEach-Object { $_.path } | Sort-Object -Unique | Where-Object { $changed -notcontains $_ })
    if ($unknown.Count -gt 0) {
        [Console]::Error.WriteLine("INVALID_PATH: comment path(s) not among the files changed by PR #$($State.PrNumber):")
        foreach ($path in $unknown) { [Console]::Error.WriteLine($path) }
        [Console]::Error.WriteLine('Fix the paths, or pass --no-verify-paths to post anyway.')
        Exit-Script $EXIT_INPUT
    }

    $raw = Get-PullRequestDiff
    if ($null -eq $raw) {
        Write-Warn 'Could not fetch the diff to verify line numbers; posting without that check.'
        return
    }

    $index = Get-RightLineIndex -DiffLines $raw
    $offenders = @($Comments | Where-Object {
        $side = Get-Property $_ 'side'
        if (-not $side) { $side = 'RIGHT' }
        $side -eq 'RIGHT' -and -not $index.Contains("$($_.path)`t$([int]$_.line)")
    } | ForEach-Object { "$($_.path) - line $($_.line)" })

    if ($offenders.Count -gt 0) {
        [Console]::Error.WriteLine('INVALID_LINE: line(s) not present in the diff for this pull request:')
        foreach ($offender in $offenders) { [Console]::Error.WriteLine($offender) }
        [Console]::Error.WriteLine('GitHub would reject the whole review. Re-check against the annotated diff from fetch.')
        Exit-Script $EXIT_INPUT
    }

    Write-Log 'Paths and line numbers verified against the diff'
}

function Resolve-CommitId {
    if ($State.CommitId) { return }
    $result = Invoke-Gh @('pr', 'view', $State.PrNumber, '--repo', $State.Repo, '--json', 'headRefOid')
    if ($result.ExitCode -ne 0) { Stop-OnGhError $result.Err }
    try {
        $State.CommitId = [string](($result.Out | ConvertFrom-Json).headRefOid)
    } catch {
        $State.CommitId = ''
    }
    if (-not $State.CommitId) {
        Stop-WithError $EXIT_API 'HEAD_SHA_UNRESOLVED' "could not determine the head commit of PR #$($State.PrNumber)."
    }
}

function Invoke-Post {
    Test-PrNumber

    if (-not $State.CommentsFile) {
        Stop-WithError $EXIT_USAGE 'MISSING_COMMENTS_FILE' '--comments is required.'
    }
    if (-not (Test-Path -LiteralPath $State.CommentsFile -PathType Leaf)) {
        Stop-WithError $EXIT_INPUT 'COMMENTS_FILE_NOT_FOUND' "'$($State.CommentsFile)' does not exist."
    }
    if ($State.Event -notin @('COMMENT', 'APPROVE', 'REQUEST_CHANGES')) {
        Stop-WithError $EXIT_INPUT 'INVALID_EVENT' "'$($State.Event)' must be COMMENT, APPROVE or REQUEST_CHANGES."
    }

    if ($State.BodyFile) {
        if (-not (Test-Path -LiteralPath $State.BodyFile -PathType Leaf)) {
            Stop-WithError $EXIT_INPUT 'BODY_FILE_NOT_FOUND' "'$($State.BodyFile)' does not exist."
        }
        $State.Body = Get-Content -LiteralPath $State.BodyFile -Raw -Encoding UTF8
    }

    # GitHub rejects a COMMENT or REQUEST_CHANGES review with an empty body.
    if (-not $State.Body -and $State.Event -ne 'APPROVE') {
        Stop-WithError $EXIT_INPUT 'MISSING_BODY' "a $($State.Event) review needs a summary; pass --body or --body-file."
    }

    Test-Authentication
    $comments = Read-Comments

    if ($State.VerifyPaths) { Test-CommentsAgainstDiff $comments }

    Resolve-CommitId
    Write-Log "Head commit: $($State.CommitId)"

    $payload = [pscustomobject]@{
        commit_id = $State.CommitId
        event     = $State.Event
        body      = $State.Body
        comments  = [object[]]@($comments)
    }
    $payloadJson = $payload | ConvertTo-Json -Depth 20
    $payloadFile = Join-Path $State.TmpDir 'payload.json'
    Write-Utf8File $payloadFile $payloadJson

    if ($State.DryRun) {
        Write-Log 'Dry run - nothing was posted. Payload:'
        $payloadJson
        return
    }

    Write-Log "Posting $($State.Event) review to $($State.Repo)#$($State.PrNumber) via the GitHub REST API"

    # POST /repos/{owner}/{repo}/pulls/{number}/reviews - one review event with
    # its inline comments, so the findings land on the Files changed tab in the
    # GitHub web UI, each with a Resolve conversation button.
    $result = Invoke-Gh @('api', "repos/$($State.Repo)/pulls/$($State.PrNumber)/reviews",
                          '--method', 'POST', '--input', $payloadFile)

    if ($result.ExitCode -ne 0) {
        if ($result.Err -match '(?i)http 422|must be part of the diff|pull_request_review_thread') {
            [Console]::Error.WriteLine('INVALID_LINE: GitHub rejected one or more comments (422).')
            [Console]::Error.WriteLine("A line must appear in the diff of commit $($State.CommitId). Re-check line numbers against a fresh fetch.")
            [Console]::Error.WriteLine($result.Err)
            Exit-Script $EXIT_INPUT
        }
        Stop-OnGhError $result.Err
    }

    $reviewUrl = ''
    try { $reviewUrl = [string](($result.Out | ConvertFrom-Json).html_url) } catch { }
    Write-Log 'Review posted'
    $reviewUrl
}

# ---------------------------------------------------------------------------

function Invoke-Main {
    param([string[]]$Arguments)

    Read-Arguments $Arguments
    Test-Requirements

    $State.TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pr-review-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $State.TmpDir -Force | Out-Null

    try {
        Resolve-Targets
        Import-Configuration

        switch ($State.Command) {
            'fetch' { Invoke-Fetch }
            'post'  { Invoke-Post }
        }
    } finally {
        if (Test-Path -LiteralPath $State.TmpDir) {
            Remove-Item -LiteralPath $State.TmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-Main $args
