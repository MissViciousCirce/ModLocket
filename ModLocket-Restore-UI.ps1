function Show-ModRestoreReview($Review) {
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Restore missing mods from backup';$dialog.ClientSize=New-Object Drawing.Size 1050,590
    $dialog.MinimumSize=New-Object Drawing.Size 900,530;$dialog.StartPosition='CenterParent'
    $summary=New-Object Windows.Forms.Label
    $summary.Location=New-Object Drawing.Point 18,16;$summary.Size=New-Object Drawing.Size 1014,92;$summary.Anchor='Top, Left, Right'
    $summary.Text=("{0} mods to restore | {1} missing records | {2} files | {3:N2} GiB`r`n`r`nRestores the versions saved in your selected backup. Existing versions and unrelated mods stay as they are.`r`nMods you deliberately removed may be listed too. Review before restoring." -f $Review.ModCount,$Review.RecordCount,$Review.FileCount,($Review.CopyBytes/1GB))
    $list=New-Object Windows.Forms.ListView
    $list.Location=New-Object Drawing.Point 18,115;$list.Size=New-Object Drawing.Size 1014,345;$list.Anchor='Top, Bottom, Left, Right'
    $list.View='Details';$list.FullRowSelect=$true;$list.ShowItemToolTips=$true
    foreach($c in @(@('Mod',235),@('Saved version',110),@('Action',170),@('Details',480))){[void]$list.Columns.Add($c[0],[int]$c[1])}
    foreach($row in @($Review.Rows | Sort-Object @{Expression={if($_.State -ceq 'Restore from backup'){0}elseif($_.State -ceq 'Needs attention'){1}else{2}}},Name)){
        $item=New-Object Windows.Forms.ListViewItem([string]$row.Name)
        foreach($value in @($row.Version,$row.State,$row.Reason)){[void]$item.SubItems.Add([string]$value)}
        $item.ToolTipText=[string]$row.Reason;[void]$list.Items.Add($item)
    }
    $notice=New-Object Windows.Forms.Label
    $notice.Location=New-Object Drawing.Point 18,475;$notice.Size=New-Object Drawing.Size 1014,50;$notice.Anchor='Bottom, Left, Right'
    $notice.Text='Keep ARK closed until restoration finishes. This restores backup files and missing installation records; it does not fetch newer releases or launch ARK. Items marked Needs attention will be skipped.'
    $restore=New-Object Windows.Forms.Button
    $restore.Text='Restore listed missing mods';$restore.Location=New-Object Drawing.Point 18,538;$restore.Size=New-Object Drawing.Size 260,35;$restore.Anchor='Bottom, Left';$restore.DialogResult='OK';$restore.Enabled=($Review.ModCount -gt 0)
    $close=New-Object Windows.Forms.Button
    $close.Text='Cancel';$close.Location=New-Object Drawing.Point 902,538;$close.Size=New-Object Drawing.Size 130,35;$close.Anchor='Bottom, Right';$close.DialogResult='Cancel'
    $dialog.Controls.AddRange(@($summary,$list,$notice,$restore,$close));$dialog.AcceptButton=$close;$dialog.CancelButton=$close
    Set-DialogTheme $dialog
    try{return $dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK}finally{$dialog.Dispose()}
}

function Request-LaunchAnyway {
    if ($script:ActiveWorker) { return }
    try {
        if (-not (Ensure-ArkRoot)) { return }
        # A launch bypasses version checks, but must not race an unfinished write
        # from a different app instance or an interrupted installation.
        $cf=Join-Path $script:ArkRoot 'ShooterGame/Binaries/Win64/ShooterGame'
        $lock=$null
        try {
            $lock=[IO.File]::Open((Join-Path $cf 'ModLocket.operation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            foreach($kind in @('UpdateTransactions','RestoreTransactions')) {
                $root=Join-Path $cf ('ModLocketSafetyPreview/'+$kind)
                if(Test-Path -LiteralPath $root){
                    foreach($dir in @(Get-ChildItem -LiteralPath $root -Directory)){
                        if((Test-Path -LiteralPath (Join-Path $dir.FullName 'journal.json')) -and -not(Test-Path -LiteralPath (Join-Path $dir.FullName 'committed.json')) -and -not(Test-Path -LiteralPath (Join-Path $dir.FullName 'rolled-back.json'))){throw 'A mod installation or restore was interrupted. Click RESTORE MISSING MODS to finish recovery before launching.'}
                    }
                }
            }
            Start-Process -FilePath 'steam://launch/2399830/option1' -ErrorAction Stop
        } finally { if($lock){$lock.Dispose()} }
        Set-StatusPill 'Attention'
        $progressLabel.Text='Launch requested - checks skipped'
        Add-LogLine 'ARK launch requested through Steam without BattlEye. Mod files, enabled settings and installation records were kept unchanged. ARK or a server may still require updates.' $Colors.Warning
    } catch { [void](Show-ThemedMessage $_.Exception.Message 'Launch anyway') }
}
