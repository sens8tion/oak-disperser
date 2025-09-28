param(
  [string]$ProjectId,
  [string]$BaseProjectName,
  [string]$Region = 'us-central1',
  [string]$ServiceAccountId = 'oak-disperser-ci',
  [string]$ServiceAccountDisplayName = 'Oak Disperser CI',
  [string]$PubSubTopic = 'action-dispersal',
  [string]$KeyOutputPath,
  [string]$BillingAccountId,
  [double]$FreeTierThreshold = 0.8,
  [switch]$SkipKey,
  [switch]$DryRun,
  [switch]$ConfigureGithubSecrets,
  [string]$GithubRepo,
  [string]$StatusWebhookUri
)

function Resolve-GcloudPath {
  $command = Get-Command gcloud -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  $fallback = Join-Path $env:LOCALAPPDATA 'Google/Cloud SDK/google-cloud-sdk/bin/gcloud.cmd'
  if (Test-Path -Path $fallback) {
    return $fallback
  }

  throw 'gcloud CLI not found. Install the Google Cloud SDK and ensure gcloud is on PATH.'
}

$gcloud = Resolve-GcloudPath

function Send-StatusNotification {
  param(
    [string]$Message,
    [string]$Severity = 'info'
  )

  if (-not $StatusWebhookUri) {
    return
  }

  try {
    $payload = [pscustomobject]@{
      message   = $Message
      severity  = $Severity
      timestamp = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json

    Invoke-RestMethod -Uri $StatusWebhookUri -Method Post -ContentType 'application/json' -Body $payload | Out-Null
  } catch {
    Write-Warning "Failed to send status notification: $($_.Exception.Message)"
  }
}

function Invoke-Gcloud {
  param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
  )

  Write-Host "--> gcloud $($Args -join ' ')"
  if ($DryRun) {
    return
  }

  & $gcloud @Args
  if ($LASTEXITCODE -ne 0) {
    throw "gcloud command failed with exit code $LASTEXITCODE"
  }
}

function Prompt-IfMissing {
  param(
    [string]$Value,
    [string]$Prompt,
    [string]$Default = ''
  )

  if ($Value) {
    return $Value
  }

  $message = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
  $input = Read-Host $message

  if ([string]::IsNullOrWhiteSpace($input)) {
    if ($Default) {
      return $Default
    }
    throw "A value is required for $Prompt"
  }

  return $input
}

function Get-RepositoryBaseName {
  try {
    $remoteUrl = git config --get remote.origin.url 2>$null
    if ($remoteUrl -and $remoteUrl -match 'github.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)') {
      return $matches.repo
    }
  } catch {
    # ignore
  }

  try {
    $root = git rev-parse --show-toplevel 2>$null
    if ($root) {
      return Split-Path -Path $root -Leaf
    }
  } catch {
    # ignore
  }

  return Split-Path -Path (Get-Location) -Leaf
}

function Sanitize-BaseName {
  param([string]$Value)

  if (-not $Value) {
    return $null
  }

  $sanitized = ($Value -replace '[^a-zA-Z0-9-]', '-').Trim('-')
  if (-not $sanitized) {
    return $null
  }

  return $sanitized
}
function Format-ProjectDisplayName {
  param([string]$Base)

  $baseValue = if ($Base) { $Base } else { 'oak-disperser' }
  $safe = ($baseValue -replace '[^a-zA-Z0-9 -]', ' ')
  $safe = ($safe -replace '\s+', ' ').Trim()
  if (-not $safe) {
    $safe = 'Oak Disperser'
  } else {
    $safe = "Oak Disperser - $safe"
  }

  if ($safe.Length -gt 30) {
    $safe = $safe.Substring(0, 30)
  }

  return $safe
}


function Ensure-GcloudLogin {
  Write-Host 'Checking gcloud authentication status...' -ForegroundColor Cyan
  if ($DryRun) {
    return
  }

  $activeAccount = & $gcloud auth list --filter='status:ACTIVE' --format='value(account)' 2>$null
  if (-not $activeAccount) {
    Write-Host 'No active gcloud account detected. Launching gcloud auth login.' -ForegroundColor Yellow
    & $gcloud auth login
    if ($LASTEXITCODE -ne 0) {
      throw 'gcloud auth login failed.'
    }
  }
}

function Test-ProjectExists {
  param([string]$Project)

  & $gcloud projects describe $Project --format='value(projectId)' --quiet 2>$null | Out-Null
  return $LASTEXITCODE -eq 0
}

