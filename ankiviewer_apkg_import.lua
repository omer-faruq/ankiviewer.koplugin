local Archiver = require("ffi/archiver")
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local json = require("json")
local ffiUtil = require("ffi/util")
local util = require("util")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local Import = {}

local function getBaseDir()
    return DataStorage:getDataDir() .. "/ankiviewer"
end

local function getSharedDir()
    local dir = getBaseDir() .. "/shared"
    util.makePath(dir)
    return dir
end

local function getMediaRoot()
    local dir = getBaseDir() .. "/media"
    util.makePath(dir)
    return dir
end

local function getTempDir()
    local dir = getBaseDir() .. "/tmp"
    util.makePath(dir)
    return dir
end

local function splitExtension(path)
    local base = path
    local name = path
    local dot = path:match("^.*()%.")
    if dot then
        base = path:sub(1, dot - 1)
    end
    return base, name
end

function Import.listApkgFiles()
    local dir = getSharedDir()
    local files = {}

    local mode = lfs.attributes(dir, "mode")
    if mode ~= "directory" then
        return files
    end

    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            if entry:lower():match("%.apkg$") then
                local full = dir .. "/" .. entry
                local attr = lfs.attributes(full, "mode")
                if attr == "file" then
                    files[#files + 1] = {
                        name = entry,
                        path = full,
                    }
                end
            end
        end
    end

    table.sort(files, function(a, b)
        return a.name:lower() < b.name:lower()
    end)

    return files
end

local function findEntries(arc)
    local collection21_path
    local collection2_path
    local media_path

    for entry in arc:iterate() do
        if entry.mode == "file" then
            if entry.path:match("collection%.anki21$") then
                collection21_path = entry.path
            elseif entry.path:match("collection%.anki2$") then
                collection2_path = entry.path
            elseif entry.path == "media" or entry.path:match("/media$") then
                media_path = entry.path
            end
        end
    end

    local collection_path = collection21_path or collection2_path
    return collection_path, media_path
end

local function loadMediaMap(arc, media_entry)
    if not media_entry then
        return {}
    end
    local content = arc:extractToMemory(media_entry)
    if not content or content == "" then
        return {}
    end
    local ok, decoded = pcall(json.decode, content)
    if not ok or type(decoded) ~= "table" then
        logger.warn("AnkiViewer: failed to decode media map from apkg")
        return {}
    end
    return decoded
end

local function extractMediaFiles(arc, media_map, deck_media_dir)
    if not media_map or next(media_map) == nil then
        return
    end

    util.makePath(deck_media_dir)

    for entry in arc:iterate() do
        if entry.mode == "file" then
            local mapped = media_map[entry.path]
            if not mapped then
                mapped = media_map[tostring(entry.path)]
            end
            if mapped and mapped ~= "" then
                local safe_name = mapped:gsub("[\\:]", "_")
                local dest = deck_media_dir .. "/" .. safe_name
                local ok = arc:extractToPath(entry.path, dest)
                if not ok then
                    logger.warn("AnkiViewer: failed to extract media file from apkg", entry.path)
                end
            end
        end
    end
end

