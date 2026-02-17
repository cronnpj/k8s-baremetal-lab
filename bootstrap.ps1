<#
bootstrap.ps1
Run this on the Talos CTL VM (inside the isolated lab network).

Key behavior:
- If an existing Talos config exists (01-talos\student-overrides\talosconfig), we REUSE it.
- We DO NOT regenerate Talos secrets on reruns unless -ForceRegenTalos is set.
- If kubeconfig already works, we skip Talos steps and continue to MetalLB/Ingress/App.
- Use -InstallOnly to skip Talos apply/bootstrap entirely (for “just install MetalLB/Ingress”).

Examples:
  .\bootstrap.ps1
  .\bootstrap.ps1 -InstallOnly
  .\bootstrap.ps1 -ControlPlaneIP 192.168.1.13 -WorkerIPs 192.168.1.16,192.168.1.17 -VipIP 192.168.1.210
  .\bootstrap.ps1 -ForceRegenTalos   # ONLY on fresh nodes
#>

[CmdletBinding()]
param(
  [string]$ClusterName    = "cita360",
  [string]$ControlPlaneIP = "192.168.1.3",

  # Preferred: any number of workers
  [string[]]$WorkerIPs    = @(),

  # Legacy (compat)
  [string]$Worker1IP      = "192.168.1.6",
  [string]$Worker2IP      = "192.168.1.7",

  [string]$VipIP          = "192.168.1.200",

  # Stop after Talos bootstrap + kubeconfig
  [switch]$TalosOnly,

  # Skip Talos apply/bootstrap; just ensure kubeconfig works and then install MetalLB/Ingress/App
  [switch]$InstallOnly,

  # Force regenerate Talos secrets/configs (ONLY for fresh nodes)
  [switch]$ForceRegenTalos
)

$ErrorActionPreference = "Stop"

$script:RepoKubeconfigPath = Join-Path $PSScriptRoot "kubeconfig"
$script:OverridesDir       = Join-Path $PSScriptRoot "01-talos\student-overrides"
$script:TalosConfigPath    = Join-Path $script:OverridesDir "talosconfig"

# -------------------------
# Helpers
# -------------------------
function Assert-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing required command '$name'. Install it first (talosctl / kubectl / git / helm)."
  }
}

function Assert-Reachable($ip, $label) {
  $ok = Test-Connection -ComputerName $ip -Count 1 -Quiet
  if (-not $ok) { throw "$label ($ip) is not reachable. Check IP/subnet/VM power state." }
}

function Assert-IPv4($ip, $label) {
  $ipObj = $null
  if (-not ([System.Net.IPAddress]::TryParse($ip, [ref]$ipObj) -and $ipObj.AddressFamily -eq 'InterNetwork')) {
    throw "$label '$ip' is not a valid IPv4 address."
  }
}

function Read-Default {
  param([Parameter(Mandatory=$true)][string]$Prompt, [string]$Default = "")
  $suffix = if ($Default) { " [$Default]" } else { "" }
  $v = Read-Host "$Prompt$suffix"
  if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
  return $v.Trim()
}

function Read-IPv4Prompt {
  param([Parameter(Mandatory=$true)][string]$Prompt, [Parameter(Mandatory=$true)][string]$Default)
  while ($true) {
    $v = Read-Default -Prompt $Prompt -Default $Default
    $ipObj = $null
    if ([System.Net.IPAddress]::TryParse($v, [ref]$ipObj) -and $ipObj.AddressFamily -eq 'InterNetwork') { return $v }
    Write-Host "Invalid IPv4 address. Try again." -ForegroundColor Yellow
  }
}

