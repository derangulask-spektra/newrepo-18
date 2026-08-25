# =============================================================================
# Logon Task - runs once as demouser at first logon
#
# User-level setup that cannot be done from the SYSTEM-context CSE:
#   1. Install VS Code extensions (Python, Jupyter, PostgreSQL)
#   2. Create Python virtual environment
#   3. Upgrade pip
#   4. Install Python dependencies from requirements.txt
#   5. Remove VS Code desktop shortcut
#   6. Validate required lab files
#   7. Report deployment status to CloudLabs Agent
# =============================================================================

Start-Transcript -Path C:\WindowsAzure\Logs\CloudLabsLogonTask.txt -Append

$allOk = $true

# =============================================================================
# Install VS Code Extensions
# =============================================================================

$codeCli = "C:\Program Files\Microsoft VS Code\bin\code.cmd"

if (-not (Test-Path $codeCli)) {
    $codeCli = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd"
}

if (Test-Path $codeCli) {

    $extensions = @(
        "ms-python.python",
        "ms-toolsai.jupyter",
        "ms-ossdata.vscode-pgsql"
    )

    foreach ($ext in $extensions) {

        Write-Host "Installing VS Code extension: $ext"

        & $codeCli --install-extension $ext --force

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Extension $ext install failed. Retrying in 10 seconds..."

            Start-Sleep -Seconds 10

            & $codeCli --install-extension $ext --force

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Failed to install extension: $ext"
                $allOk = $false
            }
        }
    }
}
else {
    Write-Warning "VS Code CLI not found."
    $allOk = $false
}

# =============================================================================
# Create Python Virtual Environment and Install Dependencies
# =============================================================================

$labRoot = "C:\Lab"

if (Test-Path $labRoot) {

    Set-Location $labRoot

    Write-Host "Creating Python virtual environment..."

    try {

        if (-not (Test-Path "$labRoot\.venv\Scripts\python.exe")) {
            python -m venv .venv
        }

        $venvPython = "$labRoot\.venv\Scripts\python.exe"

        if (Test-Path $venvPython) {

            Write-Host "Upgrading pip..."

            & $venvPython -m pip install --upgrade pip

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Failed to upgrade pip."
                $allOk = $false
            }

            $requirementsFile = Join-Path $labRoot "requirements.txt"

            if (Test-Path $requirementsFile) {

                $maxRetries = 3
                $attempt = 0
                $installSucceeded = $false

                do {

                    $attempt++

                    Write-Host "Installing Python dependencies (Attempt $attempt of $maxRetries)..."

                    & $venvPython -m pip install -r $requirementsFile

                    if ($LASTEXITCODE -eq 0) {
                        $installSucceeded = $true
                        Write-Host "Requirements installed successfully."
                        break
                    }

                    Write-Warning "Package installation failed."

                    if ($attempt -lt $maxRetries) {
                        Start-Sleep -Seconds 30
                    }

                } while ($attempt -lt $maxRetries)

                if (-not $installSucceeded) {
                    Write-Warning "Failed to install requirements after $maxRetries attempts."
                    $allOk = $false
                }
            }
            else {
                Write-Warning "requirements.txt not found."
                $allOk = $false
            }
        }
        else {
            Write-Warning "Virtual environment was not created."
            $allOk = $false
        }
    }
    catch {
        Write-Warning "Error during Python environment setup. $_"
        $allOk = $false
    }
}
else {
    Write-Warning "Lab folder not found: $labRoot"
    $allOk = $false
}

# =============================================================================
# Remove VS Code Desktop Shortcuts
# =============================================================================

$publicDesktop = :GetFolderPath('CommonDesktopDirectory')
$userDesktop   = :GetFolderPath('Desktop')

foreach ($dir in @($publicDesktop, $userDesktop)) {

    if ($dir -and (Test-Path $dir)) {

        Get-ChildItem `
            -Path $dir `
            -Filter 'Visual Studio Code*.lnk' `
            -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# Validation Checks
# =============================================================================

$checks = @(
    @{ Name = "Lab repo";       Path = "C:\Lab\README.md" },
    @{ Name = ".env file";      Path = "C:\Lab\.env" },
    @{ Name = "Notebook 1";     Path = "C:\Lab\Code\1-data-setup.ipynb" },
    @{ Name = "Notebook 2";     Path = "C:\Lab\Code\2-app-development.ipynb" },
    @{ Name = "Dataset";        Path = "C:\Lab\Dataset\cases.csv" },
    @{ Name = "requirements";   Path = "C:\Lab\requirements.txt" },
    @{ Name = "Python venv";    Path = "C:\Lab\.venv\Scripts\python.exe" }
)

foreach ($c in $checks) {

    if (Test-Path $c.Path) {
        Write-Host "[OK] $($c.Name) present."
    }
    else {
        Write-Warning "[MISSING] $($c.Name) not found at $($c.Path)"
        $allOk = $false
    }
}

# =============================================================================
# Report Deployment Status to CloudLabs Agent
# =============================================================================

$statusPath = "C:\WindowsAzure\Logs\status-sample.txt"
$validationPath = "C:\WindowsAzure\Logs\validationstatus.txt"

if (Test-Path $statusPath) {

    $status = if ($allOk) { "Succeeded" } else { "Failed" }

    $message = if ($allOk) {
        "Post Deployment Completed"
    }
    else {
        "Lab validation failed. Check CloudLabsLogonTask.txt"
    }

    (Get-Content $statusPath) |
        ForEach-Object { $_ -replace "ReplaceStatus", $status } |
        ForEach-Object { $_ -replace "ReplaceMessage", $message } |
        Set-Content $validationPath
}

# =============================================================================
# Remove One-Time Scheduled Task
# =============================================================================

Unregister-ScheduledTask -TaskName "Setup" -Confirm:$false -ErrorAction SilentlyContinue

Stop-Transcript
