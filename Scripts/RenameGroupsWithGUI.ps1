<# 
Rename part of Entra ID (Azure AD) group display names.
- Choose tenant (forces interactive login)
- Choose match mode: StartsWith / Contains / Regex
- Preview proposed renames
- Select which groups to rename
- Export log to C:\Temp\GroupRenameLog_yyyyMMdd_HHmmss.csv

Examples:
- Find: [D]       Replace: [DG]       Match mode: StartsWith
- Find: [D]       Replace: [DG]       Match mode: Contains
- Find (regex): ^\[D\]   Replace: [DG] Match mode: Regex
#>

# ------------------ Setup & Login ------------------
Import-Module Microsoft.Graph -ErrorAction Stop

# Force a clean context and prompt for tenant
try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch {}

$targetTenant = Read-Host "Enter the target Tenant ID or domain (e.g. contoso.com or GUID)"

# Force interactive sign-in to specified tenant (embedded popup); fallback to standard interactive
try {
    Connect-MgGraph -Scopes "Group.ReadWrite.All" -TenantId $targetTenant -UseEmbeddedWebView -NoWelcome
}
catch {
    Write-Warning "Embedded auth failed, trying standard interactive auth..."
    Connect-MgGraph -Scopes "Group.ReadWrite.All" -TenantId $targetTenant -NoWelcome
}

$ctx = Get-MgContext
if (-not $ctx -or -not $ctx.TenantId) {
    Write-Error "Failed to obtain Graph context after login. Aborting."
    break
}

Write-Host "Connected as $($ctx.Account) to tenant $($ctx.TenantId) ($($ctx.TenantDisplayName))" -ForegroundColor Cyan
$confirmTenant = Read-Host "Proceed with this tenant? (Y/N)"
if ($confirmTenant -notin @('Y','y')) {
    Write-Warning "Aborting at your request."
    break
}

# ------------------ Inputs ------------------
# Match mode
$modeInput = Read-Host "Match mode: (S)tartsWith, (C)ontains, (R)egex [Default: S]"
switch ($modeInput.ToUpper()) {
    'C' { $MatchMode = 'Contains' }
    'R' { $MatchMode = 'Regex' }
    default { $MatchMode = 'StartsWith' }
}
Write-Host "Match mode: $MatchMode" -ForegroundColor Cyan

# Find & replace
$FindText = Read-Host "Text to FIND (e.g. [D]  or regex like  ^\[D\] )"
if ([string]::IsNullOrWhiteSpace($FindText)) {
    Write-Error "Find text cannot be empty. Aborting."
    break
}
$ReplaceText = Read-Host "Text to REPLACE WITH (e.g. [DG]  — leave empty to remove)"

# ------------------ Fetch candidate groups ------------------
Write-Host "Searching groups in tenant $($ctx.TenantDisplayName)..." -ForegroundColor Cyan
$groups = @()

if ($MatchMode -eq 'StartsWith') {
    # Server-side filter for startswith
    $escaped = $FindText.Replace("'", "''")
    $groups = Get-MgGroup -All -Filter "startswith(displayName,'$escaped')"
} else {
    # Fetch all then client-side filter (simpler & reliable across tenants)
    $groups = Get-MgGroup -All
}

if (-not $groups) {
    Write-Warning "No groups found in this tenant."
    break
}

# ------------------ Build preview list ------------------
$candidates = New-Object System.Collections.Generic.List[Object]

