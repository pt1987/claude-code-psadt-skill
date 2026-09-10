---
name: "trigger-existing-package-folder"
tags: [trigger, should-fire, folder-context]
plugins: ["../.."]
runs: 3
max_turns: 4
context:
  scaffold_script: |
    set -e
    mkdir -p Files Assets
    printf '%s\n' '# PSADT v4 launcher (fixture, not a real package)' '$adtSession = @{ AppVendor = "Contoso"; AppName = "Widget"; AppVersion = "1.2.3" }' > Invoke-AppDeployToolkit.ps1
    printf '%s\n' '{ "schema": 1, "identity": { "appName": "Widget" } }' > psadt-package.json
---

Have a look around and tell me what state this package is in and what still needs doing.
