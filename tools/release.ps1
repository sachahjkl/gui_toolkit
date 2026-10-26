# Publishes a version of gui_toolkit: assembles the fragments of changelog.d\ into a CHANGELOG.md section and writes the
# version (ui/version.odin, the README's badge) with tools\changelog.ps1, commits that as "<version>: <summary>", tags the
# commit (annotated, signed tags need -a), pushes master and the tag, and creates the GitHub release with the section as notes.
# Branches never write the version nor CHANGELOG.md: only this script does (CONTRIBUTING.md).
#   powershell -File tools\release.ps1 0.43.0 ["one-line summary"] [-NoPush]
# -NoPush stops after the tag (to look at the commit; `git tag -d v<version>` and `git reset --hard HEAD~1` undo it).
param([Parameter(Mandatory)][string]$Version, [string]$Summary = "", [switch]$NoPush)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot)
$changelog = Join-Path $PSScriptRoot 'changelog.ps1'

if (git status --porcelain) { throw "the working tree is not clean" }
& powershell -NoProfile -ExecutionPolicy Bypass -File $changelog -Check
if ($LASTEXITCODE) { throw "changelog.d has fragments to fix first" }
& powershell -NoProfile -ExecutionPolicy Bypass -File $changelog -Assemble -Version $Version
if ($LASTEXITCODE) { throw "assembling the CHANGELOG failed" }
& powershell -NoProfile -ExecutionPolicy Bypass -File $changelog -Check -Release $Version
if ($LASTEXITCODE) { throw "the release is not consistent" }

$title = if ($Summary) { "v${Version}: $Summary" } else { "v$Version" }
git add -A -- CHANGELOG.md changelog.d ui/version.odin README.md
if ($LASTEXITCODE) { throw "git add failed" }
git commit -q -m $(if ($Summary) { "${Version}: $Summary" } else { $Version })
if ($LASTEXITCODE) { throw "git commit failed" }
$tag = "v$Version"
git tag -a $tag -m $title
if ($LASTEXITCODE) { throw "git tag failed" }
if ($NoPush) { "committed and tagged $tag (not pushed)"; exit 0 }
git push origin HEAD:master
if ($LASTEXITCODE) { throw "pushing master failed" }
git push origin $tag
if ($LASTEXITCODE) { throw "pushing the tag failed" }

$notes = Join-Path $env:TEMP "gui_toolkit-$Version-notes.md"
& powershell -NoProfile -ExecutionPolicy Bypass -File $changelog -Section -Version $Version -Out $notes
if ($LASTEXITCODE) { throw "reading the CHANGELOG section failed" }
gh release create $tag --title "gui_toolkit $Version" --notes-file $notes --verify-tag --latest
if ($LASTEXITCODE) { throw "gh release create failed" }
Remove-Item $notes
"released $tag"
