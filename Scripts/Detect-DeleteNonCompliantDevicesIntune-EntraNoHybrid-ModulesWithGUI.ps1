<#
Identify & act on non-compliant Intune devices (Delete / Retire / Wipe) with GUI preview,
optionally delete the corresponding Microsoft Entra device objects, and bootstrap prerequisites.

NEW:
- Dry-run mode (default ON) -> no changes, full preview & CSV of what WOULD happen
- 30-day hard guard -> devices checked in within 30 days are EXCLUDED from action (always)
  * They won't appear in the selection grid. A summary shows how many were skipped.

Features:
- Pre-checks & installs required modules:
    * Microsoft.Graph.Authentication
    * Microsoft.Graph.DeviceManagement
    * Microsoft.Graph.DeviceManagement.Actions
    * Microsoft.Graph.Identity.DirectoryManagement
- Forces TLS 1.2, ensures NuGet provider and PSGallery repo
- Choose tenant (fresh login & confirmation)
- Filters: compliance state, OS, owner (Company/Personal), last check-in age (optional, in addition to the 30-day guard)
- Preview via Out-GridView (with console fallback)
- Choose action: DELETE (Intune record), RETIRE, or WIPE
- Optional: also delete the Entra device object (with HYBRID PROTECTION: skip if onPremisesSyncEnabled=True)
- Logs to C:\Temp\NonCompliantDeviceActions_yyyyMMdd_HHmmss.csv

Required delegated Graph scopes:
- DeviceManagementManagedDevices.ReadWrite.All
- Directory.AccessAsUser.All
#>

# ------------------ Prereq bootstrap ------------------

# 1) Enforce TLS 1.2 for gallery downloads on older hosts
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

function Ensure-NuGetProvider {
  try {
    $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue
    if (-not $nuget -or ([version]$nuget.Version -lt [version]"2.8.5.201")) {
      Write-Host "Installing NuGet package provider..." -ForegroundColor Cyan
      Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
    }
  } catch { Write-Warning "Failed to install NuGet provider: $($_.Exception.Message)"; throw }
}

function Ensure-PSGallery {
  try {
    $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if (-not $repo) {
      Write-Host "Registering PSGallery repository..." -ForegroundColor Cyan
      Register-PSRepository -Default -ErrorAction Stop
      $repo = Get-PSRepository -Name PSGallery
    }
    if ($repo.InstallationPolicy -ne 'Trusted') {
      Write-Host "Trusting PSGallery repository..." -ForegroundColor Cyan
      Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
    }
  } catch { Write-Warning "Failed to configure PSGallery: $($_.Exception.Message)"; throw }
}

