<#
  Tortoise-WoW - Pull from OLD NATIVE BUILD source
  =================================================================
  Dumps accounts + characters from your earlier native build
  (E:\Turtle1181bots) into .sql files in .\transfer-dumps.

  IMPORTANT:
    The old build's database must be running on port 3307.
    The new server's database must NOT be running on port 3307
    while this script is being executed.

  This script:
    - Dumps tw_logon.account excluding RNDBOT* accounts
    - Dumps tw_logon.account_banned
    - Dumps all tw_char tables
    - Dumps tw_char.characters excluding RNDBOT-owned characters
    - Avoids the cross-database subquery that causes mariadb-dump
      to fail on the characters table
#>

# ---------------- CONFIG ----------------

$SrcHost     = "127.0.0.1"
$SrcPort     = 3307
$SrcUser     = "mangos"
$SrcPassword = "mangos"

$Label   = "oldnative"
$DumpDir = "$PSScriptRoot\transfer-dumps"

# MariaDB client tools bundled with the new server.
# Only the CLIENT is used here; the new server's MariaDB does not
# need to be running while this script talks to the old database.
$MariadbBin = "$PSScriptRoot\DB\bin"

# ------------------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

function Step($msg) {
    Write-Host "`n=== $msg ===" -ForegroundColor Cyan
}

function Ok($msg) {
    Write-Host "[OK] $msg" -ForegroundColor Green
}

function Fail($msg) {
    Write-Host "`n[FAILED] $msg" -ForegroundColor Red
    Read-Host "`nPress Enter to close"
    exit 1
}

# ---------------- CHECK CLIENTS ----------------

$dumpClient = "$MariadbBin\mariadb-dump.exe"
$sqlClient  = "$MariadbBin\mariadb.exe"

if (-not (Test-Path $dumpClient)) {
    Fail "mariadb-dump.exe not found at $dumpClient. This script must sit next to the DB folder."
}

if (-not (Test-Path $sqlClient)) {
    Fail "mariadb.exe not found at $sqlClient. This script must sit next to the DB folder."
}

New-Item -ItemType Directory -Force -Path $DumpDir | Out-Null

# ---------------- CONNECTION ARGUMENTS ----------------

Step "Pulling from old native build ($SrcHost`:$SrcPort)"

$dumpArgs = @(
    "-h", $SrcHost,
    "-P", $SrcPort,
    "-u", $SrcUser
)

if ($SrcPassword) {
    $dumpArgs += "-p$SrcPassword"
}

$sqlArgs = @(
    "-h", $SrcHost,
    "-P", $SrcPort,
    "-u", $SrcUser
)

if ($SrcPassword) {
    $sqlArgs += "-p$SrcPassword"
}

$logonDump = "$DumpDir\$Label`_logon.sql"
$charDump  = "$DumpDir\$Label`_char.sql"

# Remove old dump files first so a failed/new dump cannot accidentally
# leave data from an earlier run at the end of the file.
Remove-Item $logonDump -Force -ErrorAction SilentlyContinue
Remove-Item $charDump  -Force -ErrorAction SilentlyContinue

# ---------------- TEST CONNECTION ----------------

Write-Host "Testing connection to old database..."

& $sqlClient @sqlArgs -N -B -e "SELECT 1;" > $null

if ($LASTEXITCODE -ne 0) {
    Fail "Could not connect to the old database at $SrcHost`:$SrcPort. Make sure the OLD build's database is running and the NEW database is stopped."
}

Ok "Connected to old database"

# ---------------- LOGON ----------------

Write-Host "Dumping tw_logon.account (excluding auto-generated RNDBOT* accounts)..."

& $dumpClient @dumpArgs `
    --where="username NOT LIKE 'RNDBOT%'" `
    tw_logon account > $logonDump

if ($LASTEXITCODE -ne 0) {
    Fail "Could not dump tw_logon.account."
}

Write-Host "Dumping tw_logon.account_banned..."

& $dumpClient @dumpArgs `
    --no-create-info `
    tw_logon account_banned >> $logonDump

if ($LASTEXITCODE -ne 0) {
    Fail "Could not dump tw_logon.account_banned."
}

Ok "tw_logon dumped"

