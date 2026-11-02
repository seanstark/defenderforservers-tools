targetScope = 'resourceGroup'

@minLength(3)
@maxLength(18)
@description('Resource Naming Prefix: Short prefix (3 to 18 lowercase letters, numbers, or hyphens, such as arcgroupsync) used to name the Worker Function App, Report Function App, Service Bus namespace, Storage Accounts, and Application Insights.')
param namePrefix string

@description('Deployment Region: Azure region where the Function Apps, Service Bus, Storage Accounts, and Log Analytics workspace will be deployed. Defaults to the current Resource Group location.')
param location string = resourceGroup().location

@description('Microsoft Entra Tenant ID: The GUID of your Microsoft Entra ID tenant where devices, security groups, and report sign-in are located. Defaults to the deployment tenant ID.')
param tenantId string = tenant().tenantId

@description('Scoped Azure Subscription IDs: List of Azure Subscription GUIDs to scan for Azure Arc servers, Azure Native VMs, and VMSS instances. Provide at least one Subscription ID or Management Group ID.')
param subscriptionIds array = []

@description('Scoped Azure Management Group IDs: Optional list of Azure Management Group IDs (such as mg-prod) whose member subscriptions will be automatically discovered and scanned. Combined with subscriptionIds using OR.')
param managementGroupIds array = []

@description('Scoped Resource Group Names: Optional list of Resource Group names (such as rg-arc-servers) to restrict discovery. Leave empty to include all resource groups in the scoped subscriptions and management groups.')
param resourceGroupNames array = []

@description('AWS Windows Group Naming Prefix: Prefix for AWS Windows Entra ID security groups (such as MDfS-AWS-Windows-). The worker appends Passive-AccountId or Active-AccountId using the AWS AccountId resource tag.')
param awsWindowsGroupPrefix string = ''

@description('AWS Linux Group Naming Prefix: Prefix for AWS Linux Entra ID security groups (such as MDfS-AWS-Linux-). The worker appends Passive-AccountId or Active-AccountId using the AWS AccountId resource tag.')
param awsLinuxGroupPrefix string = ''

@description('GCP Windows Group Naming Prefix: Prefix for GCP Windows Entra ID security groups (such as MDfS-GCP-Windows-). The worker appends Passive-ProjectId or Active-ProjectId using the GCP ProjectId resource tag.')
param gcpWindowsGroupPrefix string = ''

@description('GCP Linux Group Naming Prefix: Prefix for GCP Linux Entra ID security groups (such as MDfS-GCP-Linux-). The worker appends Passive-ProjectId or Active-ProjectId using the GCP ProjectId resource tag.')
param gcpLinuxGroupPrefix string = ''

@description('Azure Windows Group Naming Prefix: Prefix for Azure Windows Entra ID security groups (such as MDfS-Azure-Windows-). The worker appends Passive-SubscriptionName or Active-SubscriptionName. AWS and GCP Arc machines are automatically excluded.')
param azureWindowsGroupPrefix string = ''

@description('Azure Linux Group Naming Prefix: Prefix for Azure Linux Entra ID security groups (such as MDfS-Azure-Linux-). The worker appends Passive-SubscriptionName or Active-SubscriptionName. AWS and GCP Arc machines are automatically excluded.')
param azureLinuxGroupPrefix string = ''

@allowed(['Passive', 'Active'])
@description('Default Antivirus Group Mode: Controls whether correlated devices are added to their Passive or Active group by default (defaults to Passive). A device already in its Active group is never added to Passive, and a device in Passive is never added to Active.')
param defaultGroupMode string = 'Passive'

@description('Entra Administrative Unit ID (Optional): GUID of a Microsoft Entra ID Administrative Unit. When provided (and the worker Managed Identity is granted Groups Administrator on this AU), missing Active and Passive security groups are automatically created inside this AU.')
param adminUnitId string = ''

@description('Auto-Create Missing Entra Groups: When true (and adminUnitId is set), the worker automatically creates missing Active and Passive Cloud and OS security groups inside the Administrative Unit when running in Enforce mode.')
param autoCreateGroups bool = !empty(adminUnitId)

@description('Report App Registration Client ID: The Application (client) ID GUID of the Microsoft Entra App Registration used to sign in users to the read-only web portal (must define the Report.Reader app role).')
param reportClientId string

@secure()
@description('Report App Registration Client Secret: The client secret value for the Report App Registration used by Azure App Service Authentication (Easy Auth).')
param reportClientSecret string

