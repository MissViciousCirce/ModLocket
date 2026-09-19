# Presentation only. No mod, backup, worker or launch operations live here.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ModLocketWindowTheme {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
    public static void Apply(IntPtr h) {
        try { int dark=1; DwmSetWindowAttribute(h,20,ref dark,4);
            int color=0x00251A20; DwmSetWindowAttribute(h,35,ref color,4);
        } catch (DllNotFoundException) {} catch (EntryPointNotFoundException) {}
    }
}
'@
function New-ThemePath([int]$Width,[int]$Height,[int]$Radius=16) {
    $p=New-Object Drawing.Drawing2D.GraphicsPath
    $d=2*$Radius
    $p.AddArc(1,1,$d,$d,180,90); $p.AddArc(($Width-$d-2),1,$d,$d,270,90)
    $p.AddArc(($Width-$d-2),($Height-$d-2),$d,$d,0,90); $p.AddArc(1,($Height-$d-2),$d,$d,90,90)
    $p.CloseFigure(); return $p
}
function Enable-CardArtwork($Panel) {
    $Panel.Add_Paint({param($sender,$e)
        $e.Graphics.SmoothingMode='AntiAlias'
        $path=New-ThemePath $sender.Width $sender.Height 20
        $brush=New-Object Drawing.Drawing2D.LinearGradientBrush($sender.ClientRectangle,(New-Color '#302841'),(New-Color '#181422'),90.0)
        $pen=New-Object Drawing.Pen((New-Color '#8D79AE'),1.0)
        try {$e.Graphics.FillPath($brush,$path);$e.Graphics.DrawPath($pen,$path)} finally {$brush.Dispose();$pen.Dispose();$path.Dispose()}
    })
}
function Enable-ButtonArtwork($Button) {
    $Button.Add_Paint({param($sender,$e)
        $e.Graphics.SmoothingMode='AntiAlias'
        $base=$sender.BackColor
        if (-not $sender.Enabled) {$base=New-Color '#302938'}
        $light=[Drawing.Color]::FromArgb([Math]::Min(255,$base.R+30),[Math]::Min(255,$base.G+28),[Math]::Min(255,$base.B+32))
        $brush=New-Object Drawing.Drawing2D.LinearGradientBrush($sender.ClientRectangle,$light,$base,90.0)
        $pen=New-Object Drawing.Pen((New-Color '#BCA7D7'),1.2)
        $path=New-ThemePath $sender.Width $sender.Height 15
        try {
            $e.Graphics.FillRectangle($brush,$sender.ClientRectangle); $e.Graphics.DrawPath($pen,$path)
            $fore=if($sender.Enabled){$sender.ForeColor}else{New-Color '#A79AB7'}
            $icon=New-Object Drawing.Pen($fore,2)
            $y=[int]($sender.Height/2)-12
            try {
                if($sender.Text.StartsWith('LAUNCH')){
                    $ink=New-Object Drawing.SolidBrush($fore)
                    try{$e.Graphics.FillPolygon($ink,[Drawing.Point[]]@((New-Object Drawing.Point 24,$y),(New-Object Drawing.Point 24,($y+24)),(New-Object Drawing.Point 43,($y+12))))}finally{$ink.Dispose()}
                }elseif($sender.Text.StartsWith('BACKUP')){
                    $e.Graphics.DrawEllipse($icon,21,$y,24,8)
                    $e.Graphics.DrawLine($icon,21,($y+4),21,($y+23));$e.Graphics.DrawLine($icon,45,($y+4),45,($y+23))
                    $e.Graphics.DrawArc($icon,21,($y+10),24,8,0,180);$e.Graphics.DrawArc($icon,21,($y+19),24,8,0,180)
                }elseif($sender.Text.StartsWith('MY MOD')){
                    $e.Graphics.DrawRectangle($icon,23,$y,20,27)
                    foreach($offset in @(7,13,19)){$e.Graphics.DrawLine($icon,27,($y+$offset),39,($y+$offset))}
                }elseif($sender.Text.StartsWith('MANAGE')){
                    $e.Graphics.DrawRectangle($icon,20,($y+7),28,19);$e.Graphics.DrawRectangle($icon,20,($y+2),13,5)
                }elseif($sender.Text.StartsWith('RESTORE')){
                    # Equal-width icon columns keep the two-line caption centered on the whole button.
                    $sx=$sender.Width/234.0; $sy=$sender.Height/90.0
                    $x=[single](22*$sx); $top=[single]($sender.Height/2.0-12*$sy)
                    $e.Graphics.DrawLine($icon,$x,$top,$x,[single]($top+18*$sy))
                    $e.Graphics.DrawLine($icon,[single]($x-7*$sx),[single]($top+11*$sy),$x,[single]($top+18*$sy))
                    $e.Graphics.DrawLine($icon,[single]($x+7*$sx),[single]($top+11*$sy),$x,[single]($top+18*$sy))
                    $e.Graphics.DrawLine($icon,[single]($x-10*$sx),[single]($top+25*$sy),[single]($x+10*$sx),[single]($top+25*$sy))
                }else{
                    $e.Graphics.DrawEllipse($icon,21,$y,25,25);$e.Graphics.DrawLine($icon,33,($y+4),33,($y+13));$e.Graphics.DrawLine($icon,33,($y+13),40,($y+17))
                }
            } finally {$icon.Dispose()}
            $bounds=New-Object Drawing.Rectangle 54,6,($sender.Width-62),($sender.Height-12)
            $flags=[Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::WordBreak
            if($sender.Text.StartsWith('RESTORE')) {
                $margin=[int](38*$sender.Width/234.0); $inset=[int](8*$sender.Height/90.0)
                $bounds=New-Object Drawing.Rectangle $margin,$inset,($sender.Width-2*$margin),($sender.Height-2*$inset)
                $flags=$flags -bor [Windows.Forms.TextFormatFlags]::NoPadding
            }
            [Windows.Forms.TextRenderer]::DrawText($e.Graphics,$sender.Text,$sender.Font,$bounds,$fore,$flags)
            if($sender.Focused){[Windows.Forms.ControlPaint]::DrawFocusRectangle($e.Graphics,(New-Object Drawing.Rectangle 7,7,($sender.Width-14),($sender.Height-14)),$fore,$base)}
        } finally {$brush.Dispose();$pen.Dispose();$path.Dispose()}
    })
}
function Set-InfoCircleRegion($Control) {
    $path=New-Object Drawing.Drawing2D.GraphicsPath
    try {
        $path.AddEllipse(0,0,($Control.Width-1),($Control.Height-1))
        $previous=$Control.Region
        $Control.Region=New-Object Drawing.Region($path)
        if($previous){$previous.Dispose()}
    } finally {$path.Dispose()}
}
function Enable-InfoArtwork($Button,$ActionButton) {
    # A real circular control keeps mouse/keyboard help accessible without a rectangular patch.
    $Button.Tag=$ActionButton
    Set-InfoCircleRegion $Button
    $Button.Add_Resize({param($sender,$e);Set-InfoCircleRegion $sender})
    $ActionButton.Add_BackColorChanged({$restoreInfo.Invalidate()})
    $Button.Add_MouseEnter({param($sender,$e);$sender.Tag.BackColor=$sender.Tag.Tag.Hover;$sender.Invalidate()})
    $Button.Add_MouseLeave({param($sender,$e);$sender.Tag.BackColor=$sender.Tag.Tag.Normal;$sender.Invalidate()})
    $Button.Add_Enter({param($sender,$e);$sender.Invalidate()})
    $Button.Add_Leave({param($sender,$e);$sender.Invalidate()})
    $Button.Add_Paint({param($sender,$e)
        $g=$e.Graphics; $g.SmoothingMode='AntiAlias'
        $action=$sender.Tag
        $base=if($sender.Enabled){$action.BackColor}else{New-Color '#302938'}
        $light=[Drawing.Color]::FromArgb([Math]::Min(255,$base.R+30),[Math]::Min(255,$base.G+28),[Math]::Min(255,$base.B+32))
        # Use the action's full gradient translated into this sibling's coordinates.
        $gradientBounds=New-Object Drawing.Rectangle ($action.Left-$sender.Left),($action.Top-$sender.Top),$action.Width,$action.Height
        $back=New-Object Drawing.Drawing2D.LinearGradientBrush($gradientBounds,$light,$base,90.0)
        $fore=if($sender.Enabled){$Colors.Text}else{$Colors.Muted}
        $pen=New-Object Drawing.Pen($fore,1.3)
        try {
            $g.FillRectangle($back,$sender.ClientRectangle)
            $g.DrawEllipse($pen,2,2,($sender.Width-5),($sender.Height-5))
            $flags=[Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::NoPadding
            [Windows.Forms.TextRenderer]::DrawText($g,'i',$sender.Font,$sender.ClientRectangle,$fore,$flags)
            if($sender.Focused){
                $pen.DashStyle=[Drawing.Drawing2D.DashStyle]::Dot
                $g.DrawEllipse($pen,4,4,($sender.Width-9),($sender.Height-9))
            }
        } finally {$back.Dispose();$pen.Dispose()}
    })
}
function Enable-LogFrameArtwork($Panel) {
    $Panel.Add_Paint({param($sender,$e)
        $e.Graphics.SmoothingMode='AntiAlias'
        $path=New-ThemePath $sender.Width $sender.Height 16
        $pen=New-Object Drawing.Pen($Colors.Border,3.0)
        try {$e.Graphics.DrawPath($pen,$path)} finally {$pen.Dispose();$path.Dispose()}
    })
}
function Enable-FooterSnakes($Footer) {
    # Keep the supplied transparent image bytes intact; source bounds omit empty canvas.
    $Footer.Tag=[pscustomobject]@{
        SnakeImage=[Drawing.Image]::FromFile((Join-Path $ScriptRoot 'Footer-Snake.png'))
        Source=(New-Object Drawing.Rectangle 209,270,1750,202)
    }
    $Footer.Add_Paint({param($sender,$e)
        $g=$e.Graphics; $g.SmoothingMode='AntiAlias'; $g.InterpolationMode='HighQualityBicubic'
        $scale=[double]$g.DpiX/96.0
        $textSize=[Windows.Forms.TextRenderer]::MeasureText($g,$sender.Text,$sender.Font)
        $side=($sender.ClientSize.Width-$textSize.Width)/2.0
        $gap=16*$scale; $snakeWidth=104*$scale
        if($side -lt ($snakeWidth+3*$gap)){return}
        $snakeHeight=$snakeWidth*$sender.Tag.Source.Height/$sender.Tag.Source.Width
        $y=($sender.ClientSize.Height-$snakeHeight)/2.0
        $left=($side-$snakeWidth)/2.0
        $right=$sender.ClientSize.Width-$left-$snakeWidth
        $pen=New-Object Drawing.Pen($Colors.Purple,[single]$scale)
        try {
            $mid=[single]($sender.ClientSize.Height/2.0)
            foreach($range in @(
                @($gap,($left-8*$scale)),
                @(($left+$snakeWidth+8*$scale),($side-$gap)),
                @(($sender.ClientSize.Width-$side+$gap),($right-8*$scale)),
                @(($right+$snakeWidth+8*$scale),($sender.ClientSize.Width-$gap))
            )) {
                if($range[1] -gt $range[0]){$g.DrawLine($pen,[single]$range[0],$mid,[single]$range[1],$mid)}
            }
            $source=$sender.Tag.Source
            $dest=New-Object Drawing.Rectangle ([int]$left),([int]$y),([int]$snakeWidth),([int]$snakeHeight)
            $g.DrawImage($sender.Tag.SnakeImage,$dest,$source,[Drawing.GraphicsUnit]::Pixel)
            # Mirrored destination points make the second snake face inward, without editing the PNG.
            $points=[Drawing.Point[]]@(
                (New-Object Drawing.Point ([int]($right+$snakeWidth)),([int]$y)),
                (New-Object Drawing.Point ([int]$right),([int]$y)),
                (New-Object Drawing.Point ([int]($right+$snakeWidth)),([int]($y+$snakeHeight)))
            )
            $g.DrawImage($sender.Tag.SnakeImage,$points,$source,[Drawing.GraphicsUnit]::Pixel)
        } finally {$pen.Dispose()}
    })
}
function Set-DialogTheme($Dialog) {
    $Dialog.BackColor=$Colors.CardSoft; $Dialog.ForeColor=$Colors.Text
    $Dialog.Font=New-Object Drawing.Font('Segoe UI',9)
    $Dialog.AutoScaleDimensions=New-Object Drawing.SizeF 96,96
    $Dialog.AutoScaleMode='Dpi'
    $Dialog.ShowInTaskbar=$false
    $Dialog.Add_HandleCreated({param($sender,$e);[ModLocketWindowTheme]::Apply($sender.Handle)})
    $queue=New-Object 'Collections.Generic.Queue[System.Windows.Forms.Control]'
    foreach($control in $Dialog.Controls){$queue.Enqueue($control)}
    while($queue.Count){
        $control=$queue.Dequeue(); $control.ForeColor=$Colors.Text; $control.BackColor=$Colors.CardSoft
        foreach($child in $control.Controls){$queue.Enqueue($child)}
        if($control -is [Windows.Forms.Button]){
            $control.UseVisualStyleBackColor=$false; $control.FlatStyle='Flat'
            $control.FlatAppearance.BorderColor=$Colors.Purple; $control.FlatAppearance.BorderSize=1
            $control.BackColor=$Colors.Lavender; $control.FlatAppearance.MouseOverBackColor=$Colors.PinkHot
            $control.FlatAppearance.MouseDownBackColor=$Colors.Blue
        }
        if($control -is [Windows.Forms.CheckBox]){$control.UseVisualStyleBackColor=$false}
        if($control -is [Windows.Forms.TextBox]){$control.BorderStyle='FixedSingle'}
        if($control -is [Windows.Forms.ListView]){
            $control.BorderStyle='FixedSingle'; $control.OwnerDraw=$true
            $control.Add_DrawColumnHeader({param($sender,$e)
                $brush=New-Object Drawing.SolidBrush($Colors.Lavender)
                try{$e.Graphics.FillRectangle($brush,$e.Bounds)}finally{$brush.Dispose()}
                [Windows.Forms.TextRenderer]::DrawText($e.Graphics,$e.Header.Text,$sender.Font,$e.Bounds,$Colors.Text,([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis))
            })
            $control.Add_DrawItem({param($sender,$e);if($sender.View -ne 'Details'){$e.DrawDefault=$true}})
            $control.Add_DrawSubItem({param($sender,$e)
                $back=if($e.Item.Selected){$Colors.Lavender}else{$Colors.CardSoft}
                $brush=New-Object Drawing.SolidBrush($back)
                try{$e.Graphics.FillRectangle($brush,$e.Bounds)}finally{$brush.Dispose()}
                [Windows.Forms.TextRenderer]::DrawText($e.Graphics,$e.SubItem.Text,$sender.Font,$e.Bounds,$Colors.Text,([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis))
            })
        }
    }
    if($script:UiCheck){
        $Dialog.Add_Shown({param($sender,$e)
            Write-Output ('OPENED | '+$sender.Text)
            $sender.BeginInvoke([Action]{ $sender.DialogResult=[Windows.Forms.DialogResult]::Cancel; $sender.Close() }.GetNewClosure()) | Out-Null
        })
    }
}
function Show-ThemedMessage([string]$Message,[string]$Title,[switch]$Question,$Owner=$form) {
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text=$Title; $dialog.ClientSize=New-Object Drawing.Size 540,255
    $dialog.StartPosition='CenterParent';$dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false
    $label=New-Object Windows.Forms.Label
    $label.Location=New-Object Drawing.Point 22,22;$label.Size=New-Object Drawing.Size 496,166;$label.Text=$Message
    $cancel=New-Object Windows.Forms.Button
    $cancel.Location=New-Object Drawing.Point 250,205;$cancel.Size=New-Object Drawing.Size 126,34
    $cancel.Text=if($Question){'Cancel'}else{'OK'}
    $cancel.DialogResult=if($Question){[Windows.Forms.DialogResult]::No}else{[Windows.Forms.DialogResult]::OK}
    $dialog.Controls.AddRange(@($label,$cancel));$dialog.AcceptButton=$cancel;$dialog.CancelButton=$cancel
    if($Question){
        $confirm=New-Object Windows.Forms.Button
        $confirm.Location=New-Object Drawing.Point 388,205;$confirm.Size=New-Object Drawing.Size 130,34
        $confirm.Text='Continue';$confirm.DialogResult=[Windows.Forms.DialogResult]::Yes;$dialog.Controls.Add($confirm)
    }
    Set-DialogTheme $dialog
    try{if($null-ne$Owner){return $dialog.ShowDialog($Owner)}else{return $dialog.ShowDialog()}}finally{$dialog.Dispose()}
}
function Enable-MoonlitHeader($Header) {
    $Header.BackgroundImage=[Drawing.Image]::FromFile((Join-Path $ScriptRoot 'Moonlit-Header.png'))
    $Header.Add_Paint({param($sender,$e)
        $g=$e.Graphics; $g.SmoothingMode='AntiAlias'; $g.InterpolationMode='HighQualityBicubic'
        $image=$sender.BackgroundImage
        $height=[int]($image.Width*$sender.Height/$sender.Width)
        $source=New-Object Drawing.Rectangle 0,([int]($image.Height*0.10)),$image.Width,$height
        $g.DrawImage($image,$sender.ClientRectangle,$source,[Drawing.GraphicsUnit]::Pixel)
        $path=New-ThemePath $sender.Width $sender.Height 20
        $pen=New-Object Drawing.Pen($Colors.Purple,1.1)
        try{$g.DrawPath($pen,$path)}finally{$path.Dispose();$pen.Dispose()}
    })
}
