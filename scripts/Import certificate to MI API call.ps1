# ====================================================================================
# POWERSHELL SCRIPT TO IMPORT SQL SERVER CERTIFICATE TO MANAGED INSTANCE
# USER CONFIGURABLE VALUES
# (C) 2021 Managed Instance product group
# ====================================================================================
# Enter your Azure Subscription ID
$SubscriptionID = "<YourSubscriptionID>"
# Enter your Managed Instance name
$ManagedInstanceName = "<YourManagedInstanceName>"
# Insert the cert public key blob you got from the SQL Server
$PublicKeyEncoded = "0xYourCertificateFromSQLServer"

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
$uriFull = "https://management.azure.com/subscriptions/" + $SubscriptionID + "/resourceGroups/" + $miRG+ "/providers/Microsoft.Sql/managedInstances/" + $ManagedInstanceName + "/hybridCertificate?api-version=2020-11-01-preview"
echo $uriFull

# -----------------------------------
# Build API request body
# -----------------------------------
echo "Building API request body"
$bodyFull = @"
{           
    "properties":{
         "PublicBlob":"$PublicKeyEncoded"
}}
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
echo "Invoking API call to import SQL Server certificate to Managed Instance."
Invoke-WebRequest -Method POST -Headers $headers -Uri $uriFull -ContentType "application/json" -Body $bodyFull
