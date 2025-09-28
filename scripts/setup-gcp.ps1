param(
  [Parameter(Mandatory = $false)]
  [string]$ProjectId,

  [Parameter(Mandatory = $false)]
  [string]$Region = 'us-central1',

  [Parameter(Mandatory = $false)]
  [string]$ServiceAccountId = 'oak-disperser-ci',

  [Parameter(Mandatory = $false)]
  [string]$ServiceAccountDisplayName = 'Oak Disperser CI',

  [Parameter(Mandatory = $false)]
  [string]$PubSubTopic = 'action-dispersal',

  [Parameter(Mandatory = $false)]
  [string]$KeyOutputPath,

  [switch]$SkipKey,

  [switch]$DryRun,

  [switch]$ConfigureGithubSecrets,

  [string]$GithubRepo
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

function Ensure-GcloudLogin {
  Write-Host 'Checking gcloud authentication status...' -ForegroundColor Cyan
  $activeAccount = & $gcloud auth list --filter='status:ACTIVE' --format='value(account)' 2>$null
  if (-not $activeAccount -and -not $DryRun) {
    Write-Host 'No active gcloud account detected. Launching gcloud auth login.' -ForegroundColor Yellow
    & $gcloud auth login
    if ($LASTEXITCODE -ne 0) {
      throw 'gcloud auth login failed.'
    }
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

Ensure-GcloudLogin
$ProjectId = Prompt-IfMissing -Value $ProjectId -Prompt 'Enter GCP project id'
$Region = Prompt-IfMissing -Value $Region -Prompt 'Enter region' -Default $Region
$PubSubTopic = Prompt-IfMissing -Value $PubSubTopic -Prompt 'Enter Pub/Sub topic' -Default $PubSubTopic

if ($ConfigureGithubSecrets -and $SkipKey) {
  throw 'Cannot configure GitHub secrets when --SkipKey is set. Omit --SkipKey to generate a key file.'
}

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

Ensure-GcloudResource -ResourceDescription "Pub/Sub topic '$PubSubTopic'" -Check {
  & $gcloud pubsub topics describe $PubSubTopic --project $ProjectId --format='value(name)' *> $null
  return $LASTEXITCODE -eq 0
} -Create {
  Invoke-Gcloud pubsub topics create $PubSubTopic --project $ProjectId --quiet
}

$serviceAccountEmail = "$ServiceAccountId@$ProjectId.iam.gserviceaccount.com"

Ensure-GcloudResource -ResourceDescription "service account $serviceAccountEmail" -Check {
  & $gcloud iam service-accounts describe $serviceAccountEmail --project $ProjectId *> $null
  return $LASTEXITCODE -eq 0
} -Create {
  Invoke-Gcloud iam service-accounts create $ServiceAccountId --project $ProjectId --display-name $ServiceAccountDisplayName --quiet
}

$roles = @(
  'roles/cloudfunctions.developer',
  'roles/iam.serviceAccountUser',
  'roles/pubsub.admin',
  'roles/secretmanager.secretAccessor'
)

foreach ($role in $roles) {
  Invoke-Gcloud projects add-iam-policy-binding $ProjectId --member "serviceAccount:$serviceAccountEmail" --role $role --quiet
}

if (-not $SkipKey) {
  if (-not $KeyOutputPath) {
    $KeyOutputPath = Join-Path (Get-Location) 'gcp-service-account-key.json'
  }

  if ((Test-Path -Path $KeyOutputPath) -and -not $DryRun) {
    throw "Key output path '$KeyOutputPath' already exists. Refusing to overwrite."
  }

  Invoke-Gcloud iam service-accounts keys create $KeyOutputPath --iam-account $serviceAccountEmail --project $ProjectId --quiet

  if ($DryRun) {
    Write-Host "[dry-run] would write service account key to $KeyOutputPath" -ForegroundColor DarkYellow
  } else {
    Write-Host "Service account key written to $KeyOutputPath" -ForegroundColor Yellow
  }
} else {
  Write-Host 'Skipping key creation as requested.' -ForegroundColor Yellow
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

  $runGh = Join-Path $PSScriptRoot 'run-gh.ps1'
  if (-not (Test-Path $runGh)) {
    throw 'scripts/run-gh.ps1 not found; unable to set GitHub secrets.'
  }

  $args = @('secret', 'set', $SecretName, '--repo', $Repo, '--body', $SecretValue)
  powershell -NoProfile -ExecutionPolicy Bypass -File $runGh @args
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to set GitHub secret $SecretName"
  }
}

if ($ConfigureGithubSecrets) {
  if ($DryRun) {
    Write-Host '[dry-run] would configure GitHub secrets (skipped).' -ForegroundColor DarkYellow
  } else {
    $repo = Resolve-GithubRepo -ExplicitRepo $GithubRepo
    Write-Host "Configuring GitHub secrets in $repo" -ForegroundColor Cyan

    if (-not $KeyOutputPath -or -not (Test-Path $KeyOutputPath)) {
      throw 'Service account key file not found; cannot upload GCP_SA_KEY.'
    }

    $keyContent = Get-Content -Path $KeyOutputPath -Raw
    Set-GithubSecret -Repo $repo -SecretName 'GCP_SA_KEY' -SecretValue $keyContent

    Set-GithubSecret -Repo $repo -SecretName 'GCP_PROJECT' -SecretValue $ProjectId
    $regionSecret = Prompt-IfMissing -Value $Region -Prompt 'Enter GCP region for secret' -Default $Region
    Set-GithubSecret -Repo $repo -SecretName 'GCP_REGION' -SecretValue $regionSecret
    $topicSecret = Prompt-IfMissing -Value $PubSubTopic -Prompt 'Enter Pub/Sub topic for secret' -Default $PubSubTopic
    Set-GithubSecret -Repo $repo -SecretName 'PUBSUB_TOPIC' -SecretValue $topicSecret

    $apiKey = Read-Host 'Optional INGEST_API_KEY (leave blank to skip)'
    Set-GithubSecret -Repo $repo -SecretName 'INGEST_API_KEY' -SecretValue $apiKey -Optional

    $audience = Read-Host 'Optional ALLOWED_AUDIENCE (leave blank to skip)'
    Set-GithubSecret -Repo $repo -SecretName 'ALLOWED_AUDIENCE' -SecretValue $audience -Optional

    $issuers = Read-Host 'Optional ALLOWED_ISSUERS (comma-separated, leave blank to skip)'
    Set-GithubSecret -Repo $repo -SecretName 'ALLOWED_ISSUERS' -SecretValue $issuers -Optional
  }
}

Write-Host 'GCP bootstrap complete.' -ForegroundColor Green