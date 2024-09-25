<#PSScriptInfo
.VERSION 1.3.0
.GUID 5f30b324-9305-4a7c-bd68-f9845d30659e
.AUTHOR SRM
#>

<# 
.DESCRIPTION 
This script automates the process of restoring the MariaDB master database with
a backup generated by a MariaDB slave database and reestablishes data replication.
#>

param (
	[string] $workDirectory,
	[string] $backupToRestore,
	[string] $rootPwd,
	[string] $replicationPwd,
	[string] $namespace,
	[string] $releaseName,
	[int]    $waitSeconds,
	[string] $imageDatabaseRestore,
	[string] $dockerImagePullSecretName,
	[switch] $skipSRMWebRestart
)

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

Set-PSDebug -Strict

$global:PSNativeCommandArgumentPassing='Legacy'

function Restore-DBBackup([string] $message,
	[int] $waitSeconds,
	[string] $namespace,
	[string] $podName,
	[string] $rootPwdSecretName,
	[string] $serviceAccountName,
	[string] $imageDatabaseRestore,
	[string] $imageDatabaseRestorePullSecretName) {

	if (Test-KubernetesJob $namespace $podName) {
		Remove-KubernetesJob $namespace $podName
	}
	
	$job = @'
apiVersion: batch/v1
kind: Job
metadata:
  name: '{1}'
  namespace: '{0}'
spec:
  template:
    spec:
      imagePullSecrets: {5}
      containers:
      - name: restoredb
        image: {4}
        imagePullPolicy: Always
        command: ["/bin/bash"]
        args: ["-c", "/home/sdb/restore"]
        volumeMounts:
        - mountPath: /bitnami/mariadb
          name: data
        - mountPath: /home/sdb/cfg
          name: rootpwd
          readOnly: true
      restartPolicy: Never
      securityContext:
        fsGroup: 1001
        runAsUser: 1001
      serviceAccountName: {3}
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: 'data-{1}'
      - name: rootpwd
        secret:
          secretName: '{2}'
          items:
          - key: mariadb-root-password
            path: .passwd
'@ -f $namespace, $podName, $rootPwdSecretName, $serviceAccountName, 
$imageDatabaseRestore, ($imageDatabaseRestorePullSecretName -eq '' ? '[]' : "[ {name: '$imageDatabaseRestorePullSecretName'} ]")

	$file = [io.path]::GetTempFileName()
	$job | out-file $file -Encoding ascii

	kubectl create -f $file
	if (0 -ne $LASTEXITCODE) {
		Write-Error "Unable to create restore job from file $file, kubectl exited with exit code $LASTEXITCODE."
	}
	Remove-Item -path $file

	Wait-JobSuccess $message $waitSeconds $namespace $podName

	Remove-KubernetesJob $namespace $podName
}

# Check for keytool and helm (required for restore database procedure)
'keytool','helm' | ForEach-Object {
	if ($null -eq (Get-AppCommandPath $_)) {
		Write-ErrorMessageAndExit "Restart this script after adding $_ to your PATH environment variable."
	}
}

if (-not (Test-HelmRelease $namespace $releaseName)) {
	Write-Error "Unable to find Helm release named $releaseName in namespace $namespace."
}

$deploymentWeb = "$(Get-HelmChartFullname $releaseName 'srm')-web"
$statefulSetMariaDBMaster = "$releaseName-mariadb-master"
$statefulSetMariaDBSlave = "$releaseName-mariadb-slave"
$mariaDbMasterServiceName = "$releaseName-mariadb"

if (-not (Test-Deployment $namespace $deploymentWeb)) {
	Write-Error "Unable to find Deployment named $deploymentWeb in namespace $namespace."
}

if (-not (Test-StatefulSet $namespace $statefulSetMariaDBMaster)) {
	Write-Error "Unable to find StatefulSet named $statefulSetMariaDBMaster in namespace $namespace."
}

if (-not (Test-StatefulSet $namespace $statefulSetMariaDBSlave)) {
	Write-Error "Unable to find StatefulSet named $statefulSetMariaDBSlave in namespace $namespace."
}

if (-not (Test-Service $namespace $mariaDbMasterServiceName)) {
	Write-Error "Unable to find Service named $mariaDbMasterServiceName in namespace $namespace."
}

$values = Get-HelmValues $namespace $releaseName

