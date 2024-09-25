function Get-LicenseSecretName($config) {
	"$($config.releaseName)-license-secret"
}

function Get-ScanFarmLicenseSecretName($config) {
	"$($config.releaseName)-sf-license-secret"
}

function New-ScanFarmLicenseSecret($config) {

	$licenseFiles = @{}
	if (-not [string]::IsNullOrEmpty($config.scanFarmSastLicenseFile)) {
		$licenseFiles['license.dat'] = $config.scanFarmSastLicenseFile
	}

	$urlOverride = @{}
	if (-not [string]::IsNullOrEmpty($config.scanFarmScaLicenseFile)) {

		$licenseFiles['license.json'] = $config.scanFarmScaLicenseFile

		if (-not [string]::IsNullOrEmpty($config.scanFarmScaApiUrlOverride)) {
			$urlOverride['dev-sca-api-url'] = $config.scanFarmScaApiUrlOverride
		}
	}

	New-GenericSecret $config.namespace (Get-ScanFarmLicenseSecretName $config) $urlOverride $licenseFiles `
		-dryRun | Out-File (Get-ScanFarmLicenseSecretK8sPath $config)
}

function New-ScanFarmLicenseConfig($config) {

	New-ScanFarmLicenseSecret $config
    @"
cnc:
  licenseSecretName: $(Get-ScanFarmLicenseSecretName $config)
"@ | Out-File (Get-ScanFarmLicenseValuesPath $config)
}

function New-LicenseConfig($config) {

	New-GenericSecret $config.namespace (Get-LicenseSecretName $config) -fileKeyValues @{
		"license.lic"=$($config.srmLicenseFile)
	} -dryRun | Out-File (Get-LicenseSecretK8sPath $config)

    @"
web:
  licenseSecret: $(Get-LicenseSecretName $config)
"@ | Out-File (Get-LicenseSecretValuesPath $config)

	if (-not $config.skipScanFarm) {
		New-ScanFarmLicenseConfig $config
	}
}