function Generate-ProjectId {
  param([string]$BaseName)

  $sanitized = ((($BaseName -replace '[^a-zA-Z0-9-]', '-').ToLower()).Trim('-'))
  if (-not $sanitized) {
    $sanitized = 'oak-disperser'
  }

  if ($sanitized.Length -lt 6) {
    $sanitized = ($sanitized + 'oak')
    $sanitized = $sanitized.Substring(0, [Math]::Min($sanitized.Length, 10))
  }

  $base = if ($sanitized -match '(^|-)oak-disperser$') { $sanitized } else { "$sanitized-oak-disperser" }
  if ($base.Length -gt 30) {
    $base = $base.Substring(0, 30)
  }

  $candidate = $base
  $counter = 1
  while (Test-ProjectExists $candidate) {
    $suffix = "-$counter"
    $maxPrefixLength = [Math]::Max(0, 30 - $suffix.Length)
    $prefix = $base.Substring(0, [Math]::Min($base.Length, $maxPrefixLength))
    $candidate = "$prefix$suffix"
    $counter++
  }

  return $candidate
}

function Ensure-Project {
  param(
    [string]$ProjectId,
    [string]$BaseProjectName,
    [string]$BillingAccountId
  )

  $created = $false
  if ($ProjectId) {
    if (-not (Test-ProjectExists $ProjectId)) {
      Write-Host "Project '$ProjectId' not found. Creating it." -ForegroundColor Yellow
      $displayName = Format-ProjectDisplayName $ProjectId
      Invoke-Gcloud projects create $ProjectId --name $displayName --quiet
      $created = $true
    }
  } else {
    $base = Prompt-IfMissing -Value $BaseProjectName -Prompt 'Enter base project name (letters, digits, hyphen)' -Default 'oak-disperser'
    $ProjectId = Generate-ProjectId $base
    Write-Host "Creating project '$ProjectId' derived from '$base'." -ForegroundColor Yellow
  $displayName = Format-ProjectDisplayName $base
  Invoke-Gcloud projects create $ProjectId --name $displayName --quiet
    $created = $true
  }

  if ($created) {
    Send-StatusNotification "Created project $ProjectId" 'info'
    if ($BillingAccountId) {
      Write-Host "Linking project to billing account $BillingAccountId" -ForegroundColor Cyan
      Invoke-Gcloud beta billing projects link $ProjectId --billing-account $BillingAccountId --quiet
    }

    if (-not $DryRun) {
      Start-Sleep -Seconds 5
    }
  }

  return $ProjectId
}

function Ensure-GcloudResource {
  param(
    [scriptblock]$Check,
    [scriptblock]$Create,
    [string]$ResourceDescription
  )

  if ($DryRun) {
    Write-Host "[dry-run] would ensure $ResourceDescription" -ForegroundColor DarkYellow
    return
  }

  $exists = $false
  try {
    $exists = & $Check
  } catch {
    $exists = $false
  }

  if ($exists) {
    Write-Host "$ResourceDescription already present" -ForegroundColor Green
    return
  }

  & $Create
}

function Ensure-PubSubTopic {
  param([string]$ProjectId, [string]$Topic)

  Ensure-GcloudResource -ResourceDescription "Pub/Sub topic '$Topic'" -Check {
    & $gcloud pubsub topics describe $Topic --project $ProjectId --format='value(name)' *> $null
    return $LASTEXITCODE -eq 0
  } -Create {
    Invoke-Gcloud pubsub topics create $Topic --project $ProjectId --quiet
  }
}

function Ensure-ServiceAccount {
  param([string]$ProjectId, [string]$ServiceAccountId, [string]$DisplayName)

  $email = "$ServiceAccountId@$ProjectId.iam.gserviceaccount.com"
  Ensure-GcloudResource -ResourceDescription "service account $email" -Check {
    & $gcloud iam service-accounts describe $email --project $ProjectId *> $null
    return $LASTEXITCODE -eq 0
  } -Create {
    Invoke-Gcloud iam service-accounts create $ServiceAccountId --project $ProjectId --display-name $DisplayName --quiet
  }

  return $email
}

function Grant-ServiceAccountRoles {
  param([string]$ProjectId, [string]$ServiceAccountEmail)

  $roles = @(
    'roles/cloudfunctions.developer',
    'roles/iam.serviceAccountUser',
    'roles/pubsub.admin',
    'roles/secretmanager.secretAccessor'
  )

  foreach ($role in $roles) {
    Invoke-Gcloud projects add-iam-policy-binding $ProjectId --member "serviceAccount:$ServiceAccountEmail" --role $role --quiet
  }
}

