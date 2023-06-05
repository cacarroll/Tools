param (
    $Release = '2Q23'
)

function Set-AzSubscription {
    param (
        [Parameter(Mandatory)]
        [string]$SubscriptionId
    )

    try {
        az account set --subscription $SubscriptionId
        Write-Output "Successfully set subscription to: $SubscriptionId"
    }
    catch {
        Write-Error "Failed to set subscription to: $SubscriptionId. Error: $($_.Exception.Message)"
        throw
    }
}


function Map-Drive {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory)]
        [string]$StorageAccountName,
        [Parameter(Mandatory)]
        [string]$ShareName,
        [string]$DriveLetter
    )
    
    try {
        Write-Verbose "Attempting connection to storage account: $StorageAccountName and RG: $ResourceGroupName"

        $StorageAccountKey = $(az storage account keys list -g $ResourceGroupName -n $StorageAccountName --query "[0].value" --output tsv)

        $FileShareEndpoint = $(az storage account show --name $StorageAccountName --query "primaryEndpoints.file" --output tsv).Split('/')[2]
        $UNCPath = "\\$FileShareEndpoint\$ShareName"

        if (Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue) {
            Remove-PSDrive -Name $DriveLetter -Force
        }

        $ConnectTestResult = Test-NetConnection -ComputerName $FileShareEndpoint -Port 445
        if ($ConnectTestResult.TcpTestSucceeded) {
            # Save the password so the drive will persist on reboot
            cmd.exe /C "cmdkey /add:`"$FileShareEndpoint`" /user:`"localhost\$StorageAccountName`" /pass:`"$StorageAccountKey`""
            # Mount the drive
            New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $UNCPath -Persist -Scope Global
        }
        else {
            throw "Unable to reach the Azure storage account via port 445. Check to make sure your organization or ISP is not blocking port 445, or use Azure P2S VPN, Azure S2S VPN, or Express Route to tunnel SMB traffic over a different port."
        }
    }
    catch {
        Write-Error "Error occurred while mapping drive: $_"
        throw
    }
}


