<# 
Identify & act on non-compliant Intune devices (Delete / Retire / Wipe) with GUI preview.
- Minimal Graph imports to avoid function-capacity overflow
- Choose tenant (fresh login & confirmation)
- Filter by compliance state, OS, last check-in age (days)
- Preview via Out-GridView; select devices
- Confirm action (DELETE / RETIRE / WIPE)
- Logs to C:\Temp\NonCompliantDeviceActions_yyyyMMdd_HHmmss.csv
#>

# ------------------ Minimal Graph imports ------------------
# (Avoid importing the meta-module 'Microsoft.Graph' to prevent function overflow)
Get-Module Microsoft.Graph* | Remove-Module -Force -ErrorAction SilentlyContinue

$requiredModules = @(
  'Microsoft.Graph.Authentication',
  'Microsoft.Graph.DeviceManagement',
  'Microsoft.Graph.DeviceManagement.Actions'
)

foreach ($m in $requiredModules) {
  if (-not (Get-Module -ListAvailable -Name $m)) {
    Write-Host ("Installing required module: {0}" -f $m) -ForegroundColor Cyan
    Install-Module $m -Scope CurrentUser -Force -AllowClobber
  }
  Import-Module $m -ErrorAction Stop
}

# ------------------ Setup & Login ------------------
try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch {}

$targetTenant = Read-Host "Enter the target Tenant ID or domain (e.g. contoso.com or GUID)"

$scopes = @("DeviceManagementManagedDevices.ReadWrite.All")

# Try embedded web view → interactive → device code
$connected = $false
try {
    Connect-MgGraph -Scopes $scopes -TenantId $targetTenant -UseEmbeddedWebView
    $connected = $true
} catch {
    Write-Warning "Embedded auth failed, trying standard interactive auth..."
    try {
        Connect-MgGraph -Scopes $scopes -TenantId $targetTenant
        $connected = $true
    } catch {
        Write-Warning "Interactive auth failed, trying Device Code auth..."
        Connect-MgGraph -Scopes $scopes -TenantId $targetTenant -UseDeviceCode
        $connected = $true
    }
}

if (-not $connected) { Write-Error "Unable to authenticate to Microsoft Graph."; break }

$ctx = Get-MgContext
if (-not $ctx -or -not $ctx.TenantId) { Write-Error "Failed to obtain Graph context after login. Aborting."; break }

Write-Host ("Connected as {0} to tenant {1} ({2})" -f $ctx.Account, $ctx.TenantId, $ctx.TenantDisplayName) -ForegroundColor Cyan
$confirmTenant = Read-Host "Proceed with this tenant? (Y/N)"
if ($confirmTenant -notin @('Y','y')) { Write-Warning "Aborting at your request."; break }

# ------------------ Filter inputs ------------------
$stateScope = Read-Host "Compliance scope: (N)oncompliant only OR (E)xtended (noncompliant, error, conflict, inGracePeriod)? [Default: N]"
switch ($stateScope.ToUpper()) {
    'E' { $states = @('noncompliant','error','conflict','inGracePeriod') }
    default { $states = @('noncompliant') }
}
Write-Host ("Compliance states: {0}" -f ($states -join ', ')) -ForegroundColor Cyan

$osInput = Read-Host "OS filter (All / Windows / iOS / iPadOS / Android / macOS). For multiple, comma-separate. [Default: All]"
$osList = @()
if (-not [string]::IsNullOrWhiteSpace($osInput) -and $osInput.Trim().ToLower() -ne 'all') {
    $osList = $osInput -split ',' | ForEach-Object { $_.Trim() }
    Write-Host ("OS filter: {0}" -f ($osList -join ', ')) -ForegroundColor Cyan
} else {
    Write-Host "OS filter: All" -ForegroundColor Cyan
}

$daysText = Read-Host "Minimum 'last check-in' age (days) to include (e.g., 7). Enter 0 for no limit [Default: 0]"
[int]$minAgeDays = 0
if ([int]::TryParse($daysText, [ref]$minAgeDays) -eq $false) { $minAgeDays = 0 }
$cutoff = (Get-Date).AddDays(-$minAgeDays)

