
Set-StrictMode -Version Latest

#region Azure DevOps REST API

function Invoke-AdoApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method = 'GET',

        [object]$Body,

        [string]$Token = $env:SYSTEM_ACCESSTOKEN
    )

    $ErrorActionPreference = 'Stop'

    #region Authentication

    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw (
            'Missing SYSTEM_ACCESSTOKEN. ' +
            'Provide an Azure DevOps job token or a scoped PAT for local testing.'
        )
    }

    $headers = @{
        Authorization = "Bearer $Token"
        Accept        = 'application/json'
    }

    # Local development can use a PAT with Basic authentication.
    # Never write authentication tokens to logs or pipeline output.

    if ($env:ADO_AUTH_MODE -eq 'PAT') {

        $credentials = ':' + $Token

        $encodedCredentials = [Convert]::ToBase64String(
            [Text.Encoding]::ASCII.GetBytes($credentials)
        )

        $headers.Authorization = "Basic $encodedCredentials"
    }

    #endregion

    #region Request Configuration

    $requestParameters = @{
        Uri                     = $Uri
        Method                  = $Method
        Headers                 = $headers
        ErrorAction             = 'Stop'
        TimeoutSec              = 60
        ResponseHeadersVariable = 'responseHeaders'
    }

    if ($PSBoundParameters.ContainsKey('Body')) {

        $requestParameters.Body = $Body |
            ConvertTo-Json -Depth 20 -Compress

        $requestParameters.ContentType = 'application/json'
    }

    #endregion

    #region Request Execution and Retry

    $maximumAttempts = 4

    for ($attempt = 0; $attempt -lt $maximumAttempts; $attempt++) {

        try {

            $response = Invoke-RestMethod @requestParameters

            return [pscustomobject]@{
                Data    = $response
                Headers = $responseHeaders
            }
        }
        catch {

            $statusCode = 0

            try {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            catch {
                # Some transport failures do not have an HTTP response.
            }

            $isTransientFailure = $statusCode -in @(
                429, # Too Many Requests
                500, # Internal Server Error
                502, # Bad Gateway
                503, # Service Unavailable
                504  # Gateway Timeout
            )

            $isFinalAttempt = $attempt -eq ($maximumAttempts - 1)

            if ($isFinalAttempt -or -not $isTransientFailure) {
                throw
            }

            # Exponential backoff:
            # Attempt 1 -> 2 seconds
            # Attempt 2 -> 4 seconds
            # Attempt 3 -> 8 seconds

            $retryDelay = [math]::Pow(2, $attempt + 1)

            Write-Verbose (
                "Azure DevOps API returned HTTP $statusCode. " +
                "Retrying in $retryDelay second(s)."
            )

            Start-Sleep -Seconds $retryDelay
        }
    }

    #endregion
}

#endregion

#region Azure DevOps Pagination

function Get-AdoPaged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [ValidateNotNullOrEmpty()]
        [string]$Property = 'value',

        [string]$Token = $env:SYSTEM_ACCESSTOKEN
    )

    $ErrorActionPreference = 'Stop'

    #region Initialization

    $results = [System.Collections.Generic.List[object]]::new()

    $continuationToken = $null

    #endregion

    #region Page Retrieval

    do {

        $requestUrl = $Uri

        if (-not [string]::IsNullOrWhiteSpace($continuationToken)) {

            $encodedToken = [uri]::EscapeDataString(
                $continuationToken
            )

            $requestUrl += "&continuationToken=$encodedToken"
        }

        Write-Verbose "Retrieving Azure DevOps API page."

        $response = Invoke-AdoApi `
            -Uri $requestUrl `
            -Token $Token

        # Append returned items to the combined result collection.

        $pageItems = @($response.Data.$Property)

        foreach ($item in $pageItems) {

            if ($null -ne $item) {
                $results.Add($item)
            }
        }

        # Azure DevOps commonly supplies continuation tokens
        # through the x-ms-continuationtoken response header.

        $continuationToken = $null

        foreach ($headerName in @($response.Headers.Keys)) {

            if ($headerName -ieq 'x-ms-continuationtoken') {

                $continuationToken = [string]@(
                    $response.Headers[$headerName]
                )[0]

                break
            }
        }

    } while (-not [string]::IsNullOrWhiteSpace($continuationToken))

    #endregion

    #region Results

    Write-Verbose "Retrieved $($results.Count) total item(s)."

    return $results.ToArray()

    #endregion
}

#endregion

Export-ModuleMember -Function @(
    'Invoke-AdoApi'
    'Get-AdoPaged'
)
