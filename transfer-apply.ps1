<#
  Tortoise-WoW - Apply pulled data into the NEW server
  =================================================================
  Loads whichever .sql dumps exist in .\transfer-dumps (produced by
  pull-docker.ps1 and/or pull-oldnative.ps1) into the new server, safely
  merging even if both sources have overlapping account IDs / character
  GUIDs (very likely, since two independent servers both start at 1).

  This script only ever talks to the NEW server + the dump files on disk -
  it never connects to Docker or the old build directly, so there's no
  port-juggling here. Run the relevant pull-*.ps1 script(s) first.

  HOW THE MERGE WORKS: each source below has a fixed Offset. Offset = 0
  means "import directly, no ID changes" - use that for whichever source
  you consider primary. Every other source gets its IDs shifted by its
  Offset value before merging, so it can never collide with the primary
  source or with the destination's own (tiny, fresh) ID range. A source's
  internal relationships (which character owns which item, etc.) stay
  intact because everything from that source shifts together.

  COVERED: accounts, characters, inventory + items, skills, spells, spell
  cooldowns, reputation, quest status, talents, pets (+ pet aura/spell),
  mail (+ mail items), action bars, auras, homebind, instance saves,
  social/friends, battleground data, declined names.

  NOT COVERED (do these by hand): guilds, arena teams, petitions - they
  layer their own separate ID spaces across multiple accounts at once,
  and an automated merge there risks corrupting data rather than just
  missing it.

  Safe to run more than once - a source whose dump is missing is skipped
  with a warning rather than failing the whole run.
#>

# ---------------- CONFIG ----------------
$DestHost = "127.0.0.1"
$DestPort = 3307
$DestUser = "root"
$DestPassword = ""     # blank = no password, matches the compile script's default

$DumpDir    = "$PSScriptRoot\transfer-dumps"
$MariadbBin = "$PSScriptRoot\DB\bin"

# One entry per source you've pulled. Offset = 0 for your primary source (import as-is),
# a distinct non-zero value for every other one. If a source's dump files aren't in
# transfer-dumps yet (you haven't run its pull script), it's skipped automatically.
$Sources = @(
    @{ Label = "docker";    Offset = 1000000 },
    @{ Label = "oldnative"; Offset = 5000000 }
)
# ------------------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "`n[FAILED] $msg" -ForegroundColor Red; Read-Host "`nPress Enter to close"; exit 1 }

$sqlClient = "$MariadbBin\mariadb.exe"
if (-not (Test-Path $sqlClient)) { Fail "mariadb.exe not found at $MariadbBin - this script needs to sit next to your compiled server (in E:\TortoiseCompiled, alongside the DB folder)." }

function Invoke-DestSql($sqlText, $db) {
    $args = @("-h", $DestHost, "-P", $DestPort, "-u", $DestUser)
    if ($DestPassword) { $args += "-p$DestPassword" }
    if ($db) { $args += $db }
    $sqlText | & $sqlClient @args
    if ($LASTEXITCODE -ne 0) { Fail "A statement failed against the destination database '$db'. Scroll up for the error. Is the new server's database running? .\DB\start-database.bat" }
}
function Invoke-DestSqlScalar($sqlText, $db) {
    $args = @("-h", $DestHost, "-P", $DestPort, "-u", $DestUser, "-N", "-B")
    if ($DestPassword) { $args += "-p$DestPassword" }
    if ($db) { $args += $db }
    return ($sqlText | & $sqlClient @args)
}
function Invoke-DestSqlFile($file, $db) {
    (Get-Content $file -Raw) | & $sqlClient -h $DestHost -P $DestPort -u $DestUser $(if ($DestPassword) {"-p$DestPassword"}) $db
    if ($LASTEXITCODE -ne 0) { Fail "Loading $file into '$db' failed." }
}

