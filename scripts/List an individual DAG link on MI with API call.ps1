# ====================================================================================
# POWERSHELL SCRIPT TO VIEW INDIVIDUAL MANAGED INSTANCE LINK STATUS
# USER CONFIGURABLE VALUES
# (C) 2021 Managed Instance product group
# ====================================================================================

# This script is deprecated in favor of Get-AzSqlInstanceLink cmdlet from Az.Sql module
# https://docs.microsoft.com/en-us/powershell/module/az.sql/get-azsqlinstancelink?view=azps-8.0.0

# Enter your Azure Subscription ID
$SubscriptionID = "<YourSubscriptionID>"
# Enter your Managed Instance name - example "sqlmi1"
$ManagedInstanceName = "<YourManagedInstanceName>"
# Enter the DAG link name
$DAGName = "<YourDAGName>"

# ====================================================================================
# INVOKING THE API CALL -- THIS PART IS NOT USER CONFIGURABLE
# ====================================================================================
# Login to subscription if needed
if ((Get-AzContext ) -eq $null)
{
    echo "Logging to Azure subscription"
    Login-AzAccount
}
Select-AzSubscription -SubscriptionName $SubscriptionID
# -----------------------------------
# Build URI for the API call
# -----------------------------------
echo "Building API URI"
$miRG = (Get-AzSqlInstance -InstanceName $ManagedInstanceName).ResourceGroupName
$uriFull = "https://management.azure.com/subscriptions/" + $SubscriptionID + "/resourceGroups/" + $miRG+ "/providers/Microsoft.Sql/managedInstances/" + $ManagedInstanceName + "/distributedAvailabilityGroups/" + $DAGName + "?api-version=2021-05-01-preview"
echo $uriFull
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
echo "Invoking API call to vide individual Managed Instance link status"
$response = Invoke-WebRequest -Method GET -Headers $headers -Uri $uriFull -ContentType "application/json"
echo $response.Content
