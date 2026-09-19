# Never uninstall the user's working copy from this portable test package.
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.MessageBox]::Show(
    'This test build has no installer or uninstaller. Your existing app and backups were not changed. Close this copy before removing its extracted test folder.',
    'Portable test build') | Out-Null
