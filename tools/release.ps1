# Publishes a version of gui_toolkit: checks that ui/version.odin and CHANGELOG.md say it, tags the commit (annotated,
# signed tags need -a), pushes master and the tag, and creates the GitHub release with the CHANGELOG section as notes.
#   powershell -File tools\release.ps1 0.17.0 ["one-line summary"]
param([Parameter(Mandatory)][string]$Version, [string]$Summary = "")
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot)

if ((Select-String ui\version.odin -Pattern "VERSION :: `"$([regex]::Escape($Version))`"" -Quiet) -ne $true) { throw "ui/version.odin does not say $Version" }
$changelog = [IO.File]::ReadAllText((Resolve-Path CHANGELOG.md))
$m = [regex]::Match($changelog, "(?ms)^## \[$([regex]::Escape($Version))\][^\n]*\n(.*?)(?=^## \[|\z)")
if (-not $m.Success) { throw "CHANGELOG.md has no section [$Version]" }
if (git status --porcelain) { throw "the working tree is not clean" }

$tag = "v$Version"
$title = if ($Summary) { "v${Version}: $Summary" } else { "v$Version" }
git tag -a $tag -m $title
if ($LASTEXITCODE) { throw "git tag failed" }
git push origin HEAD:master
if ($LASTEXITCODE) { throw "pushing master failed" }
git push origin $tag
if ($LASTEXITCODE) { throw "pushing the tag failed" }

$notes = Join-Path $env:TEMP "gui_toolkit-$Version-notes.md"
[IO.File]::WriteAllText($notes, $m.Groups[1].Value.Trim() + "`n", (New-Object Text.UTF8Encoding $false))
gh release create $tag --title "gui_toolkit $Version" --notes-file $notes --verify-tag --latest
if ($LASTEXITCODE) { throw "gh release create failed" }
Remove-Item $notes
"released $tag"
