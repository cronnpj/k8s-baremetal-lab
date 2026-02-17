<#
bootstrap.ps1 (lab-safe, hard-stop on partial wipes)

Goal:
- NEVER proceed into apply/bootstrap if a wipe/reset did not succeed on ALL nodes.
- Avoid the “half-old / half-new” state that triggers x509 + etcd bootstrap loops.
- Works with Talos v1.12.x behavior differences around --wait/--insecure.

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
  [int]$TimeoutKubectlSeconds  = 420,

  [switch]$ForceRebuild
)

$ErrorActionPreference = "Stop"

# Paths
$RepoRoot     = $PSScriptRoot
$TalosDir     = Join-Path $RepoRoot "01-talos"
$OverridesDir = Join-Path $TalosDir  "student-overrides"
$TalosConfig  = Join-Path $OverridesDir "talosconfig"
$Kubeconfig   = Join-Path $RepoRoot "kubeconfig"
$LogPath      = Join-Path $RepoRoot "bootstrap.log"

function Log([string]$s) {
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  $line = "[$ts] $s"
  $line | Out-File -FilePath $LogPath -Append -Encoding utf8
  Write-Host $s
}

function Show-Header([string]$Title,[string]$Color="Cyan") {
  Write-Host ""
  Write-Host $Title -ForegroundColor $Color
  Write-Host ""
}

function Assert-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing required command '${name}'. Install it first (talosctl / kubectl / git / helm)."
  }
}

function Test-TcpPort {
  param([string]$Ip,[int]$Port,[int]$TimeoutMs=1500)
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect($Ip, $Port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
    if (-not $ok) { $client.Close(); return $false }
    $client.EndConnect($iar) | Out-Null
    $client.Close()
    return $true
  } catch { return $false }
}

function Wait-ForPort {
  param([string]$Ip,[int]$Port,[int]$TimeoutSeconds,[string]$Label)
  $start = Get-Date
  while ($true) {
    if (Test-TcpPort -Ip $Ip -Port $Port) { return $true }
    if (((Get-Date)-$start).TotalSeconds -ge $TimeoutSeconds) {
      Log "$Label still not reachable: $Ip`:$Port"
      return $false
    }
    Start-Sleep -Seconds 5
  }
}

function Ensure-OverridesDir { New-Item -ItemType Directory -Force -Path $OverridesDir | Out-Null }

function Clear-GeneratedFiles {
  Remove-Item -Force -ErrorAction SilentlyContinue $Kubeconfig
  Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $OverridesDir "controlplane.yaml")
  Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $OverridesDir "worker.yaml")
  Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $OverridesDir "talosconfig")
}

function Set-TalosContext([string]$cp) {
  if (-not (Test-Path $TalosConfig)) { throw "talosconfig not found at: $TalosConfig" }
  if ((Get-Item $TalosConfig).Length -lt 200) { throw "talosconfig appears empty/corrupt at: $TalosConfig" }

  $env:TALOSCONFIG = $TalosConfig
  & talosctl config endpoint $cp | Out-Null
  & talosctl config node $cp | Out-Null
}

function Preflight-TalosApi([string[]]$Ips) {
  foreach ($ip in $Ips) {
    Log "Preflight: waiting for Talos API on $ip:50000"
    if (-not (Wait-ForPort -Ip $ip -Port 50000 -TimeoutSeconds 90 -Label "Talos API")) {
      throw "Talos API not reachable on $ip:50000. Node likely not booted properly or wrong IP."
    }
  }
}

# ---------- HARD RESET ----------
function Reset-OneNode {
  param([Parameter(Mandatory=$true)][string]$Ip, [string]$Cp)

  Log "Resetting $Ip ..."

  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    # Try SECURE reset first (if TALOSCONFIG is set and matches)
    $outS = & talosctl reset --wait=false --nodes $Ip --endpoints $Ip --graceful=false --reboot `
      --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL 2>&1
    $codeS = $LASTEXITCODE
    $txtS  = ($outS | Out-String)

    if ($codeS -eq 0) { return $true }

    # If secure failed because of x509/unknown authority, try insecure reset
    if ($txtS -match "x509:" -or $txtS -match "unknown authority" -or $txtS -match "failed to verify certificate") {
      Log "Secure reset blocked by TLS on $Ip; retrying reset with --insecure..."
      $outI = & talosctl reset --wait=false --insecure --nodes $Ip --endpoints $Ip --graceful=false --reboot `
        --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL 2>&1
      $codeI = $LASTEXITCODE
      $txtI  = ($outI | Out-String)

      if ($codeI -eq 0) { return $true }

      Log "Reset FAILED on $Ip even with --insecure:`n$txtI"
      return $false
    }

    # Maintenance mode = we cannot reset via API. Treat as failure.
    if ($txtS -match "maintenance mode" -or $txtS -match "API is not implemented in maintenance mode") {
      Log "Reset FAILED on $Ip because node is in MAINTENANCE MODE."
      return $false
    }

    Log "Reset FAILED on ${Ip}:`n$txtS"
    return $false
  }
  finally {
    $ErrorActionPreference = $prev
  }
}

