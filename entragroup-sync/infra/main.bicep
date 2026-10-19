targetScope = 'resourceGroup'

@minLength(3)
@maxLength(18)
@description('Lowercase letters, digits, and hyphens. Names must be globally unique where applicable.')
param namePrefix string
param location string = resourceGroup().location
param tenantId string = tenant().tenantId
param subscriptionIds array = []
param managementGroupIds array = []
param resourceGroupNames array = []
param targetGroupId string = ''
param windowsTargetGroupId string = ''
param linuxTargetGroupId string = ''
param reportClientId string
@secure()
param reportClientSecret string
@allowed(['Audit', 'Enforce'])
param syncMode string = 'Audit'
param schedule string = '0 */30 * * * *'
@minValue(1)
@maxValue(168)
param freshnessHours int = 24
@allowed(['B1', 'S1', 'P1v3'])
param planSku string = 'B1'
@description('Existing action groups for operational notifications. Empty means alerts have no notification recipients.')
param alertActionGroupIds array = []

var suffix = uniqueString(resourceGroup().id, namePrefix)
var workerName = '${namePrefix}-worker-${take(suffix, 6)}'
var reportName = '${namePrefix}-report-${take(suffix, 6)}'
var blobOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var queueContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var tableContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var tableReader = '76199698-9eea-4c19-bc75-cec21354c6b6'
var busSender = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
var busReceiver = '4f6c5d74-cffc-4f8c-9ac7-9c1edb143e51'
var hostRoles = [blobOwner, queueContributor, tableContributor]

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${namePrefix}-plan'
  location: location
  sku: {
    name: planSku
    tier: planSku == 'B1' ? 'Basic' : (planSku == 'S1' ? 'Standard' : 'PremiumV3')
    capacity: 1
  }
  properties: {
    reserved: false
  }
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-logs'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-insights'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'sync${suffix}'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
  }
}
resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storage
  name: 'default'
}
resource machines 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: 'machines'
}

resource hosts 'Microsoft.Storage/storageAccounts@2023-05-01' = [for kind in ['worker', 'report']: {
  name: '${kind}${suffix}'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
  }
}]

resource bus 'Microsoft.ServiceBus/namespaces@2024-01-01' = {
  name: '${namePrefix}-bus-${take(suffix, 6)}'
  location: location
  sku: { name: 'Standard', tier: 'Standard' }
  properties: {
    minimumTlsVersion: '1.2'
    disableLocalAuth: true
  }
}
resource queue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: bus
  name: 'machines'
  properties: {
    lockDuration: 'PT5M'
    maxDeliveryCount: 10
    defaultMessageTimeToLive: 'P7D'
    deadLetteringOnMessageExpiration: true
    enablePartitioning: false
  }
}

resource apps 'Microsoft.Web/sites@2023-12-01' = [for (kind, i) in ['worker', 'report']: {
  name: i == 0 ? workerName : reportName
  location: location
  kind: 'functionapp'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      alwaysOn: true
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ftpsState: 'Disabled'
      powerShellVersion: '7.4'
      use32BitWorkerProcess: false
      appSettings: concat([
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'powershell' }
        { name: 'FUNCTIONS_WORKER_RUNTIME_VERSION', value: '7.4' }
        { name: 'AzureWebJobsStorage__accountName', value: hosts[i].name }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
        { name: 'SYNC_STORAGE_ACCOUNT', value: storage.name }
        { name: 'SYNC_TENANT_ID', value: tenantId }
        { name: 'SYNC_WORKER_FUNCTION_RESOURCE_ID', value: subscriptionResourceId('Microsoft.Web/sites', workerName) }
      ], i == 0 ? [
        { name: 'SYNC_SUBSCRIPTION_IDS', value: join(subscriptionIds, ',') }
        { name: 'SYNC_MANAGEMENT_GROUP_IDS', value: join(managementGroupIds, ',') }
        { name: 'SYNC_RESOURCE_GROUP_NAMES', value: join(resourceGroupNames, ',') }
        { name: 'SYNC_GROUP_ID', value: targetGroupId }
        { name: 'SYNC_WINDOWS_GROUP_ID', value: empty(windowsTargetGroupId) ? targetGroupId : windowsTargetGroupId }
        { name: 'SYNC_LINUX_GROUP_ID', value: empty(linuxTargetGroupId) ? targetGroupId : linuxTargetGroupId }
        { name: 'SYNC_MODE', value: syncMode }
        { name: 'SYNC_FRESHNESS_HOURS', value: string(freshnessHours) }
        { name: 'SYNC_SCHEDULE', value: schedule }
        { name: 'ServiceBusConnection__fullyQualifiedNamespace', value: '${bus.name}.servicebus.windows.net' }
        { name: 'ServiceBusConnection__credential', value: 'managedidentity' }
      ] : [
        { name: 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET', value: reportClientSecret }
      ])
    }
  }
}]

