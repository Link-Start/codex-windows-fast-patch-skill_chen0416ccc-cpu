[CmdletBinding()]
param(
  [ValidateSet('Plan', 'Quarantine', 'Restore')][string]$Action = 'Plan',
  [Parameter(Mandatory = $true)][string]$WorkRoot,
  [Parameter(Mandatory = $true)][string]$ManifestPath,
  [string[]]$RelativePath,
  [string]$QuarantineRoot,
  [string]$ExpectedManifestSha256,
  [switch]$VerifyFileContents
)

$ErrorActionPreference = 'Stop'
$comparison = [StringComparison]::OrdinalIgnoreCase
$script:HashArtifactContents = $VerifyFileContents.IsPresent

function Full-Path([string]$Value) {
  if (-not [IO.Path]::IsPathRooted($Value) -or $Value.StartsWith('\\') -or $Value -match '[*?\[\]]') {
    throw 'Only literal absolute local paths are supported.'
  }
  return [IO.Path]::GetFullPath($Value).TrimEnd('\')
}

function Assert-NoReparseAncestor([string]$Path) {
  $current = $Path
  while ($current) {
    if (Test-Path -LiteralPath $current) {
      if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Reparse point is not permitted: $current"
      }
    }
    $parent = Split-Path -Parent $current
    if ($parent -eq $current) { break }
    $current = $parent
  }
}

function Assert-SafeRoot([string]$Path) {
  if ($Path.Length -le 3 -or $Path -match '(?i)\\WindowsApps(?:\\|$)|\\(?:\.codex|\.agents)(?:\\|$)') {
    throw 'A drive root, installed package, or agent state tree cannot be an artifact root.'
  }
  if ($env:USERPROFILE -and $Path.Equals([IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\'), $comparison)) {
    throw 'A protected system/user root cannot be an artifact root.'
  }
  $runtimeRoot = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'OpenAI\Codex' } else { $null }
  foreach ($protected in @($env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $runtimeRoot)) {
    if ($protected -and ($Path.Equals([IO.Path]::GetFullPath($protected).TrimEnd('\'), $comparison) -or $Path.StartsWith([IO.Path]::GetFullPath($protected).TrimEnd('\')+'\', $comparison))) {
      throw 'A protected system/user root cannot be an artifact root.'
    }
  }
  Assert-NoReparseAncestor $Path
}

function Assert-ArtifactRelativePath([string]$Path) {
  if ($Path -notmatch '^(?:build(?:[-0-9][a-zA-Z0-9_-]*)?|analysis-asar(?:[-0-9][a-zA-Z0-9_-]*)?|recovery-layout(?:[-0-9][a-zA-Z0-9_-]*)?|tests|temp|npm-cache|transactional(?:[-0-9][a-zA-Z0-9_-]*)?\\Codex_[0-9.]+_(?:update|recovery)\.msix)$') {
    throw "Not an eligible generated repair artifact: $Path"
  }
}

function Get-TreeSnapshot([string]$Path) {
  Assert-NoReparseAncestor $Path
  $rootItem = Get-Item -LiteralPath $Path -Force
  $pending = [Collections.Generic.Queue[IO.FileSystemInfo]]::new()
  $pending.Enqueue($rootItem)
  $rows = [Collections.Generic.List[object]]::new()
  while ($pending.Count) {
    $item = $pending.Dequeue()
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Nested reparse point: $($item.FullName)" }
    $relative = if ($item.FullName.Equals($rootItem.FullName, $comparison)) { '.' } else { $item.FullName.Substring($rootItem.FullName.Length + 1) }
    if ($item -is [IO.DirectoryInfo]) {
      $rows.Add([ordered]@{path=$relative;kind='directory'})
      foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force) { $pending.Enqueue($child) }
    } else {
      $row = [ordered]@{path=$relative;kind='file';bytes=$item.Length;lastWriteTimeUtcTicks=$item.LastWriteTimeUtc.Ticks}
      if ($script:HashArtifactContents) { $row.sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash }
      $rows.Add($row)
    }
  }
  return @($rows | Sort-Object { $_.path })
}

function Snapshot-Digest($Rows) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($Rows) -Depth 8 -Compress))
    return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
  } finally { $sha.Dispose() }
}

