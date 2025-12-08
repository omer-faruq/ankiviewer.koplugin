local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local ffiUtil = require("ffi/util")
local util = require("util")
local logger = require("logger")

local DB = {}

local DB_SCHEMA_VERSION = 3
local DB_DIRECTORY = ffiUtil.joinPath(DataStorage:getDataDir(), "ankiviewer")
local DB_PATH = ffiUtil.joinPath(DB_DIRECTORY, "ankiviewer.sqlite3")

local SCHEMA_STATEMENTS = {
    [[CREATE TABLE IF NOT EXISTS decks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE
    )]],
    [[CREATE TABLE IF NOT EXISTS cards (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        deck_id INTEGER NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
        front TEXT NOT NULL,
        back TEXT NOT NULL,
        ease REAL NOT NULL DEFAULT 2.5,
        interval REAL NOT NULL DEFAULT 0,
        due INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        reps INTEGER NOT NULL DEFAULT 0,
        lapses INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
    )]],
    [[CREATE INDEX IF NOT EXISTS idx_cards_deck ON cards(deck_id)]],
    [[CREATE TABLE IF NOT EXISTS source_notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        deck_id INTEGER NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
        mid TEXT,
        flds TEXT NOT NULL
    )]],
    [[CREATE INDEX IF NOT EXISTS idx_source_notes_deck ON source_notes(deck_id)]],
}

local initialized = false

local function execStatements(conn, statements)
    for _, statement in ipairs(statements) do
        local trimmed = util.trim(statement)
        if trimmed ~= "" then
            local final_stmt = trimmed
            if not final_stmt:find(";%s*$") then
                final_stmt = final_stmt .. ";"
            end
            local ok, err = pcall(conn.exec, conn, final_stmt)
            if not ok then
                error(string.format("ankiviewer sqlite schema error: %s -- %s", final_stmt, err))
            end
        end
    end
end

local function ensureDirectory()
    local ok, err = util.makePath(DB_DIRECTORY)
    if not ok then
        logger.warn("ankiviewer: unable to create database directory", err)
    end
end

local function openConnection()
    ensureDirectory()
    local conn = SQ3.open(DB_PATH)
    conn:exec("PRAGMA foreign_keys = ON;")
    conn:exec("PRAGMA synchronous = NORMAL;")
    conn:exec("PRAGMA journal_mode = WAL;")
    return conn
end

local function withConnection(fn)
    local conn = openConnection()
    local results = { pcall(fn, conn) }
    conn:close()
    if not results[1] then
        error(results[2])
    end
    return table.unpack(results, 2)
end

function DB.init()
    if initialized then
        return
    end
    ensureDirectory()
    local conn = openConnection()
    local current_version = tonumber(conn:rowexec("PRAGMA user_version;")) or 0
    if current_version < DB_SCHEMA_VERSION then
        -- Drop existing schema when we change SRS structure.
        conn:exec("PRAGMA writable_schema = ON;")
        conn:exec("DELETE FROM sqlite_master WHERE type IN ('table','index','trigger');")
        conn:exec("PRAGMA writable_schema = OFF;")
        conn:exec("VACUUM;")
        execStatements(conn, SCHEMA_STATEMENTS)
        conn:exec("PRAGMA user_version = " .. DB_SCHEMA_VERSION .. ";")
    else
        execStatements(conn, SCHEMA_STATEMENTS)
    end
    conn:close()
    initialized = true
end

function DB.importSimpleDeckFromPairs(deck_name, cards, overwrite)
    if not deck_name or deck_name == "" then
        return nil, "Missing deck name"
    end
    if not cards or #cards == 0 then
        return nil, "No cards to import"
    end
    DB.init()
    return withConnection(function(conn)
        local existing_id = conn:rowexec(string.format("SELECT id FROM decks WHERE name = '%s';", deck_name:gsub("'", "''")))
        local deck_id
        if existing_id then
            deck_id = tonumber(existing_id)
            if overwrite then
                local delete_cards = conn:prepare("DELETE FROM cards WHERE deck_id = ?;")
                delete_cards:bind(deck_id)
                delete_cards:step()
                delete_cards:close()
            end
        else
            local insert_deck = conn:prepare("INSERT INTO decks (name) VALUES (?);")
            insert_deck:bind(deck_name)
            insert_deck:step()
            insert_deck:close()
            local new_id = conn:rowexec("SELECT last_insert_rowid();")
            deck_id = new_id and tonumber(new_id) or nil
        end
        if not deck_id then
            return nil, "Failed to create or find deck"
        end
        local insert_card = conn:prepare("INSERT INTO cards (deck_id, front, back) VALUES (?, ?, ?);")
        local count = 0
        for _, pair in ipairs(cards) do
            local front = pair.front or ""
            local back = pair.back or ""
            if front ~= "" or back ~= "" then
                insert_card:reset()
                insert_card:bind(deck_id, front, back)
                insert_card:step()
                count = count + 1
            end
        end
        insert_card:close()
        return deck_id, count
    end)
