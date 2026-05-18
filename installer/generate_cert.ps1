# LocalHub self-signed code signing sertifikasi olusturucu.
# Tek seferlik calistirilir, ciktilar installer/cert/ icine yazilir.
# Sertifika 5 yil gecerli, RSA 2048 bit.

param(
  [string]$Password = "LocalHubDev2026!"
)

$ErrorActionPreference = "Stop"
$certDir = Join-Path $PSScriptRoot "cert"
$pfxPath = Join-Path $certDir "LocalHub.pfx"
$cerPath = Join-Path $certDir "LocalHub.cer"

New-Item -ItemType Directory -Force -Path $certDir | Out-Null

if (Test-Path $pfxPath) {
  Write-Host "[INFO] Sertifika zaten mevcut: $pfxPath" -ForegroundColor Yellow
  Write-Host "Tekrar olusturmak istiyorsan once sil."
  exit 0
}

Write-Host "[1/3] Self-signed code signing sertifikasi olusturuluyor..."
$cert = New-SelfSignedCertificate `
  -Type CodeSigningCert `
  -Subject "CN=LocalHub, O=LocalHub, C=TR" `
  -KeyUsage DigitalSignature `
  -FriendlyName "LocalHub Code Signing" `
  -CertStoreLocation "Cert:\CurrentUser\My" `
  -NotAfter (Get-Date).AddYears(5) `
  -KeyAlgorithm RSA `
  -KeyLength 2048 `
  -HashAlgorithm sha256

Write-Host "  Thumbprint: $($cert.Thumbprint)"

Write-Host "[2/3] PFX olarak disa aktariliyor: $pfxPath"
$pwd = ConvertTo-SecureString -String $Password -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $pwd | Out-Null

Write-Host "[3/3] CER (public) disa aktariliyor: $cerPath"
Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null

# CurrentUser store'dan temizle - artik PFX'te tutuyoruz
Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force

Write-Host ""
Write-Host "[OK] Sertifika hazirlandi" -ForegroundColor Green
Write-Host "  PFX: $pfxPath (sifre: $Password)"
Write-Host "  CER: $cerPath"
Write-Host ""
Write-Host "NOT: PFX dosyasini .gitignore'a ekle - asla commit etme!"
