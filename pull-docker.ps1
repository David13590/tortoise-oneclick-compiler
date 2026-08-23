<#
  Tortoise-WoW - Pull from DOCKER source
  =================================================================
  Dumps accounts + characters from your Docker build (Nescabir/tortoise-docker)
  into .sql files in .\transfer-dumps. Doesn't touch the new server at all -
  safe to run any time the Docker stack is up, regardless of what the new
  server's database is doing.

  Run transfer-apply.ps1 afterward to actually load this into the new server.
#>

# ---------------- CONFIG ----------------
$SrcHost     = "127.0.0.1"
$SrcPort     = 3306        # the host port your docker-compose.override.yml exposes -
                            # double check this matches what you actually set
$SrcUser     = "root"      # adjust if your Docker db uses different credentials
$SrcPassword = "root"

$Label   = "docker"
$DumpDir = "$PSScriptRoot\transfer-dumps"
# The portable MariaDB client tools - bundled with the new server, used here purely as a
# dump CLIENT (doesn't touch the new server's own database at all).
$MariadbBin = "$PSScriptRoot\DB\bin"
# ------------------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "`n[FAILED] $msg" -ForegroundColor Red; Read-Host "`nPress Enter to close"; exit 1 }

$dumpClient = "$MariadbBin\mariadb-dump.exe"
if (-not (Test-Path $dumpClient)) { Fail "mariadb-dump.exe not found at $dumpClient - this script needs to sit next to your compiled server (in E:\TortoiseCompiled, alongside the DB folder)." }

New-Item -ItemType Directory -Force -Path $DumpDir | Out-Null

Step "Pulling from Docker source ($SrcHost`:$SrcPort)"
$dumpArgs = @("-h", $SrcHost, "-P", $SrcPort, "-u", $SrcUser)
if ($SrcPassword) { $dumpArgs += "-p$SrcPassword" }

$logonDump = "$DumpDir\$Label`_logon.sql"
$charDump  = "$DumpDir\$Label`_char.sql"

Write-Host "Dumping tw_logon (account, account_banned - excluding auto-generated RNDBOT* playerbot accounts)..."
& $dumpClient @dumpArgs --where="username NOT LIKE 'RNDBOT%'" tw_logon account > $logonDump
& $dumpClient @dumpArgs --no-create-info tw_logon account_banned >> $logonDump
if ($LASTEXITCODE -ne 0) { Fail "Could not dump tw_logon. Is the Docker stack up (docker compose up -d) and is $SrcPort the port it's actually exposed on?" }

Write-Host "Dumping tw_char (full database, excluding RNDBOT-owned characters, this can take a minute)..."

# Dump all tw_char tables except characters first.
& $dumpClient @dumpArgs --ignore-table="tw_char.characters" tw_char > $charDump
if ($LASTEXITCODE -ne 0) { Fail "Could not dump tw_char (non-characters tables)." }

# Get RNDBOT account IDs separately. Avoids a cross-database subquery inside mariadb-dump.
$mariadbClient = "$MariadbBin\mariadb.exe"
if (-not (Test-Path $mariadbClient)) { Fail "mariadb.exe not found at $mariadbClient." }

$rnDBotIds = @(& $mariadbClient @dumpArgs -N -B -e "SELECT id FROM tw_logon.account WHERE username LIKE 'RNDBOT%';")
if ($LASTEXITCODE -ne 0) { Fail "Could not query RNDBOT account IDs from tw_logon." }

$rnDBotIds = @($rnDBotIds | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -match '^\d+$' })

if ($rnDBotIds.Count -gt 0) {
    Write-Host "Excluding $($rnDBotIds.Count) RNDBOT account IDs from tw_char.characters..."
    $rnDBotList = $rnDBotIds -join ','
    & $dumpClient @dumpArgs --where="account NOT IN ($rnDBotList)" tw_char characters >> $charDump
} else {
    Write-Host "No RNDBOT accounts found; dumping all tw_char.characters..."
    & $dumpClient @dumpArgs tw_char characters >> $charDump
}

if ($LASTEXITCODE -ne 0) { Fail "Could not dump tw_char.characters." }

Step "DONE"
Write-Host "Dumped to:" -ForegroundColor Green
Write-Host "  $logonDump"
Write-Host "  $charDump"
Write-Host "`nRun transfer-apply.ps1 next to load this into the new server." -ForegroundColor Yellow
Read-Host "`nPress Enter to close"
