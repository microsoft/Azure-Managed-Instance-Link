function Invoke-MiLinkCutover {
    <#
    .SYNOPSIS
    Cmdlet that performs cutover from SQL Server (primary) to SQL managed Instance (secondary)
    
    .DESCRIPTION
    Cmdlet that performs cutover from SQL Server (primary) to SQL managed Instance (secondary)
    Cmdlet can be ran in interactive mode or you can provide all necessary parameters
    Cmdlet supports ShouldProcess, can be dry-ran with -WhatIf parameter
    Cmdlet consists of 4 steps:
        1. switch replication mode to sync
        2. compare lsns
        3. remove the link
        4. remove ags

    .PARAMETER ResourceGroupName
    Resource group name of Managed Instance 
    
    .PARAMETER ManagedInstanceName
    Managed Instance Name
    
    .PARAMETER SqlInstance
    Sql Server name
    
    .PARAMETER DatabaseName
    Database name
    
    .PARAMETER PrimaryAvailabilityGroup
    Primary availability group name
    
    .PARAMETER SecondaryAvailabilityGroup
    Secondary availability group name
    
    .PARAMETER LinkName
    Instance link name
    
    .PARAMETER ManagedInstanceCredential
    Managed Instance Credential
    
    .PARAMETER CleanupPreference
    One of { "KEEP_BOTH", "DELETE_DAG", "DELETE_AG_AND_DAG" }
    Defines actions on SQL Server upon deleting the link
    
    .EXAMPLE
    # Remove-Module Invoke-MiLinkCutover
    # Import-Module 'C:\{pathtoscript}\Invoke-MiLinkCutover.ps1'

    Invoke-MiLinkCutover -ResourceGroupName CustomerExperienceTeam_RG -ManagedInstanceName chimera-ps-cli-v2 `
    -SqlInstance chimera -DatabaseName zz -PrimaryAvailabilityGroup AG_test2 -SecondaryAvailabilityGroup MI_test2 -LinkName DAG_test2  -Verbose 
    
    $cred = Get-Credential
    Invoke-MiLinkCutover -ResourceGroupName CustomerExperienceTeam_RG -ManagedInstanceName chimera-ps-cli-v2 `
    -SqlInstance chimera -DatabaseName zz -PrimaryAvailabilityGroup AG_test2 -SecondaryAvailabilityGroup MI_test2 `
    -LinkName DAG_test2 -ManagedInstanceCredential $cred -CleanupPreference "DELETE_AG_AND_DAG" -Verbose
 
    .NOTES
    General notes
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = "InteractiveParameterSet")]
    param (
        [Parameter(Mandatory = $true,
            ParameterSetName = 'InteractiveParameterSet',
            HelpMessage = 'Enter resource group name')]
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter resource group name')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true,
            ParameterSetName = 'InteractiveParameterSet',
            HelpMessage = 'Enter SQL managed instance name')]
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter SQL managed instance name')]
        [string]$ManagedInstanceName,
        
        [Parameter(Mandatory = $true,
            ParameterSetName = 'InteractiveParameterSet',
            HelpMessage = 'Enter SQL Server name')]
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter SQL Server name')]
        [string]$SqlInstance,

        [Parameter(Mandatory = $true,
            ParameterSetName = 'InteractiveParameterSet',
            HelpMessage = 'Enter target database name')]
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter target database name')]
        [string]$DatabaseName,

        [Parameter(Mandatory = $true,
            ParameterSetName = 'InteractiveParameterSet',
            HelpMessage = 'Enter primary availability group name')]
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter primary availability group name')]
        [string]$PrimaryAvailabilityGroup,

        [Parameter(Mandatory = $true,
            ParameterSetName = 'InteractiveParameterSet',
            HelpMessage = 'Enter primary availability group name')]
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter secondary availability group name')]
        [string]$SecondaryAvailabilityGroup,

        [Parameter(Mandatory = $true,
            ParameterSetName = 'InteractiveParameterSet',
            HelpMessage = 'Enter instance link name')]
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter instance link name')]
        [string]$LinkName,

        # auth params?
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter managed instance credential')]
        [PSCredential]$ManagedInstanceCredential,

        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter cleanup preference')]
        [ValidateSet("KEEP_BOTH", "DELETE_DAG", "DELETE_AG_AND_DAG")]
        [ArgumentCompletions("KEEP_BOTH", "DELETE_DAG", "DELETE_AG_AND_DAG")]
        [String]$CleanupPreference
            
    )
    Begin {
        $interactiveMode = ($PsCmdlet.ParameterSetName -eq "InteractiveParameterSet")
        if ($interactiveMode) {
            $miCredential = Get-Credential -Message "Enter your SQL Managed instance credentials in order to login"
        }
        else {
            $miCredential = $ManagedInstanceCredential
        }
        Write-Verbose "Interactive mode enabled - $interactiveMode"
    }
    Process {
        $ErrorActionPreference = "Stop"

        # should we also do Connect-AzAccount and Set-AzContext?
        $managedInstance = Get-AzSqlInstance -ResourceGroupName $ResourceGroupName -Name $ManagedInstanceName

        # TODO: check if this could be replaced with Set-SqlAvailabilityReplica -AvailabilityMode "SynchronousCommit" -FailoverMode Automatic -Path "Replica02"
        $querySyncModeSQL =
        @"
USE master;
ALTER AVAILABILITY GROUP [$LinkName]
MODIFY
AVAILABILITY GROUP ON
'$PrimaryAvailabilityGroup' WITH
(AVAILABILITY_MODE = SYNCHRONOUS_COMMIT),
'$SecondaryAvailabilityGroup' WITH
(AVAILABILITY_MODE = SYNCHRONOUS_COMMIT);
"@

        if ($PsCmdlet.ShouldProcess("SQL Server and SQL Mi", "Switch link replication mode to SYNC (planned failover)")) {
            Write-Verbose "Switching replication mode to SYNC [started]"
            Invoke-SqlCmd -Query $querySyncModeSQL -ServerInstance $SqlInstance #-Credential $SqlCredential
            Set-AzSqlInstanceLink -InstanceObject $managedInstance -LinkName $LinkName -ReplicationMode "SYNC"
            Write-Verbose "Switching replication mode to SYNC [completed]"
        }
 
        # Compare and ensure manually that LSNs are the same on SQL Server and Managed Instance
        Write-Verbose "Fetching LSN from replicas [started]"
        $queryLSN = 
        @"
SELECT drs.last_hardened_lsn
FROM sys.dm_hadr_database_replica_states drs
WHERE drs.database_id = DB_ID(N'$DatabaseName')
AND drs.is_primary_replica = 1
"@
        $sqlLSN = (Invoke-SqlCmd -Query $queryLSN -ServerInstance $SqlInstance ).last_hardened_lsn #-Credential $SqlCredential
        $miLSN = (Invoke-SqlCmd -Query $queryLSN -ServerInstance $managedInstance.FullyQualifiedDomainName -Credential $miCredential).last_hardened_lsn
        Write-Verbose "Fetching LSN from replicas [completed]"

        if ($sqlLSN -ne $miLSN) {
            Write-Host "LSNs are not equal on primary and secondary. SQL Server lsn is {$sqlLSN}, SQL managed instance lsn is {$miLSN}"
            $flagAllowDataLoss = ($false -or !$interactiveMode)
        }
        else {
            Write-Host "LSNs are equal on primary and secondary. SQL Server lsn is {$sqlLSN}, SQL managed instance lsn is {$miLSN}"    
            $flagAllowDataLoss = $true 
        }
        if ($PsCmdlet.ShouldProcess("SQL Server and SQL Mi", "Removing the link and availability groups")) {
            Write-Verbose "Removing instance link [started]"
            Remove-AzSqlInstanceLink -ResourceGroupName $ResourceGroupName -InstanceName $ManagedInstanceName -LinkName $LinkName -AllowDataLoss:$flagAllowDataLoss
            Write-Verbose "Removing instance link [completed]"

            if ($interactiveMode) {
                if ($PSCmdlet.ShouldContinue("Do you want to remove availability group $primaryAG?", "Link Cutover")) {
                    $CleanupPreference = "DELETE_AG_AND_DAG"
                }
                else {
                    if ($PSCmdlet.ShouldContinue("Do you want to remove distributed availability group $LinkName?", "Link Cutover")) {
                        $CleanupPreference = "DELETE_DAG"
                    }
                }
            }

            if ($CleanupPreference -eq "DELETE_AG_AND_DAG") { 
                Write-Verbose "Dropping availability groups [started]"
                Invoke-SqlCmd -Query "DROP AVAILABILITY GROUP [$LinkName]" -ServerInstance $SqlInstance #-Credential $SqlCredential
                Invoke-SqlCmd -Query "DROP AVAILABILITY GROUP [$PrimaryAvailabilityGroup]" -ServerInstance $SqlInstance #-Credential $SqlCredential
                Write-Verbose "Dropping availability groups [completed]"
                # TODO: check if below cmdlets can be used (path resolving?)
                #Remove-SqlAvailabilityGroup -Path "SQLSERVER:\Sql\Server\$SqlInstance\AvailabilityGroups\$LinkName"
                #Remove-SqlAvailabilityGroup -Path "SQLSERVER:\Sql\Server\$SqlInstance\AvailabilityGroups\$PrimaryAvailabilityGroup"
            }
            elseif ($CleanupPreference = "DELETE_DAG") {
                Write-Verbose "Dropping distributed availability group [started]"
                Invoke-SqlCmd -Query "DROP AVAILABILITY GROUP [$LinkName]" -ServerInstance $SqlInstance #-Credential $SqlCredential
                Write-Verbose "Dropping distributed availability group [completed]"
                #Remove-SqlAvailabilityGroup -Path "SQLSERVER:\Sql\Server\$SqlInstance\AvailabilityGroups\$LinkName"
            }
        }
    }
}