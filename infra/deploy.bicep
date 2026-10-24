targetScope = 'subscription'

param rgName string
param location string
param appiName string
param logName string

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
}

module logAnalytics 'modules/log-analytics.bicep' = {
  name: 'log-${logName}'
  scope: rg
  params: {
    name: logName
    location: location
  }
}

module appInsights 'modules/app-insights.bicep' = {
  name: 'appi-${appiName}'
  scope: rg
  params: {
    name: appiName
    location: location
    workspaceResourceId: logAnalytics.outputs.id
  }
}

output rgName string = rg.name
output logName string = logAnalytics.outputs.name
output appiName string = appInsights.outputs.name
output connectionString string = appInsights.outputs.connectionString