# ------------------ Fetch devices ------------------
Write-Host "Fetching managed devices..." -ForegroundColor Cyan
$selectProps = @(
  "id","deviceName","userPrincipalName","operatingSystem","osVersion",
  "complianceState","lastSyncDateTime","managementAgent","azureADDeviceId","deviceEnrollmentType","managedDeviceOwnerType"
)
$all = Get-MgDeviceManagementManagedDevice -All -Property ($selectProps -join ',')

if (-not $all) { Write-Warning "No managed devices found."; break }

# ------------------ Build candidate list ------------------
$candidates = New-Object System.Collections.Generic.List[Object]
$total = $all.Count; $i = 0

foreach ($d in $all) {
  $i++; $pct = if ($total -gt 0) { [int](($i/$total)*100) } else { 0 }
  Write-Progress -Activity "Evaluating devices" `
                 -Status ("Processing {0} of {1}: {2}" -f $i, $total, $d.DeviceName) `
                 -PercentComplete $pct

  if ($states -notcontains ($d.ComplianceState)) { continue }

  if ($osList.Count -gt 0) {
    if ($null -ne $d.OperatingSystem -and $d.OperatingSystem.Trim() -ne "") {
      $osMatch = $false
      foreach ($os in $osList) { if ($d.OperatingSystem -like "$os*") { $osMatch = $true; break } }
      if (-not $osMatch) { continue }
    } else { continue }
  }

  $last = $d.LastSyncDateTime
  $includeByAge = $true
  if ($minAgeDays -gt 0) {
    if ($null -ne $last -and $last -ne [datetime]::MinValue) {
      if ($last -gt $cutoff) { $includeByAge = $false }
    }
    # If never checked in (null), include as old
  }
  if (-not $includeByAge) { continue }

  $candidates.Add([pscustomobject]@{
    Id                       = $d.Id
    DeviceName               = $d.DeviceName
    UserPrincipalName        = $d.UserPrincipalName
    OperatingSystem          = $d.OperatingSystem
    OSVersion                = $d.OsVersion
    ComplianceState          = $d.ComplianceState
    LastSyncDateTime         = $d.LastSyncDateTime
    ManagementAgent          = $d.ManagementAgent
    AzureAdDeviceId          = $d.AzureAdDeviceId
    EnrollmentType           = $d.DeviceEnrollmentType
    ManagedDeviceOwnerType   = $d.ManagedDeviceOwnerType
  })
}

if ($candidates.Count -eq 0) { Write-Warning "No devices matched the selected criteria."; break }

# ------------------ Preview & selection ------------------
Write-Host "Preview: select the devices to act on..." -ForegroundColor Yellow
$selected = $null
if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
  $selected = $candidates |
    Select-Object DeviceName, UserPrincipalName, OperatingSystem, OSVersion, ComplianceState, LastSyncDateTime, ManagementAgent, EnrollmentType, ManagedDeviceOwnerType, AzureAdDeviceId, Id |
    Out-GridView -Title "Select devices to act on (multi-select) — Ctrl+Click to choose" -PassThru
} else {
  $index = 0
  $indexed = $candidates | ForEach-Object {
    $index++
    [pscustomobject]@{ Index=$index; DeviceName=$_.DeviceName; UPN=$_.UserPrincipalName; Compliance=$_.ComplianceState; LastSync=$_.LastSyncDateTime; Id=$_.Id }
  }
  $indexed | Format-Table -AutoSize
  $choice = Read-Host "Enter 'all' or comma-separated indices (e.g. 1,3,5)"
  if ($choice -eq 'all') { $selected = $candidates }
  else {
    $indices = $choice -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    $selected = foreach ($n in $indices) { $candidates[$n-1] }
  }
}

if (-not $selected -or $selected.Count -eq 0) { Write-Warning "No devices selected. Aborting."; break }

