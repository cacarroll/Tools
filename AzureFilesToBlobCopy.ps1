function Copy-AzureFilesToBlobContainer {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [String]$Release
    )

    begin {
        Write-Host "`n************ Start copy from Azure File Share to Azure Blob Container *******************" -ForegroundColor Cyan
        Import-Module .\module.psm1

        $StorageMapping = @{
            Source = @{
                SubscriptionId      = '579d0760-2880-4f13-8d8f-7a2121243198'
                StorageAccountName  = 'pipeline'
                ResourceGroupName   = 'GD-RG'
                FileShareName       = 'released'
                Folder              = "Released\$Release"
                # Folder             = 'Released\2Q23'
            }
            Destination = @{
                SubscriptionId      = '16d23ae1-53e7-474f-8f46-373c815cbb01'
                StorageAccountName  = 'releasestorage02'
                ResourceGroupName   = 'MNR-Storage-RG'
                BlobContainerName   = 'otm'
                FolderMapping = @{
                    "Released\$Release" = $Release
                }
            }
        }

        # Convert Release Date to New Format
        # $quarter, $year = $Release -split 'Q'
        # $newReleaseFormat = "FY20$year\$quarter" + 'Q'
    }

    process {
        try {
            Set-AzSubscription -SubscriptionId $StorageMapping.Source.SubscriptionId

            # Map a local drive to the file share UNC
            $DriveLetter = Get-NextAvailableDriveLetter

            Map-Drive -ResourceGroupName $StorageMapping.Source.ResourceGroupName -StorageAccountName $StorageMapping.Source.StorageAccountName -ShareName $StorageMapping.Source.FileShareName -DriveLetter $DriveLetter

            $folder = $driveLetter + ":\" + $StorageMapping.Source.Folder
            Write-Output "`n`nRetrieving parent folders on $folder. Please be patient..."
            $root = [System.IO.DirectoryInfo]::new($folder)
            $folders = $root.GetDirectories("*", [System.IO.SearchOption]::AllDirectories)

            $emptyFolders = @()
            $totalFolders = $folders.Count
            $currentFolder = 0

            foreach ($subfolder in $folders) {
                $currentFolder++
                Write-Output "`nScanning $($subfolder.FullName) for emptiness"
                Write-Progress -Activity "Scanning" -Status "Processing folder $currentFolder of $totalFolders" -PercentComplete (($currentFolder/$totalFolders)*100)

                $result = Get-EmptyFolder -Path $subfolder.FullName
                if ($result) {
                    Write-Output "`nFound empty folder at $($subfolder.FullName)"
                    $emptyFolders += $result
                }
            }

            #Retreive FileShare SASUri
            $FileShareSasUri = Get-FileShareSASUri -StorageAccountName $StorageMapping.Source.StorageAccountName -ShareName $StorageMapping.Source.FileShareName -FolderPath $StorageMapping.Source.Folder

            #### Destination Processing ####
            Set-AzSubscription -SubscriptionId $StorageMapping.Destination.SubscriptionId

            Write-Output "Creating blob container [$DestinationBlobContainer] on storage account $($StorageMapping.Destination.StorageAccountName)"
            $DestinationBlobContainer = $StorageMapping.Destination.BlobContainerName
            $DestinationStorageAccountConnectionString = $(az storage account show-connection-string --name $StorageMapping.Destination.StorageAccountName --resource-group $StorageMapping.Destination.ResourceGroupName -o tsv)
            az storage container create --name $DestinationBlobContainer --account-name $StorageMapping.Destination.StorageAccountName --connection-string $DestinationStorageAccountConnectionString

            $BlobFolderPath = ($StorageMapping.Destination.FolderMapping[$StorageMapping.Source.Folder]).Replace("\","/")
            New-EmptyFile -StorageAccountName $StorageMapping.Destination.StorageAccountName -ResourceGroupName $StorageMapping.Destination.ResourceGroupName -EmptyFolders $EmptyFolders -ShareName $BlobFolderPath -ContainerName $StorageMapping.Destination.BlobContainerName

            $BlobContainerSasUri = Get-BlobContainerSASUri -StorageAccountName $StorageMapping.Destination.StorageAccountName -ContainerName $StorageMapping.Destination.BlobContainerName -BlobFolderPath $BlobFolderPath

            Write-Output "`nUsing AzCopy to copy files from $($StorageMapping.Source.StorageAccountName) to $($StorageMapping.Destination.StorageAccountName)"
            $env:AZCOPY_CONCURRENCY_VALUE = "AUTO"
            .\azcopy.exe cp $FileShareSasUri $BlobContainerSasUri --from-to=FileBlob --s2s-preserve-access-tier=false --check-length=true --recursive --log-level=INFO
            $env:AZCOPY_CONCURRENCY_VALUE = ""

        }
        catch {
            Write-Error -Message "Error occurred: $($_.Exception.Message)"
        }
    }
    
    end {
        Remove-PSDrive -Name $DriveLetter
    }
}

Copy-AzureFilesToBlobContainer -Release $Release