# ---------------- GET RND BOT ACCOUNT IDS ----------------
#
# Do NOT use:
#
#   --where="account NOT IN (SELECT id FROM tw_logon.account ...)"
#
# because that cross-database subquery is what causes mariadb-dump
# to fail on tw_char.characters.
#
# Instead, query the RNDBOT IDs first and turn them into a simple
# numeric NOT IN (...) expression.

Write-Host "Reading RNDBOT account IDs from old database..."

$rnDBotIds = & $sqlClient @sqlArgs -N -B -e `
    "SELECT id FROM tw_logon.account WHERE username LIKE 'RNDBOT%';"

if ($LASTEXITCODE -ne 0) {
    Fail "Could not query RNDBOT account IDs from tw_logon.account."
}

$rnDBotIds = @(
    $rnDBotIds |
        ForEach-Object {
            $_.ToString().Trim()
        } |
        Where-Object {
            $_ -match '^\d+$'
        }
)

Write-Host "Found $($rnDBotIds.Count) RNDBOT account(s)."

# ---------------- CHAR DATABASE ----------------

Write-Host "Dumping tw_char (all tables except characters)..."

& $dumpClient @dumpArgs `
    --ignore-table="tw_char.characters" `
    tw_char > $charDump

if ($LASTEXITCODE -ne 0) {
    Fail "Could not dump the non-characters tables from tw_char."
}

# ---------------- CHARACTERS TABLE ----------------

if ($rnDBotIds.Count -gt 0) {

    $rnDBotList = $rnDBotIds -join ","

    Write-Host "Dumping tw_char.characters excluding RNDBOT-owned characters..."
    Write-Host "Excluding account IDs: $rnDBotList"

    & $dumpClient @dumpArgs `
        --where="account NOT IN ($rnDBotList)" `
        tw_char characters >> $charDump

    if ($LASTEXITCODE -ne 0) {
        Fail "Could not dump tw_char.characters."
    }

}
else {

    Write-Host "No RNDBOT accounts found. Dumping all tw_char.characters..."

    & $dumpClient @dumpArgs `
        tw_char characters >> $charDump

    if ($LASTEXITCODE -ne 0) {
        Fail "Could not dump tw_char.characters."
    }
}

Ok "tw_char dumped"

# ---------------- BASIC VALIDATION ----------------

if (-not (Test-Path $logonDump)) {
    Fail "The logon dump was not created."
}

if (-not (Test-Path $charDump)) {
    Fail "The character dump was not created."
}

$logonSize = (Get-Item $logonDump).Length
$charSize  = (Get-Item $charDump).Length

if ($logonSize -eq 0) {
    Fail "The logon dump is empty."
}

if ($charSize -eq 0) {
    Fail "The character dump is empty."
}

# Count transferred non-RNDBOT accounts from the dump.
$accountInsertLines = Select-String `
    -Path $logonDump `
    -Pattern "^INSERT INTO ``account``" `
    -SimpleMatch `
    -ErrorAction SilentlyContinue

# Count character INSERT statements.
$characterInsertLines = Select-String `
    -Path $charDump `
    -Pattern "^INSERT INTO ``characters``" `
    -SimpleMatch `
    -ErrorAction SilentlyContinue

# ---------------- DONE ----------------

Step "DONE"

Write-Host "Dumped to:" -ForegroundColor Green
Write-Host "  $logonDump"
Write-Host "  $charDump"

Write-Host ""
Write-Host "Logon dump size: $logonSize bytes"
Write-Host "Char dump size:  $charSize bytes"

if ($accountInsertLines) {
    Write-Host "Account INSERT statement(s): found" -ForegroundColor Green
}
else {
    Write-Host "WARNING: No account INSERT statement found in the logon dump." -ForegroundColor Yellow
}

if ($characterInsertLines) {
    Write-Host "Character INSERT statement(s): found" -ForegroundColor Green
}
else {
    Write-Host "WARNING: No character INSERT statement found in the character dump." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "The old database can now be stopped." -ForegroundColor Yellow
Write-Host "Start the new server database again, then run transfer-apply.ps1." -ForegroundColor Yellow

Read-Host "`nPress Enter to close"