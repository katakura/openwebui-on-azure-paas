using 'main.bicep'

// Values to adapt to your environment
param location = 'japaneast'
param namePrefix = 'owui'

// Avoid overlapping with the hub or other spokes
param vnetAddressPrefixes = ['192.168.40.0/24']
param acaSubnetPrefix = '192.168.40.0/27'
param pgSubnetPrefix = '192.168.40.32/28'
param peSubnetPrefix = '192.168.40.48/28'

param pgVersion = '16'
param pgSkuName = 'Standard_B1ms'
param pgTier = 'Burstable'
param pgStorageSizeGB = 32

param aoaiModelName = 'gpt-5-mini'
param aoaiModelVersion = '2025-08-07'
param aoaiDeploymentName = 'gpt-5-mini'
param aoaiCapacity = 30

param openWebUiImage = 'ghcr.io/open-webui/open-webui:v0.12.0'

// Secrets and the administrator name are read from environment variables (set by deploy.sh). Do not write them in the repository
param pgAdminLogin = readEnvironmentVariable('PG_ADMIN_LOGIN', 'owuiadmin')
// If empty, main.bicep derives it from uniqueString
param pgAdminPassword = readEnvironmentVariable('PG_ADMIN_PASSWORD', '')
param webUiSecretKey = readEnvironmentVariable('WEBUI_SECRET_KEY')

// If true, reset the settings stored in the DB to the environment variable values at startup. Set it with --reset-config of deploy.sh
param resetConfigOnStart = readEnvironmentVariable('RESET_CONFIG_ON_START', 'false') == 'true'