foreach ($g in $groups) {
    $old = $g.DisplayName
    if ([string]::IsNullOrEmpty($old)) { continue }

    $new = $null
    switch ($MatchMode) {
        'StartsWith' {
            if ($old.StartsWith($FindText, [System.StringComparison]::InvariantCultureIgnoreCase)) {
                # Replace only the prefix portion (case-insensitive)
                $new = $ReplaceText + $old.Substring($FindText.Length)
            }
        }
        'Contains' {
            # Case-insensitive literal replace using regex-escaped pattern
            $pattern = [regex]::Escape($FindText)
            $new = [regex]::Replace($old, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $ReplaceText }, 'IgnoreCase')
        }
        'Regex' {
            try {
                $new = [regex]::Replace($old, $FindText, $ReplaceText)
            } catch {
                Write-Warning "Invalid regex pattern for group '$old'. Skipping. Error: $($_.Exception.Message)"
                $new = $null
            }
        }
    }

    if ($null -ne $new -and $new -ne $old) {
        if ($new.Length -gt 256) {
            Write-Warning "Proposed name exceeds 256 chars for '$old' -> SKIPPED"
            continue
        }
        $candidates.Add([pscustomobject]@{
            Id               = $g.Id
            DisplayName      = $old
            ProposedNewName  = $new
            GroupTypes       = ($g.GroupTypes -join ';')
            SecurityEnabled  = $g.SecurityEnabled
            MailEnabled      = $g.MailEnabled
        })
    }
}

if ($candidates.Count -eq 0) {
    Write-Warning "No rename candidates found for the chosen criteria."
    break
}

Write-Host "Preview of proposed renames:" -ForegroundColor Cyan

# Try Out-GridView selection if available; else console picker
$selected = $null
if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
    $selected = $candidates |
        Select-Object DisplayName, ProposedNewName, Id, GroupTypes, SecurityEnabled, MailEnabled |
        Out-GridView -Title "Select groups to RENAME (multi-select) — Ctrl+Click to choose" -PassThru
} else {
    # Console picker
    $i = 0
    $indexed = $candidates | ForEach-Object {
        $i++
        [pscustomobject]@{ Index=$i; DisplayName=$_.DisplayName; ProposedNewName=$_.ProposedNewName; Id=$_.Id }
    }
    $indexed | Format-Table -AutoSize

    $choice = Read-Host "Enter 'all' or comma-separated indices to rename (e.g. 1,3,5)"
    if ($choice -eq 'all') {
        $selected = $candidates
    } else {
        $indices = $choice -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
        $selected = foreach ($n in $indices) { $candidates[$n-1] }
    }
}

if (-not $selected -or $selected.Count -eq 0) {
    Write-Warning "No groups selected. Aborting."
    break
}

Write-Host "You selected $($selected.Count) group(s) to rename." -ForegroundColor Yellow
$finalConfirm = Read-Host "Proceed with renaming now? (Y/N)"
if ($finalConfirm -notin @('Y','y')) {
    Write-Warning "Aborting at your request."
    break
}

# ------------------ Rename & Log ------------------
$timestamp   = (Get-Date).ToString('yyyyMMdd_HHmmss')
$exportDir   = "C:\Temp"
$logPath     = Join-Path $exportDir "GroupRenameLog_$timestamp.csv"
if (-not (Test-Path $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }

$results = New-Object System.Collections.Generic.List[Object]
$total = $selected.Count
$counter = 0

foreach ($item in $selected) {
    $counter++
    $percent = [int](($counter / $total) * 100)
    Write-Progress -Activity "Renaming groups" -Status "Processing $counter of $total : $($item.DisplayName)" -PercentComplete $percent

    try {
        Update-MgGroup -GroupId $item.Id -DisplayName $item.ProposedNewName -ErrorAction Stop
        $status = "Renamed"
        $err = ""
        Write-Host "✔ $($item.DisplayName)  ->  $($item.ProposedNewName)" -ForegroundColor Green
    }
    catch {
        $status = "Failed"
        $err = $_.Exception.Message
        Write-Warning "✖ Failed to rename '$($item.DisplayName)': $err"
    }

    $results.Add([pscustomobject]@{
        Id             = $item.Id
        OldName        = $item.DisplayName
        NewName        = $item.ProposedNewName
        Status         = $status
        Error          = $err
    })
}

$results | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
Write-Host "`nDone. Log saved to $logPath" -ForegroundColor Cyan
