$folderpath = "C:\path\to\existing\folder\"
$AllGpos = get-gpo -all
ForEach($g in $AllGpos)
{
    $filename = $g.DisplayName
    $fullpath = join-path -path $folderpath -ChildPath $filename
    $Gpo = Get-GPOReport -reporttype xml -guid $g.Id -path $fullpath

}

get-childitem -path $folderpath | Rename-Item -NewName { $PSItem.Name + ".xml" }