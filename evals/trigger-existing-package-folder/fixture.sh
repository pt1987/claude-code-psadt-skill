#!/usr/bin/env bash
# Builds the only signal this case gives the model: a directory that looks like a half-finished PSADT
# package. The prompt names neither PSADT nor Intune, so if the skill fires it is because the description
# still carries the folder clause.
#
# Runs only under `claude plugin eval --scaffold`, which is off by default.
set -e

mkdir -p Files Assets

printf '%s\n' \
  '# PSADT v4 launcher (fixture, not a real package)' \
  '$adtSession = @{ AppVendor = "Contoso"; AppName = "Widget"; AppVersion = "1.2.3" }' \
  > Invoke-AppDeployToolkit.ps1

printf '%s\n' '{ "schema": 1, "identity": { "appName": "Widget" } }' > psadt-package.json
