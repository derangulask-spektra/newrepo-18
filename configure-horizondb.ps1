<#
=============================================================================
 configure-horizondb.ps1
-----------------------------------------------------------------------------
 CloudLabs equivalent of the Skillable lifecycle scripts
 5_set_firewall_rules.ps1 and 5b_set_parameter_group.ps1.

 Runs on the lab VM from psscript.ps1 (CustomScriptExtension), AFTER the ARM
 template has already created:
   - Microsoft.HorizonDb/clusters/<clusterName>
   - Microsoft.HorizonDb/parameterGroups/<parameterGroupName>

 This script:
   1. Signs in to Azure with the CloudLabs ODL user credentials.
   2. Waits for the HorizonDB cluster to reach a terminal provisioning state.
   3. Resolves the authoritative cluster FQDN (never guessed).
   4. Attaches the parameter group to the cluster and polls until InSync.
   5. Creates the firewall rules the lab needs.
   6. Writes C:\LabFiles\horizondb-config.json for psscript.ps1 to consume.

 NOTE: the parameter group content itself is declared in the ARM template.
       Only the attach + firewall are imperative, because both are
       post-create operations on a preview resource provider.
=============================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $AzureUserName,
    [Parameter(Mandatory = $true)][string] $AzurePassword,
    [Parameter(Mandatory = $true)][string] $AzureTenantID,
    [Parameter(Mandatory = $true)][string] $AzureSubscriptionID,
    [Parameter(Mandatory = $true)][string] $ResourceGroupName,
    [Parameter(Mandatory = $true)][string] $ClusterName,
    [Parameter(Mandatory = $true)][string] $ParameterGroupName,
    [Parameter(Mandatory = $false)][string] $PgHostFallback = '',
    [Parameter(Mandatory = $false)][string] $LabVmPublicIp = '',
    [Parameter(Mandatory = $false)][string] $HorizonApiVersion = '2026-01-20-preview',
    [Parameter(Mandatory = $false)][string] $OutputFile = 'C:\LabFiles\horizondb-config.json'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------- Logging ----------------------------------------------------------
$logDir = 'C:\Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ("configure_horizondb_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function Write-Log {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Message
    $line | Out-File -FilePath $logFile -Append -Encoding UTF8
    Write-Output $line
}

function Write-ErrorBody {
    param($ErrorRecord)
    Write-Log "  !! $($ErrorRecord.Exception.Message)"
    if ($null -ne $ErrorRecord.Exception.Response) {
        try {
            $reader = New-Object System.IO.StreamReader($ErrorRecord.Exception.Response.GetResponseStream())
            Write-Log "  Response body: $($reader.ReadToEnd())"
        } catch { }
    }
}

Write-Log "==== configure-horizondb start ===="
Write-Log "Subscription:    $AzureSubscriptionID"
Write-Log "Resource group:  $ResourceGroupName"
Write-Log "Cluster:         $ClusterName"
Write-Log "Parameter group: $ParameterGroupName"

# ================== Acquire an ARM access token ==============================
# CloudLabs injects an ODL user (no MFA), so ROPC via the Azure CLI is the
# most reliable auth path on the lab VM. Az PowerShell is used as a fallback.
function Test-JwtLooksValid {
    param([string]$Token)
    # A real JWT is three base64url segments separated by dots. This is a
    # structural sanity check only — it does not verify the signature — but
    # it's enough to catch a malformed/empty/garbage token before spending
    # 30 minutes retrying ARM calls with something that was never going to work.
    if (-not $Token) { return $false }
    return ($Token -split '\.').Count -eq 3
}

function Write-JwtClaims {
    param([string]$Token, [string]$Label)
    # Decode (not verify) the middle JWT segment so we can log WHO the token
    # was actually issued to (upn/appid, tid, aud) without ever logging the
    # token itself. This is the fastest way to catch "connected as the wrong
    # identity" or "token for the wrong resource" without another 30-minute
    # round trip.
    try {
        $parts = $Token -split '\.'
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        $claims = $json | ConvertFrom-Json
        Write-Log "  [$Label] aud=$($claims.aud) tid=$($claims.tid) upn=$($claims.upn) appid=$($claims.appid) exp=$($claims.exp)"
    } catch {
        Write-Log "  [$Label] Could not decode token claims for diagnostics: $($_.Exception.Message)"
    }
}