# identify the number of replicas
$statefulSetMariaDBSlaveCount = 0
if ($values.mariadb.replication.enabled) {
	$statefulSetMariaDBSlaveCount = $values.mariadb.slave.replicas
	if ($null -eq $statefulSetMariaDBSlaveCount) {
		$statefulSetMariaDBSlaveCount = 1 # 1 is the default value
	}
}

# identify the MariaDB password K8s secret resource name
$mariaDbSecretName = "$releaseName-mariadb-default-secret"
if ($null -ne $values.mariadb.existingSecret) {
	$mariaDbSecretName = $values.mariadb.existingSecret
}

if (-not (Test-Secret $namespace $mariaDbSecretName)) {
	Write-Error "Unable to find Secret named $mariaDbSecretName in namespace $namespace."
}

$mariaDBServiceAccount = Get-ServiceAccountName $namespace 'statefulset' $statefulSetMariaDBMaster

Write-Host @"

Using the following configuration:

SRM Web Deployment Name: $deploymentWeb
MariaDB Master StatefulSet Name: $statefulSetMariaDBMaster
MariaDB Slave StatefulSet Name: $statefulSetMariaDBSlave
MariaDB Slave Replica Count: $statefulSetMariaDBSlaveCount
MariaDB Secret Name: $mariaDbSecretName
MariaDB Master Service Name: $mariaDbMasterServiceName
MariaDB Service Account: $mariaDBServiceAccount
"@

if ($backupToRestore -eq '') { 
	$backupToRestore = Read-HostText 'Enter the name of the db backup to restore' 1 
}

if ($rootPwd -eq '') { 
	$rootPwd = Read-HostSecureText 'Enter the password for the MariaDB root user' 1 
}

if ($replicationPwd -eq '') {
	$replicationPwd = Read-HostSecureText 'Enter the password for the MariaDB replication user' 1 
}

Write-Verbose "Testing for work directory '$workDirectory'"
if (-not (Test-Path $workDirectory -PathType Container)) {
	Write-Error "Unable to find specified directory ($workDirectory). Does it exist?"
}
$workDirectory = (Resolve-Path $workDirectory).path

$workDirectory = join-path $workDirectory 'backup-files'
Write-Verbose "Testing for directory at '$workDirectory'"
if (Test-Path $workDirectory -PathType Container) {
	Write-Error "Unable to continue because '$workDirectory' already exists. Rerun this script after either removing the directory or specifying a different -workDirectory parameter value."
}

Write-Verbose 'Restarting database...'
& (join-path $PSScriptRoot 'restart-db.ps1') -namespace $namespace -releaseName $releaseName -waitSeconds $waitSeconds

$backupDirectory = '/bitnami/mariadb/backup/data'
$restoreDirectory = '/bitnami/mariadb/restore'

Write-Verbose 'Searching for MariaDB slave pods...'
$podFullNamesSlaves = kubectl -n $namespace get pod -l component=slave -o name
if (0 -ne $LASTEXITCODE) {
	Write-Error "Unable to fetch slave pods, kubectl exited with exit code $LASTEXITCODE."
}

