param name string
param location string = resourceGroup().location
param currentTime string = utcNow()
param customRoleDefinitionUri string

resource script 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  name: name
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${resourceId('app-reg-automation', 'Microsoft.ManagedIdentity/userAssignedIdentities', 'AppRegCreator')}': {}
    }
  }
  properties: {
    azPowerShellVersion: '5.0'
    arguments: '-resourceName "${name}"'
    scriptContent: '''
      param([string] $resourceName)

      $graphToken = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com").Token
      $graphHeaders = @{
        'Authorization' = "Bearer $graphToken"
        'Content-Type'  = 'application/json'
      }

      $armToken = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token
      $armHeaders = @{
        'Authorization' = "Bearer $armToken"
        'Content-Type'  = 'application/json'
      }

      $subscriptionId = (Get-AzContext).Subscription.Id
      $providerUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.ContainerInstance/register?api-version=2021-04-01"
      Write-Host "Registering Microsoft.ContainerInstance provider..."
      $null = Invoke-RestMethod -Method Post -Uri $providerUri -Headers $armHeaders

      $template = @{
        displayName = $resourceName
        requiredResourceAccess = @(
          @{
            resourceAppId = "00000003-0000-0000-c000-000000000000"
            resourceAccess = @(
              @{
                id = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"
                type = "Scope"
              }
            )
          }
        )
        signInAudience = "AzureADMyOrg"
      }

      $app = (Invoke-RestMethod -Method Get -Headers $graphHeaders -Uri "https://graph.microsoft.com/beta/applications?filter=displayName eq '$($resourceName)'").value
      $principal = @{}
      if ($app) {
        $ignore = Invoke-RestMethod -Method Patch -Headers $graphHeaders -Uri "https://graph.microsoft.com/beta/applications/$($app.id)" -Body ($template | ConvertTo-Json -Depth 10)
        $principal = (Invoke-RestMethod -Method Get -Headers $graphHeaders -Uri "https://graph.microsoft.com/beta/servicePrincipals?filter=appId eq '$($app.appId)'").value
      } else {
        $app = (Invoke-RestMethod -Method Post -Headers $graphHeaders -Uri "https://graph.microsoft.com/beta/applications" -Body ($template | ConvertTo-Json -Depth 10))
        $principal = Invoke-RestMethod -Method Post -Headers $graphHeaders -Uri "https://graph.microsoft.com/beta/servicePrincipals" -Body (@{ appId = $app.appId } | ConvertTo-Json)
      }

      $app = (Invoke-RestMethod -Method Get -Headers $graphHeaders -Uri "https://graph.microsoft.com/beta/applications/$($app.id)")

      foreach ($password in $app.passwordCredentials) {
        Write-Host "Deleting secret with id: $($password.keyId)"
        $body = @{ keyId = $password.keyId }
        $null = Invoke-RestMethod -Method Post -Headers $graphHeaders -Uri "https://graph.microsoft.com/beta/applications/$($app.id)/removePassword" -Body ($body | ConvertTo-Json)
      }

      $body = @{
        passwordCredential = @{
          displayName = "Client Secret"
        }
      }
      $secret = (Invoke-RestMethod -Method Post -Headers $graphHeaders -Uri "https://graph.microsoft.com/beta/applications/$($app.id)/addPassword" -Body ($body | ConvertTo-Json)).secretText

      $DeploymentScriptOutputs = @{
        objectId = $app.id
        clientId = $app.appId
        clientSecret = $secret
        principalId = $principal.id
      }
    '''
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
    forceUpdateTag: currentTime
  }
}

resource assignRoleScript 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  name: 'assign-custom-role-to-sp'
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${resourceId('app-reg-automation', 'Microsoft.ManagedIdentity/userAssignedIdentities', 'AppRegCreator')}': {}
    }
  }
  dependsOn: [
    script
  ]
  properties: {
    azPowerShellVersion: '5.0'
    arguments: '''
      -resourceName "${name}" `
      -principalId "${script.properties.outputs.principalId}" `
      -customRoleDefinitionUri "${customRoleDefinitionUri}" `
      -subscriptionId "${subscription().subscriptionId}"
    '''
    scriptContent: '''
      param (
        [string] $resourceName,
        [string] $principalId,
        [string] $customRoleDefinitionUri,
        [string] $subscriptionId
      )

      Write-Host "Downloading custom role definition from $customRoleDefinitionUri"
      $roleDefinitionJson = Invoke-RestMethod -Uri $customRoleDefinitionUri

      $roleDefinitionJson.AssignableScopes = @("/subscriptions/$subscriptionId")

      $existing = az role definition list --name $roleDefinitionJson.Name | ConvertFrom-Json
      if (-not $existing) {
        Write-Host "Creating custom role: $($roleDefinitionJson.Name)"
        $tempPath = "$env:TEMP\\custom-role.json"
        $roleDefinitionJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $tempPath -Encoding utf8
        az role definition create --role-definition $tempPath
      } else {
        Write-Host "Role already exists: $($roleDefinitionJson.Name)"
      }

      Write-Host "Assigning role $($roleDefinitionJson.Name) to $principalId"
      az role assignment create --assignee-object-id $principalId `
                                --role "$($roleDefinitionJson.Name)" `
                                --scope "/subscriptions/$subscriptionId"
    '''
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
    forceUpdateTag: currentTime
  }
}

output objectId string = script.properties.outputs.objectId
output clientId string = script.properties.outputs.clientId
output clientSecret string = script.properties.outputs.clientSecret
output principalId string = script.properties.outputs.principalId
output currentSubscriptionId string = subscription().subscriptionId
