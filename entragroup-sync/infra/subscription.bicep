targetScope = 'subscription'

@description('Worker Managed Identity Principal ID: The Object or Principal ID GUID of the Worker Function App System-Assigned Managed Identity to grant Reader access on this subscription.')
param workerPrincipalId string

@description('Worker ArcEvent Function Resource ID: The full Azure Resource ID of the Worker Function App ArcEvent function (/subscriptions/.../providers/Microsoft.Web/sites/worker/functions/ArcEvent) that receives Event Grid events.')
param workerFunctionId string

@description('Event Grid Subscription Name: Name for the subscription-scoped Event Grid subscription that triggers when entraiddeviceid / entraiddeviceidlinux Guest Configuration assignments or MDE extensions complete.')
param eventSubscriptionName string

@description('Scoped Resource Group Names (Optional): Optional list of Resource Group names to filter Event Grid events. Leave empty to monitor all resource groups in this subscription.')
param resourceGroupNames array = []

var rgPrefixes = [for rg in resourceGroupNames: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${rg}/providers/']
var triggerOperationNames = [
  'Microsoft.GuestConfiguration/guestConfigurationAssignments/write'
  'Microsoft.HybridCompute/machines/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/write'
  'Microsoft.Compute/virtualMachines/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/write'
  'Microsoft.Compute/virtualMachineScaleSets/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/write'
  'Microsoft.HybridCompute/machines/extensions/write'
  'Microsoft.Compute/virtualMachines/extensions/write'
  'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/extensions/write'
  'Microsoft.Compute/virtualMachineScaleSets/extensions/write'
]
var subjectContainsValues = [
  '/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/entraiddeviceid'
  '/extensions/MDE.Windows'
  '/extensions/MDE.Linux'
]
var advancedFilters = empty(resourceGroupNames) ? [
  {
    operatorType: 'StringIn'
    key: 'data.operationName'
    values: triggerOperationNames
  }
  {
    operatorType: 'StringContains'
    key: 'subject'
    values: subjectContainsValues
  }
] : [
  {
    operatorType: 'StringIn'
    key: 'data.operationName'
    values: triggerOperationNames
  }
  {
    operatorType: 'StringContains'
    key: 'subject'
    values: subjectContainsValues
  }
  {
    operatorType: 'StringBeginsWith'
    key: 'subject'
    values: rgPrefixes
  }
]

resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, workerPrincipalId, 'arc-sync-reader')
  properties: {
    principalId: workerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  }
}

resource events 'Microsoft.EventGrid/eventSubscriptions@2022-06-15' = {
  name: eventSubscriptionName
  properties: {
    eventDeliverySchema: 'EventGridSchema'
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: workerFunctionId
        maxEventsPerBatch: 1
        preferredBatchSizeInKilobytes: 64
      }
    }
    filter: {
      includedEventTypes: ['Microsoft.Resources.ResourceWriteSuccess']
      advancedFilters: advancedFilters
    }
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}