function Get-ArmToken {
    Write-Log "Signing in to Azure as $AzureUserName ..."

    $token = $null
    try {
        # Disable the WAM broker before attempting ROPC sign-in. Under the
        # SYSTEM context the CustomScriptExtension runs as, there is no
        # interactive logon session for WAM to attach to, which otherwise
        # fails with "A specified logon session does not exist."
        az config set core.enable_broker_on_windows=false --only-show-errors 2>&1 | Out-Null
        az login --username $AzureUserName --password $AzurePassword --tenant $AzureTenantID --only-show-errors 2>&1 |
            Out-Null
        az account set --subscription $AzureSubscriptionID --only-show-errors 2>&1 | Out-Null
        $raw = az account get-access-token --resource "https://management.azure.com" --output json --only-show-errors
        if ($raw) { $token = ($raw | ConvertFrom-Json).accessToken }
        if ($token) { Write-Log "az CLI sign-in succeeded." }
    } catch {
        Write-Log "az CLI sign-in failed: $($_.Exception.Message)"
    }

    if ($token -and -not (Test-JwtLooksValid $token)) {
        Write-Log "az CLI returned a token that doesn't look like a valid JWT; discarding it."
        $token = $null
    }
    if ($token) { Write-JwtClaims -Token $token -Label 'az CLI' }

    if (-not $token) {
        Write-Log "Falling back to Az PowerShell sign-in..."
        # Clear any pre-existing Az context in this session first. psscript.ps1
        # runs earlier setup (CreateCredFile, etc.) in the SAME PowerShell
        # process before invoking this script via the call operator, so a
        # stale or different context could otherwise be picked up silently by
        # Get-AzAccessToken instead of the one we're about to establish.
        try { Clear-AzContext -Force -ErrorAction SilentlyContinue | Out-Null } catch { }

        $secure = ConvertTo-SecureString $AzurePassword -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential ($AzureUserName, $secure)
        Connect-AzAccount -Credential $cred -Tenant $AzureTenantID -Subscription $AzureSubscriptionID -Force -ErrorAction Stop | Out-Null

        $ctx = Get-AzContext
        Write-Log "  Az context after connect: Account=$($ctx.Account.Id) Tenant=$($ctx.Tenant.Id) Subscription=$($ctx.Subscription.Id)"

        $t = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
        if ($t.Token -is [System.Security.SecureString]) {
            $token = [System.Net.NetworkCredential]::new('', $t.Token).Password
        } else {
            $token = $t.Token
        }

        if ($token -and -not (Test-JwtLooksValid $token)) {
            Write-Log "  Az PowerShell returned a token that doesn't look like a valid JWT."
            Write-Log "  Raw token type: $($t.Token.GetType().FullName), length: $($token.Length)"
            $token = $null
        }
        if ($token) { Write-JwtClaims -Token $token -Label 'Az PowerShell' }
    }

    if (-not $token) { throw "Could not obtain a valid ARM access token by any method." }
    Write-Log "ARM token acquired and passed structural validation."
    return $token
}

$armToken = Get-ArmToken
$headers = @{
    "Authorization" = "Bearer $armToken"
    "Content-Type"  = "application/json"
}

# Fail fast rather than retrying a broken token for the full 30-minute
# timeout: do one cheap authenticated call up front (list resource groups in
# this subscription) and confirm it's not a 401/403 before entering the long
# poll loops below.
try {
    $probeUri = "https://management.azure.com/subscriptions/$AzureSubscriptionID/resourcegroups?api-version=2021-04-01&`$top=1"
    Invoke-RestMethod -Uri $probeUri -Headers $headers -Method Get | Out-Null
    Write-Log "Token probe succeeded — proceeding."
} catch {
    Write-ErrorBody $_
    throw "Token probe failed — the ARM token is being rejected (see response body above). Not retrying for 30 minutes with a token that doesn't work. Check the identity/claims logged above against the expected ODL user and subscription."
}

$clusterUri = "https://management.azure.com/subscriptions/$AzureSubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.HorizonDb/clusters/$ClusterName`?api-version=$HorizonApiVersion"
$parameterGroupId = "/subscriptions/$AzureSubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.HorizonDb/parameterGroups/$ParameterGroupName"
$pgUri = "https://management.azure.com$parameterGroupId`?api-version=$HorizonApiVersion"

$maxWaitSec  = 1800
$intervalSec = 20

