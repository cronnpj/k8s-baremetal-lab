<#
bootstrap.ps1
Run this on the Talos CTL VM (inside the isolated lab network).

Defaults:
  CP  = 192.168.1.3
  W1  = 192.168.1.6
  W2  = 192.168.1.7
  VIP = 192.168.1.200

Examples:
  .\bootstrap.ps1
  .\bootstrap.ps1 -ControlPlaneIP 192.168.1.13 -Worker1IP 192.168.1.16 -Worker2IP 192.168.1.17 -VipIP 192.168.1.210
  .\bootstrap.ps1 -TalosOnly
#>

[CmdletBinding()]
param(
  [string]$ClusterName    = "cita360",
  [string]$ControlPlaneIP = "192.168.1.3",
  [string]$Worker1IP      = "192.168.1.6",
  [string]$Worker2IP      = "192.168.1.7",
  [string]$VipIP          = "192.168.1.200",

  # If you want to stop after Talos bootstrap + kubeconfig, use -TalosOnly
  [switch]$TalosOnly
)

$ErrorActionPreference = "Stop"

function Assert-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing required command '$name'. Install it first (talosctl / kubectl / git / helm)."
  }
}

function Assert-Reachable($ip, $label) {
  $ok = Test-Connection -ComputerName $ip -Count 1 -Quiet
  if (-not $ok) { throw "$label ($ip) is not reachable. Check IP/subnet/VM power state." }
}

function Invoke-Kube {
  param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
  $kubeconfigPath = Join-Path $PSScriptRoot "kubeconfig"
  & kubectl --kubeconfig $kubeconfigPath @Args
}

function Wait-ForIngressExternalIP {
  param([int]$TimeoutSeconds = 240)

  $start = Get-Date
  while ($true) {
    $svcJson = Invoke-Kube -Args @("get","svc","-n","ingress-nginx","ingress-nginx-controller","-o","json") 2>$null
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

Write-Host "== CITA 360 Talos + Kubernetes Bootstrap ==" -ForegroundColor Cyan
Write-Host "ClusterName:    $ClusterName"
Write-Host "ControlPlaneIP: $ControlPlaneIP"
Write-Host "Worker1IP:      $Worker1IP"
Write-Host "Worker2IP:      $Worker2IP"
Write-Host "VIP (MetalLB):  $VipIP"
Write-Host ""

# Required tools on the Talos CTL VM
Assert-Command talosctl
Assert-Command kubectl
Assert-Command git
Assert-Command helm

# Reachability checks
Assert-Reachable $ControlPlaneIP "Control Plane"
Assert-Reachable $Worker1IP      "Worker 1"
Assert-Reachable $Worker2IP      "Worker 2"

# --- Talos: generate configs locally (secrets stay local)
$OverridesDir = Join-Path $PSScriptRoot "01-talos\student-overrides"
New-Item -ItemType Directory -Force -Path $OverridesDir | Out-Null

Write-Host "`n[1/6] Generating Talos configs..." -ForegroundColor Yellow
talosctl gen config $ClusterName "https://$ControlPlaneIP`:6443" --output-dir $OverridesDir

Write-Host "`n[2/6] Applying Talos configs..." -ForegroundColor Yellow
talosctl apply-config --insecure --nodes $ControlPlaneIP --file (Join-Path $OverridesDir "controlplane.yaml")
talosctl apply-config --insecure --nodes $Worker1IP      --file (Join-Path $OverridesDir "worker.yaml")
talosctl apply-config --insecure --nodes $Worker2IP      --file (Join-Path $OverridesDir "worker.yaml")

Write-Host "`n[3/6] Bootstrapping Kubernetes control plane..." -ForegroundColor Yellow
talosctl bootstrap --nodes $ControlPlaneIP --endpoints $ControlPlaneIP

Write-Host "`n[4/6] Fetching kubeconfig into repo root..." -ForegroundColor Yellow
talosctl kubeconfig $PSScriptRoot --nodes $ControlPlaneIP --endpoints $ControlPlaneIP

Write-Host "`nVerifying nodes (may take a minute)..." -ForegroundColor Yellow
Invoke-Kube -Args @("get","nodes","-o","wide")

if ($TalosOnly) {
  Write-Host "`nTalos-only mode complete." -ForegroundColor Green
  exit 0
}

# --- MetalLB
Write-Host "`n[5/6] Installing MetalLB..." -ForegroundColor Yellow

$metallbBase    = Join-Path $PSScriptRoot "02-metallb\base"
$metallbOverlay = Join-Path $PSScriptRoot "02-metallb\overlays\example"

if (-not (Test-Path $metallbBase))    { throw "Missing folder: $metallbBase" }
if (-not (Test-Path $metallbOverlay)) { throw "Missing folder: $metallbOverlay" }

Invoke-Kube -Args @("apply","-f",$metallbBase)

# Optional: update the VIP in the MetalLB pool automatically (so students don't edit YAML)
$poolFile = Join-Path $PSScriptRoot "02-metallb\overlays\example\metallb-pool.yaml"
if (Test-Path $poolFile) {
  $content = Get-Content $poolFile -Raw
  # Replace any IPv4/32 entry line under addresses with the chosen VIP
  $content = [regex]::Replace($content, '(?m)^\s*-\s*\d{1,3}(\.\d{1,3}){3}/32\s*$', "    - $VipIP/32")
  Set-Content -Path $poolFile -Value $content -Encoding utf8
}

Invoke-Kube -Args @("apply","-f",$metallbOverlay)

# --- Ingress-NGINX via Helm (LoadBalancer)
Write-Host "`n[6/6] Installing ingress-nginx via Helm..." -ForegroundColor Yellow

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx | Out-Null
helm repo update | Out-Null

# Use kubeconfig explicitly for helm
$env:KUBECONFIG = Join-Path $PSScriptRoot "kubeconfig"

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx `
  --namespace ingress-nginx --create-namespace `
  --set controller.service.type=LoadBalancer | Out-Null

Write-Host "Waiting for ingress controller deployment to be ready..." -ForegroundColor Yellow
Invoke-Kube -Args @("rollout","status","deployment/ingress-nginx-controller","-n","ingress-nginx","--timeout=240s")

Write-Host "Waiting for EXTERNAL-IP from MetalLB..." -ForegroundColor Yellow
$assignedIP = Wait-ForIngressExternalIP -TimeoutSeconds 240
Write-Host "Ingress EXTERNAL-IP: $assignedIP" -ForegroundColor Green

# --- App + Ingress rule
Write-Host "`nDeploying sample NGINX app + Ingress rule..." -ForegroundColor Yellow

$appDir      = Join-Path $PSScriptRoot "04-app"
$ingressYaml = Join-Path $PSScriptRoot "03-ingress\nginx-ingress.yaml"

if (-not (Test-Path $appDir))      { throw "Missing folder: $appDir" }
if (-not (Test-Path $ingressYaml)) { throw "Missing file: $ingressYaml" }

Invoke-Kube -Args @("apply","-f",$appDir)
Invoke-Kube -Args @("apply","-f",$ingressYaml)

Write-Host "`nCluster summary:" -ForegroundColor Cyan
Invoke-Kube -Args @("get","nodes")
Invoke-Kube -Args @("get","pods","-A")
Invoke-Kube -Args @("get","svc","-A")
Invoke-Kube -Args @("get","ingress")

Write-Host "`nDone." -ForegroundColor Green
Write-Host "Test URL (inside your lab network): http://$VipIP"
Write-Host "Note: MetalLB assigned ingress EXTERNAL-IP: $assignedIP"