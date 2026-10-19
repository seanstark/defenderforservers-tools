param($Message)
$work = if ($Message -is [string]) {
    ConvertFrom-Json -InputObject $Message -AsHashtable
}
else {
    $Message | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
}
Invoke-MachineSync -Work $work
