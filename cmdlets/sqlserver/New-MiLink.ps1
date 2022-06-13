#Requires -Modules SqlServer, Az.Sql

function New-MiLink {
    <#
    .SYNOPSIS
    Cmdlet that creates a new instance link between SQL Server (primary) and SQL managed instance (secondary)
    
    .DESCRIPTION
    Cmdlet that creates a new instance link between SQL Server (primary) and SQL managed instance (secondary)

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
    
    .EXAMPLE
    # Remove-Module New-MiLink
    # Import-Module 'C:\{pathtoscript}\New-MiLink.ps1'

    New-MiLink -ResourceGroupName CustomerExperienceTeam_RG -ManagedInstanceName chimera-ps-cli-v2 `
    -SqlInstance chimera -DatabaseName zz -PrimaryAvailabilityGroup AG_test2 -SecondaryAvailabilityGroup MI_test2 -LinkName DAG_test2  -Verbose 

 
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
        [string]$LinkName

        # auth params?
        
            
    )
    Begin {

        $interactiveMode = ($PsCmdlet.ParameterSetName -eq "InteractiveParameterSet")
        #if ($interactiveMode) {
        #    $miCredential = Get-Credential -Message "Enter your SQL Managed instance credentials in order to login"
        #}
        #else {
        #    $miCredential = $ManagedInstanceCredential
        #}
        Write-Verbose "Interactive mode enabled - $interactiveMode"
    }
    Process {
        $ErrorActionPreference = "Stop"

        # All databases that will be replicated via the link must be in full recovery mode and have at least one backup. 
        # Recovery model selected: 1 = FULL, 2 = BULK_LOGGED, 3 = SIMPLE
        $queryGetRecoveryModel = "select recovery_model from sys.databases where name = N'$DatabaseName'"
        $recoveryModel = Invoke-SqlCmd -Query $queryGetRecoveryModel -ServerInstance $SqlInstance
        if ($recoveryModel -ne 1) {
            Write-Verbose "Set recovery model to FULL for database $DatabaseName [started]"
            Invoke-SqlCmd -Query "ALTER DATABASE [$DatabaseName] SET RECOVERY FULL" -ServerInstance $SqlInstance       
            Write-Verbose "Set recovery model to FULL for database $DatabaseName [completed]"
        }

        $backupHistory = Get-SqlBackupHistory -ServerInstance $SqlInstance -DatabaseName $DatabaseName
        if (!$backupHistory) {
            $backupDiskPath = Read-Host -Prompt "Creating database backup, enter path"
            Write-Verbose "Execute backup for all databases you want to replicate [started]"
            Invoke-SqlCmd -Query "BACKUP DATABASE [$DatabaseName] TO DISK = N'$backupDiskPath'" -ServerInstance $SqlInstance
            Write-Verbose "Execute backup for all databases you want to replicate [completed]"
            Get-SqlBackupHistory -ServerInstance $SqlInstance -DatabaseName $DatabaseName
        }

        Write-Verbose "Get MI info ($ManagedInstanceName) [started]"
        $instance = Get-AzSqlInstance -ResourceGroupName $ResourceGroupName -Name $ManagedInstanceName
        $miFQDN = $instance.FullyQualifiedDomainName       
        $SqlMiInstanceConnectionString = "tcp://${miFQDN}:5022;Server=[$ManagedInstanceName]"
        Write-Verbose "Get MI info ($ManagedInstanceName) [completed]"

        # Figure out if we're on a VM https://docs.microsoft.com/en-us/azure/virtual-machines/windows/instance-metadata-service?tabs=windows#example-scenarios-for-usage
        Write-Verbose "Get VM info [started]"
        $vmMetadata = Invoke-RestMethod -Headers @{"Metadata" = "true" } -Method GET -NoProxy -Uri "http://169.254.169.254/metadata/instance?api-version=2021-02-01" 
        if (!$vmMetadata) {
            throw "This cmdlet doesn't yet support creating Instance Link from outside Azure VM"
        }
        $vmName = $vmMetadata.psobject.properties['compute'].value.name
        $vmRgName = $vmMetadata.psobject.properties['compute'].value.resourceGroupName
        $vm = Get-AzVm -ResourceGroupName $vmRgName -Name $vmName
        $nic = $vm.NetworkProfile.NetworkInterfaces[0] # TODO we can have more?
        $networkinterface = ($nic.id -split '/')[-1]
        $nicdetails = Get-AzNetworkInterface -Name $networkinterface
        # Grab the private ip of the server
        $srcIP = $nicdetails.IpConfigurations[0].PrivateIpAddress
        $sourceEndpoint = "tcp://${srcip}:5022"
        Write-Verbose "Get VM info [completed]"

        # TODO:
        # check if managed instance has <100 DBs
        # Check if MI has enough storage

        # TODO: If we don't have DBM endpoint, we have to create it
        # we can either create a new certificate for that purpose, or pick an existing one if it meets certain conditions such as:
        # - "select pvt_key_encryption_type from sys.certificates where name = N'$boxCertName'" must be MK
        # TODO: can we trust sp_get_endpoint_certificate ?
        Write-Verbose "Validate DBM endpoint certificate [started]"
        $dbmCert = Invoke-Sqlcmd -Query "exec sp_get_endpoint_certificate @endpoint_type = 4" -ServerInstance $SqlInstance -OutputSqlErrors:$false
        if (!$dbmCert) {
            $boxCertName = Read-Host "Creating a new certificate for DBM Endpoint. Enter cert name: "
            $boxCertSubject = Read-Host "Enter cert subject: "
            $queryCreateCertificate = "CREATE CERTIFICATE $boxCertName WITH SUBJECT = N'$boxCertSubject', EXPIRY_DATE = N'12/12/2030';"
            Invoke-SqlCmd -Query $queryCreateCertificate -ServerInstance $SqlInstance
        }
        Write-Verbose "Validate DBM endpoint certificate [completed]"
        # Check if theres a DBM endpoint, whose cert is signed with MK
        Write-Verbose "Validate DBM endpoint [started]"
        $queryGetEndpointDBM = "select * from sys.endpoints where type = 4" 
        $endpointDBM = Invoke-Sqlcmd -Query $queryGetEndpointDBM -ServerInstance $SqlInstance
        if (!$endpointDBM) {
            $queryCreateEndpointDBM =
            @"
CREATE ENDPOINT dbm_endpoint
STATE=STARTED
AS TCP (LISTENER_PORT=5022, LISTENER_IP = ALL)
FOR DATABASE_MIRRORING (
ROLE=ALL,
AUTHENTICATION = CERTIFICATE $boxCertName,
ENCRYPTION = REQUIRED ALGORITHM AES)
"@
            Invoke-SqlCmd -Query $queryCreateEndpointDBM -ServerInstance $SqlInstance
        }
        Write-Verbose "Validate DBM endpoint certificate [completed]"
        $dbmCert = Invoke-Sqlcmd -Query "exec sp_get_endpoint_certificate @endpoint_type = 4" -ServerInstance $SqlInstance

        # Fetch the public key of the authentication certificate from Managed Instance and import it to SQL Server
        Write-Verbose "Import MI DBM endpoint certificate into SQL Server [started]"
        $instanceDBMCertificate = $instance | Get-AzSqlInstanceEndpointCertificate -Name "DATABASE_MIRRORING"
        $instanceDBMCertificatePublicKey = $instanceDBMCertificate.PublicKey
        $queryInstanceDBMCertificateImport = "CREATE CERTIFICATE [$miFQDN] FROM BINARY = $instanceDBMCertificatePublicKey"
        $miCertInSqlServer = Invoke-Sqlcmd -Query "Select * from sys.certificates where name = N'$miFQDN'"
        if (!$miCertInSqlServer) {
            Invoke-Sqlcmd -query $queryInstanceDBMCertificateImport -ServerInstance $SqlInstance
        }
        Write-Verbose "Import MI DBM endpoint certificate into SQL Server [completed]"
        # TODO: should we also check for expiration date etc? Or publickey Mismatch? or any other case for which we'd wanna clean up?
        #Invoke-Sqlcmd -query "DROP CERTIFICATE [$miFQDN]" -ServerInstance $SqlInstance  
        #Invoke-Sqlcmd -query $queryInstanceDBMCertificateImport -ServerInstance $SqlInstance

        # Fetch the public key of SQL Server authentication certificate (outputs a binary key)
        Write-Verbose "Export SQL server DBM endpoint certificate to MI [started]"
        $serverTrustCertificatePK = $dbmCert.EndpointCertificatePublicKey
        $hexCert = [System.Text.StringBuilder]::new($serverTrustCertificatePK.Length * 2)
        foreach ($byte in $serverTrustCertificatePK) {
            $hexCert.AppendFormat("{0:x2}", $byte) | Out-Null
        }
        $dbmCert = "0x" + ($hexCert.ToString())
        # we should be able to use sp_get_endpoint_cert where type=4 to get the cert we need to push to MI ($dbmCert)
        # import the public key of authentication certificate from SQL Server to Managed Instance
        $boxCertName = $boxCertName ? $boxCertName : "DBM_Certificate_${SqlInstance}" # this naming is pretty random, TODO: come up with something better
        $miServerTrustCerts = $instance | Get-AzSqlInstanceServerTrustCertificate
        [Func[object, bool]] $delegate = { param($c); return ($c.Name -eq $boxCertName) -or ($dbmCert -match $c.PublicKey) }
        $matchedCert = [Linq.Enumerable]::Where($miServerTrustCerts, $delegate)
        if (!$matchedCert) {
            New-AzSqlInstanceServerTrustCertificate -InstanceObject $instance -CertificateName $boxCertName -PublicKey $dbmCert
        }
        Write-Verbose "Export SQL server DBM endpoint certificate to MI [completed]"

        #
        Write-Verbose "Create availability groups [started]"
        $queryAG =
        @"
CREATE AVAILABILITY GROUP [$PrimaryAvailabilityGroup]
WITH (CLUSTER_TYPE = NONE)
FOR DATABASE [$DatabaseName]
REPLICA ON N'$SqlInstance' WITH (ENDPOINT_URL = N'$sourceEndpoint', FAILOVER_MODE = MANUAL, AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, SEEDING_MODE = AUTOMATIC, SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL));
"@
        Invoke-Sqlcmd -query $queryAG -ServerInstance $SqlInstance

        # do we need this ?
        $queryPrimaryAGAlter = "ALTER AVAILABILITY GROUP $PrimaryAvailabilityGroup GRANT CREATE ANY DATABASE"
        Invoke-Sqlcmd -query $queryPrimaryAGAlter -ServerInstance $SqlInstance

        $queryDAG =
        @"
CREATE AVAILABILITY GROUP [$LinkName]
WITH (DISTRIBUTED)
AVAILABILITY GROUP ON
N'$PrimaryAvailabilityGroup' WITH (LISTENER_URL = N'$sourceEndpoint', AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = AUTOMATIC),
N'$SecondaryAvailabilityGroup' WITH (LISTENER_URL = N'$SqlMiInstanceConnectionString', AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = AUTOMATIC);
"@
        Invoke-Sqlcmd -query $queryDAG -ServerInstance $SqlInstance
        Write-Verbose "Create availability groups [completed]"

        # join the distributed Availability Group on SQL Server
        Write-Verbose "Create mi link [started]"
        $newLinkJob = New-AzSqlInstanceLink -InstanceObject $instance -Name $LinkName -PrimaryAvailabilityGroupName $PrimaryAvailabilityGroup `
            -SecondaryAvailabilityGroupName $SecondaryAvailabilityGroup -TargetDatabase $DatabaseName -SourceEndpoint $sourceEndpoint -AsJob


        $queryMonitor1 =
        @"
SELECT
ag.local_database_name AS 'Local database name',
ar.current_state AS 'Current state',
ar.is_source AS 'Is source',
ag.internal_state_desc AS 'Internal state desc',
ag.database_size_bytes / 1024 / 1024 AS 'Database size MB',
ag.transferred_size_bytes / 1024 / 1024 AS 'Transferred MB',
ag.transfer_rate_bytes_per_second / 1024 / 1024 AS 'Transfer rate MB/s',
ag.total_disk_io_wait_time_ms / 1000 AS 'Total Disk IO wait (sec)',
ag.total_network_wait_time_ms / 1000 AS 'Total Network wait (sec)',
ag.is_compression_enabled AS 'Compression',
ag.start_time_utc AS 'Start time UTC',
ag.estimate_time_complete_utc as 'Estimated time complete UTC',
ar.completion_time AS 'Completion time',
ar.number_of_attempts AS 'Attempt No'
FROM sys.dm_hadr_physical_seeding_stats AS ag
INNER JOIN sys.dm_hadr_automatic_seeding AS ar
ON local_physical_seeding_id = operation_id
"@

        $queryMonitor2 = 
        @"
SELECT DISTINCT CONVERT(VARCHAR(8), DATEADD(SECOND, DATEDIFF(SECOND, start_time_utc, estimate_time_complete_utc) ,0), 108) as 'Estimated complete time'
FROM sys.dm_hadr_physical_seeding_stats
"@

        $tries = 0
        Get-Job -Id $newLinkJob.Id | Tee-Object -Variable getJobLink
        while (($getJobLink.State -eq "Running") -and ($tries -le 7)) {
            Write-Verbose "Checking if link creation is completed, try #$tries"
            Start-Sleep -Seconds 7
            $tries = $tries + 1
            Invoke-Sqlcmd -query $queryMonitor1 -ServerInstance $SqlInstance
            Invoke-Sqlcmd -query $queryMonitor2 -ServerInstance $SqlInstance
            Get-Job -Id $newLinkJob.Id | Tee-Object -Variable getJobLink
            try {
                Get-AzSqlInstanceLink -InstanceObject $instance -Name $LinkName | Tee-Object -Variable getLinkResp
                if ($getLinkResp -and ($getLinkResp.LinkState -eq "Catchup")) {
                    break
                }
                
            }
            catch {
                Write-Verbose $_
            }
        }
        if ($tries -ge 7) {
            Write-Host "Script finishing, instance link not yet fully established. Use following commands and TSQL for monitoring:"
            Write-Host 'Get-AzSqlInstanceLink -InstanceObject $instance -Name $LinkName'
            Write-Host "$queryMonitor1"
            Write-Host "$queryMonitor2"
            Write-Host "Get-Job -Id $($newLinkJob.Id) | Receve-Job "
        }
        else {   
            Write-Verbose "Create mi link [completed]"
            Receive-Job -Id $newLinkJob.Id
            Get-AzSqlInstanceLink -InstanceObject $instance -Name $LinkName
        
        }
    }

}
