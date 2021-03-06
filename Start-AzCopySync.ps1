Function Start-AzCopySync
{
    <#
    .SYNOPSIS
        Starts the AzCopy syncronziation between storage accounts.

    .DESCRIPTION
        Syncronizes storage account containers between storage accounts. Supports syncronizing data of storage accounts in different subscriptions.  Using the switch parameter DeleteDestination will
        specificy if the destination files should be deleted if the source files were changed.  The SAS token expiration time is set for 1 hour.  If syncronization process will take longer than one hour
        it should be updated accordingly.

    .PARAMETER SourceSubscriptionName
        Specify the name of the source subscription.

    .PARAMETER DestSubscriptionName
        Specify the name of the destination subscription.

    .PARAMETER SourceStorageAccountName
        Specify the source storage account name.

    .PARAMETER SourceContainerName
        Specify the source container to syncronize.

    .PARAMETER SourceStorageAccountRG
        Specify the resource group where the source storage account resides.

    .PARAMETER DestStorageAccountName
        Specify the destination storage account name.

    .PARAMETER DestContainerName
        Specify the destination storage container name

    .PARAMETER DestStorageAccountRG
        Specify the resource group where the destination storage account resides.

    .PARAMETER DeleteDestination
        Switch to inform if destination should files should be delete/updated if the source files were modifieid.

    .EXAMPLE
        PS C:\> Start-AzCopySync -SourceSubscriptionName 'SourceSub' -DestSubscriptionName 'DestSub' `
                -SourceStorageAccountName 'sourceSA' -SourceStorageAccountRG 'sourceRG' -SourceContainerName 'sourceContainer' `
                -DestStorageAccountName 'destSA' -DestStorageAccountRG 'destRG' -DestContainerName 'destContainer' -DeleteDestination
        Starts the AzCopy syncronization process between two storage account containers.
    #>
    [CmdletBinding()]
    Param
    (
        [Parameter(ParameterSetName = 'Subscription', HelpMessage="Specify the name of the subscription.")]
        [string]
        $SourceSubscriptionName,

        [Parameter(ParameterSetName = 'Subscription', HelpMessage="Specify the name of the subscription.")]
        [string]
        $DestSubscriptionName,

        [Parameter(Mandatory=$true, HelpMessage="Specify the source storage account name.")]
        [string]
        $SourceStorageAccountName,

        [Parameter(Mandatory=$true, HelpMessage="Specify the source storage container name.")]
        [string]
        $SourceContainerName,

        [Parameter(Mandatory=$true, HelpMessage="Specify the source storage account resource group name.")]
        [string]
        $SourceStorageAccountRG,

        [Parameter(Mandatory=$true, HelpMessage="Specify the destination storage account name.")]
        [string]
        $DestStorageAccountName,

        [Parameter(Mandatory=$true, HelpMessage="Specify the destination storage account resource group name.")]
        [string]
        $DestStorageAccountRG,

        [Parameter(Mandatory=$true, HelpMessage="Specify the destination storage container name.")]
        [string]
        $DestContainerName,

        [Parameter(HelpMessage="Deletes the files/folders in destination if there don't exist in source.")]
        [switch]
        $DeleteDestination
    )
    Process
    {
        Function Get-SASUri
        {
            <#
            .SYNOPSIS
                Creates a SASuri for a storage account container.

            .DESCRIPTION
                Syncronizes storage account containers between storage accounts. Supports syncronizing data of storage accounts in different subscriptions.  Using the switch parameter DeleteDestination will
                specificy if the destination files should be deleted if the source files were changed.  The SAS token expiration time is set for 1 hour.  If syncronization process will take longer than one hour
                it should be updated accordingly.

            .PARAMETER StorageAccountName
                The name of the storage account.

            .PARAMETER ResourceGroupName
                The resource group where the storage account resides.

            .PARAMETER ContainerName
                The container name on the storage account
            #>
            [CmdletBinding()]
            param
            (
                [Parameter(Mandatory=$true, HelpMessage="Specify the storage account name.")]
                [string]
                $StorageAccountName,

                [Parameter(Mandatory=$true, HelpMessage="Specify the resource group name.")]
                [string]
                $ResourceGroupName,

                [Parameter(Mandatory=$true, HelpMessage="Specify the container name.")]
                [string]
                $ContainerName
            )
            Process
            {
                $StorageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -AccountName $StorageAccountName).Value[0]
                $Context = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey
                $SASURI = New-AzStorageContainerSASToken -Context $Context -ExpiryTime(get-date).AddHours(1) -FullUri -Name $ContainerName -Permission rwld

                Write-Output $SasUri
            }
        }

        if ($PSCmdlet.ParameterSetName -eq 'Subscription')
        {
            Write-Output "Setting Azure Context to $SourceSubscriptionName"
            $null = Set-AzContext -Subscription $SourceSubscriptionName -ErrorAction Stop
            $SourceSasUri = Get-SASUri -ResourceGroupName $SourceStorageAccountRG -StorageAccountName $SourceStorageAccountName -ContainerName $SourceContainerName -ErrorAction Stop

            Write-Output "Setting Azure Context to $DestSubscriptionName"
            $null = Set-AzContext -Subscription $DestSubscriptionName -ErrorAction Stop
            $DestSasUri = Get-SASUri -ResourceGroupName $DestStorageAccountRG -StorageAccountName $DestStorageAccountName -ContainerName $DestContainerName -ErrorAction Stop
        }
        else
        {
            $SourceSasUri = Get-SASUri -ResourceGroupName $SourceStorageAccountRG -StorageAccountName $SourceStorageAccountName -ContainerName $SourceContainerName -ErrorAction Stop
            $DestSasUri = Get-SASUri -ResourceGroupName $DestStorageAccountRG -StorageAccountName $DestStorageAccountName -ContainerName $DestSContainerName -ErrorAction Stop
        }

        if ($deleteDestination)
        {
            Write-Output "Starting AzCopy syncronization and will delete destiation if files were upated/deleted in source"
            .\azcopy.exe sync $sourceSASUri $destSASUri --delete-destination=true
        }
        else
        {
            Write-Output "Starting AzCopy syncronization and will NOT delete destiation if files were upated/deleted in source"
            .\azcopy.exe sync $sourceSASUri $destSASUri --delete-destination=false
        }
    }
}