function Ensure-ServiceAccountKey {
  param([string]$ServiceAccountEmail, [string]$ProjectId)

  if ($SkipKey) {
    Write-Host 'Skipping key creation as requested.' -ForegroundColor Yellow
    return $null
  }

  $outputPath = $KeyOutputPath
  if ($outputPath) {
    $resolved = Resolve-Path -LiteralPath $outputPath -ErrorAction SilentlyContinue
    if ($resolved) {
      $outputPath = $resolved.Path
    }
  } else {
    $outputPath = Join-Path (Get-Location) 'gcp-service-account-key.json'
  }

  if ((Test-Path -Path $outputPath) -and -not $DryRun) {
    throw "Key output path '$outputPath' already exists. Refusing to overwrite."
  }

  Invoke-Gcloud iam service-accounts keys create $outputPath --iam-account $ServiceAccountEmail --project $ProjectId --quiet

  if ($DryRun) {
    Write-Host "[dry-run] would write service account key to $outputPath" -ForegroundColor DarkYellow
  } else {
    Write-Host "Service account key written to $outputPath" -ForegroundColor Yellow
  }

  return $outputPath
}

function Resolve-GithubRepo {
  param([string]$ExplicitRepo)

  if ($ExplicitRepo) {
    return $ExplicitRepo
  }

  try {
    $remoteUrl = git config --get remote.origin.url 2>$null
    if ($remoteUrl -match 'github.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)') {
      return "$($matches.owner)/$($matches.repo)"
    }
  } catch {
    # ignore
  }

  throw 'Unable to determine GitHub repository. Pass -GithubRepo owner/repo.'
}

function Set-GithubSecret {
  param(
    [string]$Repo,
    [string]$SecretName,
    [string]$SecretValue,
    [switch]$Optional
  )

  if (-not $SecretValue) {
    if ($Optional) {
      Write-Host "Skipping optional secret $SecretName" -ForegroundColor Yellow
      return
    }

    throw "Value required for GitHub secret $SecretName"
  }

  $runGhScript = Join-Path $PSScriptRoot 'run-gh.ps1'
  if (-not (Test-Path $runGhScript)) {
    throw 'scripts/run-gh.ps1 not found; unable to set GitHub secrets. Configure gh manually or copy the template.'
  }

  $args = @('secret', 'set', $SecretName, '--repo', $Repo, '--body', $SecretValue)
  powershell -NoProfile -ExecutionPolicy Bypass -File $runGhScript @args
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to set GitHub secret $SecretName"
  }
}

function Check-FreeTierUsage {
  param([string]$ProjectId, [double]$Threshold)

  if ($DryRun) {
    Write-Host '[dry-run] would check free-tier usage' -ForegroundColor DarkYellow
    return
  }

  $nowUtc = [DateTime]::UtcNow
  $startUtc = [DateTime]::ParseExact($nowUtc.ToString('yyyy-MM') + '-01T00:00:00Z', 'yyyy-MM-dd\THH:mm:ss\Z', $null)

  $filter = 'metric.type="cloudfunctions.googleapis.com/function/execution_count"'
  $encodedFilter = [System.Uri]::EscapeDataString($filter)
  $start = $startUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
  $end = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
  $uri = "https://monitoring.googleapis.com/v3/projects/$ProjectId/timeSeries?filter=$encodedFilter&interval.startTime=$start&interval.endTime=$end&aggregation.alignmentPeriod=86400s&aggregation.perSeriesAligner=ALIGN_SUM&aggregation.crossSeriesReducer=REDUCE_SUM"

  $token = & $gcloud auth print-access-token
  if (-not $token) {
    Write-Warning 'Unable to obtain access token for free-tier check.'
    return
  }

  try {
    $response = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $token" }
  } catch {
    Write-Warning "Unable to query Cloud Monitoring for free-tier usage: $($_.Exception.Message)"
    return
  }

  $total = 0.0
  $seriesCollection = @()
  if ($response -and $response.timeSeries) {
    $seriesCollection = $response.timeSeries
  }
  foreach ($series in $seriesCollection) {
    $points = @()
    if ($series -and $series.points) {
      $points = $series.points
    }
    foreach ($point in $points) {
      $value = $point.value
      if ($value.doubleValue) {
        $total += [double]$value.doubleValue
      } elseif ($value.int64Value) {
        $total += [double]$value.int64Value
      }
    }
  }

  $limit = 2000000.0
  $ratio = if ($limit -eq 0) { 0.0 } else { $total / $limit }
  $percent = [Math]::Round($ratio * 100, 1)
  Write-Host "Current monthly Cloud Functions executions: $([math]::Round($total, 0)) / $([math]::Round($limit,0)) (${percent}% of free tier)" -ForegroundColor Cyan

  if ($ratio -ge $Threshold) {
    $message = "Free-tier threshold reached: $([math]::Round($total,0)) executions (${percent}% of limit). Aborting bootstrap."
    Write-Host $message -ForegroundColor Red
    Send-StatusNotification $message 'critical'
    throw 'Free-tier usage threshold exceeded; aborting setup.'
  }

  if ($ratio -ge ($Threshold - 0.1)) {
    $warn = "Free-tier usage is approaching the threshold (${percent}% of limit)."
    Write-Host $warn -ForegroundColor Yellow
    Send-StatusNotification $warn 'warning'
  }
}

