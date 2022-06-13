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
        # SQL Server / Env checks

        $ErrorActionPreference = "Stop" # Don't continue on error

        $interactiveMode = ($PsCmdlet.ParameterSetName -eq "InteractiveParameterSet")
        #if ($interactiveMode) {
        #    $miCredential = Get-Credential -Message "Enter your SQL Managed instance credentials in order to login"
        #}
        #else {
        #    $miCredential = $ManagedInstanceCredential
        #}
        Write-Verbose "Interactive mode enabled - $interactiveMode"

        # Some cmdlets are not supported across all PS versions so we need to know which PS are we using
        Write-Verbose "Check PS [started]"
        $PS7 = [System.Version]"7.0.0.0"
        $PScurrVersion = (Get-Host).version
        if ($PScurrVersion -lt $PS7) {
            throw "PS version not supported. Please run Initialize-MiLinkEnvironment"
        }
        Write-Verbose "Check PS [completed]"

        #  Instance link feature for SQL Managed Instance was introduced in CU15 of SQL Server 2019.
        Write-Verbose "Check SQL Server Version [started]"
        $minVersion = [System.Version]"15.0.4198.2"
        $currVersion = [System.Version] (Invoke-Sqlcmd -query  "SELECT SERVERPROPERTY('ProductVersion') AS BuildNumber" -serverinstance $SqlInstance)[0]
        if ($currVersion -lt $minVersion) {
            throw "SQL Server version not supported. Please run Initialize-MiLinkEnvironment"
        }
        Write-Verbose "Check SQL Server Version [completed]"

        #To make sure that you have the database master key, use the following T-SQL script on SQL Server:
        Write-Verbose "Check database master key [started]"
        $masterKeyResult = Invoke-SqlCmd -query "SELECT * FROM sys.symmetric_keys WHERE name LIKE '%DatabaseMasterKey%'" -ServerInstance $SqlInstance
        if (!$masterKeyResult) {
            throw "Database Master Key is missing. Please run Initialize-MiLinkEnvironment"
        }
        Write-Verbose "Check database master key [completed]"

        #The link feature for SQL Managed Instance relies on the Always On availability groups feature, which isn't enabled by default. To learn more, review Enable the Always On availability groups feature.
        #To confirm that the Always On availability groups feature is enabled:
        Write-Verbose "Check Always On [started]"
        $alwaysOn = Invoke-Sqlcmd -Query "select SERVERPROPERTY('IsHadrEnabled') as IsHadrEnabled" -ServerInstance $SqlInstance
        if ($alwaysOn.IsHadrEnabled -ne 1) {
            throw "AlwaysOn is off. Please run Initialize-MiLinkEnvironment"
        }
        Write-Verbose "Check Always On [completed]"

        Write-Verbose "Get MI info ($ManagedInstanceName) [started]"
        $instance = Get-AzSqlInstance -ResourceGroupName $ResourceGroupName -Name $ManagedInstanceName
        $miFQDN = $instance.FullyQualifiedDomainName       
        Write-Verbose "Get MI info ($ManagedInstanceName) [completed]"

        Write-Verbose "Test connectivity [started]"
        $testSqlMiConn = Test-NetConnection -ComputerName $miFQDN -Port 5022
        if ($testSqlMiConn.TcpTestSucceeded -eq $False) {
            throw "Can't establish TCP connection to specified MI. Please run Initialize-MiLinkEnvironment"
        }
        Write-Verbose "Test connectivity [completed]"

        # Import Microsoft & Digicert PKI root-authority certificate (trusted by Azure), if not exist"
        Write-Verbose "Import Microsoft PKI root-authority certificate (trusted by Azure) [started]"
        Write-Verbose "Import DigiCert PKI root-authority certificate (trusted by Azure) [started]"
        $microsoftPKIcertificateBytes = "0x308205A830820390A00302010202101ED397095FD8B4B347701EAABE7F45B3300D06092A864886F70D01010C05003065310B3009060355040613025553311E301C060355040A13154D6963726F736F667420436F72706F726174696F6E313630340603550403132D4D6963726F736F66742052534120526F6F7420436572746966696361746520417574686F726974792032303137301E170D3139313231383232353132325A170D3432303731383233303032335A3065310B3009060355040613025553311E301C060355040A13154D6963726F736F667420436F72706F726174696F6E313630340603550403132D4D6963726F736F66742052534120526F6F7420436572746966696361746520417574686F72697479203230313730820222300D06092A864886F70D01010105000382020F003082020A0282020100CA5BBE94338C299591160A95BD4762C189F39936DF4690C9A5ED786A6F479168F8276750331DA1A6FBE0E543A3840257015D9C4840825310BCBFC73B6890B6822DE5F465D0CC6D19CC95F97BAC4A94AD0EDE4B431D8707921390808364353904FCE5E96CB3B61F50943865505C1746B9B685B51CB517E8D6459DD8B226B0CAC4704AAE60A4DDB3D9ECFC3BD55772BC3FC8C9B2DE4B6BF8236C03C005BD95C7CD733B668064E31AAC2EF94705F206B69B73F578335BC7A1FB272AA1B49A918C91D33A823E7640B4CD52615170283FC5C55AF2C98C49BB145B4DC8FF674D4C1296ADF5FE78A89787D7FD5E2080DCA14B22FBD489ADBACE479747557B8F45C8672884951C6830EFEF49E0357B64E798B094DA4D853B3E55C428AF57F39E13DB46279F1EA25E4483A4A5CAD513B34B3FC4E3C2E68661A45230B97A204F6F0F3853CB330C132B8FD69ABD2AC82DB11C7D4B51CA47D14827725D87EBD545E648659DAF5290BA5BA2186557129F68B9D4156B94C4692298F433E0EDF9518E4150C9344F7690ACFC38C1D8E17BB9E3E394E14669CB0E0A506B13BAAC0F375AB712B590811E56AE572286D9C9D2D1D751E3AB3BC655FD1E0ED3740AD1DAAAEA69B897288F48C407F852433AF4CA55352CB0A66AC09CF9F281E1126AC045D967B3CEFF23A2890A54D414B92AA8D7ECF9ABCD255832798F905B9839C40806C1AC7F0E3D00A50203010001A3543052300E0603551D0F0101FF040403020186300F0603551D130101FF040530030101FF301D0603551D0E0416041409CB597F86B2708F1AC339E3C0D9E9BFBB4DB223301006092B06010401823715010403020100300D06092A864886F70D01010C05000382020100ACAF3E5DC21196898EA3E792D69715B813A2A6422E02CD16055927CA20E8BAB8E81AEC4DA89756AE6543B18F009B52CD55CD53396D624C8B0D5B7C2E44BF83108FF3538280C34F3AC76E113FE6E3169184FB6D847F3474AD89A7CEB9D7D79F846492BE95A1AD095333DDEE0AEA4A518E6F55ABBAB59446AE8C7FD8A2502565608046DB3304AE6CB598745425DC93E4F8E355153DB86DC30AA412C169856EDF64F15399E14A75209D950FE4D6DC03F15918E84789B2575A94B6A9D8172B1749E576CBC156993A37B1FF692C919193E1DF4CA337764DA19FF86D1E1DD3FAECFBF4451D136DCFF759E52227722B86F357BB30ED244DDC7D56BBA3B3F8347989C1E0F20261F7A6FC0FBB1C170BAE41D97CBD27A3FD2E3AD19394B1731D248BAF5B2089ADB7676679F53AC6A69633FE5392C846B11191C6997F8FC9D66631204110872D0CD6C1AF3498CA6483FB1357D1C1F03C7A8CA5C1FD9521A071C193677112EA8F880A691964992356FBAC2A2E70BE66C40C84EFE58BF39301F86A9093674BB268A3B5628FE93F8C7A3B5E0FE78CB8C67CEF37FD74E2C84F3372E194396DBD12AFBE0C4E707C1B6F8DB332937344166DE8F4F7E095808F965D38A4F4ABDE0A308793D84D00716245274B3A42845B7F65B76734522D9C166BAAA8D87BA3424C71C70CCA3E83E4A6EFB701305E51A379F57069A641440F86B02C91C63DEAAE0F84";
        $queryCertCreate = 
        @"
