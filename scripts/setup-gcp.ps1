param(
  [Parameter(Mandatory = $true)]
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

  [switch]$DryRun
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

Write-Host 'GCP bootstrap complete.' -ForegroundColor Green