function Reset-Nodes {
  param([string[]]$Ips)

  Show-Header "RESET: Wiping Talos STATE + EPHEMERAL on all nodes (must succeed on ALL)" "Yellow"
  Log ("Nodes: {0}" -f ($Ips -join ", "))

  $fail = @()
  foreach ($ip in $Ips) {
    if (-not (Reset-OneNode -Ip $ip -Cp $ControlPlaneIP)) { $fail += $ip }
  }

  if ($fail.Count -gt 0) {
    throw ("Reset did not succeed on: {0}. STOPPING to prevent half-old/half-new cluster state. Fix those nodes (disk/ISO/maintenance mode/IP) and rerun." -f ($fail -join ", "))
  }

  Log "All nodes reported reset OK. Waiting for control plane Talos API to return..."
  if (-not (Wait-ForPort -Ip $ControlPlaneIP -Port 50000 -TimeoutSeconds $TimeoutTalosApiSeconds -Label "Talos API (CP)")) {
    throw "Talos API did not come back on $ControlPlaneIP:50000 in time."
  }
}

# ---------- CONFIG GENERATION ----------
function Generate-TalosConfigs {
  Ensure-OverridesDir
  Clear-GeneratedFiles

  Show-Header "[1/6] Generating Talos configs" "Yellow"
  & talosctl gen config $ClusterName "https://${ControlPlaneIP}:6443" --output-dir $OverridesDir --force | Out-Null

  if (-not (Test-Path (Join-Path $OverridesDir "controlplane.yaml"))) { throw "controlplane.yaml was not generated." }
  if (-not (Test-Path (Join-Path $OverridesDir "worker.yaml")))      { throw "worker.yaml was not generated." }
  if (-not (Test-Path $TalosConfig))                                 { throw "talosconfig was not generated." }

  Set-TalosContext -cp $ControlPlaneIP
}

function Apply-NodeConfig {
  param([string]$ip,[ValidateSet("controlplane","worker")]$role,[string]$cp)

  $file = if ($role -eq "controlplane") { Join-Path $OverridesDir "controlplane.yaml" } else { Join-Path $OverridesDir "worker.yaml" }
  if (-not (Test-Path $file)) { throw "Missing ${role} config file: $file" }

  Log "Applying $role config to $ip ..."

  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out1  = & talosctl apply-config --insecure --nodes $ip --endpoints $cp --file $file 2>&1
    $code1 = $LASTEXITCODE
    $txt1  = ($out1 | Out-String)
    if ($code1 -eq 0) { return }

    if ($txt1 -match "certificate required" -or $txt1 -match "tls: certificate required") {
      Log "TLS required on $ip; retrying apply-config securely..."
      $out2  = & talosctl apply-config --nodes $ip --endpoints $cp --file $file 2>&1
      $code2 = $LASTEXITCODE
      $txt2  = ($out2 | Out-String)
      if ($code2 -eq 0) { return }
      throw "Secure apply-config failed on ${ip}:`n$txt2"
    }

    throw "Insecure apply-config failed on ${ip}:`n$txt1"
  }
  finally { $ErrorActionPreference = $prev }
}