CREATE CERTIFICATE [MicrosoftPKI] FROM BINARY = $microsoftPKIcertificateBytes
"@
        $queryCertAddIssuer = 
        @"
DECLARE @CERTID int
SELECT @CERTID = CERT_ID('MicrosoftPKI')
EXEC sp_certificate_add_issuer @CERTID, N'*.database.windows.net'
GO
"@
        $microsoftDigiCertCertificateBytes = "0x3082038E30820276A0030201020210033AF1E6A711A9A0BB2864B11D09FAE5300D06092A864886F70D01010B05003061310B300906035504061302555331153013060355040A130C446967694365727420496E6331193017060355040B13107777772E64696769636572742E636F6D3120301E06035504031317446967694365727420476C6F62616C20526F6F74204732301E170D3133303830313132303030305A170D3338303131353132303030305A3061310B300906035504061302555331153013060355040A130C446967694365727420496E6331193017060355040B13107777772E64696769636572742E636F6D3120301E06035504031317446967694365727420476C6F62616C20526F6F7420473230820122300D06092A864886F70D01010105000382010F003082010A0282010100BB37CD34DC7B6BC9B26890AD4A75FF46BA210A088DF51954C9FB88DBF3AEF23A89913C7AE6AB061A6BCFAC2DE85E092444BA629A7ED6A3A87EE054752005AC50B79C631A6C30DCDA1F19B1D71EDEFDD7E0CB948337AEEC1F434EDD7B2CD2BD2EA52FE4A9B8AD3AD499A4B625E99B6B00609260FF4F214918F76790AB61069C8FF2BAE9B4E992326BB5F357E85D1BCD8C1DAB95049549F3352D96E3496DDD77E3FB494BB4AC5507A98F95B3B423BB4C6D45F0F6A9B29530B4FD4C558C274A57147C829DCD7392D3164A060C8C50D18F1E09BE17A1E621CAFD83E510BC83A50AC46728F67314143D4676C387148921344DAF0F450CA649A1BABB9CC5B1338329850203010001A3423040300F0603551D130101FF040530030101FF300E0603551D0F0101FF040403020186301D0603551D0E041604144E2254201895E6E36EE60FFAFAB912ED06178F39300D06092A864886F70D01010B05000382010100606728946F0E4863EB31DDEA6718D5897D3CC58B4A7FE9BEDB2B17DFB05F73772A3213398167428423F2456735EC88BFF88FB0610C34A4AE204C84C6DBF835E176D9DFA642BBC74408867F3674245ADA6C0D145935BDF249DDB61FC9B30D472A3D992FBB5CBBB5D420E1995F534615DB689BF0F330D53E31E28D849EE38ADADA963E3513A55FF0F970507047411157194EC08FAE06C49513172F1B259F75F2B18E99A16F13B14171FE882AC84F102055D7F31445E5E044F4EA879532930EFE5346FA2C9DFF8B22B94BD90945A4DEA4B89A58DD1B7D529F8E59438881A49E26D56FADDD0DC6377DED03921BE5775F76EE3C8DC45D565BA2D9666EB33537E532B6";
        $queryDigiCertCreate = 
        @"
