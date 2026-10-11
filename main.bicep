targetScope = 'resourceGroup'

// ---- General ----
@description('Region')
param location string = resourceGroup().location

@description('Prefix for resource names')
param namePrefix string = 'owui'

@description('Suffix for globally unique names (Storage, Azure OpenAI subdomain, PostgreSQL)')
param uniqueSuffix string = take(uniqueString(resourceGroup().id), 6)

// ---- Network ----
@description('VNet address space. Avoid overlapping with the hub or other spokes')
param vnetAddressPrefixes array = ['192.168.40.0/24']

@description('Subnet for the Container Apps environment (/27 or larger, delegated to Microsoft.App/environments)')
param acaSubnetPrefix string = '192.168.40.0/27'

@description('Subnet for PostgreSQL (delegated to Microsoft.DBforPostgreSQL/flexibleServers)')
param pgSubnetPrefix string = '192.168.40.32/28'

@description('Subnet for private endpoints')
param peSubnetPrefix string = '192.168.40.48/28'

// ---- PostgreSQL ----
@description('PostgreSQL version')
param pgVersion string = '16'

@description('PostgreSQL SKU')
param pgSkuName string = 'Standard_B1ms'

@description('PostgreSQL tier')
param pgTier string = 'Burstable'

@description('PostgreSQL storage (GB)')
param pgStorageSizeGB int = 32

@description('PostgreSQL administrator login')
param pgAdminLogin string = 'owuiadmin'

@description('PostgreSQL administrator password (alphanumeric only because it is embedded in a URL). If empty, it is derived from uniqueString, which is deterministic and not random (for verification use only)')
@secure()
param pgAdminPassword string = ''

@description('Database name used by Open WebUI')
param pgDatabaseName string = 'openwebui'

// ---- Azure OpenAI ----
@description('Model name')
param aoaiModelName string = 'gpt-5-mini'

@description('Model version')
param aoaiModelVersion string = '2025-08-07'

@description('Deployment name')
param aoaiDeploymentName string = 'gpt-5-mini'

@description('Deployment capacity (in units of 1,000 TPM)')
param aoaiCapacity int = 30

// ---- App ----
@description('Open WebUI container image (pinned tag)')
param openWebUiImage string = 'ghcr.io/open-webui/open-webui:v0.12.0'

@description('Container CPU (vCPU)')
param containerCpu string = '1'

@description('Container memory')
param containerMemory string = '2Gi'

@description('Secret key for signing Open WebUI sessions')
@secure()
param webUiSecretKey string

@description('Enable the Open WebUI automations feature. Disabling it stops the scheduler from processing automations (ENABLE_AUTOMATIONS)')
param enableAutomations bool = false

@description('Interval in seconds at which the scheduler checks for due timers (TIMER_POLL_INTERVAL). The default is 1; a larger value reduces background traffic to the DB')
param timerPollIntervalSeconds int = 60

@description('If true, reset the settings stored in the DB to the environment variable values at startup (RESET_CONFIG_ON_START). Use it once, then set it back to false')
param resetConfigOnStart bool = false

@description('Send AVM usage telemetry')
param enableTelemetry bool = true

var vnetName = 'vnet-${namePrefix}'
var storageContainerName = 'openwebui'
var pgDnsZoneName = '${namePrefix}.private.postgres.database.azure.com'
// Prefix with Pg1 to satisfy the complexity requirements (upper case, lower case, digits). Use the specified password if there is one
var generatedPgPassword = 'Pg1${uniqueString(subscription().subscriptionId, resourceGroup().id, 'pg-admin-1')}${uniqueString(resourceGroup().id, namePrefix, 'pg-admin-2')}'
var pgPassword = empty(pgAdminPassword) ? generatedPgPassword : pgAdminPassword

// ---- Logs ----
module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'log-${uniqueString(deployment().name)}'
  params: {
    name: 'log-${namePrefix}'
    location: location
    enableTelemetry: enableTelemetry
    dataRetention: 30
    dailyQuotaGb: '1'
  }
}

// ---- Network ----
module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'vnet-${uniqueString(deployment().name)}'
  params: {
    name: vnetName
    location: location
    enableTelemetry: enableTelemetry
    addressPrefixes: vnetAddressPrefixes
    subnets: [
      {
        name: 'snet-aca'
        addressPrefix: acaSubnetPrefix
        delegation: 'Microsoft.App/environments'
      }
      {
        name: 'snet-pg'
        addressPrefix: pgSubnetPrefix
        delegation: 'Microsoft.DBforPostgreSQL/flexibleServers'
      }
      {
        name: 'snet-pe'
        addressPrefix: peSubnetPrefix
      }
    ]
  }
}

