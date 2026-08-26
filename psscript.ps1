Param (
    [Parameter(Mandatory = $true)]
    [string]
    $AzureUserName,

    [string]
    $AzurePassword,

    [string]
    $AzureTenantID,

    [string]
    $AzureSubscriptionID,

    [string]
    $ODLID,

    [string]
    $DeploymentID,

    [string]
    $vmAdminUsername,

    [string]
    $adminPassword,

    [string]
    $trainerUserName,

    [string]
    $trainerUserPassword,

    # ---------- Lab-specific values injected by the ARM template -------------
    [string]
    $resourceGroupName,

    [string]
    $openAiAccountName,

    [string]
    $openAiEndpoint,

    [string]
    $openAiKey,

    [string]
    $openAiDeployment = "gpt-5",

    [string]
    $embedDeployment = "text-embedding-3-small",

    [string]
    $openAiApiVersion = "2025-03-01-preview",

    [string]
    $clusterName,

    [string]
    $pgHostFallback,

    [string]
    $pgUser,

    [string]
    $pgPassword,

    [string]
    $parameterGroupName = "lab",

    [string]
    $labVmPublicIp
)

Start-Transcript -Path C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension.txt -Append
[Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls
[Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls"

# C:\Logs is used throughout this script (pip-freeze.txt below, plus warning
# messages that point support staff there) and is also created independently
# by configure-horizondb.ps1 later in this run. Create it here, up front, so
# nothing that writes to it earlier in the script depends on run order.
New-Item -ItemType Directory -Path 'C:\Logs' -Force | Out-Null

#Import Common Functions
$path = pwd
$path = $path.Path
$commonscriptpath = "$path" + "\cloudlabs-common\cloudlabs-windows-functions.ps1"
. $commonscriptpath

# Run Imported functions from cloudlabs-windows-functions.ps1
WindowsServerCommon
InstallAzPowerShellModule
InstallAzCLI
CloudLabsManualAgent Install

#Installing Modern VM Validator
InstallModernVmValidator

CreateCredFile $AzureUserName $AzurePassword $AzureTenantID $AzureSubscriptionID $DeploymentID

Enable-CloudLabsEmbeddedShadow $vmAdminUsername $trainerUserName $trainerUserPassword

sleep 10

Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Verbose

# =============================================================================
# Machine-level tooling
# =============================================================================

#Install Visual Studio Code
Install-ChocoPackage -PackageName "vscode"

#Install Python 3.11 (lab requires 3.11+)
Install-ChocoPackage -PackageName "python311"

#Install git
Install-ChocoPackage -PackageName "git.install"

# Refresh PATH so python/git/code are resolvable in this session
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')

# =============================================================================
# Download and extract the lab package to C:\Lab
# =============================================================================

$ErrorActionPreference = 'Stop'

$LabRoot = "C:\Lab"
$zipUrl  = "https://experienceazure.blob.core.windows.net/templates/Building-an-Agentic-Legal-Research-Application/assets/Building-Agentic-legal-reasearch-applications.zip"
$zipPath = "C:\Lab\Building-Agentic-legal-research-application.zip"

if (Test-Path $LabRoot) {
    Remove-Item -Path $LabRoot -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $LabRoot -Force | Out-Null

try {
    Write-Host "Downloading lab package..."
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
} catch {
    Write-Error "Download failed: $($_.Exception.Message)"
    exit 1
}

Write-Host "Extracting lab package..."
$tempExtract = Join-Path $LabRoot "__extract_tmp"
Expand-Archive -LiteralPath $zipPath -DestinationPath $tempExtract -Force

$extracted = Get-ChildItem $tempExtract
if ($extracted.Count -eq 1 -and $extracted[0].PSIsContainer) {
    Get-ChildItem -LiteralPath $extracted[0].FullName -Force |
        Move-Item -Destination $LabRoot -Force
} else {
    $extracted | Move-Item -Destination $LabRoot -Force
}

Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue

Write-Host "Lab package ready at $LabRoot"
Get-ChildItem $LabRoot -Force | Select-Object Mode, LastWriteTime, Length, Name | Format-Table -AutoSize

# =============================================================================
# Install Python dependencies from requirements.txt (machine-wide)
# Client feedback #2: the attendee must never run pip install during the lab.
# =============================================================================
$pythonExe = "C:\Python311\python.exe"
if (-not (Test-Path $pythonExe)) { $pythonExe = "python" }

$requirements = Join-Path $LabRoot "requirements.txt"
if (-not (Test-Path $requirements)) {
    Write-Warning "requirements.txt not found at $requirements - skipping dependency install."
} else {
    & $pythonExe -m pip install --upgrade pip
    & $pythonExe -m pip install -r $requirements
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "pip install returned exit code $LASTEXITCODE - retrying once..."
        Start-Sleep -Seconds 15
        & $pythonExe -m pip install -r $requirements
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "pip install failed twice. Attendees may need to re-run it manually."
    }

    # Jupyter kernel so the notebooks open ready-to-run in VS Code
    & $pythonExe -m pip install ipykernel
    & $pythonExe -m ipykernel install --name "lab511" --display-name "Python 3.11 (Lab)" 2>&1 | Out-Null

    # Record what was installed, for support triage
    & $pythonExe -m pip freeze | Out-File -FilePath "C:\Logs\pip-freeze.txt" -Encoding UTF8
}

# =============================================================================
# Configure HorizonDB: attach the parameter group, open the firewall,
# and resolve the authoritative cluster FQDN.
# Client feedback #1: Exercise 1 is now fully build-time.
# =============================================================================
$pgHost = $pgHostFallback
$horizonConfigPath = "C:\LabFiles\horizondb-config.json"

if ($clusterName) {
    try {
        $configureScript = Join-Path $path "configure-horizondb.ps1"
        if (-not (Test-Path $configureScript)) {
            # The CSE unpacks fileUris flat into the working directory for
            # non-Azure-Storage sources (e.g. GitHub raw URLs); fall back to a
            # direct download if the layout ever changes. This download is
            # inside the same try/catch as the script execution below — a
            # failed download here used to throw uncaught and could kill the
            # rest of this script silently, with no log and no warning.
            Write-Host "configure-horizondb.ps1 not found at $configureScript — downloading from GitHub..."
            $configureScript = "C:\LabFiles\configure-horizondb.ps1"
            (New-Object System.Net.WebClient).DownloadFile(
                "https://raw.githubusercontent.com/derangulask-spektra/newrepo-18/refs/heads/main/configure-horizondb.ps1",
                $configureScript)
            Write-Host "Downloaded configure-horizondb.ps1 to $configureScript"
        }

        & $configureScript `
            -AzureUserName $AzureUserName `
            -AzurePassword $AzurePassword `
            -AzureTenantID $AzureTenantID `
            -AzureSubscriptionID $AzureSubscriptionID `
            -ResourceGroupName $resourceGroupName `
            -ClusterName $clusterName `
            -ParameterGroupName $parameterGroupName `
            -PgHostFallback $pgHostFallback `
            -LabVmPublicIp $labVmPublicIp `
            -OutputFile $horizonConfigPath

        if (Test-Path $horizonConfigPath) {
            $horizonConfig = Get-Content $horizonConfigPath -Raw | ConvertFrom-Json
            if ($horizonConfig.pgHost) { $pgHost = $horizonConfig.pgHost }
        }
        Write-Host "[OK] HorizonDB configured. Host: $pgHost" -ForegroundColor Green
    } catch {
        Write-Warning "configure-horizondb.ps1 failed: $($_.Exception.Message)"
        Write-Warning "Continuing so the VM still comes up; see C:\Logs for details."
    }
} else {
    Write-Warning "clusterName was empty — skipping HorizonDB configuration entirely. Check that deploy.json's labSettings variable is actually reaching this script (e.g. via 'az vm extension show' or the CSE transcript at C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension.txt)."
}

# =============================================================================
# Fetch the Azure OpenAI key if the ARM template did not supply one
# =============================================================================
if (-not $openAiKey -and $openAiAccountName) {
    try {
        Write-Host "Fetching Azure OpenAI key via Azure CLI..."
        az login --username $AzureUserName --password $AzurePassword --tenant $AzureTenantID --only-show-errors 2>&1 | Out-Null
        az account set --subscription $AzureSubscriptionID --only-show-errors 2>&1 | Out-Null
        $openAiKey = az cognitiveservices account keys list `
            --name $openAiAccountName `
            --resource-group $resourceGroupName `
            --query key1 -o tsv
    } catch {
        Write-Warning "Could not fetch the Azure OpenAI key: $($_.Exception.Message)"
    }
}

# =============================================================================
# Build a fully populated C:\Lab\.env
# Client feedback #3: the attendee must never hand-copy values into .env.
# Values are written unquoted, matching the format python-dotenv expects and
# the original postprovision.sh output.
# =============================================================================
$envLines = @(
    "# Azure OpenAI Configuration"
    "AZURE_OPENAI_ENDPOINT=$openAiEndpoint"
    "AZURE_OPENAI_KEY=$openAiKey"
    "AZURE_OPENAI_DEPLOYMENT=$openAiDeployment"
    "AZURE_EMBED_DEPLOYMENT=$embedDeployment"
    "AZURE_API_VERSION=$openAiApiVersion"
    ""
    "# Database Configuration"
    "AZURE_PG_HOST=$pgHost"
    "AZURE_PG_NAME=postgres"
    "AZURE_PG_USER=$pgUser"
    "AZURE_PG_PASSWORD=$pgPassword"
    "AZURE_PG_PORT=5432"
    "AZURE_PG_SSLMODE=require"
) -join [Environment]::NewLine

Set-Content -Path "$LabRoot\.env" -Value $envLines -Encoding UTF8 -Force
Write-Host "[OK] C:\Lab\.env created and populated." -ForegroundColor Green

# Sanity check: fail loudly in the logs if any value is still empty
foreach ($required in @('AZURE_OPENAI_ENDPOINT','AZURE_OPENAI_KEY','AZURE_PG_HOST','AZURE_PG_PASSWORD')) {
    $line = (Get-Content "$LabRoot\.env") | Where-Object { $_ -like "$required=*" }
    if (-not $line -or $line -eq "$required=") {
        Write-Warning "[.env] $required is empty - the notebooks will fail. Check C:\Logs."
    }
}

#Download LogonTask (user-level setup: VS Code extensions, desktop shortcuts)
$WebClient = New-Object System.Net.WebClient
$WebClient.DownloadFile("https://raw.githubusercontent.com/derangulask-spektra/newrepo-18/refs/heads/main/logontask-01.ps1","C:\LabFiles\logontask-01.ps1")

#Enable Auto-Logon
$AutoLogonRegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $AutoLogonRegPath -Name "AutoAdminLogon" -Value "1" -type String
Set-ItemProperty -Path $AutoLogonRegPath -Name "DefaultUsername" -Value "$($env:ComputerName)\demouser" -type String
Set-ItemProperty -Path $AutoLogonRegPath -Name "DefaultPassword" -Value $adminPassword -type String
Set-ItemProperty -Path $AutoLogonRegPath -Name "AutoLogonCount" -Value "1" -type DWord

# Scheduled Task
$Trigger= New-ScheduledTaskTrigger -AtLogOn
$User= "$($env:ComputerName)\demouser"
$Action= New-ScheduledTaskAction -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\Powershell.exe" -Argument "-executionPolicy Unrestricted -File C:\LabFiles\logontask-01.ps1"
Register-ScheduledTask -TaskName "Setup" -Trigger $Trigger -User $User -Action $Action -RunLevel Highest -Force
Set-ExecutionPolicy -ExecutionPolicy bypass -Force
$Validstatus="Pending"
$Validmessage=" Post Deployment is Pending"

#Set the final deployment status
CloudlabsManualAgent setStatus

Stop-Transcript
Restart-Computer -Force