@allowed(['Audit', 'Enforce'])
@description('Synchronization Mode: Audit (default) only evaluates correlation and records WouldAdd without modifying any Entra ID groups. Enforce creates and updates group memberships for verified devices.')
param syncMode string = 'Audit'

@description('Inventory Timer Schedule (NCRONTAB): 6-field NCRONTAB expression controlling how often the full Azure Resource Graph inventory runs. Default 0 */30 * * * * runs every 30 minutes.')
param schedule string = '0 */30 * * * *'

@minValue(1)
@maxValue(168)
@description('MDE Telemetry Freshness Window (Hours): Maximum age in hours (1 to 168, default 24) for Microsoft Defender for Endpoint DeviceInfo records to be trusted for correlation.')
param freshnessHours int = 24

@allowed(['B1', 'S1', 'P1v3'])
@description('App Service Plan SKU: Hosting tier for the Worker and Report Function Apps (B1 Basic, S1 Standard, or P1v3 Premium v3). Default is B1.')
param planSku string = 'B1'

@description('Alert Action Group Resource IDs (Optional): List of Azure Monitor Action Group resource IDs to notify when dead-letter queue, failed run, or stale inventory alerts fire. Leave empty for no notification recipients.')
param alertActionGroupIds array = []

var suffix = uniqueString(resourceGroup().id, namePrefix)
var workerName = '${namePrefix}-worker-${take(suffix, 6)}'
var reportName = '${namePrefix}-report-${take(suffix, 6)}'
var blobOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var queueContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var tableContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var tableReader = '76199698-9eea-4c19-bc75-cec21354c6b6'
var busSender = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
var busReceiver = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'
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
      powerShellVersion: '7.6'
      use32BitWorkerProcess: false
      appSettings: concat([
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'powershell' }
        { name: 'FUNCTIONS_WORKER_RUNTIME_VERSION', value: '7.6' }
        { name: 'AzureWebJobsDisableHomepage', value: 'true' }
        { name: 'AzureWebJobsStorage__accountName', value: hosts[i].name }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
        { name: 'SYNC_STORAGE_ACCOUNT', value: storage.name }
        { name: 'SYNC_TENANT_ID', value: tenantId }
        { name: 'SYNC_WORKER_FUNCTION_RESOURCE_ID', value: resourceId('Microsoft.Web/sites', workerName) }
        { name: 'SYNC_APPINSIGHTS_RESOURCE_ID', value: insights.id }
      ], i == 0 ? [
        { name: 'SYNC_SUBSCRIPTION_IDS', value: join(subscriptionIds, ',') }
        { name: 'SYNC_MANAGEMENT_GROUP_IDS', value: join(managementGroupIds, ',') }
        { name: 'SYNC_RESOURCE_GROUP_NAMES', value: join(resourceGroupNames, ',') }
        { name: 'SYNC_AWS_WINDOWS_GROUP_PREFIX', value: awsWindowsGroupPrefix }
        { name: 'SYNC_AWS_LINUX_GROUP_PREFIX', value: awsLinuxGroupPrefix }
        { name: 'SYNC_GCP_WINDOWS_GROUP_PREFIX', value: gcpWindowsGroupPrefix }
        { name: 'SYNC_GCP_LINUX_GROUP_PREFIX', value: gcpLinuxGroupPrefix }
        { name: 'SYNC_AZURE_WINDOWS_GROUP_PREFIX', value: azureWindowsGroupPrefix }
        { name: 'SYNC_AZURE_LINUX_GROUP_PREFIX', value: azureLinuxGroupPrefix }
        { name: 'SYNC_DEFAULT_GROUP_MODE', value: defaultGroupMode }
        { name: 'SYNC_ADMIN_UNIT_ID', value: adminUnitId }
        { name: 'SYNC_AUTO_CREATE_GROUPS', value: string(autoCreateGroups) }
        { name: 'SYNC_MODE', value: syncMode }
        { name: 'SYNC_FRESHNESS_HOURS', value: string(freshnessHours) }
        { name: 'SYNC_SCHEDULE', value: schedule }
        { name: 'PSWorkerInProcConcurrencyUpperBound', value: '8' }
        { name: 'FUNCTIONS_WORKER_PROCESS_COUNT', value: '2' }
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
    login: { tokenStore: { enabled: false } }
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
output reportUrl string = 'https://${apps[1].properties.defaultHostName}/'
output reportRedirectUri string = 'https://${apps[1].properties.defaultHostName}/.auth/login/aad/callback'
output dataStorageAccount string = storage.name
output serviceBusNamespace string = bus.name