function Import.inspectApkg(apkg_path)
    if not apkg_path or apkg_path == "" then
        return false, "Missing apkg path"
    end

    local shared_dir = getSharedDir()
    local base_name = apkg_path
    if apkg_path:sub(1, #shared_dir) == shared_dir then
        base_name = apkg_path:sub(#shared_dir + 2)
    end
    local short_name = base_name
    local dot = short_name:match("^.*()%.")
    if dot then
        short_name = short_name:sub(1, dot - 1)
    end
    if short_name == "" then
        short_name = "Imported deck"
    end

    local arc = Archiver.Reader:new()
    local ok_open = arc:open(apkg_path)
    if not ok_open then
        return false, "Unable to open apkg archive"
    end

    local collection_entry, _ = findEntries(arc)
    if not collection_entry then
        arc:close()
        return false, "apkg archive does not contain collection.anki2"
    end

    local temp_dir = getTempDir()
    local collection_path = temp_dir .. "/collection.inspect.anki2"
    local ok_extract = arc:extractToPath(collection_entry, collection_path)
    arc:close()
    if not ok_extract then
        return false, "Failed to extract collection.anki2 from apkg"
    end

    local ok_result, result_or_err = pcall(function()
        local conn = SQ3.open(collection_path, "ro")
        conn:set_busy_timeout(5000)

        local models_json = conn:rowexec("SELECT models FROM col LIMIT 1;")
        local models = {}
        if models_json and models_json ~= "" then
            local ok_models, decoded = pcall(json.decode, models_json)
            if ok_models and type(decoded) == "table" then
                models = decoded
            else
                logger.warn("AnkiViewer: inspectApkg failed to decode models JSON")
            end
        end

        local result = {
            short_name = short_name,
            models = {},
        }

        for mid, model in pairs(models) do
            if type(model) == "table" and type(model.flds) == "table" then
                local entry = {
                    id = tostring(mid),
                    name = model.name,
                    note_count = 0,
                    fields = {},
                }
                for idx, def in ipairs(model.flds) do
                    local fname = (type(def) == "table" and def.name) or tostring(idx)
                    entry.fields[#entry.fields + 1] = {
                        index = idx,
                        name = fname,
                        samples = {},
                    }
                end
                result.models[tostring(mid)] = entry
            end
        end

        if next(result.models) ~= nil then
            local sep = string.char(31)

            -- Detect if we effectively have a single model. When that is
            -- the case, some modern decks might have mismatched model IDs
            -- between the models JSON and the notes.mid column. In that
            -- scenario, we still want to collect sample texts, so we apply
            -- all notes to this single entry.
            local single_entry
            local multiple_entries = false
            for _, entry in pairs(result.models) do
                if single_entry then
                    multiple_entries = true
                    break
                end
                single_entry = entry
            end

            local function htmlToTextForInspect(s)
                if type(s) ~= "string" or s == "" then
                    return ""
                end
                s = s:gsub("<br ?/?>", "\n")
                s = s:gsub("</p>", "\n\n"):gsub("<p[^>]*>", "")
                s = s:gsub("&nbsp;", " ")
                s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&")
                s = s:gsub("<[^>]+>", " ")
                s = s:gsub("%[sound:[^%]]-%]", "")
                s = s:gsub("\r\n", "\n")
                s = s:gsub(" *\n *", "\n")
                s = s:gsub("\n%s*\n+", "\n\n")
                s = s:gsub(" +", " ")
                s = s:gsub("^%s+", ""):gsub("%s+$", "")
                return s
            end

            local stmt = conn:prepare("SELECT mid, flds FROM notes;")
            while true do
                local row = stmt:step()
                if not row then
                    break
                end
                local mid = tostring(row[1])
                local entry = result.models[mid]
                if (not entry) and single_entry and (not multiple_entries) then
                    entry = single_entry
                end
                if entry then
                    entry.note_count = (entry.note_count or 0) + 1
                    local flds = row[2]
                    if type(flds) == "string" and flds ~= "" then
                        local values = {}
                        for field in (flds .. sep):gmatch("(.-)" .. sep) do
                            values[#values + 1] = htmlToTextForInspect(field)
                        end
                        for idx, value in ipairs(values) do
                            if value ~= "" then
                                local field_desc = entry.fields[idx]
                                if field_desc then
                                    local samples = field_desc.samples
                                    if #samples < 3 then
                                        samples[#samples + 1] = value
                                    end
                                end
                            end
                        end
                    end
                end
            end
            stmt:close()
        end

        conn:close()
        return result
    end)

    if not ok_result then
        logger.warn("AnkiViewer: inspectApkg failed", result_or_err)
        return false, "Failed to inspect apkg collection"
    end

    return true, result_or_err
end

local function extractCardsFromQuery(conn, sql)
    local cards = {}
    local stmt = conn:prepare(sql)
    while true do
        local row = stmt:step()
        if not row then
            break
        end
        local flds = row[1]
        if type(flds) == "string" and flds ~= "" then
            local parts = {}
            local sep = string.char(31)
            for field in (flds .. sep):gmatch("(.-)" .. sep) do
                parts[#parts + 1] = field
            end

            local front = ""
            local back_parts = {}

            for index, field in ipairs(parts) do
                local trimmed = field:gsub("^%s+", ""):gsub("%s+$", "")
                if trimmed ~= "" then
                    if front == "" then
                        front = trimmed
                    else
                        back_parts[#back_parts + 1] = trimmed
                    end
                end
            end

            local back = table.concat(back_parts, "\n\n")

            if front == "" and back ~= "" then
                front = back
            end

            if front ~= "" or back ~= "" then
                cards[#cards + 1] = {
                    front = front,
                    back = back,
                }
            end
        end
    end
    stmt:close()
    return cards
end

local function htmlToText(s)
    if type(s) ~= "string" or s == "" then
        return ""
    end
    s = s:gsub("<br ?/?>", "\n")
    s = s:gsub("</p>", "\n\n"):gsub("<p[^>]*>", "")
    s = s:gsub("&nbsp;", " ")
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&")
    s = s:gsub("<[^>]+>", " ")
    s = s:gsub("%[sound:[^%]]-%]", "")
    s = s:gsub("\r\n", "\n")
    s = s:gsub(" *\n *", "\n")
    s = s:gsub("\n%s*\n+", "\n\n")
    s = s:gsub(" +", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function joinPartsWithDivider(parts)
    if not parts or #parts == 0 then
        return ""
    end
    if #parts == 1 then
        return parts[1]
    end
    local out = {}
    for i, text in ipairs(parts) do
        if i == 1 then
            out[#out + 1] = text
        else
            out[#out + 1] = "──────── \n" .. text
        end
    end
    return table.concat(out, "\n")
end

local function collectRawNotes(collection_path)
    local conn = SQ3.open(collection_path, "ro")
    conn:set_busy_timeout(5000)
    local notes = {}
    local stmt = conn:prepare("SELECT mid, flds FROM notes;")
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
    conn:close()
    return notes
end

local function collectNoteCards(collection_path, mapping)
    local conn = SQ3.open(collection_path, "ro")
    conn:set_busy_timeout(5000)

    local cards = {}

    if mapping and type(mapping.models) == "table" then
        local sep = string.char(31)

        -- Detect whether we have a single primary model mapping or
        -- multiple models. When there is only one, we can safely
        -- apply that mapping to all notes, which avoids issues when
        -- model IDs in the notes and models JSON do not match exactly
        -- (a situation that can occur with some modern Anki decks).
        local single_mapping
        local multiple_mappings = false
        for _, model_mapping in pairs(mapping.models) do
            if single_mapping then
                multiple_mappings = true
                break
            end
            single_mapping = model_mapping
        end

        if single_mapping and not multiple_mappings then
            local stmt = conn:prepare("SELECT mid, flds FROM notes;")
            while true do
                local row = stmt:step()
                if not row then
                    break
                end
                local mid = row[1]
                local flds = row[2]
                if type(flds) == "string" and flds ~= "" then
                    local values = {}
                    for field in (flds .. sep):gmatch("(.-)" .. sep) do
                        values[#values + 1] = htmlToText(field)
                    end

                    local function collectByIndexes(indexes)
                        local list = {}
                        if type(indexes) == "table" then
                            for _, idx in ipairs(indexes) do
                                idx = tonumber(idx)
                                if idx and values[idx] and values[idx] ~= "" then
                                    list[#list + 1] = values[idx]
                                end
                            end
                        end
                        return list
                    end

                    local front_indexes = single_mapping.front_indexes or {}
                    local back_indexes = single_mapping.back_indexes or {}

                    local front_parts = collectByIndexes(front_indexes)
                    local back_parts = collectByIndexes(back_indexes)

                    local front = joinPartsWithDivider(front_parts)
                    local back = joinPartsWithDivider(back_parts)
                    if front == "" and back ~= "" then
                        front = back
                    end
                    if front ~= "" or back ~= "" then
                        cards[#cards + 1] = {
                            front = front,
                            back = back,
                        }
                    end
                end
            end
            stmt:close()
            conn:close()
            return cards
        else
            local stmt = conn:prepare("SELECT mid, flds FROM notes;")
            while true do
                local row = stmt:step()
                if not row then
                    break
                end
                local mid = tostring(row[1])
                local model_mapping = mapping.models[mid]
                if model_mapping then
                    local flds = row[2]
                    if type(flds) == "string" and flds ~= "" then
                        local values = {}
                        for field in (flds .. sep):gmatch("(.-)" .. sep) do
                            values[#values + 1] = htmlToText(field)
                        end

                        local function collectByIndexes(indexes)
                            local list = {}
                            if type(indexes) == "table" then
                                for _, idx in ipairs(indexes) do
                                    idx = tonumber(idx)
                                    if idx and values[idx] and values[idx] ~= "" then
                                        list[#list + 1] = values[idx]
                                    end
                                end
                            end
                            return list
                        end

                        local front_indexes = model_mapping.front_indexes or {}
                        local back_indexes = model_mapping.back_indexes or {}

                        local front_parts = collectByIndexes(front_indexes)
                        local back_parts = collectByIndexes(back_indexes)

                        local front = joinPartsWithDivider(front_parts)
                        local back = joinPartsWithDivider(back_parts)
                        if front == "" and back ~= "" then
                            front = back
                        end
                        if front ~= "" or back ~= "" then
                            cards[#cards + 1] = {
                                front = front,
                                back = back,
                            }
                        end
                    end
                end
            end
            stmt:close()
            conn:close()
            return cards
        end
    end

    local ok_templates, template_cards_or_err = pcall(function()
        local models_json = conn:rowexec("SELECT models FROM col LIMIT 1;")
        if not models_json or models_json == "" then
            return {}
        end
        local ok_models, models = pcall(json.decode, models_json)
        if not ok_models or type(models) ~= "table" then
            logger.warn("AnkiViewer: failed to decode models JSON from collection.anki2")
            return {}
        end

        local function renderTemplate(fmt, fields_by_name)
            if type(fmt) ~= "string" or fmt == "" then
                return ""
            end
            local rendered = fmt:gsub("{{([^}]+)}}", function(name)
                name = name:gsub("^%s+", ""):gsub("%s+$", "")
                return fields_by_name[name] or ""
            end)
            return htmlToText(rendered)
        end

        local function splitFields(flds)
            local parts = {}
            local sep = string.char(31)
            for field in (flds .. sep):gmatch("(.-)" .. sep) do
                parts[#parts + 1] = field
            end
            return parts
        end

        local function buildFieldMap(model, values)
            local map = {}
            local defs = type(model.flds) == "table" and model.flds or {}
            for i = 1, #values do
                local def = defs[i]
                local name = (type(def) == "table" and def.name) or tostring(i)
                map[name] = values[i] or ""
            end
            return map
        end

        local function findTemplateForOrd(model, ord)
            local tmpls = type(model.tmpls) == "table" and model.tmpls or nil
            if not tmpls or #tmpls == 0 then
                return nil
            end
            for _, tmpl in ipairs(tmpls) do
                if tonumber(tmpl.ord) == ord then
                    return tmpl
                end
            end
            return tmpls[ord + 1] or tmpls[1]
        end

        local cards_with_templates = {}
        local stmt = conn:prepare([[SELECT c.ord, n.mid, n.flds
            FROM cards c
            JOIN notes n ON n.id = c.nid;]])
        while true do
            local row = stmt:step()
            if not row then
                break
            end
            local ord = tonumber(row[1]) or 0
            local mid = tostring(row[2])
            local flds = row[3]
            if type(flds) == "string" and flds ~= "" then
                local model = models[mid]
                if type(model) == "table" then
                    local values = splitFields(flds)
                    local field_map = buildFieldMap(model, values)
                    local tmpl = findTemplateForOrd(model, ord)
                    if tmpl then
                        local front = renderTemplate(tmpl.qfmt or "", field_map)
                        local back_fmt = tmpl.afmt or ""
                        if back_fmt:find("{{FrontSide}}", 1, true) then
                            back_fmt = back_fmt:gsub("{{FrontSide}}", front)
                        end
                        local back = renderTemplate(back_fmt, field_map)
                        if (front == "" and back ~= "") then
                            front = back
                        end
                        if front ~= "" or back ~= "" then
                            cards_with_templates[#cards_with_templates + 1] = {
                                front = front,
                                back = back,
                            }
                        end
                    end
                end
            end
        end
        stmt:close()

        return cards_with_templates
    end)

    if ok_templates and type(template_cards_or_err) == "table" and #template_cards_or_err > 0 then
        cards = template_cards_or_err
    else
        cards = extractCardsFromQuery(conn, [[SELECT n.flds
            FROM cards c
            JOIN notes n ON n.id = c.nid;]])

        if #cards == 0 then
            cards = extractCardsFromQuery(conn, "SELECT flds FROM notes;")
        end
    end

    conn:close()
    return cards
end

function Import.buildCardsFromSourceNotes(notes, mapping)
    local cards = {}
    if not notes or #notes == 0 then
        return cards
    end
    if not mapping or type(mapping.models) ~= "table" then
        return cards
    end
    local sep = string.char(31)
    local single_mapping
    local multiple_mappings = false
    for _, model_mapping in pairs(mapping.models) do
        if single_mapping then
            multiple_mappings = true
            break
        end
        single_mapping = model_mapping
    end
    if single_mapping and not multiple_mappings then
        for _, note in ipairs(notes) do
            local flds = note.flds
            if type(flds) == "string" and flds ~= "" then
                local values = {}
                for field in (flds .. sep):gmatch("(.-)" .. sep) do
                    values[#values + 1] = htmlToText(field)
                end
                local function collectByIndexes(indexes)
                    local list = {}
                    if type(indexes) == "table" then
                        for _, idx in ipairs(indexes) do
                            idx = tonumber(idx)
                            if idx and values[idx] and values[idx] ~= "" then
                                list[#list + 1] = values[idx]
                            end
                        end
                    end
                    return list
                end
                local front_indexes = single_mapping.front_indexes or {}
                local back_indexes = single_mapping.back_indexes or {}
                local front_parts = collectByIndexes(front_indexes)
                local back_parts = collectByIndexes(back_indexes)
                local front = joinPartsWithDivider(front_parts)
                local back = joinPartsWithDivider(back_parts)
                if front == "" and back ~= "" then
                    front = back
                end
                if front ~= "" or back ~= "" then
                    cards[#cards + 1] = {
                        front = front,
                        back = back,
                    }
                end
            end
        end
        return cards
    end
    for _, note in ipairs(notes) do
        local mid = tostring(note.mid)
        local model_mapping = mapping.models[mid]
        if model_mapping then
            local flds = note.flds
            if type(flds) == "string" and flds ~= "" then
                local values = {}
                for field in (flds .. sep):gmatch("(.-)" .. sep) do
                    values[#values + 1] = htmlToText(field)
                end
                local function collectByIndexes(indexes)
                    local list = {}
                    if type(indexes) == "table" then
                        for _, idx in ipairs(indexes) do
                            idx = tonumber(idx)
                            if idx and values[idx] and values[idx] ~= "" then
                                list[#list + 1] = values[idx]
                            end
                        end
                    end
                    return list
                end
                local front_indexes = model_mapping.front_indexes or {}
                local back_indexes = model_mapping.back_indexes or {}
                local front_parts = collectByIndexes(front_indexes)
                local back_parts = collectByIndexes(back_indexes)
                local front = joinPartsWithDivider(front_parts)
                local back = joinPartsWithDivider(back_parts)
                if front == "" and back ~= "" then
                    front = back
                end
                if front ~= "" or back ~= "" then
                    cards[#cards + 1] = {
                        front = front,
                        back = back,
                    }
                end
            end
        end
    end
    return cards
end

function Import.importApkg(apkg_path, mapping)
    if not apkg_path or apkg_path == "" then
        return false, "Missing apkg path"
    end

    local shared_dir = getSharedDir()
    local base_name = apkg_path
    if apkg_path:sub(1, #shared_dir) == shared_dir then
        base_name = apkg_path:sub(#shared_dir + 2)
    end
    local short_name = base_name
    local dot = short_name:match("^.*()%.")
    if dot then
        short_name = short_name:sub(1, dot - 1)
    end
    if short_name == "" then
        short_name = "Imported deck"
    end

    local arc = Archiver.Reader:new()
    local ok_open = arc:open(apkg_path)
    if not ok_open then
        return false, "Unable to open apkg archive"
    end

    local collection_entry, media_entry = findEntries(arc)
    if not collection_entry then
        arc:close()
        return false, "apkg archive does not contain collection.anki2"
    end

    local temp_dir = getTempDir()
    local collection_path = temp_dir .. "/collection.anki2"
    local ok_extract = arc:extractToPath(collection_entry, collection_path)
    if not ok_extract then
        arc:close()
        return false, "Failed to extract collection.anki2 from apkg"
    end

    local media_root = getMediaRoot()
    local deck_media_dir = media_root .. "/" .. short_name

    local raw_notes = {}
    local ok_raw, raw_or_err = pcall(collectRawNotes, collection_path)
    if ok_raw and type(raw_or_err) == "table" then
        raw_notes = raw_or_err
    else
        logger.warn("AnkiViewer: failed to collect raw notes from collection", raw_or_err)
    end

    local cards = collectNoteCards(collection_path, mapping)
    -- If the current field mapping (or templates) did not produce any
    -- front/back pairs, do not pretend the import succeeded: surface a
    -- clear error so the user knows they need to adjust the selection.
    if not cards or #cards == 0 then
        arc:close()
        return false, "No cards were produced from this .apkg with the current field selection. Try choosing different front/back fields."
    end

    -- Diagnostics: how many cards/notes are present in the original Anki
    -- collection, regardless of our heuristic filtering.
    local total_cards = 0
    local total_notes = 0
    local ok_diag, diag_err = pcall(function()
        local conn_diag = SQ3.open(collection_path, "ro")
        conn_diag:set_busy_timeout(5000)
        local c = conn_diag:rowexec("SELECT COUNT(*) FROM cards;")
        local n = conn_diag:rowexec("SELECT COUNT(*) FROM notes;")
        conn_diag:close()
        total_cards = tonumber(c) or 0
        total_notes = tonumber(n) or 0
    end)
    if not ok_diag then
        logger.warn("AnkiViewer: diagnostics on collection.anki2 failed", diag_err)
    end

    arc:close()

    local AnkiDB = require("ankiviewer_db")
    local ok_db, deck_id, count = pcall(AnkiDB.importSimpleDeckFromPairs, short_name, cards, true)
    if not ok_db then
        logger.warn("AnkiViewer: importSimpleDeckFromPairs failed", deck_id)
        return false, "Failed to import cards into local database"
    end
    if deck_id and raw_notes and #raw_notes > 0 then
        local ok_store, store_err = pcall(AnkiDB.storeSourceNotes, deck_id, raw_notes)
        if not ok_store then
            logger.warn("AnkiViewer: failed to store source notes for deck", store_err)
        end
    end

    return true, {
        deck_name = short_name,
        deck_id = deck_id,
        card_count = count or 0,
        media_dir = deck_media_dir,
        source_total_cards = total_cards,
        source_total_notes = total_notes,
        extracted_cards = #cards,
    }
end

return Import
