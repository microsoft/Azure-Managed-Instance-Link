# Run in Azure Cloud Shell
# ===============================================================================
# POWERSHELL SCRIPT TO IMPORT SQL SERVER CERTIFICATE TO MANAGED INSTANCE
# USER CONFIGURABLE VALUES
# (C) 2021-2022 SQL Managed Instance product group
# ===============================================================================

# This script is deprecated in favor of New-AzSqlInstanceServerTrustCertificate cmdlet from Az.Sql module
# https://docs.microsoft.com/en-us/powershell/module/az.sql/new-azsqlinstanceservertrustcertificate?view=azps-8.0.0

# Enter your Azure subscription ID
$SubscriptionID = "<YourSubscriptionID>"

# Enter your managed instance name – for example, "sqlmi1"
$ManagedInstanceName = "<YourManagedInstanceName>"

# Enter the name for the server trust certificate – for example, "Cert_sqlserver1_endpoint"
$certificateName = "<YourServerTrustCertificateName>"

# Insert the certificate public key blob that you got from SQL Server – for example, "0x1234567..."

$PublicKeyEncoded = "<PublicKeyEncoded>"

# ===============================================================================
# INVOKING THE API CALL -- REST OF THE SCRIPT IS NOT USER CONFIGURABLE
# ===============================================================================
# Log in and select a subscription if needed.
#
if ((Get-AzContext ) -eq $null)
{
    echo "Logging to Azure subscription"
    Login-AzAccount
}
Select-AzSubscription -SubscriptionName $SubscriptionID

# Build the URI for the API call.
#
$miRG = (Get-AzSqlInstance -InstanceName $ManagedInstanceName).ResourceGroupName
$uriFull = "https://management.azure.com/subscriptions/" + $SubscriptionID + "/resourceGroups/" + $miRG+ "/providers/Microsoft.Sql/managedInstances/" + $ManagedInstanceName + "/serverTrustCertificates/" + $certificateName + "?api-version=2021-08-01-preview"
echo $uriFull

# Build the API request body.
#
$bodyFull = "{ `"properties`":{ `"PublicBlob`":`"$PublicKeyEncoded`" } }"

echo $bodyFull 

# Get auth token and build the HTTP request header.
#
$azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
$currentAzureContext = Get-AzContext
$profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azProfile)
$token = $profileClient.AcquireAccessToken($currentAzureContext.Tenant.TenantId)
$authToken = $token.AccessToken
$headers = @{}
$headers.Add("Authorization", "Bearer "+"$authToken")

# Invoke API call
#
Invoke-WebRequest -Method PUT -Headers $headers -Uri $uriFull -ContentType "application/json" -Body $bodyFull
