<#
bootstrap.ps1 (Stable Lab Version)

Assumptions:
- Fresh Talos nodes (no old STATE)
- Running from Win11 CTL VM
- Repo cloned locally

Defaults:
  CP  = 192.168.1.3
  W1  = 192.168.1.5
  W2  = 192.168.1.6
  VIP = 192.168.1.200
#>

[CmdletBinding()]
param(
  [string]  $ClusterName    = "cita360",
  [string]  $ControlPlaneIP = "192.168.1.3",
  [string[]]$WorkerIPs      = @("192.168.1.5","192.168.1.6"),
  [string]  $VipIP          = "192.168.1.200",

  [int]$TimeoutTalosApiSeconds = 300,
  [int]$TimeoutK8sApiSeconds   = 420,
  [int]$TimeoutKubectlSeconds  = 420
)

$ErrorActionPreference = "Stop"

# -------------------------
# Paths
# -------------------------
$RepoRoot     = $PSScriptRoot
$OverridesDir = Join-Path $RepoRoot "01-talos\student-overrides"
$TalosConfig  = Join-Path $OverridesDir "talosconfig"
$Kubeconfig   = Join-Path $RepoRoot "kubeconfig"

# -------------------------
# Utility Functions
# -------------------------

function Show-Header($Title,$Color="Cyan") {
  Write-Host ""
  Write-Host $Title -ForegroundColor $Color
  Write-Host ""
}

function Assert-Command($Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $Name"
  }
}

function Wait-ForPort($Ip,$Port,$TimeoutSeconds,$Label) {
  $start = Get-Date
  while ($true) {
    if (Test-NetConnection $Ip -Port $Port -InformationLevel Quiet) { return }
    if (((Get-Date)-$start).TotalSeconds -ge $TimeoutSeconds) {
      throw "$Label not reachable in time: ${Ip}:${Port}"
    }
    Start-Sleep -Seconds 5
  }
}

function Wait-ForKubectl($TimeoutSeconds) {
  $start = Get-Date
  while ($true) {
    try {
      & kubectl --kubeconfig $Kubeconfig get nodes -o name 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { return }
    } catch {}
    if (((Get-Date)-$start).TotalSeconds -ge $TimeoutSeconds) {
      throw "kubectl not ready in time."
    }
    Start-Sleep -Seconds 5
  }
}

function New-CleanOverridesDir {
  New-Item -ItemType Directory -Force -Path $OverridesDir | Out-Null
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $OverridesDir "*")
  Remove-Item -Force -ErrorAction SilentlyContinue $Kubeconfig
}

function Set-TalosContext {
  $env:TALOSCONFIG = $TalosConfig
  talosctl config endpoint $ControlPlaneIP | Out-Null
  talosctl config node $ControlPlaneIP     | Out-Null
}

function Talos-Apply($NodeIP,$FilePath) {
  Write-Host "Applying config to $NodeIP ..." -ForegroundColor Gray
  talosctl apply-config --insecure --nodes $NodeIP --endpoints $ControlPlaneIP --file $FilePath
}

function Talos-Bootstrap {
  Write-Host "Bootstrapping etcd/Kubernetes..." -ForegroundColor Gray
  talosctl bootstrap --nodes $ControlPlaneIP --endpoints $ControlPlaneIP
}

function Talos-Kubeconfig {
  Write-Host "Fetching kubeconfig..." -ForegroundColor Gray
  talosctl kubeconfig $Kubeconfig --insecure --nodes $ControlPlaneIP --endpoints $ControlPlaneIP --force
}

function Kube {
  param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
  & kubectl --kubeconfig $Kubeconfig @Args
}

# -------------------------
# Add-on Installers
# -------------------------

function Install-MetalLB {
  Show-Header "Installing MetalLB" "Yellow"

  $metallbBase    = Join-Path $RepoRoot "02-metallb\base"
  $metallbOverlay = Join-Path $RepoRoot "02-metallb\overlays\example"

  Kube apply -f $metallbBase | Out-Null

  $poolFile = Join-Path $metallbOverlay "metallb-pool.yaml"
  if (Test-Path $poolFile) {
    $content = Get-Content $poolFile -Raw
    $content = [regex]::Replace(
      $content,
      '(?m)^\s*-\s*\d{1,3}(\.\d{1,3}){3}/32\s*$',
      "    - $VipIP/32"
    )
    Set-Content -Path $poolFile -Value $content -Encoding utf8
  }

  Kube apply -f $metallbOverlay | Out-Null
}

function Install-IngressNginx {
  Show-Header "Installing ingress-nginx (Helm)" "Yellow"

  $env:KUBECONFIG = $Kubeconfig

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx | Out-Null
  helm repo update | Out-Null

  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx `
    --namespace ingress-nginx --create-namespace `
    --set controller.service.type=LoadBalancer | Out-Null

  Kube rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=240s | Out-Null
}

function Install-AppAndIngress {
  Show-Header "Deploying sample app + ingress" "Yellow"

  $appDir      = Join-Path $RepoRoot "04-app"
  $ingressYaml = Join-Path $RepoRoot "03-ingress\nginx-ingress.yaml"

  Kube apply -f $appDir | Out-Null
  Kube apply -f $ingressYaml | Out-Null
}

# -------------------------
# MAIN
# -------------------------

Clear-Host
Show-Header "== CITA 360 Talos + Kubernetes Bootstrap =="

Assert-Command talosctl
Assert-Command kubectl
Assert-Command helm

Write-Host "Control Plane: $ControlPlaneIP"
Write-Host "Workers:       $($WorkerIPs -join ', ')"
Write-Host "VIP:           $VipIP"

# Wait initial Talos API
Show-Header "Waiting for Talos API (50000)"
Wait-ForPort $ControlPlaneIP 50000 $TimeoutTalosApiSeconds "Talos API"

# Generate configs
Show-Header "Generating Talos configs (fresh PKI)"
New-CleanOverridesDir
talosctl gen config $ClusterName "https://${ControlPlaneIP}:6443" `
  --output-dir $OverridesDir --force

Set-TalosContext

# Apply configs
Show-Header "Applying configs (insecure)"
Talos-Apply $ControlPlaneIP (Join-Path $OverridesDir "controlplane.yaml")
foreach ($w in $WorkerIPs) {
  Talos-Apply $w (Join-Path $OverridesDir "worker.yaml")
}

# CRITICAL FIX: Wait for Talos restart
Show-Header "Waiting for Talos API to restart after apply-config"
Start-Sleep -Seconds 10
Wait-ForPort $ControlPlaneIP 50000 $TimeoutTalosApiSeconds "Talos API (post-apply)"

# Bootstrap
Show-Header "Bootstrapping control plane"
Wait-ForPort $ControlPlaneIP 50000 120 "Talos API (pre-bootstrap)"
Talos-Bootstrap

# Wait for Kubernetes API
Show-Header "Waiting for Kubernetes API (6443)"
Wait-ForPort $ControlPlaneIP 6443 $TimeoutK8sApiSeconds "Kubernetes API"

# Fetch kubeconfig
Show-Header "Fetching kubeconfig"
Talos-Kubeconfig

# Wait for kubectl
Show-Header "Waiting for kubectl"
Wait-ForKubectl $TimeoutKubectlSeconds

Write-Host ""
Write-Host "Kubernetes is up." -ForegroundColor Green

# Add-ons
Install-MetalLB
Install-IngressNginx
Install-AppAndIngress

Show-Header "Cluster summary" "Cyan"
Kube get nodes -o wide
Kube get pods -A
Kube get svc -A
Kube get ingress

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Test URL: http://$VipIP"
