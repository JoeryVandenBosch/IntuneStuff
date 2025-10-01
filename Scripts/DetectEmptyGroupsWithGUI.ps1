<#
Delete Entra ID (Azure AD) groups with a GUI preview + confirmation.
- Choose tenant (forces interactive login & confirmation)
- Choose mode: Empty groups OR Name match (StartsWith / Contains / Regex)
- Preview candidates in Out-GridView (multi-select)
- Final "TYPE DELETE" confirmation
- Deletes selected groups and logs to C:\Temp\GroupDeleteLog_yyyyMMdd_HHmmss.csv

Notes:
- Deleting groups moves them to "Deleted items" in Entra ID. You can attempt restore with:
  Restore-MgDirectoryDeletedItem -DirectoryObjectId <GroupId>
- Be careful with Microsoft 365 groups (mailbox/SharePoint content implications).
- On-premises synced groups typically must be deleted on-prem.
#>

# ------------------ Setup & Login ------------------
Import-Module Microsoft.Graph -ErrorAction Stop

# Clean context and prompt for tenant
try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch {}

$targetTenant = Read-Host "Enter the target Tenant ID or domain (e.g. contoso.com or GUID)"

# Force interactive sign-in to specified tenant (embedded web); fallback to standard interactive
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

# ------------------ Helpers ------------------
function Get-GroupMemberCount {
    param([Parameter(Mandatory=$true)][string]$GroupId)
    try {
        (Get-MgGroupMember -GroupId $GroupId -All:$true -ErrorAction SilentlyContinue | Measure-Object).Count
    } catch { 0 }
}

# ------------------ Mode selection ------------------
$modeInput = Read-Host "Mode: (E)mpty groups OR (N)ame match? [Default: E]"
switch ($modeInput.ToUpper()) {
    'N' { $Mode = 'NameMatch' }
    default { $Mode = 'Empty' }
}
Write-Host "Selected mode: $Mode" -ForegroundColor Cyan

# ------------------ Build candidate list ------------------
$candidates = New-Object System.Collections.Generic.List[Object]

if ($Mode -eq 'Empty') {
    Write-Host "Retrieving all groups and scanning for empties..." -ForegroundColor Cyan
    $allGroups = Get-MgGroup -All
    if (-not $allGroups) { Write-Warning "No groups found."; break }

    $total = $allGroups.Count; $i = 0
    foreach ($g in $allGroups) {
        $i++; $pct = if ($total -gt 0) { [int](($i/$total)*100) } else { 0 }
        Write-Progress -Activity "Scanning for empty groups" -Status "Processing $i of $total : $($g.DisplayName)" -PercentComplete $pct

        $count = Get-GroupMemberCount -GroupId $g.Id
        if ($count -eq 0) {
            $candidates.Add([pscustomobject]@{
                Id                      = $g.Id
                DisplayName             = $g.DisplayName
                MemberCount             = 0
                GroupTypes              = ($g.GroupTypes -join ';')
                SecurityEnabled         = $g.SecurityEnabled
                MailEnabled             = $g.MailEnabled
                OnPremisesSyncEnabled   = $g.OnPremisesSyncEnabled
            })
        }
    }
}
else {
    # NameMatch mode
    $modeMatch = Read-Host "Match: (S)tartsWith, (C)ontains, (R)egex [Default: S]"
    switch ($modeMatch.ToUpper()) {
        'C' { $MatchMode = 'Contains' }
        'R' { $MatchMode = 'Regex' }
        default { $MatchMode = 'StartsWith' }
    }
    Write-Host "Match mode: $MatchMode" -ForegroundColor Cyan

    $FindText = Read-Host "Text to MATCH (literal or regex, e.g. [D] or ^\[D\])"
    if ([string]::IsNullOrWhiteSpace($FindText)) { Write-Error "Match text cannot be empty."; break }

    Write-Host "Fetching groups..." -ForegroundColor Cyan
    if ($MatchMode -eq 'StartsWith') {
        $escaped = $FindText.Replace("'", "''")
        $groups = Get-MgGroup -All -Filter "startswith(displayName,'$escaped')"
    } else {
        $groups = Get-MgGroup -All
    }
    if (-not $groups) { Write-Warning "No groups found for the criteria."; break }

    $total = $groups.Count; $i = 0
    foreach ($g in $groups) {
        $i++; $pct = if ($total -gt 0) { [int](($i/$total)*100) } else { 0 }
        Write-Progress -Activity "Filtering groups by name" -Status "Processing $i of $total : $($g.DisplayName)" -PercentComplete $pct

        $name = $g.DisplayName
        if ([string]::IsNullOrEmpty($name)) { continue }

        $isMatch = $false
        switch ($MatchMode) {
            'StartsWith' { if ($name.StartsWith($FindText, [System.StringComparison]::InvariantCultureIgnoreCase)) { $isMatch = $true } }
            'Contains'   { if ($name.IndexOf($FindText, [System.StringComparison]::InvariantCultureIgnoreCase) -ge 0) { $isMatch = $true } }
            'Regex'      { try { if ([regex]::IsMatch($name, $FindText)) { $isMatch = $true } } catch { Write-Warning "Invalid regex: $FindText. $_"; $isMatch = $false } }
        }

        if ($isMatch) {
            $count = Get-GroupMemberCount -GroupId $g.Id
            $candidates.Add([pscustomobject]@{
                Id                      = $g.Id
                DisplayName             = $name
                MemberCount             = $count
                GroupTypes              = ($g.GroupTypes -join ';')
                SecurityEnabled         = $g.SecurityEnabled
                MailEnabled             = $g.MailEnabled
                OnPremisesSyncEnabled   = $g.OnPremisesSyncEnabled
            })
        }
    }
}

