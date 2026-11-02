
Set-StrictMode -Version Latest

#region Lifecycle Notifications

function Send-LifecycleNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Config,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Payload
    )

    $ErrorActionPreference = 'Stop'

    #region Webhook Configuration

    # Retrieve the webhook endpoint from the environment.
    #
    # The receiver may be a Teams workflow or another
    # HTTP endpoint capable of accepting JSON payloads.
    #
    # Store the webhook URL as a secret pipeline variable.
    # Never hardcode webhook URLs in source control.

    $webhookUrl = $env:BRANCH_LIFECYCLE_WEBHOOK

    if ([string]::IsNullOrWhiteSpace($webhookUrl)) {

        Write-Warning (
            'Branch lifecycle webhook is not configured. ' +
            'Notification was not delivered.'
        )

        return $false
    }

    #endregion

    #region Payload Serialization

    # Serialize the notification envelope as JSON.
    #
    # Expected payload:
    # {
    #     organization = "Example Organization"
    #     generatedAt  = "2026-10-31T..."
    #     events       = @( ... )
    # }

    try {

        $jsonPayload = $Payload |
            ConvertTo-Json -Depth 12 -ErrorAction Stop
    }
    catch {

        throw (
            'Failed to serialize branch lifecycle notification: ' +
            $_.Exception.Message
        )
    }

    #endregion

    #region Notification Delivery

    Write-Verbose 'Sending branch lifecycle notification.'

    try {

        Invoke-RestMethod `
            -Uri $webhookUrl `
            -Method Post `
            -ContentType 'application/json' `
            -Body $jsonPayload `
            -TimeoutSec 30 `
            -ErrorAction Stop |
            Out-Null
    }
    catch {

        # Notification failures must propagate to the caller.
        # The orchestration layer uses these failures to
        # prevent branch deletion.

        throw (
            'Branch lifecycle notification delivery failed: ' +
            $_.Exception.Message
        )
    }

    #endregion

    #region Delivery Result

    Write-Verbose 'Branch lifecycle webhook request completed successfully.'

    return $true

    #endregion
}

#endregion

Export-ModuleMember -Function Send-LifecycleNotification