CREATE CERTIFICATE [DigiCertPKI] FROM BINARY = $microsoftDigiCertCertificateBytes
"@
        $queryDigiCertAddIssuer = 
        @"
DECLARE @CERTID int
SELECT @CERTID = CERT_ID('DigiCertPKI')
EXEC sp_certificate_add_issuer @CERTID, N'*.database.windows.net'
GO
"@
        $certCmds = @(
            { Invoke-Sqlcmd -query $using:queryCertCreate -ServerInstance $SqlInstance },
            { Invoke-Sqlcmd -query $using:queryCertAddIssuer -ServerInstance $SqlInstance },
            { Invoke-Sqlcmd -query $using:queryDigiCertCreate -ServerInstance $SqlInstance },
            { Invoke-Sqlcmd -query $using:queryDigiCertAddIssuer -ServerInstance $SqlInstance }
        )
        $temp_guid = New-Guid
        foreach ($certCmd in $certCmds) {
            start-job $certCmd -Name "ChimeraSetupCertificateCmds_$temp_guid"
        }
        # Errors to ignore (happens if we already added these certs to the server)
        $errsToIgnore = @("A certificate with name 'MicrosoftPKI' already exists or this certificate already has been added to the database.",
            "The certificate 'MicrosoftPKI' has been already added as a trusted issuer for DNS name '*.database.windows.net'",
            "A certificate with name 'DigiCertPKI' already exists or this certificate already has been added to the database.",
            "The certificate 'DigiCertPKI' has been already added as a trusted issuer for DNS name '*.database.windows.net'")
        foreach ($jobId in (Get-Job -Name "ChimeraSetupCertificateCmds_$temp_guid" -HasMoreData:$true).Id) {
            try {
                Receive-Job -Id $jobId -ErrorAction Stop
            }
            catch {
                $ex = $_
                if ($ex -match ($errsToIgnore -join '|')) {
                    Write-Verbose $ex
                }
                else {
                    throw $ex 
                }
            }
        }
        Write-Verbose "Import Microsoft PKI root-authority certificate (trusted by Azure) [completed]"
        Write-Verbose "Import DigiCert PKI root-authority certificate (trusted by Azure) [completed]"

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
            $queryCreateCertificate = "CREATE CERTIFICATE $boxCertName WITH SUBJECT = N'$boxCertSubject', EXPIRY_DATE = N'$((get-date).AddYears(10).ToString("dd/MM/yyyy"))';"
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