function Write-JsonAtomic([string]$Path, $Value) {
  Assert-NoReparseAncestor $Path
  $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
  [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 12), [Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Assert-Snapshot([string]$Path, [string]$Expected) {
  if (-not (Test-Path -LiteralPath $Path)) { throw "Artifact is missing: $Path" }
  $digest = Snapshot-Digest (Get-TreeSnapshot $Path)
  if ($digest -cne $Expected) { throw "Artifact changed since planning; no move allowed: $Path" }
}

$root = Full-Path $WorkRoot
$manifestFile = Full-Path $ManifestPath
if ([IO.Path]::GetExtension($manifestFile) -ine '.json') { throw 'Manifest must be a retained JSON file.' }
Assert-SafeRoot $root
Assert-NoReparseAncestor $manifestFile
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'WorkRoot must already exist.' }
if (-not $manifestFile.StartsWith($root + '\', $comparison)) { throw 'Keep the manifest inside the retained work root.' }

if ($Action -eq 'Plan') {
  if (-not $RelativePath -or -not $QuarantineRoot) { throw 'Plan requires explicit artifact paths and a quarantine root.' }
  if (Test-Path -LiteralPath $manifestFile) { throw 'Do not overwrite an existing plan.' }
  $quarantine = Full-Path $QuarantineRoot
  Assert-SafeRoot $quarantine
  if ([IO.Path]::GetPathRoot($root) -ine [IO.Path]::GetPathRoot($quarantine)) { throw 'Quarantine must be on the same drive; copy/delete fallback is not permitted.' }
  if ($quarantine.Equals($root, $comparison) -or $quarantine.StartsWith($root + '\', $comparison) -or $root.StartsWith($quarantine + '\', $comparison)) { throw 'Work and quarantine roots must not overlap.' }
  $id = [guid]::NewGuid().ToString('N')
  $destinationRoot = Join-Path $quarantine $id
  $targets = @()
  foreach ($relative in $RelativePath) {
    Write-Verbose "Hashing artifact inventory: $relative"
    # Only conventional disposable repair outputs are eligible; evidence and state stay put.
    Assert-ArtifactRelativePath $relative
    $source = Full-Path (Join-Path $root $relative)
    if (-not $source.StartsWith($root + '\', $comparison) -or $manifestFile.StartsWith($source + '\', $comparison)) { throw 'Artifact escapes scope or contains its own manifest.' }
    if (@($targets | Where-Object { $_.source -ieq $source }).Count) { throw 'Duplicate artifact path.' }
    $snapshot = Get-TreeSnapshot $source
    $bytes = 0L; $files = 0
    foreach ($row in $snapshot) { if ($row.kind -eq 'file') { $bytes += $row.bytes; $files++ } }
    $targets += [ordered]@{source=$source;destination=(Join-Path $destinationRoot $relative);snapshotSha256=(Snapshot-Digest $snapshot);files=$files;bytes=$bytes}
  }
  $mode = if ($script:HashArtifactContents) { 'sha256' } else { 'metadata' }
  $manifest = [ordered]@{schema=1;operation='same-volume-quarantine';verificationMode=$mode;id=$id;workRoot=$root;quarantineRoot=$quarantine;createdUtc=[DateTime]::UtcNow.ToString('o');targets=$targets}
  $parent = Split-Path -Parent $manifestFile
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Write-JsonAtomic $manifestFile $manifest
  [pscustomobject]@{stage='planned';manifest=$manifestFile;sha256=(Get-FileHash -LiteralPath $manifestFile).Hash;targets=$targets.Count;bytes=($targets | ForEach-Object { $_.bytes } | Measure-Object -Sum).Sum;diskSpaceFreed=0} | ConvertTo-Json
  return
}

if (-not $ExpectedManifestSha256 -or (Get-FileHash -LiteralPath $manifestFile).Hash -cne $ExpectedManifestSha256) { throw 'An unchanged, explicitly reviewed manifest hash is required.' }
$plan = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ($plan.schema -ne 1 -or $plan.operation -cne 'same-volume-quarantine' -or $plan.workRoot -cne $root -or $plan.id -notmatch '^[a-f0-9]{32}$' -or -not $plan.targets.Count) { throw 'Invalid artifact plan.' }
if ($plan.verificationMode -notin @('metadata','sha256')) { throw 'Invalid verification mode.' }
$script:HashArtifactContents = $plan.verificationMode -eq 'sha256'
$quarantine = Full-Path $plan.quarantineRoot
Assert-SafeRoot $quarantine
if ([IO.Path]::GetPathRoot($root) -ine [IO.Path]::GetPathRoot($quarantine) -or $quarantine.StartsWith($root + '\', $comparison) -or $root.StartsWith($quarantine + '\', $comparison) -or $quarantine.Equals($root, $comparison)) { throw 'Invalid quarantine boundary.' }
$destinationRoot = Join-Path $quarantine $plan.id
$journalPath = $manifestFile + '.journal.json'
$journal = if (Test-Path -LiteralPath $journalPath) { Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
if ($journal -and $journal.manifestSha256 -cne $ExpectedManifestSha256) { throw 'Journal belongs to a different manifest.' }
$operations = @()
foreach ($entry in $plan.targets) {
  Write-Verbose "Verifying artifact before $Action`: $($entry.source)"
  $source = Full-Path $entry.source
  $destination = Full-Path $entry.destination
  if (-not $source.StartsWith($root + '\', $comparison) -or -not $destination.StartsWith($destinationRoot + '\', $comparison)) { throw 'Manifest path escaped its root.' }
  $relative = $source.Substring($root.Length + 1)
  Assert-ArtifactRelativePath $relative
  if ($destination -ine (Join-Path $destinationRoot $relative) -or $manifestFile.StartsWith($source + '\', $comparison)) { throw 'Invalid destination mapping.' }
  $from = if ($Action -eq 'Quarantine') { $source } else { $destination }
  $to = if ($Action -eq 'Quarantine') { $destination } else { $source }
  Assert-NoReparseAncestor $from
  Assert-NoReparseAncestor $to
  if (-not (Test-Path -LiteralPath $from)) {
    if (-not $journal) { throw 'Missing source without an operation journal.' }
    Assert-Snapshot $to $entry.snapshotSha256
    continue
  }
  if (Test-Path -LiteralPath $to) { throw "Destination exists; never overwrite it: $to" }
  Assert-Snapshot $from $entry.snapshotSha256
  $operations += [pscustomobject]@{from=$from;to=$to;digest=$entry.snapshotSha256}
}
# All targets pass before the first move; a journal is persisted before each atomic rename.
Write-JsonAtomic $journalPath ([ordered]@{manifestSha256=$ExpectedManifestSha256;action=$Action;stage='preflight-complete';time=[DateTime]::UtcNow.ToString('o')})
foreach ($operation in $operations) {
  Assert-Snapshot $operation.from $operation.digest
  Assert-NoReparseAncestor $operation.to
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $operation.to) | Out-Null
  Write-JsonAtomic $journalPath ([ordered]@{manifestSha256=$ExpectedManifestSha256;action=$Action;stage='moving';from=$operation.from;to=$operation.to;time=[DateTime]::UtcNow.ToString('o')})
  $item = Get-Item -LiteralPath $operation.from -Force
  if ($item.PSIsContainer) { [IO.Directory]::Move($operation.from, $operation.to) } else { [IO.File]::Move($operation.from, $operation.to) }
  Assert-Snapshot $operation.to $operation.digest
}
$result = [ordered]@{manifestSha256=$ExpectedManifestSha256;action=$Action;stage=($Action.ToLowerInvariant()+'-complete');verificationMode=$plan.verificationMode;targets=$plan.targets.Count;diskSpaceFreed=0;time=[DateTime]::UtcNow.ToString('o')}
Write-JsonAtomic $journalPath $result
$result | ConvertTo-Json
