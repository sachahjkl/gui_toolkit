type: Fixed

**A test package that does not end names itself** (	ools/test_windowless.ps1): each package is killed after 300 s, with its log (the state changes of its tests) in the CI's, instead of the CI cutting the whole step off after twelve minutes with nothing to read.
