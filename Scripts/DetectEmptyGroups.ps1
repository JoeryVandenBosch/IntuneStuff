# Requires Microsoft.Graph PowerShell SDK

# --- Ask which tenant to use ---
$targetTenant = Read-Host "Enter the target Tenant ID or domain (e.g. contoso.com or GUID)"

# --- Ensure a clean context in this session ---
try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch {}

# --- Try to connect with an interactive popup (embedded web view) ---
# Note: -TenantId targets the tenant you specify; the popup lets you choose the right account.
try {
    Connect-MgGraph -Scopes "Group.Read.All" -TenantId $targetTenant -UseEmbeddedWebView -NoWelcome
}
catch {
    Write-Warning "Embedded auth failed, trying standard interactive auth..."
    # Fallback: standard interactive
    Connect-MgGraph -Scopes "Group.Read.All" -TenantId $targetTenant -NoWelcome
}

# --- Verify connected tenant ---
$ctx = Get-MgContext
if (-not $ctx -or -not $ctx.TenantId) {
    Write-Error "Failed to obtain Graph context after login. Aborting."
    break
}

Write-Host "Connected as $($ctx.Account) to tenant $($ctx.TenantId) ($($ctx.TenantDisplayName))" -ForegroundColor Cyan
$confirm = Read-Host "Proceed with this tenant? (Y/N)"
if ($confirm -notin @('Y','y')) {
    Write-Warning "Aborting at your request."
    break
}

# --- Helper: check if a group is empty ---
function IsGroupEmpty {
    param(
        [Parameter(Mandatory = $true)]
        [string] $GroupId
    )
    # Get all members (handle pagination)
    $members = Get-MgGroupMember -GroupId $GroupId -All:$true -ErrorAction SilentlyContinue
    return (-not $members)
}

# --- Retrieve all groups ---
Write-Host "Retrieving groups from tenant $($ctx.TenantDisplayName)..." -ForegroundColor Cyan
$allGroups = Get-MgGroup -All
$total     = $allGroups.Count
$counter   = 0
$emptyGroups = @()

Write-Host "Scanning $total groups for empties..." -ForegroundColor Cyan

foreach ($group in $allGroups) {
    $counter++
    $percent = if ($total -gt 0) { [int](($counter / $total) * 100) } else { 0 }

    # keep a space before colon to avoid VS Code parser issue with $var:
    Write-Progress -Activity "Checking groups" `
                   -Status "Processing $counter of $total : $($group.DisplayName)" `
                   -PercentComplete $percent

    if (IsGroupEmpty -GroupId $group.Id) {
        $emptyGroups += $group
        Write-Host "Empty group found: $($group.DisplayName)" -ForegroundColor Yellow
    }
}

# --- Ensure export folder exists ---
$exportPath = "C:\Temp\EmptyGroups1.csv"
$exportFolder = Split-Path $exportPath -Parent
if (-not (Test-Path -Path $exportFolder)) {
    New-Item -ItemType Directory -Path $exportFolder -Force | Out-Null
}

# --- Export to CSV ---
$emptyGroups |
    Select-Object DisplayName, Id, GroupTypes, SecurityEnabled, MailEnabled |
    Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8

Write-Host "`nDone! Found $($emptyGroups.Count) empty groups in tenant $($ctx.TenantDisplayName). Exported to $exportPath" -ForegroundColor Green