end

function DB.deleteDeck(deck_id)
    if not deck_id then
        return false, "Missing deck id"
    end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare("DELETE FROM decks WHERE id = ?;")
        stmt:bind(deck_id)
        stmt:step()
        stmt:close()
        return true
    end)
end

function DB.storeSourceNotes(deck_id, notes)
    if not deck_id then
        return nil, "Missing deck id"
    end
    DB.init()
    return withConnection(function(conn)
        local delete_stmt = conn:prepare("DELETE FROM source_notes WHERE deck_id = ?;")
        delete_stmt:bind(deck_id)
        delete_stmt:step()
        delete_stmt:close()
        if not notes or #notes == 0 then
            return 0
        end
        local insert_stmt = conn:prepare("INSERT INTO source_notes (deck_id, mid, flds) VALUES (?, ?, ?);")
        local count = 0
        for _, note in ipairs(notes) do
            local mid = note.mid
            local flds = note.flds or ""
            if type(flds) == "string" and flds ~= "" then
                insert_stmt:reset()
                insert_stmt:bind(deck_id, mid, flds)
                insert_stmt:step()
                count = count + 1
            end
        end
        insert_stmt:close()
        return count
    end)
end

function DB.loadSourceNotes(deck_id)
    if not deck_id then
        return {}
    end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare("SELECT mid, flds FROM source_notes WHERE deck_id = ? ORDER BY id;")
        stmt:bind(deck_id)
        local notes = {}
        while true do
            local row = stmt:step()
            if not row then
                break
            end
            local mid = row[1]
            local flds = row[2]
            if type(flds) == "string" and flds ~= "" then
                notes[#notes + 1] = {
                    mid = mid,
                    flds = flds,
                }
            end
        end
        stmt:close()
        return notes
    end)
end

local function getOrCreateDefaultDeckId(conn)
    local existing_id = conn:rowexec("SELECT id FROM decks WHERE name = 'Default';")
    if existing_id then
        return tonumber(existing_id)
    end
    conn:exec("INSERT INTO decks (name) VALUES ('Default');")
    local new_id = conn:rowexec("SELECT last_insert_rowid();")
    return new_id and tonumber(new_id) or nil
end

local function coerceNumber(value, default)
    if value == nil then
        return default
    end
    local n = tonumber(value)
    if not n then
        return default
    end
    return n
end

local function mapCardRow(row)
    if not row then
        return nil
    end
    return {
        id = coerceNumber(row.id, nil),
        deck_id = coerceNumber(row.deck_id, nil),
        front = row.front,
        back = row.back,
        ease = coerceNumber(row.ease, 2.5),
        interval = coerceNumber(row.interval, 0),
        due = coerceNumber(row.due, os.time()),
        reps = coerceNumber(row.reps, 0),
        lapses = coerceNumber(row.lapses, 0),
    }
end

function DB.listDecks()
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[SELECT d.id, d.name, COUNT(c.id) AS card_count
            FROM decks d
            LEFT JOIN cards c ON c.deck_id = d.id
            GROUP BY d.id, d.name
            ORDER BY d.name COLLATE NOCASE;]])
        local rows = stmt:resultset("hik")
        stmt:close()
        if not rows or not rows[0] or #rows[0] == 0 then
            return {}
        end
        local headers = rows[0]
        local list = {}
        for i = 1, #rows[1] do
            local row = {}
            for col_index, col_name in ipairs(headers) do
                local column_values = rows[col_index]
                row[col_name] = column_values[i]
            end
            list[#list + 1] = {
                id = coerceNumber(row.id, nil),
                name = tostring(row.name or ""),
                card_count = coerceNumber(row.card_count, 0),
            }
        end
        return list
    end)
end

function DB.ensureSampleData()
    DB.init()
    return withConnection(function(conn)
        local deck_id = getOrCreateDefaultDeckId(conn)
        if not deck_id then
            return nil
        end
        local count = tonumber(conn:rowexec(string.format("SELECT COUNT(*) FROM cards WHERE deck_id = %d;", deck_id))) or 0
        if count == 0 then
            local insert_stmt = conn:prepare("INSERT INTO cards (deck_id, front, back) VALUES (?, ?, ?);")
            local samples = {
                { "Capital of France?", "Paris" },
                { "2 + 2 = ?", "4" },
                { "Author of \"1984\"?", "George Orwell" },
            }
            for _, pair in ipairs(samples) do
                insert_stmt:reset()
                insert_stmt:bind(deck_id, pair[1], pair[2])
                insert_stmt:step()
            end
            insert_stmt:close()
        end
        return deck_id
    end)
end

