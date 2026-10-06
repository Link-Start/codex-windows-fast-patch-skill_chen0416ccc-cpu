param([Parameter(Mandatory=$true)][string]$TemporaryRoot)
$ErrorActionPreference='Stop'
$script:checks=0
$tool=Join-Path $PSScriptRoot 'retire-codex-artifacts.ps1'
$fixture=Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ([guid]::NewGuid().ToString('N'))
$work=Join-Path $fixture 'work'
$quarantine=Join-Path $fixture 'quarantine'
$plan=Join-Path $work 'evidence\plan.json'
New-Item -ItemType Directory -Force -Path (Join-Path $work 'build\empty'),(Join-Path $work 'temp'),(Join-Path $work 'evidence'),(Join-Path $work 'backups') | Out-Null
$unicodeName=([string][char]0x4E2D)+([char]0x6587)+'.txt'
$payload=Join-Path $work ('build\'+$unicodeName)
[IO.File]::WriteAllText($payload,'original payload',[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $work 'temp\sample.txt'),'temporary data')
$tempWriteTime=[IO.File]::GetLastWriteTimeUtc((Join-Path $work 'temp\sample.txt'))
$payloadWriteTime=[IO.File]::GetLastWriteTimeUtc($payload)
[IO.File]::WriteAllText((Join-Path $work 'backups\keep.txt'),'preserved backup')

function Assert([bool]$Condition,[string]$Message) {
  if(-not $Condition){throw $Message}
  $script:checks++
}
function Expect-Failure([scriptblock]$Action,[string]$Pattern) {
  $errorText=$null
  try { & $Action | Out-Null } catch { $errorText=$_.Exception.Message }
  Assert ($errorText -and $errorText -match $Pattern) "Expected $Pattern, got $errorText"
}
function Plan([string[]]$Paths,[string]$Output=$plan,[string]$Retention=$quarantine) {
  & $tool -Action Plan -WorkRoot $work -ManifestPath $Output -RelativePath $Paths -QuarantineRoot $Retention
}

Expect-Failure { Plan @('backups') } 'Not an eligible'
Expect-Failure { Plan @('evidence') } 'Not an eligible'
Expect-Failure { Plan @('..\outside') } 'Not an eligible'
Expect-Failure { Plan @('build','build') } 'Duplicate'
Expect-Failure { Plan @('build') -Retention (Join-Path $work 'retired') } 'must not overlap'
$otherVolume=if($work.StartsWith('C:',[StringComparison]::OrdinalIgnoreCase)){'D:\codex-quarantine-test'}else{'C:\codex-quarantine-test'}
Expect-Failure { Plan @('build') -Retention $otherVolume } 'same drive'
Expect-Failure { & $tool -Action Plan -WorkRoot ([IO.Path]::GetPathRoot($work)) -ManifestPath $plan -RelativePath build -QuarantineRoot $quarantine } 'artifact root'
Expect-Failure { & $tool -Action Plan -WorkRoot (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes') -ManifestPath $plan -RelativePath build -QuarantineRoot $quarantine } 'protected system/user root'

$outside=Join-Path $fixture 'outside'
New-Item -ItemType Directory -Path $outside | Out-Null
[IO.File]::WriteAllText((Join-Path $outside 'keep.txt'),'outside target')
$junction=Join-Path $work 'build\link'
New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
Expect-Failure { Plan @('build') } 'reparse point'
[IO.Directory]::Delete($junction)
Assert ((Get-Content -LiteralPath (Join-Path $outside 'keep.txt') -Raw) -eq 'outside target') 'Reparse target changed'

$planned=Plan @('build','temp') | ConvertFrom-Json
$hash=$planned.sha256
Assert ((Test-Path -LiteralPath $payload) -and -not (Test-Path -LiteralPath $quarantine)) 'Plan moved an artifact'
Expect-Failure { Plan @('build') } 'existing plan'
Expect-Failure { & $tool -Action Quarantine -WorkRoot $work -ManifestPath $plan -ExpectedManifestSha256 ('0'*64) } 'reviewed manifest hash'

[IO.File]::WriteAllText((Join-Path $work 'temp\sample.txt'),'modified payload')
Expect-Failure { & $tool -Action Quarantine -WorkRoot $work -ManifestPath $plan -ExpectedManifestSha256 $hash } 'changed since planning'
Assert ((Test-Path -LiteralPath (Join-Path $work 'build')) -and -not (Test-Path -LiteralPath $quarantine)) 'Batch moved first item before validating later item'
[IO.File]::WriteAllText((Join-Path $work 'temp\sample.txt'),'temporary data')
[IO.File]::SetLastWriteTimeUtc((Join-Path $work 'temp\sample.txt'),$tempWriteTime)

$done=& $tool -Action Quarantine -WorkRoot $work -ManifestPath $plan -ExpectedManifestSha256 $hash | ConvertFrom-Json
Assert ($done.stage -eq 'quarantine-complete' -and $done.diskSpaceFreed -eq 0) 'Incorrect quarantine status'
Assert (-not (Test-Path -LiteralPath $payload)) 'Artifact still in work directory'
Assert ((Get-Content -LiteralPath (Join-Path $work 'backups\keep.txt') -Raw) -eq 'preserved backup') 'Backup changed'
$manifest=Get-Content -LiteralPath $plan -Raw -Encoding UTF8 | ConvertFrom-Json
$movedFile=Join-Path $manifest.targets[0].destination $unicodeName
Assert ((Get-Content -LiteralPath $movedFile -Raw) -eq 'original payload') 'Quarantined payload changed'
Assert (Test-Path -LiteralPath (Join-Path $manifest.targets[0].destination 'empty') -PathType Container) 'Empty directory lost'
$repeat=& $tool -Action Quarantine -WorkRoot $work -ManifestPath $plan -ExpectedManifestSha256 $hash | ConvertFrom-Json
Assert ($repeat.stage -eq 'quarantine-complete') 'Idempotent quarantine failed'

New-Item -ItemType Directory -Path (Join-Path $work 'build') | Out-Null
Expect-Failure { & $tool -Action Restore -WorkRoot $work -ManifestPath $plan -ExpectedManifestSha256 $hash } 'Destination exists'
[IO.Directory]::Delete((Join-Path $work 'build'))
$restored=& $tool -Action Restore -WorkRoot $work -ManifestPath $plan -ExpectedManifestSha256 $hash | ConvertFrom-Json
Assert ($restored.stage -eq 'restore-complete') 'Restore failed'
Assert ((Get-Content -LiteralPath $payload -Raw) -eq 'original payload') 'Restore changed payload'
Assert (Test-Path -LiteralPath (Join-Path $work 'build\empty')) 'Restore lost empty directory'
$again=& $tool -Action Restore -WorkRoot $work -ManifestPath $plan -ExpectedManifestSha256 $hash | ConvertFrom-Json
Assert ($again.stage -eq 'restore-complete') 'Idempotent restore failed'

# Simulate interruption after one atomic rename; the journal permits a bounded resume.
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifest.targets[0].destination) | Out-Null
[IO.Directory]::Move($manifest.targets[0].source,$manifest.targets[0].destination)
$resumed=& $tool -Action Quarantine -WorkRoot $work -ManifestPath $plan -ExpectedManifestSha256 $hash | ConvertFrom-Json
Assert ($resumed.stage -eq 'quarantine-complete') 'Interrupted quarantine did not resume'
[IO.File]::WriteAllText($movedFile,'changed after quarantine')
Expect-Failure { & $tool -Action Restore -WorkRoot $work -ManifestPath $plan -ExpectedManifestSha256 $hash } 'changed since planning'
Assert (-not (Test-Path -LiteralPath $payload)) 'Changed quarantine was moved despite failed preflight'
[IO.File]::WriteAllText($movedFile,'original payload',[Text.UTF8Encoding]::new($false))
[IO.File]::SetLastWriteTimeUtc($movedFile,$payloadWriteTime)
& $tool -Action Restore -WorkRoot $work -ManifestPath $plan -ExpectedManifestSha256 $hash | Out-Null
Assert ((Get-Content -LiteralPath $payload -Raw) -eq 'original payload') 'Final restoration failed'
$contentPlan=Join-Path $work 'evidence\content-plan.json'
$full=& $tool -Action Plan -WorkRoot $work -ManifestPath $contentPlan -RelativePath build -QuarantineRoot $quarantine -VerifyFileContents | ConvertFrom-Json
[IO.File]::WriteAllText($payload,'altered! payload',[Text.UTF8Encoding]::new($false))
[IO.File]::SetLastWriteTimeUtc($payload,$payloadWriteTime)
Expect-Failure { & $tool -Action Quarantine -WorkRoot $work -ManifestPath $contentPlan -ExpectedManifestSha256 $full.sha256 } 'changed since planning'
[IO.File]::WriteAllText($payload,'original payload',[Text.UTF8Encoding]::new($false))
[IO.File]::SetLastWriteTimeUtc($payload,$payloadWriteTime)
Write-Output "ARTIFACT_RETIREMENT_PASSED checks=$script:checks fixture=$fixture"