$podNamesSlaves = @()
if (Test-Path $backupToRestore -PathType Container) {

	Write-Verbose "Copying backup from '$backupToRestore' to '$workDirectory'..."
	Copy-Item -LiteralPath $backupToRestore -Destination $workDirectory -Recurse

	$podFullNamesSlaves | ForEach-Object {

		$podName = $_ -replace 'pod/',''
		$podNamesSlaves = $podNamesSlaves + $podName
	}
} else {

	Write-Verbose "Finding MariaDB slave pod containing backup named $backupToRestore..."
	$podNameBackupSlave = ''
	$podFullNamesSlaves | ForEach-Object {

		$podName = $_ -replace 'pod/',''
		$podNamesSlaves = $podNamesSlaves + $podName
		
		if ($podNameBackupSlave -eq '') {
			$backups = kubectl -n $namespace exec -c mariadb $podName -- ls $backupDirectory
			if (0 -eq $LASTEXITCODE) {
				if ($backups -contains $backupToRestore) {
					$podNameBackupSlave = $podName
					Write-Verbose "Found backup $backupToRestore in pod named $podNameBackupSlave..."
				}
			}
		}
	}
	if ('' -eq $podNameBackupSlave) {
		Write-Error "Backup '$backupToRestore' is neither a local directory path nor a backup from a subordinate MariaDB database."
	}

	Write-Verbose "Copying backup files from pod $podNameBackupSlave..."
	kubectl -n $namespace cp -c mariadb $podNameBackupSlave`:$backupDirectory/$backupToRestore $workDirectory
	if (0 -ne $LASTEXITCODE) {
		Write-Error "Unable to copy backup to $workDirectory, kubectl exited with exit code $LASTEXITCODE."
	}
}

if ((Get-ChildItem $workDirectory -ErrorAction Silent).Count -eq 0) {
	Write-Error "No files to restore were found in '$workDirectory'"
}

Write-Verbose 'Searching for SRM Web pods...'
$podName = kubectl -n $namespace get pod -l component=frontend -o name
if (0 -ne $LASTEXITCODE) {
	Write-Error "Unable to find SRM Web pod, kubectl exited with exit code $LASTEXITCODE."
}
$podName = $podName -replace 'pod/',''

Write-Verbose 'Searching for MariaDB master pod...'
$podNameMaster = kubectl -n $namespace get pod -l component=master -o name
if (0 -ne $LASTEXITCODE) {
	Write-Error "Unable to find MariaDB master pod, kubectl exited with exit code $LASTEXITCODE."
}
$podNameMaster = $podNameMaster -replace 'pod/',''

Write-Verbose "Stopping SRM Web deployment named $deploymentWeb..."
Set-DeploymentReplicas  $namespace $deploymentWeb 0 $waitSeconds

Write-Verbose "Copying backup files to master pod named $podNameMaster..."
Copy-DBBackupFiles $namespace $workDirectory $podNameMaster 'mariadb' $restoreDirectory
$podNamesSlaves | ForEach-Object {
	Write-Verbose "Copying backup files to slave pod named $_..."
	Copy-DBBackupFiles $namespace $workDirectory $_ 'mariadb' $restoreDirectory
}

Write-Verbose 'Stopping slave database instances...'
$podNamesSlaves | ForEach-Object {
	Write-Verbose "Stopping slave named $_..."
	Stop-SlaveDB $namespace $_ 'mariadb' $rootPwd
}

Write-Verbose "Stopping $statefulSetMariaDBMaster statefulset replica..."
Set-StatefulSetReplicas $namespace $statefulSetMariaDBMaster 0 $waitSeconds

Write-Verbose "Stopping $statefulSetMariaDBSlave statefulset replica(s)..."
Set-StatefulSetReplicas $namespace $statefulSetMariaDBSlave 0 $waitSeconds

Write-Verbose "Restoring database backup on pod $podNameMaster..."
Restore-DBBackup 'Master Restore' $waitSeconds $namespace $podNameMaster $mariaDbSecretName $mariaDBServiceAccount $imageDatabaseRestore $dockerImagePullSecretName
$podNamesSlaves | ForEach-Object {
	Write-Verbose "Restoring database backup on pod $_..."
	Restore-DBBackup "Slave Restore [$_]" $waitSeconds $namespace $_ $mariaDbSecretName $mariaDBServiceAccount $imageDatabaseRestore $dockerImagePullSecretName
}

Write-Verbose "Starting $statefulSetMariaDBMaster statefulset replica..."
Set-StatefulSetReplicas $namespace $statefulSetMariaDBMaster 1 $waitSeconds

Write-Verbose "Starting $statefulSetMariaDBSlave statefulset replica(s)..."
Set-StatefulSetReplicas $namespace $statefulSetMariaDBSlave $statefulSetMariaDBSlaveCount $waitSeconds

Write-Verbose 'Resetting master database...'
$filePos = Get-MasterFilePosAfterReset $namespace 'mariadb' $podNameMaster $rootPwd

Write-Verbose 'Connecting slave database(s)...'
$podNamesSlaves | ForEach-Object {
	Write-Verbose "Restoring slave database pod $_..."
	Start-SlaveDB $namespace $_ 'mariadb' 'replicator' $replicationPwd $rootPwd $mariaDbMasterServiceName $filePos
}

if ($skipSRMWebRestart) {
	Write-Verbose "Skipping SRM Web Restart..."
	Write-Verbose " To restart SRM Web, run: kubectl -n $namespace scale --replicas=1 deployment/$deploymentWeb"
} else {
	Write-Verbose "Starting SRM Web deployment named $deploymentWeb..."
	Set-DeploymentReplicas  $namespace $deploymentWeb 1 $waitSeconds
}

Write-Host 'Done'