local function computeScheduling(card, rating, now_ts)
    local ease = card.ease or 2.5
    local interval = card.interval or 0
    local reps = card.reps or 0
    local lapses = card.lapses or 0
    local now = now_ts or os.time()

    local is_new = (interval == 0) and (reps == 0)

    -- New card behavior: mimic Anki-style initial steps
    if is_new then
        if rating == "again" then
            lapses = lapses + 1
            ease = math.max(1.3, ease - 0.2)
            local due = now + 1 * 60 -- ~<1m
            return ease, interval, reps, lapses, due
        elseif rating == "hard" then
            reps = reps + 1
            ease = math.max(1.3, ease - 0.15)
            local due = now + 6 * 60 -- ~<6m
            return ease, interval, reps, lapses, due
        elseif rating == "good" then
            reps = reps + 1
            local due = now + 10 * 60 -- ~<10m
            return ease, interval, reps, lapses, due
        elseif rating == "easy" then
            reps = reps + 1
            ease = ease + 0.15
            interval = 4 -- days
            local due = now + interval * 86400 -- 4d
            return ease, interval, reps, lapses, due
        end
    end

    -- Review card behavior (simplified SM-2 style)
    if rating == "again" then
        reps = 0
        lapses = lapses + 1
        interval = 0
        ease = math.max(1.3, ease - 0.2)
        local due = now + 10 * 60
        return ease, interval, reps, lapses, due
    elseif rating == "hard" then
        reps = reps + 1
        ease = math.max(1.3, ease - 0.15)
        if interval < 1 then
            interval = 1
        end
        interval = interval * 1.2
        local due = now + interval * 86400
        return ease, interval, reps, lapses, due
    elseif rating == "good" then
        reps = reps + 1
        if interval == 0 then
            interval = 1
        else
            interval = interval * ease
        end
        local due = now + interval * 86400
        return ease, interval, reps, lapses, due
    elseif rating == "easy" then
        reps = reps + 1
        ease = ease + 0.15
        if interval == 0 then
            interval = 3
        else
            interval = interval * ease * 1.3
        end
        local due = now + interval * 86400
        return ease, interval, reps, lapses, due
    end

    return ease, interval, reps, lapses, card.due or now
end

local function formatDelta(delta)
    if delta <= 0 then
        return "0m"
    end
    if delta < 3600 then
        local minutes = math.floor(delta / 60 + 0.5)
        return tostring(minutes) .. "m"
    end
    if delta < 86400 then
        local hours = math.floor(delta / 3600 + 0.5)
        return tostring(hours) .. "h"
    end
    local days = math.floor(delta / 86400 + 0.5)
    return tostring(days) .. "d"
end

function DB.fetchNextDueCard(deck_id, now_ts)
    DB.init()
    if not deck_id then
        return nil
    end
    local now = now_ts or os.time()
    return withConnection(function(conn)
        local stmt = conn:prepare([[SELECT id, deck_id, front, back, ease, interval, due, reps, lapses
            FROM cards
            WHERE deck_id = ? AND due <= ?
            ORDER BY due ASC
            LIMIT 1;]])
        stmt:bind(deck_id, now)
        local rows = stmt:resultset("hik")
        stmt:close()
        if not rows or not rows[1] or #rows[1] == 0 then
            return nil
        end
        local headers = rows[0]
        local row = {}
        for header_index, header in ipairs(headers) do
            local column_values = rows[header_index]
            row[header] = column_values[1]
        end
        return mapCardRow(row)
    end)
end

function DB.previewIntervals(card, now_ts)
    if not card or not card.id then
        return nil
    end
    local now = now_ts or os.time()
    local result = {}
    local ratings = { "again", "hard", "good", "easy" }
    for _, rating in ipairs(ratings) do
        local ease, interval, reps, lapses, due = computeScheduling(card, rating, now)
        local delta = due - now
        result[rating] = {
            ease = ease,
            interval = interval,
            reps = reps,
            lapses = lapses,
            due = due,
            label = formatDelta(delta),
        }
    end
    return result
end

function DB.updateCardScheduling(card, rating, now_ts)
    if not card or not card.id then
        return nil
    end
    DB.init()
    local now = now_ts or os.time()
    local new_ease, new_interval, new_reps, new_lapses, new_due = computeScheduling(card, rating, now)
    withConnection(function(conn)
        local stmt = conn:prepare([[UPDATE cards
            SET ease = ?, interval = ?, due = ?, reps = ?, lapses = ?, updated_at = ?
            WHERE id = ?;]])
        stmt:bind(new_ease, new_interval, new_due, new_reps, new_lapses, now, card.id)
        stmt:step()
        stmt:close()
    end)
    return {
        id = card.id,
        deck_id = card.deck_id,
        front = card.front,
        back = card.back,
        ease = new_ease,
        interval = new_interval,
        due = new_due,
        reps = new_reps,
        lapses = new_lapses,
    }
end

return DB