# ================== Wait for the cluster to be ready =========================
Write-Log "Waiting for cluster provisioning to complete..."
$elapsed = 0
$cluster = $null
while ($elapsed -lt $maxWaitSec) {
    try {
        $cluster = Invoke-RestMethod -Uri $clusterUri -Headers $headers -Method Get
        $state = $cluster.properties.provisioningState
        Write-Log "  Cluster provisioningState: $state (elapsed ${elapsed}s)"
        if ($state -eq 'Succeeded') { break }
        if ($state -in @('Failed','Canceled')) { throw "Cluster reached terminal state '$state'." }
    } catch {
        Write-Log "  GET cluster failed (will retry): $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $intervalSec
    $elapsed += $intervalSec
}
if (-not $cluster -or $cluster.properties.provisioningState -ne 'Succeeded') {
    throw "HorizonDB cluster '$ClusterName' did not reach Succeeded within $maxWaitSec seconds."
}

# ================== Resolve the authoritative FQDN ===========================
$resolvedHost = $null
foreach ($prop in @('fullyQualifiedDomainName','primaryEndpoint','endpoint','hostname')) {
    if ($cluster.properties.PSObject.Properties.Name -contains $prop -and $cluster.properties.$prop) {
        $resolvedHost = $cluster.properties.$prop
        Write-Log "Resolved cluster host from properties.$prop = $resolvedHost"
        break
    }
}
if (-not $resolvedHost) {
    $resolvedHost = $PgHostFallback
    Write-Log "Cluster host not present on the resource; using fallback: $resolvedHost"
}
if (-not $resolvedHost) { throw "Could not determine the HorizonDB host name." }

# Some API versions return the endpoint with a scheme or port; strip both.
$resolvedHost = $resolvedHost -replace '^[a-z]+://', ''
$resolvedHost = ($resolvedHost -split ':')[0].TrimEnd('/')
Write-Log "HorizonDB host: $resolvedHost"

# ================== Wait for the parameter group =============================
Write-Log "Waiting for parameter group '$ParameterGroupName' to be ready..."
$elapsed = 0
$pgState = ''
while ($elapsed -lt $maxWaitSec) {
    try {
        $pgGet = Invoke-RestMethod -Uri $pgUri -Headers $headers -Method Get
        $pgState = $pgGet.properties.provisioningState
        Write-Log "  Parameter group state: $pgState (elapsed ${elapsed}s)"
        if ($pgState -eq 'Succeeded') { break }
        if ($pgState -in @('Failed','Canceled')) { throw "Parameter group reached terminal state '$pgState'." }
    } catch {
        Write-Log "  GET parameter group failed (will retry): $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $intervalSec
    $elapsed += $intervalSec
}
if ($pgState -ne 'Succeeded') {
    throw "Parameter group '$ParameterGroupName' did not reach Succeeded (last state: '$pgState')."
}

# ================== Attach the parameter group to the cluster ================
Write-Log "Attaching parameter group to cluster $ClusterName ..."
$attachBody = @{
    properties = @{
        parameterGroup = @{
            id               = $parameterGroupId
            applyImmediately = $true
        }
    }
} | ConvertTo-Json -Depth 8

$attachAttempts = 0
$attached = $false
while (-not $attached -and $attachAttempts -lt 5) {
    $attachAttempts++
    try {
        $patch = Invoke-WebRequest -Method PATCH -Uri $clusterUri -Headers $headers -Body $attachBody -UseBasicParsing
        Write-Log "  -> PATCH submitted (attempt $attachAttempts). HTTP $($patch.StatusCode)"
        $attached = $true
    } catch {
        Write-ErrorBody $_
        if ($attachAttempts -ge 5) { throw "Failed to attach the parameter group after $attachAttempts attempts." }
        Start-Sleep -Seconds 30
    }
}

# ================== Poll until the cluster reports InSync ====================
Write-Log "Waiting for parameterGroup.syncStatus = InSync ..."
$elapsed = 0
$syncStatus = ''
$clusterState = ''
while ($elapsed -lt $maxWaitSec) {
    Start-Sleep -Seconds $intervalSec
    $elapsed += $intervalSec
    try {
        $clusterGet   = Invoke-RestMethod -Uri $clusterUri -Headers $headers -Method Get
        $clusterState = $clusterGet.properties.provisioningState
        $syncStatus   = $clusterGet.properties.parameterGroup.syncStatus
        Write-Log "  provisioningState: $clusterState | syncStatus: $syncStatus (elapsed ${elapsed}s)"
        if ($syncStatus -eq 'InSync') { break }
        if ($clusterState -in @('Failed','Canceled')) { break }
    } catch {
        Write-Log "  GET cluster failed (will retry): $($_.Exception.Message)"
    }
}
if ($syncStatus -ne 'InSync') {
    throw "Parameter group did not reach InSync (last syncStatus '$syncStatus', provisioningState '$clusterState')."
}
Write-Log "Parameter group is InSync."

# ================== Firewall rules ===========================================
# The firewall rule resource is nested under a compute pool, not the cluster
# directly: .../clusters/{clusterName}/pools/{poolName}/firewallRules/{name}.
#
# Microsoft's own quickstart doc contains a CONFLICTING example: an `az rest`
# snippet whose URL omits the cluster segment entirely
# (.../providers/Microsoft.HorizonDB/pools/DefaultPool/firewallRules/{name}).
# Do not "fix" this script to match that snippet. It is contradicted by:
#   1. The "Important: not supported via CLI extension" note printed directly
#      above that exact snippet in the same doc.
#   2. The doc's OWN `az horizondb firewall-rule create --cluster-name ...`
#      troubleshooting example, which requires a cluster name for the same
#      operation.
#   3. The Go SDK (generated from the real swagger spec, not prose):
#      FirewallRulesClient.BeginCreateOrUpdate(resourceGroupName, clusterName,
#      poolName, firewallRuleName, ...) and PoolsClient.Get(resourceGroupName,
#      clusterName, poolName, ...) — pools are NEVER a top-level resource,
#      only ever nested under a cluster.
# Three independent, mutually-corroborating sources vs. one snippet that
# contradicts its own page. The nested URL below is correct.
$poolsUri = "https://management.azure.com/subscriptions/$AzureSubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.HorizonDb/clusters/$ClusterName/pools?api-version=$HorizonApiVersion"
$poolName = 'DefaultPool'
try {
    $poolsResp = Invoke-RestMethod -Uri $poolsUri -Headers $headers -Method Get
    if ($poolsResp.value -and $poolsResp.value.Count -gt 0) {
        $poolName = $poolsResp.value[0].name
        Write-Log "Resolved pool name from Pools API: $poolName"
    } else {
        Write-Log "Pools list returned no items; using fallback pool name: $poolName"
    }
} catch {
    Write-Log "  GET pools failed; using fallback pool name '$poolName': $($_.Exception.Message)"
}

$fwBaseUri = "https://management.azure.com/subscriptions/$AzureSubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.HorizonDb/clusters/$ClusterName/pools/$poolName/firewallRules"

function Set-HorizonFirewallRule {
    param([string]$RuleName, [string]$StartIp, [string]$EndIp, [string]$Description)

    Write-Log "Creating firewall rule: $RuleName ($StartIp - $EndIp)"
    $body = @{
        properties = @{
            startIpAddress = $StartIp
            endIpAddress   = $EndIp
            description    = $Description
        }
    } | ConvertTo-Json -Depth 5

    $uri = "$fwBaseUri/$RuleName`?api-version=$HorizonApiVersion"
    for ($i = 1; $i -le 3; $i++) {
        try {
            $resp = Invoke-RestMethod -Method PUT -Uri $uri -Headers $headers -Body $body
            Write-Log "  -> Submitted. Provisioning state: $($resp.properties.provisioningState)"
            return
        } catch {
            Write-ErrorBody $_
            if ($i -eq 3) { throw "Failed to create firewall rule '$RuleName'." }
            Start-Sleep -Seconds 20
        }
    }
}

# Allow Azure services (0.0.0.0/0.0.0.0 is the documented "Azure services" rule).
# This only permits calls from other Azure-internal services/control plane —
# it does NOT open the cluster to the internet.
Set-HorizonFirewallRule -RuleName 'AllowAzureServices' -StartIp '0.0.0.0' -EndIp '0.0.0.0' `
    -Description 'Allow Azure services'

# Allow the lab VM specifically, by its exact IP.
# Source: the Standard SKU public IP address ARM assigned to the VM's NIC,
# passed in from the template output "LabVM Public IP". This is the actual
# source IP HorizonDB will see (Standard public IPs attached directly to a
# NIC, with no load balancer in front, SNAT outbound traffic to that same
# address), so it is both accurate and stable for the life of the lab.
#
# This is now the ONLY rule that grants the lab VM database access — there
# is no 0.0.0.0-255.255.255.255 catch-all. If this step fails, the lab
# environment must not report itself as ready, so failure here throws.
$labVmIp = $null
if ($LabVmPublicIp) {
    $labVmIp = $LabVmPublicIp.Trim()
    Write-Log "Lab VM public IP (from ARM output): $labVmIp"
} else {
    Write-Log "No -LabVmPublicIp supplied; falling back to a runtime IP lookup."
    try {
        $labVmIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 30).ip
        Write-Log "Lab VM public IP (from runtime lookup): $labVmIp"
    } catch {
        Write-Log "Could not determine the lab VM public IP: $($_.Exception.Message)"
    }
}
if (-not $labVmIp) {
    throw "Could not determine the lab VM's public IP by any method. Cannot create the AllowLabVM firewall rule, and there is no catch-all rule to fall back on."
}
Set-HorizonFirewallRule -RuleName 'AllowLabVM' -StartIp $labVmIp -EndIp $labVmIp `
    -Description 'Allow the CloudLabs lab VM'

# ================== Emit config for psscript.ps1 =============================
$outDir = Split-Path -Parent $OutputFile
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

[pscustomobject]@{
    clusterName        = $ClusterName
    pgHost             = $resolvedHost
    poolName           = $poolName
    parameterGroupName = $ParameterGroupName
    syncStatus         = $syncStatus
    labVmPublicIp      = $labVmIp
    configuredAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputFile -Encoding UTF8 -Force

Write-Log "Wrote $OutputFile"
Write-Log "==== configure-horizondb complete ===="