Write-Host ("You selected {0} device(s)." -f $selected.Count) -ForegroundColor Yellow

# ------------------ Choose action ------------------
$actionInput = Read-Host "Action: (D)elete from Intune, (R)etire, or (W)ipe? [Default: R]"
switch ($actionInput.ToUpper()) {
  'D' { $Action = 'Delete' }
  'W' { $Action = 'Wipe' }
  default { $Action = 'Retire' }
}
Write-Host ("Chosen action: {0}" -f $Action) -ForegroundColor Cyan

switch ($Action) {
  'Delete' { $confirmText = Read-Host "Type EXACTLY:  DELETE  to proceed"; if ($confirmText -ne 'DELETE') { Write-Warning "Confirmation failed. Aborting."; break } }
  'Retire' { $confirmText = Read-Host "Type EXACTLY:  RETIRE  to proceed"; if ($confirmText -ne 'RETIRE') { Write-Warning "Confirmation failed. Aborting."; break } }
  'Wipe'   { $confirmText = Read-Host "Type EXACTLY:  WIPE  to proceed";   if ($confirmText -ne 'WIPE')   { Write-Warning "Confirmation failed. Aborting."; break } }
}

# ------------------ Execute & log ------------------
$timestamp   = (Get-Date).ToString('yyyyMMdd_HHmmss')
$exportDir   = "C:\Temp"
$logPath     = Join-Path $exportDir "NonCompliantDeviceActions_$timestamp.csv"
if (-not (Test-Path $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }

$results = New-Object System.Collections.Generic.List[Object]
$totalSel = $selected.Count; $n = 0

foreach ($dev in $selected) {
  $n++; $pct = [int](($n/$totalSel)*100)
  Write-Progress -Activity ("{0} devices" -f $Action) `
                 -Status ("Processing {0} of {1}: {2}" -f $n, $totalSel, $dev.DeviceName) `
                 -PercentComplete $pct

  $status = "Unknown"; $err = ""
  try {
    switch ($Action) {
      'Delete' { Remove-MgDeviceManagementManagedDevice -ManagedDeviceId $dev.Id -ErrorAction Stop; $status = "Deleted" }
      'Retire' { Invoke-MgDeviceManagementManagedDeviceRetire -ManagedDeviceId $dev.Id -ErrorAction Stop; $status = "Retire initiated" }
      'Wipe'   {
        $body = @{
          keepEnrollmentData    = $false
          keepUserData          = $false
          macOsUnlockCode       = $null
          persistEsimDataPlan   = $false
          useProtectedWipe      = $false
        }
        Invoke-MgDeviceManagementManagedDeviceWipe -ManagedDeviceId $dev.Id -BodyParameter $body -ErrorAction Stop
        $status = "Wipe initiated"
      }
    }
    Write-Host ("✔ {0}: {1} [{2}]" -f $Action, $dev.DeviceName, $dev.UserPrincipalName) -ForegroundColor Green
  } catch {
    $status = "Failed"; $err = $_.Exception.Message
    Write-Warning ("✖ {0} failed for {1}: {2}" -f $Action, $dev.DeviceName, $err)
  }

  $results.Add([pscustomobject]@{
    Action                    = $Action
    Status                    = $status
    Error                     = $err
    DeviceId                  = $dev.Id
    AzureAdDeviceId           = $dev.AzureAdDeviceId
    DeviceName                = $dev.DeviceName
    UserPrincipalName         = $dev.UserPrincipalName
    OperatingSystem           = $dev.OperatingSystem
    OSVersion                 = $dev.OSVersion
    ComplianceState           = $dev.ComplianceState
    LastSyncDateTime          = $dev.LastSyncDateTime
    ManagementAgent           = $dev.ManagementAgent
    EnrollmentType            = $dev.EnrollmentType
    ManagedDeviceOwnerType    = $dev.ManagedDeviceOwnerType
  })
}

$results | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
Write-Host ("`nDone. Log saved to {0}" -f $logPath) -ForegroundColor Cyan