var acaSubnetId = vnet.outputs.subnetResourceIds[0]
var pgSubnetId = vnet.outputs.subnetResourceIds[1]
var peSubnetId = vnet.outputs.subnetResourceIds[2]

// ---- Private DNS zones ----
module dnsOpenAi 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'dns-openai-${uniqueString(deployment().name)}'
  params: {
    name: 'privatelink.openai.azure.com'
    enableTelemetry: enableTelemetry
    virtualNetworkLinks: [
      { virtualNetworkResourceId: vnet.outputs.resourceId, registrationEnabled: false }
    ]
  }
}

module dnsBlob 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'dns-blob-${uniqueString(deployment().name)}'
  params: {
    name: 'privatelink.blob.${environment().suffixes.storage}'
    enableTelemetry: enableTelemetry
    virtualNetworkLinks: [
      { virtualNetworkResourceId: vnet.outputs.resourceId, registrationEnabled: false }
    ]
  }
}

module dnsPostgres 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'dns-pg-${uniqueString(deployment().name)}'
  params: {
    name: pgDnsZoneName
    enableTelemetry: enableTelemetry
    virtualNetworkLinks: [
      { virtualNetworkResourceId: vnet.outputs.resourceId, registrationEnabled: false }
    ]
  }
}

// ---- PostgreSQL (VNet integration; allow-list pgvector) ----
module postgres 'br/public:avm/res/db-for-postgre-sql/flexible-server:0.16.1' = {
  name: 'pg-${uniqueString(deployment().name)}'
  params: {
    name: 'pg-${namePrefix}-${uniqueSuffix}'
    location: location
    enableTelemetry: enableTelemetry
    skuName: pgSkuName
    tier: pgTier
    version: pgVersion
    storageSizeGB: pgStorageSizeGB
    availabilityZone: -1
    highAvailability: 'Disabled'
    geoRedundantBackup: 'Disabled'
    backupRetentionDays: 7
    // Advanced threat protection (Defender) may incur costs, so disable it for verification
    enableAdvancedThreatProtection: false
    administratorLogin: pgAdminLogin
    administratorLoginPassword: pgPassword
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
    }
    delegatedSubnetResourceId: pgSubnetId
    privateDnsZoneArmResourceId: dnsPostgres.outputs.resourceId
    publicNetworkAccess: 'Disabled'
    databases: [
      { name: pgDatabaseName }
    ]
    configurations: [
      { name: 'azure.extensions', value: 'VECTOR', source: 'user-override' }
    ]
  }
}

// ---- Storage (Blob; private endpoint only) ----
module storage 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: 'st-${uniqueString(deployment().name)}'
  // Creating private endpoints in the same subnet in parallel can fail with RetryableError, so serialize them
  dependsOn: [
    openai
  ]
  params: {
    name: take('st${namePrefix}${uniqueSuffix}', 24)
    location: location
    enableTelemetry: enableTelemetry
    skuName: 'Standard_LRS'
    allowSharedKeyAccess: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
    }
    blobServices: {
      containers: [
        { name: storageContainerName }
      ]
    }
    privateEndpoints: [
      {
        name: 'pe-st-${namePrefix}'
        service: 'blob'
        subnetResourceId: peSubnetId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: dnsBlob.outputs.resourceId }
          ]
        }
      }
    ]
  }
}

// ---- Azure OpenAI (private endpoint only) ----
module openai 'br/public:avm/res/cognitive-services/account:0.19.1' = {
  name: 'aoai-${uniqueString(deployment().name)}'
  params: {
    name: 'aoai-${namePrefix}-${uniqueSuffix}'
    location: location
    enableTelemetry: enableTelemetry
    kind: 'OpenAI'
    sku: 'S0'
    customSubDomainName: 'aoai-${namePrefix}-${uniqueSuffix}'
    // Open WebUI connects with an API key (Entra ID authentication is not used)
    disableLocalAuth: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
    }
    deployments: [
      {
        name: aoaiDeploymentName
        model: {
          format: 'OpenAI'
          name: aoaiModelName
          version: aoaiModelVersion
        }
        sku: {
          name: 'GlobalStandard'
          capacity: aoaiCapacity
        }
      }
    ]
    privateEndpoints: [
      {
        name: 'pe-aoai-${namePrefix}'
        subnetResourceId: peSubnetId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: dnsOpenAi.outputs.resourceId }
          ]
        }
      }
    ]
  }
}

// ---- Container Apps environment (VNet integration, Consumption) ----
module containerAppsEnv 'br/public:avm/res/app/managed-environment:0.16.0' = {
  name: 'cae-${uniqueString(deployment().name)}'
  params: {
    name: 'cae-${namePrefix}'
    location: location
    enableTelemetry: enableTelemetry
    infrastructureSubnetResourceId: acaSubnetId
    internal: false
    publicNetworkAccess: 'Enabled'
    zoneRedundant: false
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    }
  }
}

