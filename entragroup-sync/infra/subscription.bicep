targetScope = 'subscription'

param workerPrincipalId string
param workerFunctionId string
param eventSubscriptionName string
param resourceGroupNames array = []

var rgPrefixes = [for rg in resourceGroupNames: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${rg}/providers/Microsoft.HybridCompute/machines/']
var advancedFilters = empty(resourceGroupNames) ? [
  {
    operatorType: 'StringIn'
    key: 'data.operationName'
    values: ['Microsoft.HybridCompute/machines/write']
  }
] : [
  {
    operatorType: 'StringIn'
    key: 'data.operationName'
    values: ['Microsoft.HybridCompute/machines/write']
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