resource workerHostRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in hostRoles: {
  name: guid(hosts[0].id, apps[0].id, role)
  scope: hosts[0]
  properties: {
    principalId: apps[0].identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
  }
}]
resource reportHostRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in hostRoles: {
  name: guid(hosts[1].id, apps[1].id, role)
  scope: hosts[1]
  properties: {
    principalId: apps[1].identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
  }
}]
resource dataWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, apps[0].id, tableContributor)
  scope: storage
  properties: {
    principalId: apps[0].identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', tableContributor)
  }
}
resource dataReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, apps[1].id, tableReader)
  scope: storage
  properties: {
    principalId: apps[1].identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', tableReader)
  }
}
resource sendRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(queue.id, apps[0].id, busSender)
  scope: queue
  properties: {
    principalId: apps[0].identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', busSender)
  }
}
resource receiveRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(queue.id, apps[0].id, busReceiver)
  scope: queue
  properties: {
    principalId: apps[0].identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', busReceiver)
  }
}

resource reportAuth 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: apps[1]
  name: 'authsettingsV2'
  properties: {
    platform: { enabled: true, runtimeVersion: '~1' }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: reportClientId
          clientSecretSettingName: 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [reportClientId, 'api://${reportClientId}']
        }
      }
    }
    login: { tokenStore: { enabled: true } }
    httpSettings: { requireHttps: true }
  }
}

resource basicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = [for (kind, i) in ['worker', 'report']: {
  parent: apps[i]
  name: 'scm'
  properties: { allow: false }
}]

resource deadLetters 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${namePrefix}-dead-letters'
  location: 'global'
  properties: {
    description: 'Arc-to-Entra work is dead-lettered. Inspect the machines queue and worker logs before replaying.'
    severity: 2
    enabled: true
    scopes: [bus.id]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'DeadLetters'
          metricNamespace: 'Microsoft.ServiceBus/namespaces'
          metricName: 'DeadletteredMessages'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Maximum'
          dimensions: [{ name: 'EntityName', operator: 'Include', values: ['machines'] }]
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [for id in alertActionGroupIds: { actionGroupId: id }]
  }
}
resource staleInventory 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: '${namePrefix}-inventory-stale'
  location: location
  kind: 'LogAlert'
  properties: {
    displayName: 'Arc-to-Entra inventory has not completed in 90 minutes'
    description: 'Adjust the query threshold if changing the default 30-minute schedule.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'P2D'
    scopes: [workspace.id]
    criteria: {
      allOf: [
        {
          query: 'AppTraces | where AppRoleName == "${workerName}" and Message startswith "INFORMATION: Inventory completed:" or AppRoleName == "${workerName}" and Message startswith "Inventory completed:" | summarize LastSuccess = max(TimeGenerated) | where isnull(LastSuccess) or LastSuccess < ago(90m)'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: { actionGroups: alertActionGroupIds }
  }
}

output workerAppName string = apps[0].name
output workerPrincipalId string = apps[0].identity.principalId
output workerFunctionId string = '${apps[0].id}/functions/ArcEvent'
output reportAppName string = apps[1].name
output reportUrl string = 'https://${apps[1].properties.defaultHostName}/api/report/'
output reportRedirectUri string = 'https://${apps[1].properties.defaultHostName}/.auth/login/aad/callback'
output dataStorageAccount string = storage.name
output serviceBusNamespace string = bus.name
