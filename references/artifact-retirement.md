# Recoverable Repair Artifact Retirement

Use this after a completed repair when permanent cleanup was denied or when the user wants recoverable handling of large generated artifacts. It is a materially different operation: same-volume renames with content verification, not permanent deletion under another command name. It clears the build locations but frees **zero disk space**. Never label quarantine as deletion or claim reclaimed capacity.

`blocked by policy` from command creation is an executor refusal, not an NTFS error or an error emitted by the cleanup script. The short message does not identify the rejecting layer or its rationale. Do not change approval/sandbox settings, add broad allow rules, wrap the rejected deletion in another language, or dispatch it through a scheduled task. Official [Auto-review guidance](https://learn.chatgpt.com/docs/sandboxing/auto-review) permits a materially safer alternative; it does not let a skill override a denial.

## Automatic Workflow

1. Confirm the repair/build and its helper processes have finished. Preserve evidence, backups, state, active runtimes, and any recovery package still needed for an unfinished installation. Do not infer artifact ownership from a directory name alone: use the current repair's recorded paths and successful results.
2. Use `scripts/retire-codex-artifacts.ps1 -Action Plan` with an explicit work root, artifact-relative paths, retained manifest path, and a separate quarantine root on the same drive. By default it fingerprints the complete directory inventory, sizes, and write times, including empty directories, without rereading gigabytes of disposable file contents. Same-volume rename preserves the actual files. Use `-VerifyFileContents` during planning when full per-file SHA-256 verification is needed; the chosen mode is retained in the manifest and journal. Metadata comparison is not byte-integrity proof.
3. Inspect the plan and pass its exact SHA-256 to `-Action Quarantine`. The tool preflights every artifact before moving any, rejects reparse points and protected roots, and refuses differences in the selected snapshot mode or occupied destinations. It never overwrites an artifact or falls back to copy/delete. The manifest journal records progress so an interrupted operation can be resumed without a duplicate move.
4. Read the final journal. Report `quarantine-complete`, the retained manifest and quarantine location, and explicitly state that disk space was not freed. Preserve this receipt in the repair handoff. This route runs within the already-authorized repair scope and normally requires no manual user command.
5. If this different operation is also denied, stop. Record the exact refused action and available reason; do not launch it outside the review path. A skill cannot guarantee acceptance under every host policy. Do not present a manual recursive-delete command as a completed fix.

Example for a completed transaction; choose actual recorded artifact paths rather than copying this list blindly:

```powershell
$root = '<completed-repair-work-root>'
$manifest = Join-Path $root 'evidence\retirement-plan.json'
$quarantine = '<separate-same-drive-artifact-quarantine>'
$plan = & "$SkillRoot\scripts\retire-codex-artifacts.ps1" -Action Plan `
  -WorkRoot $root -ManifestPath $manifest -QuarantineRoot $quarantine `
  -RelativePath @('build', 'analysis-asar', 'recovery-layout', 'tests', 'temp', 'npm-cache') |
  ConvertFrom-Json
& "$SkillRoot\scripts\retire-codex-artifacts.ps1" -Action Quarantine `
  -WorkRoot $root -ManifestPath $manifest -ExpectedManifestSha256 $plan.sha256
```

The root itself, `evidence`, `backups`, user configuration, installed plugins, and runtime caches are not eligible artifact names. The helper intentionally supports only conventional repair staging directories and explicitly named transactional MSIX files. An unfamiliar layout requires inspection and a reviewed extension of the scope rules, not renaming user data to fit the allowlist.

## Restore

Use the same retained manifest and SHA-256 with `-Action Restore`. It validates the quarantined snapshot in the manifest's recorded mode before moving items back and refuses any existing destination. It can resume after interruption and is idempotent after a completed restore. A restore is also a file mutation subject to the executor's normal review.

Keep quarantine contents until a separately authorized disposal policy can actually run. Do not schedule future deletion as an escape from a present refusal. When immediate disk-space recovery is a hard requirement and permanent deletion remains prohibited, report that specific limitation instead of calling this reversible operation a space-recovery solution.

Validation: `test-retire-codex-artifacts.ps1 -TemporaryRoot <isolated-test-root>` exercises real directory/file moves and restoration, Chinese filenames, empty directories, batch preflight, changes after planning, collisions, reparse rejection, and repeat runs. Run it with Windows PowerShell 5.1 and PowerShell 7.
