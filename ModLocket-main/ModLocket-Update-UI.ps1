function Show-ModUpdatePlan($Report){
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Download and install Windows mod updates';$dialog.ClientSize=New-Object Drawing.Size 1080,610
    $dialog.MinimumSize=New-Object Drawing.Size 950,550;$dialog.StartPosition='CenterParent'
    $summary=New-Object Windows.Forms.Label
    $summary.Location=New-Object Drawing.Point 20,16;$summary.Size=New-Object Drawing.Size 1040,105;$summary.Anchor='Top, Left, Right'
    $summary.Text=("{0} installable updates | {1:N2} GiB download | {2} mods need attention`r`n`r`nDownloads are checked before installation. Previous versions are retained for recovery.`r`nClose ARK until this finishes. Then create a fresh backup for protected launch." -f $Report.UpdateCount,($Report.DownloadBytes/1GB),$Report.AttentionCount)
    $list=New-Object Windows.Forms.ListView
    $list.Location=New-Object Drawing.Point 20,125;$list.Size=New-Object Drawing.Size 1040,355;$list.Anchor='Top, Bottom, Left, Right'
    $list.View='Details';$list.FullRowSelect=$true;$list.MultiSelect=$false
    foreach($c in @(@('Mod',230),@('Installed',100),@('Windows release',110),@('Status',165),@('Details',400))){[void]$list.Columns.Add($c[0],[int]$c[1])}
    foreach($row in $Report.Rows){
        $item=New-Object Windows.Forms.ListViewItem([string]$row.Name)
        foreach($value in @($row.Installed,$row.Available,$row.State,$row.Reason)){[void]$item.SubItems.Add([string]$value)}
        [void]$list.Items.Add($item)
    }
    $notice=New-Object Windows.Forms.Label
    $notice.Location=New-Object Drawing.Point 20,493;$notice.Size=New-Object Drawing.Size 1035,45;$notice.Anchor='Bottom, Left, Right'
    $notice.Text='Only the listed available updates will be installed. Pending installs, unsupported files and premium mods stay unchanged. Server-version compatibility still depends on your server.'
    $install=New-Object Windows.Forms.Button
    $install.Text='Download and install updates';$install.Location=New-Object Drawing.Point 20,555;$install.Size=New-Object Drawing.Size 260,35;$install.Anchor='Bottom, Left';$install.Enabled=$true
    if($Report.UpdateCount -gt 0){$install.DialogResult='OK'}
    else{
        $install.Text='Check again';$install.DialogResult='Retry'
        $notice.Text='No installable updates were found. Check again refreshes CurseForge results. Mods marked Update blocked need ARK; unavailable rows explain what could not be checked.'
    }
    $close=New-Object Windows.Forms.Button
    $close.Text='Close';$close.Location=New-Object Drawing.Point 925,555;$close.Size=New-Object Drawing.Size 130,35;$close.Anchor='Bottom, Right';$close.DialogResult='Cancel'
    $dialog.Controls.AddRange(@($summary,$list,$notice,$install,$close));$dialog.AcceptButton=$close;$dialog.CancelButton=$close
    Set-DialogTheme $dialog
    try{return [string]$dialog.ShowDialog($form)}finally{$dialog.Dispose()}
}
