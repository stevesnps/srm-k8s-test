<#PSScriptInfo
.VERSION 1.1.0
.GUID b50a27fd-f6dc-4467-881f-7e8faa15f27a
.AUTHOR Synopsys
.DESCRIPTION Starts the SRM Helm Prep Wizard after conditionally helping with module installation.
#>

$unboundArguments = $MyInvocation.UnboundArguments
& "$PSScriptRoot/../../.start.ps1" -startScriptPath 'admin/migrate/.ps/.migrate.ps1' @unboundArguments