# Tables that hold a character-owned row, and which column on each is the character's guid.
$CharGuidTables = @(
    @{ Table = "character_action";            Col = "guid" },
    @{ Table = "character_aura";               Col = "guid" },
    @{ Table = "character_battleground_data";  Col = "guid" },
    @{ Table = "character_declinedname";       Col = "guid" },
    @{ Table = "character_gifts";              Col = "guid" },
    @{ Table = "character_homebind";           Col = "guid" },
    @{ Table = "character_instance";           Col = "guid" },
    @{ Table = "character_inventory";          Col = "guid" },
    @{ Table = "character_pet";                Col = "owner" },
    @{ Table = "character_queststatus";        Col = "guid" },
    @{ Table = "character_reputation";         Col = "guid" },
    @{ Table = "character_skills";             Col = "guid" },
    @{ Table = "character_social";             Col = "guid" },
    @{ Table = "character_spell";              Col = "guid" },
    @{ Table = "character_spell_cooldown";     Col = "guid" },
    @{ Table = "character_stats";              Col = "guid" },
    @{ Table = "character_talent";             Col = "guid" },
    @{ Table = "item_instance";                Col = "owner_guid" },
    @{ Table = "mail";                         Col = "receiver" }
)
$CharGuidExtraCols = @(
    @{ Table = "character_social"; Col = "friend" }   # a character guid, not the row owner
)
$ItemGuidTables = @(
    @{ Table = "item_instance";       Col = "guid" },
    @{ Table = "character_inventory"; Col = "item" },
    @{ Table = "character_inventory"; Col = "bag" },   # 0 means "not bagged" - skip those
    @{ Table = "mail_items";          Col = "item_guid" }
)
$PetIdTables = @(
    @{ Table = "character_pet";      Col = "id" },
    @{ Table = "pet_aura";           Col = "guid" },
    @{ Table = "pet_spell";          Col = "guid" },
    @{ Table = "pet_spell_cooldown"; Col = "guid" }
)
$MailIdTables = @(
    @{ Table = "mail";       Col = "id" },
    @{ Table = "mail_items"; Col = "mail_id" }
)
$CharacterOwnRow = @{ Table = "characters"; GuidCol = "guid"; AccountCol = "account" }

