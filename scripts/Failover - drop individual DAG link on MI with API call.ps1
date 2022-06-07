# Run in Azure Cloud Shell
# ====================================================================================
# POWERSHELL SCRIPT TO FAIL OVER AND MIGRATE DATABASE WITH SQL MANAGED INSTANCE LINK
# USER CONFIGURABLE VALUES
# (C) 2021-2022 SQL Managed Instance product group
# ====================================================================================
# Enter your Azure subscription ID
$SubscriptionID = "<SubscriptionID>"
# Enter your managed instance name – for example, "sqlmi1"
$ManagedInstanceName = "<ManagedInstanceName>"
# Enter the distributed availability group link name
$DAGName = "<DAGName>"

# ====================================================================================
# INVOKING THE API CALL -- THIS PART IS NOT USER CONFIGURABLE.
# ====================================================================================
# Log in and select a subscription if needed
if ((Get-AzContext ) -eq $null)
{
    echo "Logging to Azure subscription"
    Login-AzAccount
}
Select-AzSubscription -SubscriptionName $SubscriptionID

# Build a URI for the API call
#
$miRG = (Get-AzSqlInstance -InstanceName $ManagedInstanceName).ResourceGroupName
$uriFull = "https://management.azure.com/subscriptions/" + $SubscriptionID + "/resourceGroups/" + $miRG+ "/providers/Microsoft.Sql/managedInstances/" + $ManagedInstanceName + "/distributedAvailabilityGroups/" + $DAGName + "?api-version=2021-05-01-preview"
echo $uriFull

# Get an authentication token and build the header
#
$azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
$currentAzureContext = Get-AzContext
$profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azProfile)
$token = $profileClient.AcquireAccessToken($currentAzureContext.Tenant.TenantId)
$authToken = $token.AccessToken
$headers = @{}
$headers.Add("Authorization", "Bearer "+"$authToken")

# Invoke the API call
#
Invoke-WebRequest -Method DELETE -Headers $headers -Uri $uriFull -ContentType "application/json"