Ensure-GcloudLogin
$ProjectId = Ensure-Project -ProjectId $ProjectId -BaseProjectName $BaseProjectName -BillingAccountId $BillingAccountId

Check-FreeTierUsage -ProjectId $ProjectId -Threshold $FreeTierThreshold

$Region = Prompt-IfMissing -Value $Region -Prompt 'Enter region' -Default $Region
$PubSubTopic = Prompt-IfMissing -Value $PubSubTopic -Prompt 'Enter Pub/Sub topic' -Default $PubSubTopic

Write-Host "Configuring project '$ProjectId' in region '$Region'" -ForegroundColor Cyan
Invoke-Gcloud config set project $ProjectId --quiet

$services = @(
  'cloudfunctions.googleapis.com',
  'pubsub.googleapis.com',
  'secretmanager.googleapis.com'
)

foreach ($service in $services) {
  Invoke-Gcloud services enable $service --quiet
}

Ensure-PubSubTopic -ProjectId $ProjectId -Topic $PubSubTopic
$serviceAccountEmail = Ensure-ServiceAccount -ProjectId $ProjectId -ServiceAccountId $ServiceAccountId -DisplayName $ServiceAccountDisplayName
Grant-ServiceAccountRoles -ProjectId $ProjectId -ServiceAccountEmail $serviceAccountEmail
$keyPath = Ensure-ServiceAccountKey -ServiceAccountEmail $serviceAccountEmail -ProjectId $ProjectId

if ($ConfigureGithubSecrets) {
  if ($DryRun) {
    Write-Host '[dry-run] would configure GitHub secrets (skipped).' -ForegroundColor DarkYellow
  } else {
    $repo = Resolve-GithubRepo -ExplicitRepo $GithubRepo
    Write-Host "Configuring GitHub secrets in $repo" -ForegroundColor Cyan

    if (-not $keyPath -or -not (Test-Path $keyPath)) {
      throw 'Service account key file not found; cannot upload GCP_SA_KEY.'
    }

    $keyContent = Get-Content -LiteralPath $keyPath -Raw
    Set-GithubSecret -Repo $repo -SecretName 'GCP_SA_KEY' -SecretValue $keyContent
    Set-GithubSecret -Repo $repo -SecretName 'GCP_PROJECT' -SecretValue $ProjectId

    $regionSecret = Prompt-IfMissing -Value $Region -Prompt 'GCP region for secret' -Default $Region
    Set-GithubSecret -Repo $repo -SecretName 'GCP_REGION' -SecretValue $regionSecret

    $topicSecret = Prompt-IfMissing -Value $PubSubTopic -Prompt 'Pub/Sub topic for secret' -Default $PubSubTopic
    Set-GithubSecret -Repo $repo -SecretName 'PUBSUB_TOPIC' -SecretValue $topicSecret

    $apiKey = Read-Host 'Optional INGEST_API_KEY (leave blank to skip)'
    Set-GithubSecret -Repo $repo -SecretName 'INGEST_API_KEY' -SecretValue $apiKey -Optional

    $audience = Read-Host 'Optional ALLOWED_AUDIENCE (leave blank to skip)'
    Set-GithubSecret -Repo $repo -SecretName 'ALLOWED_AUDIENCE' -SecretValue $audience -Optional

    $issuers = Read-Host 'Optional ALLOWED_ISSUERS (comma-separated, leave blank to skip)'
    Set-GithubSecret -Repo $repo -SecretName 'ALLOWED_ISSUERS' -SecretValue $issuers -Optional

    Send-StatusNotification "Updated GitHub secrets for $repo" 'info'
  }
}

Send-StatusNotification "GCP bootstrap completed for project $ProjectId" 'info'
Write-Host 'GCP bootstrap complete.' -ForegroundColor Green