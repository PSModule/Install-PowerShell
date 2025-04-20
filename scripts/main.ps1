#Requires -Modules GitHub

[CmdletBinding()]
param(
    [Parameter()]
    [string] $Subject = $env:<ORG_NAME>_<REPO_NAME>_INPUT_subject
)

begin {
    $scriptName = $MyInvocation.MyCommand.Name
    Write-Debug "[$scriptName] - Start"
}

process {
    try {
        Write-Output "Hello, $Subject!"
    } catch {
        throw $_
    }
}

end {
    Write-Debug "[$scriptName] - End"
}
