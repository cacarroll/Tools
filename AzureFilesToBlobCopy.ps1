param (
  $SourceStorageAccountName = 'files123',
  $SourceResourceGroupName = 'D-Sub-HUB-001',
  $DestinationStorageAccountName = 'blob123',
  $DestinationResourceGroupName = 'D-Sub-HUB-001'
)

function Map-Drive {
    [CmdletBinding()]
    param (
        $ResourceGroupName,
        $StorageAccountName,
        $ShareName,
        $drive_letter = "Q"
    )

    # Get the storage account key
    $StorageAccountKey=$(az storage account keys list -g $ResourceGroupName -n $StorageAccountName --query "[0].value" --output tsv)
    
    $fileShareEndpoint=$((az storage account show --name $StorageAccountName --query "primaryEndpoints.file" --output tsv) -split '/')[2]
    $unc_path = "\\$fileShareEndpoint\$ShareName"

    if (Get-PSdrive -Name $drive_letter -ErrorAction SilentlyContinue){
        Remove-Psdrive -Name $drive_letter
    }
   
    $connectTestResult = Test-NetConnection -ComputerName $fileShareEndPoint -Port 445
    if ($connectTestResult.TcpTestSucceeded) {
        # Save the password so the drive will persist on reboot
        cmd.exe /C "cmdkey /add:`"$fileShareEndPoint`" /user:`"localhost\$StorageAccountName`" /pass:`"$StorageAccountKey`""
        # Mount the drive
        New-PSDrive -Name Q -PSProvider FileSystem -Root $unc_path -Persist -scope Global
    } else {
        Write-Error -Message "Unable to reach the Azure storage account via port 445. Check to make sure your organization or ISP is not blocking port 445, or use Azure P2S VPN, Azure S2S VPN, or Express Route to tunnel SMB traffic over a different port."
        Throw
    }
}

function Get-FileShareSASUri {
    [CmdletBinding()]
    param (
        $StorageAccountName,
        $ShareName
    )

    $expiry=(Get-Date).AddDays(1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    $storageKey = $(az storage account keys list --account-name $StorageAccountName --query "[?keyName=='key1'].value" --output tsv)
    
    $sasToken=$(az storage share generate-sas -n $ShareName --account-name $StorageAccountName --account-key $storageKey --https-only --permissions dlrw --expiry $expiry -o tsv)

    # Get file share endpoint URL
    $fileShareEndpoint=$(az storage account show --name $StorageAccountName --query "primaryEndpoints.file" --output tsv)

    # Append file share name to endpoint URL
    $fileShareSasUri = "$fileShareEndpoint$shareName/*?$sasToken"

    return $fileShareSasUri
}

function Get-BlobContainerSASUri {
    [CmdletBinding()]
    param (
        $StorageAccountName,
        $ContainerName
    )

    $expiry=(Get-Date).AddDays(1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    $storageKey = $(az storage account keys list --account-name $StorageAccountName --query "[?keyName=='key1'].value" --output tsv)
    
    $sasToken=$(az storage container generate-sas --account-name $StorageAccountName --account-key $storageKey --name $containerName --permissions racwdl --expiry $expiry --output tsv)

    # Get file share endpoint URL
    $blobEndpoint=$(az storage account show --name $StorageAccountName --query "primaryEndpoints.blob" --output tsv)

    # Append file share name to endpoint URL
    $blobContainerSasUri = "$blobEndpoint$shareName/?$sasToken"

    return $blobContainerSasUri
}

Function Get-EmptyFolders {
    [CmdletBinding()]
    param (
        $Path
    )

    $emptyFolders = @()
    Get-ChildItem -Path $path -Directory -Recurse | ForEach-Object {
        if ((Get-ChildItem -path $($_.Fullname) -Recurse).count -eq 0) {
            $emptyFolders += $($_.Fullname).substring(3).replace('\','/')
        }
    }
    return $emptyFolders
}

Function New-EmptyFile {
    [CmdletBinding()]
    param (
        $StorageAccountName,
        $ResourceGroupName,
        $EmptyFolders,
        $ShareName
    )

    $connectionString = $(az storage account show-connection-string --name $StorageAccountName --resource-group $ResourceGroupName -o tsv)

    New-Item -path $env:tmp -Name empty.txt

    foreach ($emptyFolder in $emptyFolders) {
        Write-Output "Creating empty.txt on $StorageAccountName/$EmptyFolder"
        az storage blob upload-batch --destination "$shareName/$emptyFolder" --source "C:\tmp" --pattern "empty.txt" --account-name $StorageAccountName --connection-string $ConnectionString
    }

    Remove-Item "$env:temp\empty.txt"
}


Write-Host "`n************Start copy from Azure File Share to Azure Blob Container*******************" -ForeGroundColor Cyan
Write-Output "Retreiving file shares from $SourceStorageAccountName"
$SourceStorageAccountConnectionString = $(az storage account show-connection-string --name $SourceStorageAccountName --resource-group $SourceResourceGroupName -o tsv)
$fileShares = $(az storage share list --connection-string $sourceStorageAccountConnectionString --query "[].{name:name}") | ConvertFrom-Json

foreach ($fileShare in $fileShares.name) {
  # Mirror fileshare to blob container
  Write-Output "Creating container $fileshare on storage account $DestinationStorageAccountName"
  $DestinationStorageAccountConnectionString = $(az storage account show-connection-string --name $DestinationStorageAccountName --resource-group $DestinationResourceGroupName -o tsv)
  az storage container create --name $fileShare --account-name $DestinationStorageAccountName --connection-string $DestinationStorageAccountConnectionString
  
  # Map a local drive to the file share unc
  Map-Drive -ResourceGroupName $SourceResourceGroupName -StorageAccountName $SourceStorageAccountName -ShareName $fileshare
  
  # Get Empty folders on fileshare
  $emptyFolders = Get-EmptyFolders -Path 'Q:'

  #Create path and emptyfile
  New-EmptyFile -StorageAccount $DestinationStorageAccountName -ResourceGroupName $DestinationResourceGroupName -EmptyFolders $EmptyFolders -ShareName $fileShare

  $fileShareSasUri = Get-FileShareSASUri -StorageAccountName $SourceStorageAccountName -ShareName $fileShare

  $blobContainerSasUri = Get-BlobContainerSasUri -StorageAccountName $DestinationStorageAccountName -containerName $fileshare
  
  $env:AZCOPY_CONCURRENCY_VALUE = "AUTO"
  .\azcopy.exe cp $fileShareSasUri $blobContainerSasUri --from-to=FileBlob --s2s-preserve-access-tier=false --check-length=true --include-directory-stub=false --s2s-preserve-blob-tags=false --recursive
  $env:AZCOPY_CONCURRENCY_VALUE = ""

  Remove-Psdrive -Name 'Q'
}