function Read-IPv4ListPrompt {
  param([Parameter(Mandatory=$true)][string]$Prompt, [string[]]$Defaults = @())

  Write-Host ""
  Write-Host $Prompt -ForegroundColor Cyan
  Write-Host "Enter one IP per line. Press Enter on a blank line to finish." -ForegroundColor DarkGray
  if ($Defaults.Count -gt 0) {
    Write-Host ("Default workers: {0}" -f ($Defaults -join ", ")) -ForegroundColor DarkGray
    Write-Host "Tip: Press Enter immediately to accept defaults." -ForegroundColor DarkGray
  }

  $items = @()

  $first = Read-Host "Worker IP (blank to finish)"
  if ([string]::IsNullOrWhiteSpace($first)) {
    if ($Defaults.Count -gt 0) { return $Defaults }
    Write-Host "Please enter at least one worker IP." -ForegroundColor Yellow
  } else {
    $items += $first.Trim()
  }

  while ($true) {
    $v = Read-Host "Worker IP (blank to finish)"
    if ([string]::IsNullOrWhiteSpace($v)) { break }
    $items += $v.Trim()
  }

  $out = @()
  foreach ($ip in $items) {
    $ipObj = $null
    if (-not ([System.Net.IPAddress]::TryParse($ip, [ref]$ipObj) -and $ipObj.AddressFamily -eq 'InterNetwork')) {
      Write-Host "Invalid IPv4 in list: $ip" -ForegroundColor Yellow
      return (Read-IPv4ListPrompt -Prompt $Prompt -Defaults $Defaults)
    }
    $out += $ip
  }
  return $out
}

