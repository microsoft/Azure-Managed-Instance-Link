# Run in Azure Cloud Shell
# =============================================================================
# POWERSHELL SCRIPT FOR CREATING MANAGED INSTANCE LINK
# USER CONFIGURABLE VALUES
# (C) 2021-2022 SQL Managed Instance product group 
# =============================================================================
# Enter your Azure subscription ID
$SubscriptionID = "<SubscriptionID>"
# Enter your managed instance name – for example, "sqlmi1"
$ManagedInstanceName = "<ManagedInstanceName>"
# Enter the availability group name that was created on SQL Server
$AGName = "<AGName>"
# Enter the distributed availability group name that was created on SQL Server
$DAGName = "<DAGName>"
# Enter the database name that was placed in the availability group for replication
$DatabaseName = "<DatabaseName>"
# Enter the SQL Server address
$SQLServerAddress = "<SQLServerAddress>"

# =============================================================================
# INVOKING THE API CALL -- THIS PART IS NOT USER CONFIGURABLE
# =============================================================================
# Log in to the subscription if needed
if ((Get-AzContext ) -eq $null)
{
    echo "Logging to Azure subscription"
    Login-AzAccount
}
Select-AzSubscription -SubscriptionName $SubscriptionID
# -----------------------------------
# Build the URI for the API call
# -----------------------------------
echo "Building API URI"
$miRG = (Get-AzSqlInstance -InstanceName $ManagedInstanceName).ResourceGroupName
$uriFull = "https://management.azure.com/subscriptions/" + $SubscriptionID + "/resourceGroups/" + $miRG+ "/providers/Microsoft.Sql/managedInstances/" + $ManagedInstanceName + "/distributedAvailabilityGroups/" + $DAGName + "?api-version=2021-05-01-preview"
echo $uriFull
# -----------------------------------
# Build the API request body
# -----------------------------------
echo "Buildign API request body"
$bodyFull = @"
{
    "properties":{
        "TargetDatabase":"$DatabaseName",
        "SourceEndpoint":"TCP://$SQLServerAddress`:5022",
        "PrimaryAvailabilityGroupName":"$AGName",
        "SecondaryAvailabilityGroupName":"$ManagedInstanceName",
    }
}
"@
echo $bodyFull 
# -----------------------------------
# Get the authentication token and build the header
# -----------------------------------
$azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
$currentAzureContext = Get-AzContext
$profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azProfile)    
$token = $profileClient.AcquireAccessToken($currentAzureContext.Tenant.TenantId)
$authToken = $token.AccessToken
$headers = @{}
$headers.Add("Authorization", "Bearer "+"$authToken")
# -----------------------------------
# Invoke the API call
# -----------------------------------
echo "Invoking API call to have Managed Instance join DAG on SQL Server"
$response = Invoke-WebRequest -Method PUT -Headers $headers -Uri $uriFull -ContentType "application/json" -Body $bodyFull
echo $response
