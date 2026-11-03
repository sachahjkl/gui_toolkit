# Publishes a version of gui_toolkit: assembles the fragments of changelog.d\ into a CHANGELOG.md section and writes the
# version (ui/version.odin, the README's badge) with tools/changelog, commits that as "<version>: <summary>", tags the
# commit (annotated, signed tags need -a), pushes master and the tag, and creates the GitHub release with the section as notes.
# Branches never write the version nor CHANGELOG.md: only this script does (CONTRIBUTING.md). The About picture shows the
# version: it is retaken here, in that commit.
#   powershell -File tools\release.ps1 0.43.0 ["one-line summary"] [-NoPush]
# -NoPush stops after the tag (to look at the commit; `git tag -d v<version>` and `git reset --hard HEAD~1` undo it).
param([Parameter(Mandatory)][string]$Version, [string]$Summary = "", [switch]$NoPush)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot)
$changelog = 'build\changelog.exe'
odin build tools/changelog -out:$changelog
if ($LASTEXITCODE) { throw "building tools/changelog failed" }

if (git status --porcelain) { throw "the working tree is not clean" }
& $changelog -check
if ($LASTEXITCODE) { throw "changelog.d has fragments to fix first" }
& $changelog -assemble -version:$Version
if ($LASTEXITCODE) { throw "assembling the CHANGELOG failed" }
& $changelog -check -release:$Version
if ($LASTEXITCODE) { throw "the release is not consistent" }
& cmd /c ".\build.bat" fidget
if ($LASTEXITCODE) { throw "building fidget failed" }
& node tools/screenshots.mjs --only about
if ($LASTEXITCODE) { throw "the About picture failed" }

$title = if ($Summary) { "v${Version}: $Summary" } else { "v$Version" }
git add -A -- CHANGELOG.md changelog.d ui/version.odin README.md docs/screenshots/about.png
if ($LASTEXITCODE) { throw "git add failed" }
git commit -q -m $(if ($Summary) { "${Version}: $Summary" } else { $Version })
if ($LASTEXITCODE) { throw "git commit failed" }
$tag = "v$Version"
git tag -a $tag -m $title
if ($LASTEXITCODE) { throw "git tag failed" }
if ($NoPush) { "committed and tagged $tag (not pushed)"; exit 0 }
# (git writes its progress to stderr: under a redirected stderr PowerShell would take it for an error; the exit codes say)
$ErrorActionPreference = 'Continue'
git push -q origin HEAD:master
if ($LASTEXITCODE) { throw "pushing master failed" }
git push -q origin $tag
if ($LASTEXITCODE) { throw "pushing the tag failed" }
$ErrorActionPreference = 'Stop'

$notes = Join-Path $env:TEMP "gui_toolkit-$Version-notes.md"
& $changelog -section -version:$Version -out:$notes
if ($LASTEXITCODE) { throw "reading the CHANGELOG section failed" }
gh release create $tag --title "gui_toolkit $Version" --notes-file $notes --verify-tag --latest
if ($LASTEXITCODE) { throw "gh release create failed" }
Remove-Item $notes
"released $tag"