if ($candidates.Count -eq 0) {
    Write-Warning "No candidate groups found."
    break
}

# ------------------ GUI selection ------------------
Write-Host "Select the groups you want to DELETE..." -ForegroundColor Yellow
$selected = $null
if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
    $selected = $candidates |
        Select-Object DisplayName, MemberCount, GroupTypes, SecurityEnabled, MailEnabled, OnPremisesSyncEnabled, Id |
        Out-GridView -Title "Select groups to DELETE (multi-select) — Ctrl+Click to choose" -PassThru
} else {
    # Console fallback
    $i = 0
    $indexed = $candidates | ForEach-Object {
        $i++
        [pscustomobject]@{
            Index=$i; DisplayName=$_.DisplayName; MemberCount=$_.MemberCount; Id=$_.Id
        }
    }
    $indexed | Format-Table -AutoSize
    $choice = Read-Host "Enter 'all' or comma-separated indices to delete (e.g. 1,3,5)"
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

Write-Host "`nYou selected $($selected.Count) group(s) to DELETE." -ForegroundColor Yellow
Write-Host "WARNING: This will delete the selected groups." -ForegroundColor Red
$confirmText = Read-Host "Type EXACTLY:  DELETE  (to proceed) "
if ($confirmText -ne 'DELETE') {
    Write-Warning "Confirmation failed. Aborting."
    break
}

# ------------------ Delete & Log ------------------
$timestamp   = (Get-Date).ToString('yyyyMMdd_HHmmss')
$exportDir   = "C:\Temp"
$logPath     = Join-Path $exportDir "GroupDeleteLog_$timestamp.csv"
if (-not (Test-Path $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }

$results = New-Object System.Collections.Generic.List[Object]
$total = $selected.Count; $n = 0

foreach ($item in $selected) {
    $n++; $pct = [int](($n/$total)*100)
    Write-Progress -Activity "Deleting groups" -Status "Processing $n of $total : $($item.DisplayName)" -PercentComplete $pct

    try {
        # Note: on-prem synced groups typically must be deleted on-prem; this may fail.
        Remove-MgGroup -GroupId $item.Id -ErrorAction Stop
        $status = "Deleted"
        $err = ""
        Write-Host "✔ Deleted: $($item.DisplayName)" -ForegroundColor Green
    }
    catch {
        $status = "Failed"
        $err = $_.Exception.Message
        Write-Warning "✖ Failed to delete '$($item.DisplayName)': $err"
    }

    $results.Add([pscustomobject]@{
        Id                      = $item.Id
        DisplayName             = $item.DisplayName
        MemberCount             = $item.MemberCount
        GroupTypes              = $item.GroupTypes
        SecurityEnabled         = $item.SecurityEnabled
        MailEnabled             = $item.MailEnabled
        OnPremisesSyncEnabled   = $item.OnPremisesSyncEnabled
        Status                  = $status
        Error                   = $err
        RestoreHint             = ("Restore-MgDirectoryDeletedItem -DirectoryObjectId {0}" -f $item.Id)
    })
}

$results | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
Write-Host "`nDone. Log saved to $logPath" -ForegroundColor Cyan
Write-Host "If needed, you can try to restore a deleted group with the command in the 'RestoreHint' column." -ForegroundColor DarkCyan