function Bootstrap-TalosAndK8s {
  Show-Header "[2/6] Applying Talos configs" "Yellow"

  Preflight-TalosApi -Ips (@($ControlPlaneIP) + $WorkerIPs)

  Apply-NodeConfig -ip $ControlPlaneIP -role "controlplane" -cp $ControlPlaneIP
  Start-Sleep -Seconds 5
  foreach ($w in $WorkerIPs) { Apply-NodeConfig -ip $w -role "worker" -cp $ControlPlaneIP }

  Show-Header "[3/6] Bootstrapping Kubernetes control plane (etcd bootstrap)" "Yellow"
  & talosctl bootstrap --nodes $ControlPlaneIP --endpoints $ControlPlaneIP 2>&1 | Out-Null

  Start-Sleep -Seconds 10

  Show-Header "[4/6] Waiting for Kubernetes API (port 6443)" "Yellow"
  if (-not (Wait-ForPort -Ip $ControlPlaneIP -Port 6443 -TimeoutSeconds $TimeoutK8sApiSeconds -Label "Kubernetes API")) {
    throw "Kubernetes API did not come up on $ControlPlaneIP:6443"
  }

  Show-Header "[5/6] Fetching kubeconfig + waiting for kubectl" "Yellow"
  & talosctl kubeconfig $Kubeconfig --nodes $ControlPlaneIP --endpoints $ControlPlaneIP --force | Out-Null
  if (-not (Test-Path $Kubeconfig)) { throw "kubeconfig was not created at: $Kubeconfig" }

  $start = Get-Date
  while ($true) {
    & kubectl --kubeconfig $Kubeconfig get nodes -o name 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { break }
    if (((Get-Date)-$start).TotalSeconds -ge $TimeoutKubectlSeconds) {
      throw "kubectl did not become ready in time."
    }
    Start-Sleep -Seconds 5
  }
}

function Kube { param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args) & kubectl --kubeconfig $Kubeconfig @Args }

function Install-MetalLB {
  Show-Header "[6/6] Installing MetalLB" "Yellow"
  $metallbBase    = Join-Path $RepoRoot "02-metallb\base"
  $metallbOverlay = Join-Path $RepoRoot "02-metallb\overlays\example"
  if (-not (Test-Path $metallbBase))    { throw "Missing folder: $metallbBase" }
  if (-not (Test-Path $metallbOverlay)) { throw "Missing folder: $metallbOverlay" }

  Kube apply -f $metallbBase | Out-Null

  $poolFile = Join-Path $metallbOverlay "metallb-pool.yaml"
  if (Test-Path $poolFile) {
    $content = Get-Content $poolFile -Raw
    $content = [regex]::Replace($content,'(?m)^\s*-\s*\d{1,3}(\.\d{1,3}){3}/32\s*$',"    - $VipIP/32")
    Set-Content -Path $poolFile -Value $content -Encoding utf8
  }

  Kube apply -f $metallbOverlay | Out-Null
}

function Install-IngressNginx {
  Show-Header "Installing ingress-nginx (Helm)" "Yellow"
  $env:KUBECONFIG = $Kubeconfig
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx | Out-Null
  helm repo update | Out-Null
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace --set controller.service.type=LoadBalancer | Out-Null
  Kube rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=240s | Out-Null
}

function Install-AppAndIngress {
  Show-Header "Deploying sample app + ingress rule" "Yellow"
  $appDir      = Join-Path $RepoRoot "04-app"
  $ingressYaml = Join-Path $RepoRoot "03-ingress\nginx-ingress.yaml"
  if (-not (Test-Path $appDir))      { throw "Missing folder: $appDir" }
  if (-not (Test-Path $ingressYaml)) { throw "Missing file: $ingressYaml" }
  Kube apply -f $appDir | Out-Null
  Kube apply -f $ingressYaml | Out-Null
}

# MAIN
Clear-Host
Remove-Item -Force -ErrorAction SilentlyContinue $LogPath

Show-Header "== CITA 360 Talos + Kubernetes Bootstrap ==" "Cyan"
Log "Repo root: $RepoRoot"

Assert-Command talosctl
Assert-Command kubectl
Assert-Command git
Assert-Command helm

$allNodes = @($ControlPlaneIP) + $WorkerIPs

# If kubectl works and not forcing rebuild, skip rebuild
$clusterOk = $false
if (-not $ForceRebuild -and (Test-Path $Kubeconfig)) {
  & kubectl --kubeconfig $Kubeconfig get nodes -o name 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { $clusterOk = $true }
}

if (-not $clusterOk) {
  Generate-TalosConfigs

  # HARD STOP: do not proceed unless ALL resets succeed
  Reset-Nodes -Ips $allNodes

  # After reset, generate fresh PKI again and proceed
  Generate-TalosConfigs
  Bootstrap-TalosAndK8s

  Log "Rebuild complete. kubectl is working."
}

Install-MetalLB
Install-IngressNginx
Install-AppAndIngress

Write-Host ""
Write-Host "Cluster summary:" -ForegroundColor Cyan
Kube get nodes -o wide
Kube get pods -A
Kube get svc -A
Kube get ingress

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Test URL (inside lab network): http://$VipIP"