function Test-KubectlWithKubeconfig {
  param([string]$Path)
  if (-not $Path) { return $false }
  if (-not (Test-Path $Path)) { return $false }
  & kubectl --kubeconfig $Path get nodes -o name 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function Resolve-WorkingKubeconfig {
  if (Test-KubectlWithKubeconfig -Path $script:RepoKubeconfigPath) { return $script:RepoKubeconfigPath }

  $default = Join-Path $HOME ".kube\config"
  if (Test-KubectlWithKubeconfig -Path $default) { return $default }

  return $null
}

function Invoke-Kube {
  param(
    [Parameter(Mandatory=$true)][string]$KubeconfigPath,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Args
  )
  & kubectl --kubeconfig $KubeconfigPath @Args
}

function Wait-ForIngressExternalIP {
  param(
    [Parameter(Mandatory=$true)][string]$KubeconfigPath,
    [int]$TimeoutSeconds = 240
  )

  $start = Get-Date
  while ($true) {
    $svcJson = Invoke-Kube -KubeconfigPath $KubeconfigPath -Args @("get","svc","-n","ingress-nginx","ingress-nginx-controller","-o","json") 2>$null
    if ($LASTEXITCODE -eq 0 -and $svcJson) {
      try {
        $obj = $svcJson | ConvertFrom-Json
        $ip  = $obj.status.loadBalancer.ingress[0].ip
        if ($ip) { return $ip }
      } catch { }
    }

    if (((Get-Date) - $start).TotalSeconds -gt $TimeoutSeconds) {
      throw "Timed out waiting for ingress-nginx-controller EXTERNAL-IP."
    }
    Start-Sleep -Seconds 5
  }
}

function Ensure-KubeconfigFromTalos {
  param([string]$ControlPlaneIP)

  if (-not (Test-Path $script:TalosConfigPath)) {
    return $false
  }

  $env:TALOSCONFIG = $script:TalosConfigPath
  Write-Host "Using existing TALOSCONFIG: $($script:TalosConfigPath)" -ForegroundColor DarkGray

  if (Test-Path $script:RepoKubeconfigPath) { Remove-Item $script:RepoKubeconfigPath -Force }

  # This requires the correct talosconfig (from the original secrets)
  talosctl kubeconfig $script:RepoKubeconfigPath --nodes $ControlPlaneIP --endpoints $ControlPlaneIP --force | Out-Null

  return (Test-KubectlWithKubeconfig -Path $script:RepoKubeconfigPath)
}

# -------------------------
# Prompt logic
# -------------------------
if (-not $WorkerIPs -or $WorkerIPs.Count -eq 0) {
  $WorkerIPs = @($Worker1IP, $Worker2IP) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

$boundKeys = @($PSBoundParameters.Keys)
$ranWithExplicitValues =
  $boundKeys.Contains("ClusterName") -or
  $boundKeys.Contains("ControlPlaneIP") -or
  $boundKeys.Contains("WorkerIPs") -or
  $boundKeys.Contains("Worker1IP") -or
  $boundKeys.Contains("Worker2IP") -or
  $boundKeys.Contains("VipIP") -or
  $boundKeys.Contains("InstallOnly") -or
  $boundKeys.Contains("ForceRegenTalos")

if (-not $ranWithExplicitValues) {
  Clear-Host
  Write-Host "== CITA 360 Talos + Kubernetes Bootstrap ==" -ForegroundColor Cyan
  Write-Host ""

  $defaultWorkers = @("192.168.1.6", "192.168.1.7")

  $ClusterName    = Read-Default         -Prompt "Cluster name"       -Default $ClusterName
  $ControlPlaneIP = Read-IPv4Prompt      -Prompt "Control Plane IP"   -Default $ControlPlaneIP
  $WorkerIPs      = Read-IPv4ListPrompt  -Prompt "Worker node IPs"    -Defaults $defaultWorkers
  $VipIP          = Read-IPv4Prompt      -Prompt "VIP (MetalLB) IP"   -Default $VipIP
  Write-Host ""
}

Assert-IPv4 $ControlPlaneIP "ControlPlaneIP"
Assert-IPv4 $VipIP "VipIP"
if (-not $WorkerIPs -or $WorkerIPs.Count -lt 1) { throw "You must provide at least one worker IP." }
for ($i=0; $i -lt $WorkerIPs.Count; $i++) { Assert-IPv4 $WorkerIPs[$i] ("WorkerIPs[{0}]" -f $i) }

Write-Host "== CITA 360 Talos + Kubernetes Bootstrap ==" -ForegroundColor Cyan
Write-Host "ClusterName:    $ClusterName"
Write-Host "ControlPlaneIP: $ControlPlaneIP"
Write-Host "Workers:        $($WorkerIPs -join ', ')"
Write-Host "VIP (MetalLB):  $VipIP"
Write-Host ""

# Tools
Assert-Command talosctl
Assert-Command kubectl
Assert-Command git
Assert-Command helm

# Network checks
Assert-Reachable $ControlPlaneIP "Control Plane"
for ($i=0; $i -lt $WorkerIPs.Count; $i++) { Assert-Reachable $WorkerIPs[$i] ("Worker {0}" -f ($i+1)) }

# -------------------------
# 1) If kubectl already works, skip Talos and continue
# -------------------------
$KubeconfigPath = Resolve-WorkingKubeconfig
if ($KubeconfigPath) {
  Write-Host "Cluster reachable (kubectl works). Skipping Talos steps." -ForegroundColor Green
  Write-Host "Using kubeconfig: $KubeconfigPath" -ForegroundColor DarkGray

  if ($TalosOnly) {
    Write-Host "`nTalos-only mode requested, but cluster is already up. Nothing to do." -ForegroundColor Green
    exit 0
  }
}
else {
  # -------------------------
  # 2) Try to fetch kubeconfig using EXISTING talosconfig (rerun scenario)
  # -------------------------
  New-Item -ItemType Directory -Force -Path $script:OverridesDir | Out-Null

  if (-not $ForceRegenTalos -and (Test-Path $script:TalosConfigPath)) {
    Write-Host "No working kubeconfig found. Attempting to fetch kubeconfig using existing talosconfig..." -ForegroundColor Yellow
    $ok = Ensure-KubeconfigFromTalos -ControlPlaneIP $ControlPlaneIP
    if ($ok) {
      $KubeconfigPath = $script:RepoKubeconfigPath
      Write-Host "Kubeconfig recovered successfully: $KubeconfigPath" -ForegroundColor Green

      if ($TalosOnly) {
        Write-Host "`nTalos-only mode complete (kubeconfig recovered)." -ForegroundColor Green
        exit 0
      }
    }
    elseif ($InstallOnly) {
      throw "InstallOnly requested, but no kubeconfig works and kubeconfig recovery failed. You likely regenerated Talos secrets at some point or lost the original talosconfig. Restore the original '01-talos\student-overrides\talosconfig' from the first successful run, or rebuild the cluster."
    }
  }

  # If still no kubeconfig and InstallOnly is set, stop here.
  if (-not $KubeconfigPath -and $InstallOnly) {
    throw "InstallOnly requested but no kubeconfig is available. Either copy a working kubeconfig into the repo root as 'kubeconfig' or restore the original talosconfig so the script can fetch kubeconfig."
  }

  # -------------------------
  # 3) Fresh bootstrap path (only when needed)
  # -------------------------
  if (-not $KubeconfigPath) {

    if (-not $ForceRegenTalos -and (Test-Path $script:TalosConfigPath)) {
      Write-Host "Existing talosconfig found, but kubeconfig is still not usable. Proceeding with Talos bootstrap using existing talosconfig..." -ForegroundColor Yellow
      $env:TALOSCONFIG = $script:TalosConfigPath
    }
    else {
      Write-Host "`n[1/6] Generating Talos configs..." -ForegroundColor Yellow
      talosctl gen config $ClusterName "https://$ControlPlaneIP`:6443" --output-dir $script:OverridesDir

      if (-not (Test-Path $script:TalosConfigPath)) { throw "Missing talosconfig at: $($script:TalosConfigPath)" }
      $env:TALOSCONFIG = $script:TalosConfigPath
      Write-Host "Using TALOSCONFIG: $($script:TalosConfigPath)" -ForegroundColor DarkGray
    }

    function Invoke-TalosApplyConfig {
      param(
        [Parameter(Mandatory=$true)][string]$NodeIP,
        [Parameter(Mandatory=$true)][ValidateSet("controlplane","worker")][string]$Role
      )

      $file = if ($Role -eq "controlplane") { Join-Path $script:OverridesDir "controlplane.yaml" } else { Join-Path $script:OverridesDir "worker.yaml" }
      if (-not (Test-Path $file)) { throw "Missing config file: $file" }

      Write-Host "Applying $Role config to $NodeIP..." -ForegroundColor Gray

      # Try insecure first (fresh nodes)
      $out = talosctl apply-config --insecure --nodes $NodeIP --endpoints $ControlPlaneIP --file $file 2>&1 | Out-String
      if ($LASTEXITCODE -eq 0) { return }

      # If TLS required, try secure ONLY if we are using a pre-existing talosconfig (rerun case)
      if ($out -match "certificate required") {
        Write-Host "Node requires TLS; retrying apply-config using TALOSCONFIG..." -ForegroundColor Yellow
        talosctl apply-config --nodes $NodeIP --endpoints $ControlPlaneIP --file $file
        if ($LASTEXITCODE -ne 0) { throw "apply-config failed for ${NodeIP}" }
        return
      }

      throw "apply-config failed for ${NodeIP}: $out"
    }

    Write-Host "`n[2/6] Applying Talos configs..." -ForegroundColor Yellow
    Invoke-TalosApplyConfig -NodeIP $ControlPlaneIP -Role "controlplane"
    foreach ($w in $WorkerIPs) { Invoke-TalosApplyConfig -NodeIP $w -Role "worker" }

    Write-Host "`n[3/6] Bootstrapping Kubernetes control plane..." -ForegroundColor Yellow
    talosctl bootstrap --nodes $ControlPlaneIP --endpoints $ControlPlaneIP

    Write-Host "`n[4/6] Fetching kubeconfig..." -ForegroundColor Yellow
    if (Test-Path $script:RepoKubeconfigPath) { Remove-Item $script:RepoKubeconfigPath -Force }
    talosctl kubeconfig $script:RepoKubeconfigPath --nodes $ControlPlaneIP --endpoints $ControlPlaneIP --force | Out-Null

    if (-not (Test-Path $script:RepoKubeconfigPath)) {
      throw "talosctl kubeconfig did not create: $($script:RepoKubeconfigPath)"
    }

    $KubeconfigPath = $script:RepoKubeconfigPath
    Write-Host "Kubeconfig created: $KubeconfigPath" -ForegroundColor Green

    Write-Host "`nVerifying nodes (may take a minute)..." -ForegroundColor Yellow
    Invoke-Kube -KubeconfigPath $KubeconfigPath -Args @("get","nodes","-o","wide")

    if ($TalosOnly) {
      Write-Host "`nTalos-only mode complete." -ForegroundColor Green
      exit 0
    }
  }
}

# -------------------------
# MetalLB + Ingress + App
# -------------------------
Write-Host "`n[5/6] Installing MetalLB..." -ForegroundColor Yellow

$metallbBase    = Join-Path $PSScriptRoot "02-metallb\base"
$metallbOverlay = Join-Path $PSScriptRoot "02-metallb\overlays\example"

if (-not (Test-Path $metallbBase))    { throw "Missing folder: $metallbBase" }
if (-not (Test-Path $metallbOverlay)) { throw "Missing folder: $metallbOverlay" }

Invoke-Kube -KubeconfigPath $KubeconfigPath -Args @("apply","-f",$metallbBase)

# Auto-update VIP in pool
$poolFile = Join-Path $PSScriptRoot "02-metallb\overlays\example\metallb-pool.yaml"
if (Test-Path $poolFile) {
  $content = Get-Content $poolFile -Raw
  $content = [regex]::Replace($content, '(?m)^\s*-\s*\d{1,3}(\.\d{1,3}){3}/32\s*$', "    - $VipIP/32")
  Set-Content -Path $poolFile -Value $content -Encoding utf8
}

Invoke-Kube -KubeconfigPath $KubeconfigPath -Args @("apply","-f",$metallbOverlay)

Write-Host "`n[6/6] Installing ingress-nginx via Helm..." -ForegroundColor Yellow
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx | Out-Null
helm repo update | Out-Null

$env:KUBECONFIG = $KubeconfigPath

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx `
  --namespace ingress-nginx --create-namespace `
  --set controller.service.type=LoadBalancer | Out-Null

Write-Host "Waiting for ingress controller deployment to be ready..." -ForegroundColor Yellow
Invoke-Kube -KubeconfigPath $KubeconfigPath -Args @("rollout","status","deployment/ingress-nginx-controller","-n","ingress-nginx","--timeout=240s")

Write-Host "Waiting for EXTERNAL-IP from MetalLB..." -ForegroundColor Yellow
$assignedIP = Wait-ForIngressExternalIP -KubeconfigPath $KubeconfigPath -TimeoutSeconds 240
Write-Host "Ingress EXTERNAL-IP: $assignedIP" -ForegroundColor Green

Write-Host "`nDeploying sample NGINX app + Ingress rule..." -ForegroundColor Yellow

$appDir      = Join-Path $PSScriptRoot "04-app"
$ingressYaml = Join-Path $PSScriptRoot "03-ingress\nginx-ingress.yaml"

if (-not (Test-Path $appDir))      { throw "Missing folder: $appDir" }
if (-not (Test-Path $ingressYaml)) { throw "Missing file: $ingressYaml" }

Invoke-Kube -KubeconfigPath $KubeconfigPath -Args @("apply","-f",$appDir)
Invoke-Kube -KubeconfigPath $KubeconfigPath -Args @("apply","-f",$ingressYaml)

Write-Host "`nCluster summary:" -ForegroundColor Cyan
Invoke-Kube -KubeconfigPath $KubeconfigPath -Args @("get","nodes")
Invoke-Kube -KubeconfigPath $KubeconfigPath -Args @("get","pods","-A")
Invoke-Kube -KubeconfigPath $KubeconfigPath -Args @("get","svc","-A")
Invoke-Kube -KubeconfigPath $KubeconfigPath -Args @("get","ingress")

Write-Host "`nDone." -ForegroundColor Green
Write-Host "Test URL (inside your lab network): http://$VipIP"
Write-Host "Note: MetalLB assigned ingress EXTERNAL-IP: $assignedIP"