function Ensure-Module {
  param([Parameter(Mandatory)][string]$Name)
  try {
    if (-not (Get-Module -ListAvailable -Name $Name)) {
      Write-Host ("Installing module: {0}" -f $Name) -ForegroundColor Cyan
      Install-Module -Name $Name -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module -Name $Name -ErrorAction Stop
  } catch { Write-Warning ("Failed to install/import module {0}: {1}" -f $Name, $_.Exception.Message); throw }
}

# Clean out any previously loaded Graph mega-modules (prevents 4096 func overflow)
Get-Module Microsoft.Graph* | Remove-Module -Force -ErrorAction SilentlyContinue

# Ensure prerequisites
Ensure-NuGetProvider
Ensure-PSGallery

# Minimal Graph submodules we need
$RequiredGraphModules = @(
  'Microsoft.Graph.Authentication',
  'Microsoft.Graph.DeviceManagement',
  'Microsoft.Graph.DeviceManagement.Actions',
  'Microsoft.Graph.Identity.DirectoryManagement'
)
$RequiredGraphModules | ForEach-Object { Ensure-Module -Name $_ }

# ------------------ Setup & Login ------------------

try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch {}

$targetTenant = Read-Host "Enter the target Tenant ID or domain (e.g. contoso.com or GUID)"

# Needed scopes: Intune device actions + directory device delete
$scopes = @(
  "DeviceManagementManagedDevices.ReadWrite.All",
  "Directory.AccessAsUser.All"
)

# Try embedded web view → interactive → device code
$connected = $false
try { Connect-MgGraph -Scopes $scopes -TenantId $targetTenant -UseEmbeddedWebView; $connected = $true }
catch {
  Write-Warning "Embedded auth failed, trying standard interactive auth..."
  try { Connect-MgGraph -Scopes $scopes -TenantId $targetTenant; $connected = $true }
  catch {
    Write-Warning "Interactive auth failed, trying Device Code auth..."
    Connect-MgGraph -Scopes $scopes -TenantId $targetTenant -UseDeviceCode; $connected = $true
  }
}
if (-not $connected) { Write-Error "Unable to authenticate to Microsoft Graph."; break }

$ctx = Get-MgContext
if (-not $ctx -or -not $ctx.TenantId) { Write-Error "Failed to obtain Graph context after login. Aborting."; break }

Write-Host ("Connected as {0} to tenant {1} ({2})" -f $ctx.Account, $ctx.TenantId, $ctx.TenantDisplayName) -ForegroundColor Cyan
$confirmTenant = Read-Host "Proceed with this tenant? (Y/N)"
if ($confirmTenant -notin @('Y','y')) { Write-Warning "Aborting at your request."; break }

# ------------------ Guard & Filter inputs ------------------

# DRY-RUN
$dryRunAns = Read-Host "Dry-run (no changes)? (Y/N) [Default: Y]"
$DryRun = $true; if ($dryRunAns -and $dryRunAns.ToUpper() -eq 'N') { $DryRun = $false }
Write-Host ("Dry-run: {0}" -f ($DryRun ? 'ENABLED' : 'DISABLED')) -ForegroundColor Yellow

# 30-day hard guard (always enforced)
$GuardDays = 30
$GuardCutoff = (Get-Date).AddDays(-$GuardDays)
Write-Host ("Safety guard: devices with last check-in within {0} days are EXCLUDED." -f $GuardDays) -ForegroundColor Yellow

# Compliance scope
$stateScope = Read-Host "Compliance scope: (N)oncompliant only OR (E)xtended (noncompliant, error, conflict, inGracePeriod)? [Default: N]"
switch ($stateScope.ToUpper()) {
  'E' { $states = @('noncompliant','error','conflict','inGracePeriod') }
  default { $states = @('noncompliant') }
}
Write-Host ("Compliance states: {0}" -f ($states -join ', ')) -ForegroundColor Cyan

# OS filter
$osInput = Read-Host "OS filter (All / Windows / iOS / iPadOS / Android / macOS). For multiple, comma-separate. [Default: All]"
$osList = @()
if (-not [string]::IsNullOrWhiteSpace($osInput) -and $osInput.Trim().ToLower() -ne 'all') {
  $osList = $osInput -split ',' | ForEach-Object { $_.Trim() }
  Write-Host ("OS filter: {0}" -f ($osList -join ', ')) -ForegroundColor Cyan
} else { Write-Host "OS filter: All" -ForegroundColor Cyan }

# Owner filter
$ownerInput = Read-Host "Owner filter: (A)ll, (C)ompany only, (P)ersonal only [Default: A]"
switch ($ownerInput.ToUpper()) {
  'C' { $ownerFilter = 'company' }
  'P' { $ownerFilter = 'personal' }
  default { $ownerFilter = 'all' }
}
Write-Host ("Owner filter: {0}" -f $ownerFilter) -ForegroundColor Cyan

# Optional extra age filter (beyond the 30-day guard)
$daysText = Read-Host "Additional min 'last check-in' age (days) to include (0 = no extra limit) [Default: 0]"
[int]$minAgeDays = 0; if ([int]::TryParse($daysText, [ref]$minAgeDays) -eq $false) { $minAgeDays = 0 }
$ExtraCutoff = (Get-Date).AddDays(-$minAgeDays)
# Effective cutoff is the stricter of the two (max of the lookback)
$EffectiveCutoff = if ($GuardCutoff -lt $ExtraCutoff) { $ExtraCutoff } else { $GuardCutoff }
Write-Host ("Effective minimum age = {0} days" -f [int]((Get-Date) - $EffectiveCutoff).TotalDays) -ForegroundColor Cyan

# Also delete from Entra?
$alsoDeleteAAD = Read-Host "Also delete the Microsoft Entra device objects for selected devices? (Y/N) [Default: Y]"
$deleteAAD = $true; if ($alsoDeleteAAD -and $alsoDeleteAAD.ToUpper() -eq 'N') { $deleteAAD = $false }
if ($deleteAAD) {
  Write-Host "Entra deletion ENABLED — BitLocker keys and device object will be removed. Hybrid-joined devices will be skipped automatically." -ForegroundColor Yellow
}

# ------------------ Fetch devices ------------------

Write-Host "Fetching managed devices..." -ForegroundColor Cyan
$selectProps = @(
  "id","deviceName","userPrincipalName","operatingSystem","osVersion",
  "complianceState","lastSyncDateTime","managementAgent","azureADDeviceId",
  "deviceEnrollmentType","managedDeviceOwnerType"
)
$all = Get-MgDeviceManagementManagedDevice -All -Property ($selectProps -join ',')
if (-not $all) { Write-Warning "No managed devices found."; break }

# ------------------ Build candidate list (enforcing 30-day guard) ------------------

$candidates = New-Object System.Collections.Generic.List[Object]
$skippedByGuard = New-Object System.Collections.Generic.List[Object]
$total = $all.Count; $i = 0

foreach ($d in $all) {
  $i++; $pct = if ($total -gt 0) { [int](($i/$total)*100) } else { 0 }
  Write-Progress -Activity "Evaluating devices" -Status ("Processing {0} of {1}: {2}" -f $i, $total, $d.DeviceName) -PercentComplete $pct

  # Compliance filter
  if ($states -notcontains ($d.ComplianceState)) { continue }

  # OS filter
  if ($osList.Count -gt 0) {
    if ($null -ne $d.OperatingSystem -and $d.OperatingSystem.Trim() -ne "") {
      $osMatch = $false; foreach ($os in $osList) { if ($d.OperatingSystem -like "$os*") { $osMatch = $true; break } }
      if (-not $osMatch) { continue }
    } else { continue }
  }

  # Owner filter
  if ($ownerFilter -ne 'all') {
    if ($null -eq $d.ManagedDeviceOwnerType -or $d.ManagedDeviceOwnerType.ToLower() -ne $ownerFilter) { continue }
  }

  # 30-day guard & extra age
  $last = $d.LastSyncDateTime
  $isEligible = $true
  if ($null -ne $last -and $last -ne [datetime]::MinValue) {
    if ($last -gt $EffectiveCutoff) {
      $isEligible = $false
    }
  } # if null => treat as old => eligible

  $ageDays = if ($null -ne $last -and $last -ne [datetime]::MinValue) { [int]((Get-Date) - $last).TotalDays } else { $null }

  $record = [pscustomobject]@{
    Id                       = $d.Id
    DeviceName               = $d.DeviceName
    UserPrincipalName        = $d.UserPrincipalName
    OperatingSystem          = $d.OperatingSystem
    OSVersion                = $d.OsVersion
    ComplianceState          = $d.ComplianceState
    LastSyncDateTime         = $d.LastSyncDateTime
    AgeDays                  = $ageDays
    ManagementAgent          = $d.ManagementAgent
    AzureAdDeviceId          = $d.AzureAdDeviceId
    EnrollmentType           = $d.DeviceEnrollmentType
    ManagedDeviceOwnerType   = $d.ManagedDeviceOwnerType
  }

  if ($isEligible) { $candidates.Add($record) } else { $skippedByGuard.Add($record) }
}

Write-Host ("Guard summary: {0} device(s) excluded by the 30-day/extra-age guard; {1} eligible." -f $skippedByGuard.Count, $candidates.Count) -ForegroundColor Yellow
if ($candidates.Count -eq 0) { Write-Warning "No devices eligible for action under current guard/filters."; break }

# ------------------ Preview & selection ------------------

Write-Host "Preview: select the devices to act on..." -ForegroundColor Yellow
$selected = $null
if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
  $selected = $candidates |
    Select-Object DeviceName, UserPrincipalName, OperatingSystem, OSVersion, ComplianceState, AgeDays, LastSyncDateTime, ManagementAgent, EnrollmentType, ManagedDeviceOwnerType, AzureAdDeviceId, Id |
    Out-GridView -Title "Select devices to act on (multi-select) — Ctrl+Click to choose" -PassThru
} else {
  $index = 0
  $indexed = $candidates | ForEach-Object {
    $index++
    [pscustomobject]@{ Index=$index; DeviceName=$_.DeviceName; UPN=$_.UserPrincipalName; Compliance=$_.ComplianceState; AgeDays=$_.AgeDays; LastSync=$_.LastSyncDateTime; Id=$_.Id }
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

# Final confirmation(s) — skipped in dry-run to keep flow smooth
if (-not $DryRun) {
  switch ($Action) {
    'Delete' { $confirmText = Read-Host "Type EXACTLY:  DELETE  to proceed"; if ($confirmText -ne 'DELETE') { Write-Warning "Confirmation failed. Aborting."; break } }
    'Retire' { $confirmText = Read-Host "Type EXACTLY:  RETIRE  to proceed"; if ($confirmText -ne 'RETIRE') { Write-Warning "Confirmation failed. Aborting."; break } }
    'Wipe'   { $confirmText = Read-Host "Type EXACTLY:  WIPE  to proceed";   if ($confirmText -ne 'WIPE')   { Write-Warning "Confirmation failed. Aborting."; break } }
  }
  if ($deleteAAD) {
    $confirmAAD = Read-Host "Type EXACTLY:  DELETE AAD  to also delete the Entra device objects (hybrid devices will be skipped)"
    if ($confirmAAD -ne 'DELETE AAD') { Write-Warning "Entra deletion not confirmed; will skip AAD deletions."; $deleteAAD = $false }
  }
}

# ------------------ Execute (or simulate) & log ------------------

$timestamp   = (Get-Date).ToString('yyyyMMdd_HHmmss')
$exportDir   = "C:\Temp"
$logPath     = Join-Path $exportDir "NonCompliantDeviceActions_$timestamp.csv"
if (-not (Test-Path $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }

$results = New-Object System.Collections.Generic.List[Object]
$totalSel = $selected.Count; $n = 0

foreach ($dev in $selected) {
  $n++; $pct = [int](($n/$totalSel)*100)
  Write-Progress -Activity ("{0} devices" -f $Action) -Status ("Processing {0} of {1}: {2}" -f $n, $totalSel, $dev.DeviceName) -PercentComplete $pct

  $status = "Unknown"; $err = ""
  $aadDeleteStatus = if ($deleteAAD) { "Planned" } else { "Skipped" }
  $aadDeleteError = ""; $aadObjectId = $null; $aadHybrid = $null

  try {
    if ($DryRun) {
      switch ($Action) {
        'Delete' { $status = "Would delete (Intune record)" }
        'Retire' { $status = "Would retire" }
        'Wipe'   { $status = "Would wipe" }
      }
      Write-Host ("● [DRY-RUN] {0}: {1} [{2}]" -f $Action, $dev.DeviceName, $dev.UserPrincipalName) -ForegroundColor Yellow
    } else {
      switch ($Action) {
        'Delete' { Remove-MgDeviceManagementManagedDevice -ManagedDeviceId $dev.Id -ErrorAction Stop; $status = "Deleted (Intune record)" }
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
    }
  } catch {
    $status = "Failed"; $err = $_.Exception.Message
    Write-Warning ("✖ {0} failed for {1}: {2}" -f $Action, $dev.DeviceName, $err)
  }

  # Optional Entra deletion with HYBRID PROTECTION
  if ($deleteAAD -and $dev.AzureAdDeviceId) {
    try {
      $aad = Get-MgDevice -Filter ("deviceId eq '{0}'" -f $dev.AzureAdDeviceId) -Property "id,deviceId,displayName,onPremisesSyncEnabled" -ErrorAction Stop
      if ($aad) {
        $aadObjectId = $aad.Id; $aadHybrid = $aad.OnPremisesSyncEnabled
        if ($aadHybrid -eq $true) {
          $aadDeleteStatus = "Skipped (hybrid-joined)"
          Write-Host ("  ⏭ Skipped Entra delete (hybrid): {0} (objectId {1})" -f $aad.DisplayName, $aad.Id) -ForegroundColor DarkCyan
        } else {
          if ($DryRun) {
            $aadDeleteStatus = "Would delete (AAD object)"
            Write-Host ("  ● [DRY-RUN] Would delete Entra device: {0} (objectId {1})" -f $aad.DisplayName, $aad.Id) -ForegroundColor Yellow
          } else {
            Remove-MgDevice -DeviceId $aad.Id -ErrorAction Stop
            $aadDeleteStatus = "Deleted (AAD object)"
            Write-Host ("  ✔ Entra device deleted: {0} (objectId {1})" -f $aad.DisplayName, $aad.Id) -ForegroundColor DarkYellow
          }
        }
      } else { $aadDeleteStatus = "Not found" }
    } catch {
      $aadDeleteStatus = "Failed"; $aadDeleteError  = $_.Exception.Message
      Write-Warning ("  ✖ Entra device delete failed for {0}: {1}" -f $dev.DeviceName, $aadDeleteError)
    }
  }

  $results.Add([pscustomobject]@{
    DryRun                   = $DryRun
    Action                   = $Action
    Status                   = $status
    Error                    = $err
    DeviceId_Intune          = $dev.Id
    AAD_DeviceId             = $dev.AzureAdDeviceId
    AAD_ObjectId             = $aadObjectId
    AAD_OnPremisesSyncEnabled= $aadHybrid
    AAD_DeleteStatus         = $aadDeleteStatus
    AAD_DeleteError          = $aadDeleteError
    DeviceName               = $dev.DeviceName
    UserPrincipalName        = $dev.UserPrincipalName
    OperatingSystem          = $dev.OperatingSystem
    OSVersion                = $dev.OSVersion
    ComplianceState          = $dev.ComplianceState
    LastSyncDateTime         = $dev.LastSyncDateTime
    AgeDays                  = $dev.AgeDays
    ManagementAgent          = $dev.ManagementAgent
    EnrollmentType           = $dev.EnrollmentType
    ManagedDeviceOwnerType   = $dev.ManagedDeviceOwnerType
  })
}

# Also export a tab with the 30-day-guarded devices for your review
$timestamp   = (Get-Date).ToString('yyyyMMdd_HHmmss')
$exportDir   = "C:\Temp"
$logPath     = Join-Path $exportDir "NonCompliantDeviceActions_$timestamp.csv"
if (-not (Test-Path $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }

$results | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
$guardLog = Join-Path $exportDir "NonCompliantDevices_SKIPPED_ByGuard_$timestamp.csv"
$skippedByGuard | Export-Csv -Path $guardLog -NoTypeInformation -Encoding UTF8

Write-Host ("`nDone. Logs saved to:`n  {0}`n  {1}" -f $logPath, $guardLog) -ForegroundColor Cyan
Write-Host "Safety guard: any device with a last check-in within 30 days was excluded from action." -ForegroundColor DarkCyan
Write-Host "Hybrid-joined (onPremisesSyncEnabled = True) Entra devices were skipped by design." -ForegroundColor DarkCyan
