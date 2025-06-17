@description('Nome da aplicação a ser criada.')
param name string

@description('Localização onde o recurso será implantado. Padrão: localização do resource group.')
param location string = resourceGroup().location

@description('Timestamp atual em UTC, utilizado para versionamento ou auditoria.')
param currentTime string = utcNow()

@description('Nome da função personalizada (Custom Role) a ser atribuída.')
param customRoleName string

@description('Identidade gerenciada (Managed Identity) será utilizada como registrador da aplicação - Necessita ter função (Role) "Owner"')
param managedIdentity string

@description('Nome único para a atribuição de função, gerado a partir do nome da função, nome do recurso e ID da assinatura.')
param roleAssignmentName string = guid(customRoleName, name, subscription().subscriptionId)

var subscriptionId = subscription().subscriptionId
var roleDefinitionGuid = guid('${subscriptionId}/${customRoleName}')

resource script 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  name: name
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${resourceId(resourceGroup().name, 'Microsoft.ManagedIdentity/userAssignedIdentities', managedIdentity)}': {}
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
      $armEndpoint = "https://management.azure.com"
      $providerUri = "$armEndpoint/subscriptions/$subscriptionId/providers/Microsoft.ContainerInstance/register?api-version=2021-04-01"
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

resource customRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: roleDefinitionGuid
  properties: {
    roleName: customRoleName
    description: 'Permite leitura de recursos e métricas para análise e recomendações.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Compute/virtualMachines/read'
          'Microsoft.Compute/disks/read'
          'Microsoft.Sql/servers/databases/read'
          'Microsoft.Storage/storageAccounts/read'
          'Microsoft.Resources/subscriptions/resourceGroups/read'
          'Microsoft.Resources/subscriptions/resources/read'
        ]
        notActions: []
      }
    ]
    assignableScopes: [
      resourceGroup().id
    ]
  }
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: roleAssignmentName
  properties: {
    roleDefinitionId: customRole.id
    principalId: script.properties.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

output objectId string = script.properties.outputs.objectId
output clientId string = script.properties.outputs.clientId
output clientSecret string = script.properties.outputs.clientSecret
output subscriptionId string = subscription().subscriptionId