function Get-FileShareSASUri {
    [CmdletBinding()]
    param (
        $StorageAccountName,
        $ShareName
    )
    
    try {
        $Expiry = (Get-Date).AddDays(1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

        $StorageKey = $(az storage account keys list --account-name $StorageAccountName --query "[?keyName=='key1'].value" --output tsv)
        
        $SasToken = $(az storage share generate-sas -n $ShareName --account-name $StorageAccountName --account-key $StorageKey --https-only --permissions dlrw --expiry $Expiry -o tsv)

        $FileShareEndpoint = $(az storage account show --name $StorageAccountName --query "primaryEndpoints.file" --output tsv)

        $FileShareSasUri = "$FileShareEndpoint$ShareName/?$SasToken"

        return $FileShareSasUri
    }
    catch {
        Write-Error "Error occurred while generating File Share SAS URI: $_"
        throw
    }
}

function Get-BlobContainerSASUri {
    [CmdletBinding()]
    param (
        $StorageAccountName,
        $ContainerName
    )

    $Expiry = (Get-Date).AddDays(1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    $StorageKey = $(az storage account keys list --account-name $StorageAccountName --query "[0].value" --output tsv)
    
    $SasToken = $(az storage container generate-sas --account-name $StorageAccountName --account-key $StorageKey --name $ContainerName --permissions rwl --expiry $Expiry --output tsv)

    $BlobEndpoint = $(az storage account show --name $StorageAccountName --query "primaryEndpoints.blob" --output tsv)

    $BlobContainerSasUri = "$BlobEndpoint$ContainerName/?$SasToken"

    return $BlobContainerSasUri
}


function Get-EmptyFolder {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    $folder = [System.IO.DirectoryInfo]::new($Path)

    if ($folder.GetFiles("*", [System.IO.SearchOption]::TopDirectoryOnly).Count -eq 0 -and
        $folder.GetDirectories().Count -eq 0) {
        $pathSplit = $folder.FullName.Split("\")
        $emptyFolder = ($pathSplit[3..($pathSplit.Length - 1)] -join "/")
        return $emptyFolder
    }
    return $null
}

function Get-NextAvailableDriveLetter {
    $driveLetters = [char[]]('D'..'Z')
    foreach ($letter in $driveLetters) {
        if (!(Test-Path -Path "$letter`:\")) {
            return $letter
        }
    }
    throw "No available drive letter found."
}

function New-EmptyFile {
    [CmdletBinding()]
    param (
        $StorageAccountName,
        $ResourceGroupName,
        $EmptyFolders,
        $ShareName
    )

    $ShareName = $ShareName.Replace("\","/")
    $ConnectionString = $(az storage account show-connection-string --name $StorageAccountName --resource-group $ResourceGroupName -o tsv)

    New-Item -Path $env:TEMP -Name empty.txt -Force | Out-Null

    foreach ($EmptyFolder in $EmptyFolders) {
        $path = $EmptyFolder.replace("\","/")
        Write-Output "Creating empty.txt on $StorageAccountName/$ShareName/$path"
        az storage blob upload-batch --destination "$ShareName/$EmptyFolder" --source $env:TEMP --pattern "empty.txt" --account-name $StorageAccountName --connection-string $ConnectionString
    }

    Remove-Item "$env:TEMP\empty.txt"
}


Write-Host "`n************ Start copy from Azure File Share to Azure Blob Container *******************" -ForegroundColor Cyan

# Convert Release Date to New Format
$quarter, $year = $Release -split 'Q'
$newReleaseFormat = "FY20$year\$quarter" + 'Q'

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
        StorageAccountName  = 'releasestorage01'
        ResourceGroupName   = 'MNR-Storage-RG'
        BlobContainerName   = 'otm'
        FolderMapping = @{
            "Released\$Release" = $newReleaseFormat
        }
    }
}

try {
    Set-AzSubscription -SubscriptionId $StorageMapping.Source.SubscriptionId

    # Map a local drive to the file share UNC
    $DriveLetter = Get-NextAvailableDriveLetter

    Map-Drive -ResourceGroupName $StorageMapping.Source.ResourceGroupName -StorageAccountName $StorageMapping.Source.StorageAccountName -ShareName $StorageMapping.Source.FileShareName -DriveLetter $DriveLetter

    $folder = $driveLetter + ":\" + $StorageMapping.Source.Folder
    Write-Output "`n`nRetrieving parent folders on $folder. Please be patient..."
    # $root = [System.IO.DirectoryInfo]::new($folder)
    # $folders = $root.GetDirectories("*", [System.IO.SearchOption]::AllDirectories)

    # $emptyFolders = @()
    # $totalFolders = $folders.Count
    # $currentFolder = 0

    # foreach ($subfolder in $folders) {
    #     $currentFolder++
    #     Write-Output "`nScanning $($subfolder.FullName) for emptiness"
    #     Write-Progress -Activity "Scanning" -Status "Processing folder $currentFolder of $totalFolders" -PercentComplete (($currentFolder/$totalFolders)*100)

    #     $result = Get-EmptyFolder -Path $subfolder.FullName
    #     if ($result) {
    #         Write-Output "`nFound empty folder at $($subfolder.FullName)"
    #         $emptyFolders += $result
    #     }
    # }

    #Retreive FileShare SASUri
    $FileShareName = $StorageMapping.Source.FileShareName + "/" + ($StorageMapping.Source.Folder).Replace("\","/")
    $FileShareSasUri = Get-FileShareSASUri -StorageAccountName $StorageMapping.Source.StorageAccountName -ShareName $FileShareName

    #### Destination Processing ####
    Set-AzSubscription -SubscriptionId $StorageMapping.Destination.SubscriptionId
    
    Write-Output "Creating blob container [$DestinationBlobContainer] on storage account $($StorageMapping.Destination.StorageAccountName)"
    $DestinationBlobContainer = $StorageMapping.Destination.BlobContainerName
    $DestinationStorageAccountConnectionString = $(az storage account show-connection-string --name $StorageMapping.Destination.StorageAccountName --resource-group $StorageMapping.Destination.ResourceGroupName -o tsv)
    az storage container create --name $DestinationBlobContainer --account-name $StorageMapping.Destination.StorageAccountName --connection-string $DestinationStorageAccountConnectionString
    
    $path = $StorageMapping.Destination.FolderMapping[$StorageMapping.Source.Folder]
    $BlobShareName = "$DestinationBlobContainer\$path".Replace("\","/")
    # New-EmptyFile -StorageAccountName $StorageMapping.Destination.StorageAccountName -ResourceGroupName $StorageMapping.Destination.ResourceGroupName -EmptyFolders $EmptyFolders -ShareName $BlobShareName
    
    $BlobContainerSasUri = Get-BlobContainerSASUri -StorageAccountName $StorageMapping.Destination.StorageAccountName -ContainerName $BlobShareName

    Write-Output "`nUsing AzCopy to copy files from $FileShareName to $BlobShareName"
    $env:AZCOPY_CONCURRENCY_VALUE = "AUTO"
    .\azcopy.exe cp $FileShareSasUri $BlobContainerSasUri --from-to=FileBlob --s2s-preserve-access-tier=false --check-length=true --recursive --log-level=INFO     
    # $env:AZCOPY_CONCURRENCY_VALUE = ""

    Remove-PSDrive -Name $DriveLetter
}
catch {
    Write-Error -Message "Error occurred: $($_.Exception.Message)"
}