// ---- Open WebUI ----
// Expose only the deployed model on the connection (index 0)
var openAiApiConfigs = string({
  '0': {
    enable: true
    model_ids: [
      aoaiDeploymentName
    ]
  }
})
var pgFqdn = postgres.outputs.?fqdn ?? ''
var databaseUrl = 'postgresql://${pgAdminLogin}:${pgPassword}@${pgFqdn}:5432/${pgDatabaseName}?sslmode=require'

var baseEnv = [
  { name: 'PORT', value: '8080' }
  { name: 'UVICORN_WORKERS', value: '1' }
  { name: 'ENABLE_OLLAMA_API', value: 'false' }
  { name: 'ENABLE_WEBSOCKET_SUPPORT', value: 'true' }
  // Background polling by the scheduler generates network traffic even when nobody uses the app.
  // Keep it low so that the replica can be billed at the idle rate (< 1,000 bytes/s received)
  { name: 'ENABLE_AUTOMATIONS', value: toLower(string(enableAutomations)) }
  { name: 'TIMER_POLL_INTERVAL', value: string(timerPollIntervalSeconds) }
  { name: 'WEBUI_SECRET_KEY', secretRef: 'webui-secret-key' }
  // PostgreSQL (database and vector search)
  { name: 'DATABASE_URL', secretRef: 'database-url' }
  { name: 'VECTOR_DB', value: 'pgvector' }
  { name: 'PGVECTOR_DB_URL', secretRef: 'database-url' }
  // Blob Storage (uploaded files)
  { name: 'STORAGE_PROVIDER', value: 'azure' }
  { name: 'AZURE_STORAGE_ENDPOINT', value: 'https://${storage.outputs.name}.blob.${environment().suffixes.storage}' }
  { name: 'AZURE_STORAGE_CONTAINER_NAME', value: storageContainerName }
  { name: 'AZURE_STORAGE_KEY', secretRef: 'azure-storage-key' }
  // Azure OpenAI (OpenAI-compatible endpoint). One connection (index 0)
  // Restrict the model list to the deployed model with model_ids in OPENAI_API_CONFIGS
  // (otherwise every model that Azure OpenAI returns is listed)
  // After the first start these values are stored in the DB, so changing the environment variables has no effect
  { name: 'OPENAI_API_BASE_URLS', value: '${openai.outputs.endpoint}openai/v1' }
  { name: 'OPENAI_API_KEYS', secretRef: 'openai-api-key' }
  { name: 'OPENAI_API_CONFIGS', value: openAiApiConfigs }
]

// Settings are stored in the DB after the first start, so set this to true once, only when an environment variable change must take effect
var containerEnv = concat(baseEnv, resetConfigOnStart ? [
  { name: 'RESET_CONFIG_ON_START', value: 'true' }
] : [])

module openWebUi 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'ca-${uniqueString(deployment().name)}'
  params: {
    name: 'ca-${namePrefix}'
    location: location
    enableTelemetry: enableTelemetry
    environmentResourceId: containerAppsEnv.outputs.resourceId
    workloadProfileName: 'Consumption'
    ingressExternal: true
    ingressTargetPort: 8080
    ingressAllowInsecure: false
    activeRevisionsMode: 'Single'
    // One replica for verification. For more replicas, review Redis (WebSocket) and the number of DB connections
    scaleSettings: {
      minReplicas: 1
      maxReplicas: 1
    }
    secrets: [
      { name: 'database-url', value: databaseUrl }
      { name: 'webui-secret-key', value: webUiSecretKey }
      { name: 'openai-api-key', value: openai.outputs.?primaryKey ?? '' }
      { name: 'azure-storage-key', value: storage.outputs.primaryAccessKey }
    ]
    containers: [
      {
        name: 'open-webui'
        image: openWebUiImage
        resources: {
          cpu: json(containerCpu)
          memory: containerMemory
        }
        env: containerEnv
        probes: [
          {
            type: 'Startup'
            httpGet: { path: '/health', port: 8080 }
            periodSeconds: 10
            failureThreshold: 60
            timeoutSeconds: 5
          }
          {
            type: 'Readiness'
            httpGet: { path: '/health/db', port: 8080 }
            periodSeconds: 10
            timeoutSeconds: 5
          }
          {
            type: 'Liveness'
            httpGet: { path: '/health', port: 8080 }
            periodSeconds: 30
            timeoutSeconds: 5
          }
        ]
      }
    ]
  }
}

output openWebUiFqdn string = openWebUi.outputs.fqdn
output postgresFqdn string = postgres.outputs.?fqdn ?? ''
output openAiEndpoint string = openai.outputs.endpoint
output storageAccountName string = storage.outputs.name
