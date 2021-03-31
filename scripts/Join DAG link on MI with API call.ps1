# ====================================================================================
# POWERSHELL SCRIPT FOR MANAGED INSTANCE TO JOIN DAG CREATED ON SQL SERVER
# USER CONFIGURABLE VALUES
# (C) 2021 Managed Instance product group
# ====================================================================================
# Enter your Azure Subscription ID
$SubscriptionID = "<YourSubscriptionID>"
# Enter your Managed Instance name
$ManagedInstanceName = "<YourManagedInstanceName>"
# Enter AG name that was created on the SQL Server
$AGName = "<YourAGName>"
# Enter DAG name that was created on SQL Server
$DAGName = "<YourDAGName>"
# Enter database name that was placed in AG for replciation
$DatabaseName = "<YourDatabaseName>"
# Enter SQL Server IP
$SQLServerIP = "<SQLServerIPaccessibleFromMI>"

# ====================================================================================
# INVOKING THE API CALL -- THIS PART IS NOT USER CONFIGURABLE
# ====================================================================================
# Login to subscription
echo "Logging to Azure subscription"
Login-AzAccount
Select-AzSubscription -SubscriptionName $SubscriptionID
# -----------------------------------
# Build URI for the API call
# -----------------------------------
echo "Building API URI"
$miRG = (Get-AzSqlInstance -InstanceName $ManagedInstanceName).ResourceGroupName
$uriFull = "https://management.azure.com/subscriptions/" + $SubscriptionID + "/resourceGroups/" + $miRG+ "/providers/Microsoft.Sql/managedInstances/" + $ManagedInstanceName + "/hybridLink/" + $DAGName + "?api-version=2020-11-01-preview"
echo $uriFull
# -----------------------------------
# Build API request body
# -----------------------------------
echo "Building API request body"
$bodyFull = @"
{
    "properties":{
        "TargetDatabase":"$DatabaseName",
        "SourceEndpoint":"TCP://$SQLServerIP`:5022",
        "PrimaryAvailabilityGroupName":"$AGName",
        "SecondaryAvailabilityGroupName":"$ManagedInstanceName",
    }
}
"@
echo $bodyFull 

# -----------------------------------
# Get auth token and build the header
# -----------------------------------
$azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
$currentAzureContext = Get-AzContext
$profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azProfile)    
$token = $profileClient.AcquireAccessToken($currentAzureContext.Tenant.TenantId)
$authToken = $token.AccessToken
$headers = @{}
$headers.Add("Authorization", "Bearer "+"$authToken")

# -----------------------------------
# Invoke API call
# -----------------------------------
echo "Invoking API call for Managed Instance to join DAG created on SQL Server."
Invoke-RestMethod -Method PUT -Headers $headers -Uri $uriFull -ContentType "application/json" -Body $bodyFull