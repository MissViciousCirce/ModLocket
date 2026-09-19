. (Join-Path $ScriptRoot 'ModLocket-CurseForge.ps1')
function Show-UpdateConnection {
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Check for updates';$dialog.ClientSize=New-Object Drawing.Size 620,315
    $dialog.StartPosition='CenterParent';$dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false
    $intro=New-Object Windows.Forms.Label
    $intro.Location=New-Object Drawing.Point 22,20;$intro.Size=New-Object Drawing.Size 576,85
    $intro.Text="Compare your installed mod IDs with saved lists and full backups while ARK is closed.`r`n`r`nLive CurseForge checks require an approved API key. Without one, you can still compare local records and save a small mod list."
    $label=New-Object Windows.Forms.Label
    $label.Location=New-Object Drawing.Point 22,115;$label.Size=New-Object Drawing.Size 576,28
    $label.Text='CurseForge API key (optional; leave blank to keep an existing key)'
    $key=New-Object Windows.Forms.TextBox
    $key.Location=New-Object Drawing.Point 22,145;$key.Size=New-Object Drawing.Size 576,28;$key.UseSystemPasswordChar=$true
    $note=New-Object Windows.Forms.Label
    $note.Location=New-Object Drawing.Point 22,187;$note.Size=New-Object Drawing.Size 576,48
    $note.Text='A key entered here is encrypted for your Windows account. A saved key is not proof of approved API access. This check sends mod IDs to CurseForge.'
    $link=New-Object Windows.Forms.LinkLabel
    $link.Location=New-Object Drawing.Point 22,267;$link.Size=New-Object Drawing.Size 190,25;$link.Text='CurseForge API access information'
    $link.LinkColor=$Colors.Ice;$link.ActiveLinkColor=$Colors.Purple
    $link.Add_LinkClicked({Start-Process 'https://docs.curseforge.com/rest-api/#getting-started'})
    $cancel=New-Object Windows.Forms.Button
    $cancel.Text='Cancel';$cancel.Location=New-Object Drawing.Point 328,265;$cancel.Size=New-Object Drawing.Size 125,32;$cancel.DialogResult='Cancel'
    $check=New-Object Windows.Forms.Button
    $check.Text='Check now';$check.Location=New-Object Drawing.Point 469,265;$check.Size=New-Object Drawing.Size 129,32;$check.DialogResult='OK'
    $dialog.Controls.AddRange(@($intro,$label,$key,$note,$link,$cancel,$check));$dialog.AcceptButton=$check;$dialog.CancelButton=$cancel
    Set-DialogTheme $dialog
    try {
        if($dialog.ShowDialog($form) -ne [Windows.Forms.DialogResult]::OK){return $false}
        if(-not [string]::IsNullOrWhiteSpace($key.Text)){Save-CurseForgeKey $key.Text}
        return $true
    } finally {$key.Clear();$dialog.Dispose()}
}
function Show-ModComparison($Report) {
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Mod list and published-version comparison';$dialog.ClientSize=New-Object Drawing.Size 1100,610
    $dialog.StartPosition='CenterParent';$dialog.FormBorderStyle='Sizable';$dialog.MinimumSize=New-Object Drawing.Size 1000,580
    $summary=New-Object Windows.Forms.Label
    $summary.Location=New-Object Drawing.Point 20,16;$summary.Size=New-Object Drawing.Size 1060,115;$summary.Anchor='Top, Left, Right'
    $summary.Text="$($Report.ModCount) known mods | CurseForge: $($Report.OnlineMode)`r`n$($Report.OnlineMessage)`r`n`r`nA saved mod list uses very little space. Full backups include files for offline restoration."
    if($Report.InvalidIdentityCount -gt 0){$summary.Text+="`r`n$($Report.InvalidIdentityCount) local identities need review; saving the list is disabled."}
    $list=New-Object Windows.Forms.ListView
    $list.Location=New-Object Drawing.Point 20,145;$list.Size=New-Object Drawing.Size 1060,319;$list.Anchor='Top, Bottom, Left, Right'
    $list.View='Details';$list.FullRowSelect=$true;$list.MultiSelect=$false;$list.HideSelection=$false
    foreach($column in @(@('Mod / ID',215),@('Installed file',100),@('Backup file',100),@('Saved-list file',100),@('Published file',100),@('Local state',165),@('CurseForge result',235))){[void]$list.Columns.Add($column[0],[int]$column[1])}
    foreach($row in $Report.Rows){
        $item=New-Object Windows.Forms.ListViewItem("$($row.Name) [$($row.ModId)]")
        foreach($value in @($row.InstalledFileId,$row.BackupFileId,$row.SavedListFileId,$row.PublishedFileId,$row.LocalState,$row.OnlineState)){[void]$item.SubItems.Add([string]$value)}
        $item.Tag=$row;[void]$list.Items.Add($item)
    }
    $details=New-Object Windows.Forms.Label
    $details.Location=New-Object Drawing.Point 20,477;$details.Size=New-Object Drawing.Size 1060,60;$details.Anchor='Bottom, Left, Right'
    $details.Text='Select a row for its saved-version comparisons. Blank file IDs mean unavailable, not verified current.'
    $list.Add_SelectedIndexChanged({
        if($list.SelectedItems.Count -eq 1){$row=$list.SelectedItems[0].Tag;$details.Text="$($row.Name) [$($row.ModId)]`r`nBackup: $($row.BackupComparison) | Saved list: $($row.SavedListComparison)`r`nCurseForge checked: $($row.OnlineCheckedUtc)"}
    }.GetNewClosure())
    $save=New-Object Windows.Forms.Button
    $save.Text='Save mod list only';$save.Location=New-Object Drawing.Point 20,555;$save.Size=New-Object Drawing.Size 185,34;$save.Anchor='Bottom, Left';$save.Enabled=[bool]$Report.CanSaveList
    $save.DialogResult='OK'
    $close=New-Object Windows.Forms.Button
    $close.Text='Close';$close.Location=New-Object Drawing.Point 950,555;$close.Size=New-Object Drawing.Size 130,34;$close.Anchor='Bottom, Right';$close.DialogResult='Cancel'
    $dialog.Controls.AddRange(@($summary,$list,$details,$save,$close));$dialog.AcceptButton=$close;$dialog.CancelButton=$close
    Set-DialogTheme $dialog
    try {return $dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK} finally {$dialog.Dispose()}
}