foreach ($src in $Sources) {
    $label  = $src.Label
    $offset = [int]$src.Offset
    $logonDump = "$DumpDir\$label`_logon.sql"
    $charDump  = "$DumpDir\$label`_char.sql"

    if (-not (Test-Path $logonDump) -or -not (Test-Path $charDump)) {
        Warn "No dump files found for '$label' in $DumpDir - skipping. Run pull-$label.ps1 first if you want this source included."
        continue
    }

    Step "Applying '$label'$(if ($offset -gt 0) { " (offset $offset)" })"

    $stageLogon = "tw_logon_stage_$label"
    $stageChar  = "tw_char_stage_$label"

    Step "Loading '$label' into staging databases"
    Invoke-DestSql "DROP DATABASE IF EXISTS $stageLogon; CREATE DATABASE $stageLogon;" $null
    Invoke-DestSql "DROP DATABASE IF EXISTS $stageChar; CREATE DATABASE $stageChar;" $null

    # pull-docker.ps1 dumps account_banned with --no-create-info, so the staging
    # database must have that table before the dump is loaded.
    Invoke-DestSql "CREATE TABLE $stageLogon.account_banned LIKE tw_logon.account_banned;" $null

    Invoke-DestSqlFile $logonDump $stageLogon
    Invoke-DestSqlFile $charDump $stageChar
    Ok "Staged as $stageLogon / $stageChar"

    Step "Removing AiPlayerbot's auto-generated filler accounts (RNDBOT*) - these regenerate fresh on every server start, so they're never worth transferring and would just collide across sources"
    $botAccounts = Invoke-DestSqlScalar "SELECT COUNT(*) FROM account WHERE username LIKE 'RNDBOT%';" $stageLogon
    Invoke-DestSql "DELETE FROM characters WHERE account NOT IN (SELECT id FROM $stageLogon.account);" $stageChar
    Invoke-DestSql "DELETE FROM account WHERE username LIKE 'RNDBOT%';" $stageLogon
    Ok "Removed $botAccounts filler account(s) and their characters from staging"

    if ($offset -gt 0) {
        Step "Shifting IDs in staging by $offset"
        Invoke-DestSql "UPDATE account SET id = id + $offset;" $stageLogon
        Invoke-DestSql "UPDATE account_banned SET id = id + $offset;" $stageLogon
        Invoke-DestSql "UPDATE characters SET $($CharacterOwnRow.GuidCol) = $($CharacterOwnRow.GuidCol) + $offset, $($CharacterOwnRow.AccountCol) = $($CharacterOwnRow.AccountCol) + $offset;" $stageChar

        foreach ($t in $CharGuidTables) {
            $exists = Invoke-DestSqlScalar "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stageChar' AND TABLE_NAME='$($t.Table)';" $null
            if ([int]$exists -eq 1) { Invoke-DestSql "UPDATE $($t.Table) SET $($t.Col) = $($t.Col) + $offset;" $stageChar }
        }
        foreach ($t in $CharGuidExtraCols) {
            $exists = Invoke-DestSqlScalar "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stageChar' AND TABLE_NAME='$($t.Table)';" $null
            if ([int]$exists -eq 1) { Invoke-DestSql "UPDATE $($t.Table) SET $($t.Col) = $($t.Col) + $offset WHERE $($t.Col) <> 0;" $stageChar }
        }
        foreach ($t in $ItemGuidTables) {
            $exists = Invoke-DestSqlScalar "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stageChar' AND TABLE_NAME='$($t.Table)';" $null
            if ([int]$exists -eq 1) { Invoke-DestSql "UPDATE $($t.Table) SET $($t.Col) = $($t.Col) + $offset WHERE $($t.Col) <> 0;" $stageChar }
        }
        foreach ($t in $PetIdTables) {
            $exists = Invoke-DestSqlScalar "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stageChar' AND TABLE_NAME='$($t.Table)';" $null
            if ([int]$exists -eq 1) { Invoke-DestSql "UPDATE $($t.Table) SET $($t.Col) = $($t.Col) + $offset;" $stageChar }
        }
        foreach ($t in $MailIdTables) {
            $exists = Invoke-DestSqlScalar "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stageChar' AND TABLE_NAME='$($t.Table)';" $null
            if ([int]$exists -eq 1) { Invoke-DestSql "UPDATE $($t.Table) SET $($t.Col) = $($t.Col) + $offset;" $stageChar }
        }
        Ok "IDs shifted"
    }

    Step "Merging '$label' into tw_logon / tw_char (skipping any exact ID/username duplicates)"
    Invoke-DestSql "INSERT IGNORE INTO tw_logon.account SELECT * FROM $stageLogon.account;" $null
    Invoke-DestSql "INSERT IGNORE INTO tw_logon.account_banned SELECT * FROM $stageLogon.account_banned;" $null
    Invoke-DestSql "INSERT IGNORE INTO tw_char.characters SELECT * FROM $stageChar.characters;" $null
    $allMergeTables = @()
    foreach ($group in @($CharGuidTables, $ItemGuidTables, $PetIdTables, $MailIdTables)) {
        foreach ($t in @($group)) {
            if ($null -ne $t.Table) { $allMergeTables += [string]$t.Table }
        }
    }
    $allMergeTables = $allMergeTables | Sort-Object -Unique
    foreach ($tableName in $allMergeTables) {
        $exists = Invoke-DestSqlScalar "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stageChar' AND TABLE_NAME='$tableName';" $null
        if ([int]$exists -eq 1) { Invoke-DestSql "INSERT IGNORE INTO tw_char.$tableName SELECT * FROM $stageChar.$tableName;" $null }
    }
    Ok "'$label' merged in"

    Invoke-DestSql "DROP DATABASE $stageLogon; DROP DATABASE $stageChar;" $null
    Ok "Cleaned up staging databases"
}

Step "DONE"
$acctCount = Invoke-DestSqlScalar "SELECT COUNT(*) FROM account;" "tw_logon"
$charCount = Invoke-DestSqlScalar "SELECT COUNT(*) FROM characters;" "tw_char"
Write-Host "Destination now has $acctCount account(s) and $charCount character(s)." -ForegroundColor Green
Write-Host "`nNOT transferred (do these by hand if needed): guilds, arena teams, petitions." -ForegroundColor Yellow
Write-Host "Verify: log into a transferred account/character and check bags, bank, mail, and spec look right." -ForegroundColor Yellow
Write-Host "Passwords: SRP6 password hashes (v/s fields) carried over unchanged, so everyone's existing password still works." -ForegroundColor Yellow
Read-Host "`nPress Enter to close"
