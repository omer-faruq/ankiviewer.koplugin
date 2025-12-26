local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local Menu = require("ui/widget/menu")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local LuaSettings = require("luasettings")
local CheckButton = require("ui/widget/checkbutton")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local _ = require("gettext")
local AnkiDB = require("ankiviewer_db")
local AnkiApkgImport = require("ankiviewer_apkg_import")

local VERTICAL_SPAN_SMALL = rawget(Size.span, "vertical_small") or rawget(Size.span, "vertical_default") or rawget(Size.span, "vertical_large") or 0

local AnkiViewerScreen = InputContainer:extend{}
local AnkiViewerStudyScreen = InputContainer:extend{}
local AnkiViewer = WidgetContainer:extend{
    name = "ankiviewer",
    is_doc_only = false,
}

local FIELD_MAPPING_SETTINGS = LuaSettings:open("ankiviewer_mappings")
local INSPECT_CACHE_SETTINGS = LuaSettings:open("ankiviewer_inspect_cache")

local function loadAllFieldMappings()
    local mappings = FIELD_MAPPING_SETTINGS:readSetting("mappings")
    if type(mappings) ~= "table" then
        mappings = {}
    end
    return mappings
end

local function formatDeckTitle(name)
    if type(name) ~= "string" or name == "" then
        return name
    end
    -- Replace runs of underscores with single spaces for better wrapping.
    local display = name:gsub("_+", " ")
    -- Hard cap very long titles so they do not dominate the header.
    if #display > 60 then
        display = display:sub(1, 57) .. "..."
    end
    return display
end

local function saveAllFieldMappings(mappings)
    if type(mappings) ~= "table" then
        mappings = {}
    end
    FIELD_MAPPING_SETTINGS:saveSetting("mappings", mappings)
    FIELD_MAPPING_SETTINGS:flush()
end

local function loadAllInspectInfo()
    local cache = INSPECT_CACHE_SETTINGS:readSetting("inspect")
    if type(cache) ~= "table" then
        cache = {}
    end
    return cache
end

local function saveAllInspectInfo(cache)
    if type(cache) ~= "table" then
        cache = {}
    end
    INSPECT_CACHE_SETTINGS:saveSetting("inspect", cache)
    INSPECT_CACHE_SETTINGS:flush()
end

local function loadInspectInfoForKey(key)
    if not key or key == "" then
        return nil
    end
    local cache = loadAllInspectInfo()
    return cache[key]
end

local function saveInspectInfoForKey(key, inspect_info)
    if not key or key == "" or type(inspect_info) ~= "table" then
        return
    end
    local cache = loadAllInspectInfo()
    cache[key] = inspect_info
    saveAllInspectInfo(cache)
end

local function clearDeckMetadataForShortName(short_name)
    if not short_name or short_name == "" then
        return
    end
    local mappings = loadAllFieldMappings()
    if mappings[short_name] then
        mappings[short_name] = nil
        saveAllFieldMappings(mappings)
    end
    local cache = loadAllInspectInfo()
    if cache[short_name] then
        cache[short_name] = nil
        saveAllInspectInfo(cache)
    end
end

local function loadFieldMappingForShortName(short_name)
    if not short_name or short_name == "" then
        return nil
    end
    local mappings = loadAllFieldMappings()
    return mappings[short_name]
end

local function saveFieldMappingForShortName(short_name, mapping)
    if not short_name or short_name == "" or type(mapping) ~= "table" then
        return
    end
    local models = mapping.models
    if type(models) ~= "table" or next(models) == nil then
        return
    end
    local mappings = loadAllFieldMappings()
    mappings[short_name] = mapping
    saveAllFieldMappings(mappings)
end

local function findApkgFileByShortName(short_name)
    if not short_name or short_name == "" then
        return nil
    end
    local files = AnkiApkgImport.listApkgFiles()
    if not files or #files == 0 then
        return nil
    end
    local target_lower = short_name:lower()
    local target_norm = target_lower:gsub("[_%s]+", "")
    local fuzzy_match = nil
    for _, file in ipairs(files) do
        local name = file.name or ""
        local base = name
        local dot = name:match("^.*()%.")
        if dot then
            base = name:sub(1, dot - 1)
        end
        local base_lower = base:lower()
        if base_lower == target_lower then
            return file
        end
        -- Fuzzy match: ignore underscores vs spaces and minor
        -- differences in formatting. Keep the first fuzzy match as
        -- fallback if there is no exact match.
        if not fuzzy_match then
            local base_norm = base_lower:gsub("[_%s]+", "")
            if base_norm == target_norm then
                fuzzy_match = file
            end
        end
    end
    return fuzzy_match
end

function AnkiViewerScreen:init()
    local Screen = Device.screen
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    local title = TextWidget:new{
        face = Font:getFace("tfont"),
        text = _("Anki Viewer"),
    }
    local info = TextWidget:new{
        face = Font:getFace("smallinfofont"),
        text = _("Study Anki-style flashcards on your device using locally imported Anki decks."),
    }

    local button_row = ButtonTable:new{
        shrink_unneeded_width = true,
        width = math.floor(Screen:getWidth() * 0.8),
        buttons = {
            {
                {
                    text = _("Local study"),
                    callback = function()
                        self:openLocalStudy()
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        self:onClose()
                    end,
                },
            },
        },
    }

    local frame = FrameContainer:new{
        padding = Size.padding.large,
        margin = Size.margin.default,
        title,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        info,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        button_row,
    }

    self.layout = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Size.span.vertical_large },
        frame,
    }
    self[1] = self.layout

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function AnkiViewerScreen:openLocalStudy()
    if not self.plugin then
        return
    end
    self.plugin:openLocalStudyFromHome(self)
end

function AnkiViewerScreen:onClose()
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    if self.plugin then
        self.plugin:onScreenClosed()
    end
end

function AnkiViewerStudyScreen:updateRatingLabels(previews)
    local function set_interval(widget, key)
        if not widget then
            return
        end
        local label = ""
        if previews and previews[key] and type(previews[key].label) == "string" and previews[key].label ~= "" then
            label = previews[key].label
        else
            if key == "again" then
                label = "<1m"
            elseif key == "hard" then
                label = "<6m"
            elseif key == "good" then
                label = "<10m"
            elseif key == "easy" then
                label = "4d"
            end
        end
        widget:setText(label)
    end

    set_interval(self.interval_again, "again")
    set_interval(self.interval_hard, "hard")
    set_interval(self.interval_good, "good")
    set_interval(self.interval_easy, "easy")
end

function AnkiViewerScreen:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    local content_size = self.layout:getSize()
    local offset_x = x + math.floor((self.dimen.w - content_size.w) / 2)
    local offset_y = y + math.floor((self.dimen.h - content_size.h) / 2)
    self.layout:paintTo(bb, offset_x, offset_y)
end

function AnkiViewerStudyScreen:init()
    local Screen = Device.screen
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    self.settings = LuaSettings:open("ankiviewer.settings")

    local default_id = AnkiDB.ensureSampleData()
    -- last_deck_id may have been stored as string; coerce to number so it
    -- matches numeric deck IDs returned by AnkiDB.listDecks().
    local last_id = tonumber(self.settings:readSetting("last_deck_id"))
    local decks = AnkiDB.listDecks()
    local selected_id = nil
    local selected_name = _("Default deck")
    if decks and #decks > 0 then
        -- First, try to find the last used deck
        if last_id then
            for _, d in ipairs(decks) do
                if d.id == last_id then
                    selected_id = d.id
                    selected_name = d.name or selected_name
                    break
                end
            end
        end
        -- If last deck not found, use the first available deck
        if not selected_id and decks[1] then
            selected_id = decks[1].id
            selected_name = decks[1].name or selected_name
        end
    end
    -- Fallback to default if no decks exist
    if not selected_id then
        selected_id = default_id
    end

    self.deck_id = selected_id
    self.deck_name = selected_name -- internal/raw name
    self.deck_title = formatDeckTitle(selected_name) -- display name
    self.current_card = nil
    self.showing_back = false

    local card_width = math.floor(Screen:getWidth() * 0.85)
    local card_height = Size.item.height_large * 8

    local title_max_width = math.floor(Screen:getWidth() * 0.9)
    local title_face = Font:getFace("cfont", 26)
    local title_line_height_px = math.floor((1 + 0.3) * title_face.size)
    local title_height = title_line_height_px * 2
    self.title_widget = TextBoxWidget:new{
        face = title_face,
        text = self.deck_title,
        width = title_max_width,
        height = title_height,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "center",
    }
    local card_inner_width = card_width - (Size.margin.default * 2 + Size.padding.fullscreen * 2 + Size.border.window * 2)
    local card_inner_height = card_height - (Size.margin.default * 2 + Size.padding.fullscreen * 2 + Size.border.window * 2)
    self.card_widget = TextBoxWidget:new{
        face = Font:getFace("cfont"),
        text = "",
        width = card_inner_width,
        height = card_inner_height,
        alignment = "center",
        -- If the content is still too tall, show ellipsis instead of
        -- overflowing outside the card frame.
        height_overflow_show_ellipsis = true,
    }
    self.status_widget = TextWidget:new{
        face = Font:getFace("smallinfofont"),
        text = "",
    }

    self.interval_widget = TextWidget:new{
        face = Font:getFace("smallinfofont"),
        text = "",
    }

    -- Card container to give more space around the text and enforce a minimum width
    self.card_container = CenterContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = card_width, h = card_height },
        self.card_widget,
    }

    -- Card frame to visually emphasize question/answer
    self.card_frame = FrameContainer:new{
        padding = Size.padding.fullscreen,
        margin = Size.margin.default,
        radius = Size.radius.window,
        bordersize = Size.border.window,
        self.card_container,
    }

    -- Top controls row: Settings | Close, with deck title below
    self.close_button = Button:new{
        text = _("Close"),
        callback = function()
            self:onClose()
        end,
        text_font_face = "cfont",
        text_font_size = 24,
        text_font_bold = false,
        bordersize = 0,
        margin = 0,
        radius = 0,
    }

    self.decks_button = Button:new{
        text = _("Decks"),
        callback = function()
            self:showDeckSelection()
        end,
        text_font_face = "cfont",
        text_font_size = 24,
        text_font_bold = false,
        bordersize = 0,
        margin = 0,
        radius = 0,
    }

    self.settings_button = Button:new{
        text = _("Settings"),
        callback = function()
            self:showSettingsMenu()
        end,
        text_font_face = "cfont",
        text_font_size = 24,
        text_font_bold = false,
        bordersize = 0,
        margin = 0,
        radius = 0,
    }

    self.import_button = Button:new{
        text = _("Import"),
        callback = function()
            if self.plugin and self.plugin.importLocalApkg then
                self.plugin:importLocalApkg()
            end
        end,
        text_font_face = "cfont",
        text_font_size = 24,
        text_font_bold = false,
        bordersize = 0,
        margin = 0,
        radius = 0,
    }

    local top_controls = HorizontalGroup:new{
        align = "center",
        self.decks_button,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        TextWidget:new{
            face = Font:getFace("cfont", 22),
            text = "|",
        },
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        self.settings_button,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        TextWidget:new{
            face = Font:getFace("cfont", 22),
            text = "|",
        },
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        self.import_button,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        TextWidget:new{
            face = Font:getFace("cfont", 22),
            text = "|",
        },
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        self.close_button,
    }

    local top_bar = VerticalGroup:new{
        align = "center",
        top_controls,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.title_widget,
    }

    -- Row used when showing the front side (only Show answer)
    local show_row = ButtonTable:new{
        shrink_unneeded_width = true,
        width = math.floor(Screen:getWidth() * 0.85),
        buttons = {
            {
                {
                    id = "show_button",
                    text = _("Show answer"),
                    callback = function()
                        self:onShowOrNext()
                    end,
                },
            },
        },
    }
    self.show_button = show_row:getButtonById("show_button")

    -- Interval labels (non-interactive) for each rating, slightly smaller than smallinfofont
    local small_interval_size = math.floor(Font.sizemap.smallinfofont * 0.85)
    local small_interval_face = Font:getFace("smallinfofont", small_interval_size)
    self.interval_again = TextWidget:new{
        face = small_interval_face,
        text = "",
    }
    self.interval_hard = TextWidget:new{
        face = small_interval_face,
        text = "",
    }
    self.interval_good = TextWidget:new{
        face = small_interval_face,
        text = "",
    }
    self.interval_easy = TextWidget:new{
        face = small_interval_face,
        text = "",
    }

    -- Rating buttons, one column per rating (interval label above, button below)
    self.again_button = Button:new{
        text = _("Again"),
        callback = function()
            self:onRate("again")
        end,
        width = math.floor(Screen:getWidth() * 0.18),
        bordersize = 0,
        margin = 0,
        radius = 0,
    }
    self.hard_button = Button:new{
        text = _("Hard"),
        callback = function()
            self:onRate("hard")
        end,
        width = math.floor(Screen:getWidth() * 0.18),
        bordersize = 0,
        margin = 0,
        radius = 0,
    }
    self.good_button = Button:new{
        text = _("Good"),
        callback = function()
            self:onRate("good")
        end,
        width = math.floor(Screen:getWidth() * 0.18),
        bordersize = 0,
        margin = 0,
        radius = 0,
    }
    self.easy_button = Button:new{
        text = _("Easy"),
        callback = function()
            self:onRate("easy")
        end,
        width = math.floor(Screen:getWidth() * 0.18),
        bordersize = 0,
        margin = 0,
        radius = 0,
    }

    local col_again = VerticalGroup:new{
        align = "center",
        self.interval_again,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.again_button,
    }
    local col_hard = VerticalGroup:new{
        align = "center",
        self.interval_hard,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.hard_button,
    }
    local col_good = VerticalGroup:new{
        align = "center",
        self.interval_good,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.good_button,
    }
    local col_easy = VerticalGroup:new{
        align = "center",
        self.interval_easy,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.easy_button,
    }

    local rating_row = HorizontalGroup:new{
        align = "center",
        col_again,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        col_hard,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        col_good,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        col_easy,
    }

    -- Separate layouts for front (question) and back (answer + ratings)
    self.front_layout = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        top_bar,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.card_frame,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        show_row,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
    }

    self.back_layout = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        top_bar,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.card_frame,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        rating_row,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
    }

    self.active_layout = self.front_layout
    self[1] = self.front_layout

    self:setRatingButtonsEnabled(false)
    self:setShowButtonVisible(true)
    self:loadNextCard()

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function AnkiViewerStudyScreen:setStatus(text)
    self.status_widget:setText(text or "")
end

function AnkiViewerStudyScreen:setRatingButtonsEnabled(enabled)
    local flag = not not enabled
    if self.again_button then self.again_button:enableDisable(flag) end
    if self.hard_button then self.hard_button:enableDisable(flag) end
    if self.good_button then self.good_button:enableDisable(flag) end
    if self.easy_button then self.easy_button:enableDisable(flag) end
end

function AnkiViewerStudyScreen:setShowButtonVisible(visible)
    if not self.show_button then
        return
    end
    if visible then
        self.show_button:enableDisable(true)
        self.show_button:setText(_("Show answer"))
    else
        self.show_button:enableDisable(false)
        self.show_button:setText("")
    end
end

function AnkiViewerStudyScreen:loadNextCard()
    local randomize_equal_due = false
    if self.settings then
        randomize_equal_due = not not self.settings:readSetting("randomize_equal_due")
    end
    local card = AnkiDB.fetchNextDueCard(self.deck_id, nil, randomize_equal_due)
    if not card then
        self.current_card = nil
        self.showing_back = false
        self.card_widget:setText(_("No cards due."))
        self:setShowButtonVisible(false)
        self:setRatingButtonsEnabled(false)
        self.active_layout = self.front_layout
        self[1] = self.front_layout
        self:refresh()
        return
    end
    self.current_card = card
    self.showing_back = false
    self.card_widget:setText(card.front)
    self:setShowButtonVisible(true)
    self:setRatingButtonsEnabled(false)
    self.active_layout = self.front_layout
    self[1] = self.front_layout
    self:refresh()
end

function AnkiViewerStudyScreen:onShowOrNext()
    if not self.current_card then
        self:loadNextCard()
        return
    end
    if not self.showing_back then
        self.showing_back = true
        self.card_widget:setText(self.current_card.back)
        local previews = AnkiDB.previewIntervals(self.current_card)
        self:updateRatingLabels(previews)
        self:setShowButtonVisible(false)
        self:setRatingButtonsEnabled(true)
        self.active_layout = self.back_layout
        self[1] = self.back_layout
        self:refresh()
    end
end

function AnkiViewerStudyScreen:onRate(rating)
    if not self.current_card then
        return
    end
    local updated = AnkiDB.updateCardScheduling(self.current_card, rating)
    self.current_card = updated or self.current_card
    self.showing_back = false
    self:loadNextCard()
end

function AnkiViewerStudyScreen:showSettingsMenu()
    local study = self
    local screen = Device.screen
    local menu

    local items = {
        {
            text = _("Randomize cards with same due"),
            keep_menu_open = true,
            mandatory_func = function()
                if not study.settings then
                    return "OFF"
                end
                if study.settings:readSetting("randomize_equal_due") then
                    return "ON"
                end
                return "OFF"
            end,
            checked_func = function()
                if not study.settings then
                    return false
                end
                return not not study.settings:readSetting("randomize_equal_due")
            end,
            callback = function()
                if not study.settings then
                    return
                end
                local current = not not study.settings:readSetting("randomize_equal_due")
                study.settings:saveSetting("randomize_equal_due", not current)
                study.settings:flush()
                if menu and menu.updateItems then
                    menu:updateItems(1, true)
                end
            end,
        },
        {
            text = _("Field mapping"),
            keep_menu_open = false,
            callback = function()
                if menu then
                    UIManager:close(menu)
                end
                if study.plugin and study.plugin.openCurrentDeckFieldMapping then
                    study.plugin:openCurrentDeckFieldMapping(study)
                end
            end,
        },
        {
            text = _("Close"),
            keep_menu_open = false,
            callback = function()
                if menu then
                    UIManager:close(menu)
                end
            end,
        },
    }

    menu = Menu:new{
        title = _("Settings"),
        item_table = items,
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.9),
        height = math.floor(screen:getHeight() * 0.9),
    }

    function menu:onMenuChoice(item)
        if item.callback then
            item.callback()
        end
        if not item.keep_menu_open then
            UIManager:close(self)
        end
        return true
    end

    UIManager:show(menu)
end

function AnkiViewerStudyScreen:applyDeckSelection(deck)
    if not deck or not deck.id then
        return
    end
    self.deck_id = deck.id
    self.deck_name = deck.name or self.deck_name
    self.deck_title = formatDeckTitle(self.deck_name)
    if self.title_widget and self.title_widget.setText then
        self.title_widget:setText(self.deck_title)
    end
    if self.settings then
        self.settings:saveSetting("last_deck_id", self.deck_id)
        self.settings:flush()
    end
    self.current_card = nil
    self.showing_back = false
    self:loadNextCard()
end

function AnkiViewerStudyScreen:showDeckSelection()
    local decks = AnkiDB.listDecks()
    if not decks or #decks == 0 then
        local msg = InfoMessage:new{
            text = _("No decks available."),
            timeout = 4,
            show_icon = true,
        }
        UIManager:show(msg)
        return
    end

    local study = self
    local items = {}
    for i, d in ipairs(decks) do
        local label = d.name or ("Deck " .. tostring(d.id or ""))
        if d.card_count and d.card_count > 0 then
            label = string.format("%s (%d)", label, d.card_count)
        end
        table.insert(items, {
            text = label,
            keep_menu_open = false,
            deck_id = d.id,
            deck_name = d.name,
            callback = function()
                study:applyDeckSelection(d)
            end,
        })
    end

    local screen = Device.screen
    local menu = Menu:new{
        title = _("Select deck"),
        item_table = items,
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.9),
        height = math.floor(screen:getHeight() * 0.9),
    }

    function menu:onMenuChoice(item)
        if item.callback then
            item.callback()
        end
        UIManager:close(self)
        return true
    end

    function menu:onMenuHold(item)
        local deck_id = item and item.deck_id
        if not deck_id then
            return true
        end
        local deck_name = item.deck_name or item.text or ""
        UIManager:show(ConfirmBox:new{
            text = string.format(_("Delete deck \"%s\"?"), deck_name),
            ok_text = _("Delete"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                local ok_call, result_or_err = pcall(AnkiDB.deleteDeck, deck_id)
                if not ok_call or not result_or_err then
                    local err_text = not ok_call and result_or_err or _("Delete failed")
                    local msg = InfoMessage:new{
                        text = _("Failed to delete deck: ") .. tostring(err_text or "Lua error"),
                        timeout = 6,
                        show_icon = true,
                    }
                    UIManager:show(msg)
                    return
                end

                if study.deck_id == deck_id then
                    local remaining = AnkiDB.listDecks()
                    local replacement = nil
                    for _, d in ipairs(remaining) do
                        if d.id ~= deck_id then
                            replacement = d
                            break
                        end
                    end
                    if replacement then
                        study:applyDeckSelection(replacement)
                    else
                        study.deck_id = nil
                        study.deck_name = study.deck_name or _("Default deck")
                        study.deck_title = formatDeckTitle(study.deck_name)
                        if study.title_widget and study.title_widget.setText then
                            study.title_widget:setText(study.deck_title)
                        end
                        study.current_card = nil
                        study.showing_back = false
                        study.card_widget:setText(_("No cards available."))
                        study:setShowButtonVisible(false)
                        study:setRatingButtonsEnabled(false)
                    end
                end

                clearDeckMetadataForShortName(deck_name)

                UIManager:close(menu)
            end,
        })
        return true
    end

    UIManager:show(menu)
end

function AnkiViewer:openCurrentDeckFieldMapping(study_screen)
    local loading = InfoMessage:new{
        text = _("Preparing field mapping…"),
        timeout = 0,
    }
    UIManager:show(loading)

    if not study_screen or not (study_screen.deck_name or study_screen.deck_title) then
        UIManager:close(loading)
        local msg = InfoMessage:new{
            text = _("No active deck to configure."),
            timeout = 4,
            show_icon = true,
        }
        UIManager:show(msg)
        return
    end

    local deck_name = study_screen.deck_name or study_screen.deck_title
    local short_name = deck_name
    local existing_mapping = loadFieldMappingForShortName(short_name)

    local inspect_info
    local cache_key
    if existing_mapping and existing_mapping.short_name and existing_mapping.short_name ~= "" then
        cache_key = existing_mapping.short_name
        inspect_info = loadInspectInfoForKey(cache_key)
    end
    if not inspect_info then
        cache_key = short_name
        inspect_info = loadInspectInfoForKey(cache_key)
    end

    if inspect_info then
        UIManager:close(loading)
        local effective_short = inspect_info.short_name or cache_key or short_name
        existing_mapping = loadFieldMappingForShortName(effective_short)
        self:showApkgFieldMappingDialog(nil, inspect_info, existing_mapping, function(apply, mapping)
            if not apply then
                return
            end
            if mapping and effective_short and effective_short ~= "" then
                mapping.short_name = effective_short
                saveFieldMappingForShortName(effective_short, mapping)
                local msg = InfoMessage:new{
                    text = _("Field mapping saved for this deck."),
                    timeout = 4,
                    show_icon = true,
                }
                UIManager:show(msg)

                local deck_id = study_screen.deck_id
                local deck_title = study_screen.deck_name or effective_short
                if deck_id then
                    self:_reimportFromSourceNotes(deck_id, deck_title, mapping, nil)
                end
            else
                local msg = InfoMessage:new{
                    text = _("No changes to field mapping."),
                    timeout = 4,
                    show_icon = true,
                }
                UIManager:show(msg)
            end
        end)
        return
    end

    local file = findApkgFileByShortName(short_name)
    if not file and existing_mapping and existing_mapping.short_name and existing_mapping.short_name ~= "" then
        file = findApkgFileByShortName(existing_mapping.short_name)
    end

    if not file then
        UIManager:close(loading)
        local msg = InfoMessage:new{
            text = _("No matching .apkg file found for this deck."),
            timeout = 6,
            show_icon = true,
        }
        UIManager:show(msg)
        return
    end

    local analyzing = InfoMessage:new{
        text = string.format(_("Analyzing %s…"), file.name or short_name),
        timeout = 0,
    }
    UIManager:close(loading)
    UIManager:show(analyzing)

    local ok_pcall, ok_inspect, inspect_payload = pcall(AnkiApkgImport.inspectApkg, file.path)
    UIManager:close(analyzing)

    if not ok_pcall then
        local msg = InfoMessage:new{
            text = _("Failed to analyze .apkg: ") .. tostring(ok_inspect or "Lua error"),
            timeout = 8,
            show_icon = true,
        }
        UIManager:show(msg)
        return
    end

    if not ok_inspect then
        local err_text = inspect_payload or "Unknown error"
        local msg = InfoMessage:new{
            text = _("Failed to analyze .apkg: ") .. tostring(err_text),
            timeout = 8,
            show_icon = true,
        }
        UIManager:show(msg)
        return
    end

    local inspect_info2 = inspect_payload or {}
    local effective_short = inspect_info2.short_name or short_name
    saveInspectInfoForKey(effective_short, inspect_info2)
    existing_mapping = loadFieldMappingForShortName(effective_short)

    self:showApkgFieldMappingDialog(file, inspect_info2, existing_mapping, function(apply, mapping)
        if not apply then
            return
        end
        if mapping and effective_short and effective_short ~= "" then
            mapping.short_name = effective_short
            saveFieldMappingForShortName(effective_short, mapping)
            local msg = InfoMessage:new{
                text = _("Field mapping saved for this deck."),
                timeout = 4,
                show_icon = true,
            }
            UIManager:show(msg)

            local deck_id = study_screen.deck_id
            local deck_title = study_screen.deck_name or effective_short
            if deck_id then
                self:_reimportFromSourceNotes(deck_id, deck_title, mapping, file)
            else
                self:_performApkgImport(file, mapping)
            end
        else
            local msg = InfoMessage:new{
                text = _("No changes to field mapping."),
                timeout = 4,
                show_icon = true,
            }
            UIManager:show(msg)
        end
    end)
end

function AnkiViewer:_performApkgImport(file, mapping)
    if not file or not file.path then
        return
    end

    local progress = InfoMessage:new{
        text = string.format(_("Importing %s…"), file.name or file.path),
        timeout = 0,
    }
    UIManager:show(progress)

    local ok_call, ok_import, payload = pcall(AnkiApkgImport.importApkg, file.path, mapping)
    UIManager:close(progress)

    local text
    if not ok_call then
        text = _("Failed to import .apkg: ") .. tostring(ok_import or "Lua error")
    else
        if ok_import and payload and type(payload) == "table" then
            local info = payload
            local deck_name = info.deck_name or file.name or _("Imported deck")
            local card_count = tonumber(info.card_count or 0) or 0
            local src_cards = tonumber(info.source_total_cards or 0) or 0
            local src_notes = tonumber(info.source_total_notes or 0) or 0
            local extracted = tonumber(info.extracted_cards or 0) or 0
            if card_count == 0 then
                text = string.format(_("Imported deck '%s' with %d cards (source cards: %d, notes: %d, extracted: %d)."), deck_name, card_count, src_cards, src_notes, extracted)
            else
                text = string.format(_("Imported deck '%s' with %d cards."), deck_name, card_count)
            end
        else
            local err_msg = payload or "Unknown error"
            text = _("Failed to import .apkg: ") .. tostring(err_msg)
        end
    end

    local msg = InfoMessage:new{
        text = text,
        timeout = 8,
        show_icon = true,
    }
    UIManager:show(msg)
end

function AnkiViewer:_reimportFromSourceNotes(deck_id, deck_name, mapping, file)
    if not deck_id or not mapping then
        if file then
            self:_performApkgImport(file, mapping)
        end
        return
    end

    local progress = InfoMessage:new{
        text = _("Rebuilding deck from stored notes…"),
        timeout = 0,
    }
    UIManager:show(progress)

    local notes
    local ok_notes, notes_or_err = pcall(AnkiDB.loadSourceNotes, deck_id)
    if ok_notes then
        notes = notes_or_err
    else
        notes = nil
    end

    if not notes or #notes == 0 then
        UIManager:close(progress)
        if file then
            self:_performApkgImport(file, mapping)
        else
            local msg = InfoMessage:new{
                text = _("No stored source notes are available for this deck; cannot rebuild cards."),
                timeout = 8,
                show_icon = true,
            }
            UIManager:show(msg)
        end
        return
    end

    local cards = AnkiApkgImport.buildCardsFromSourceNotes(notes, mapping)
    if not cards or #cards == 0 then
        UIManager:close(progress)
        local msg = InfoMessage:new{
            text = _("No cards were produced from stored notes with the current field selection. Try choosing different front/back fields."),
            timeout = 8,
            show_icon = true,
        }
        UIManager:show(msg)
        return
    end

    local ok_db, imported_deck_id, count = pcall(AnkiDB.importSimpleDeckFromPairs, deck_name, cards, true)
    UIManager:close(progress)

    local text
    if not ok_db then
        text = _("Failed to import cards into local database.")
    else
        text = string.format(_("Rebuilt deck '%s' with %d cards from stored notes."), deck_name, count or 0)
    end

    local msg = InfoMessage:new{
        text = text,
        timeout = 8,
        show_icon = true,
    }
    UIManager:show(msg)
end

function AnkiViewer:showApkgFieldMappingDialog(file, inspect_info, existing_mapping, on_done)
    local models = (inspect_info and inspect_info.models) or {}
    if type(models) ~= "table" or next(models) == nil then
        if on_done then
            on_done(true, nil)
        end
        return
    end

    local Screen = Device.screen
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    -- Inner content width slightly smaller than screen, used for wrapping text
    local dialog_width = math.floor(screen_width * 0.9)
    local dialog_height = math.floor(screen_height * 0.9)

    local title = TextBoxWidget:new{
        face = Font:getFace("x_smalltfont"),
        text = _("Select front and back fields"),
        width = dialog_width,
    }

    local subtitle_text = (file and file.name) or (inspect_info and inspect_info.short_name) or _("Deck")
    local subtitle = TextBoxWidget:new{
        face = Font:getFace("smallinfofont"),
        text = subtitle_text,
        width = dialog_width,
    }

    local description = TextBoxWidget:new{
        face = Font:getFace("smallinfofont"),
        text = _("Choose which note fields to use on the front and back of cards. You can select multiple fields."),
        width = dialog_width,
    }

    local content_group = VerticalGroup:new{
        align = "left",
    }

    local existing_models = existing_mapping and existing_mapping.models or nil
    local model_state = {}

    -- Determine a single primary model to keep the UI simple.
    -- We pick the model with the highest note_count that has fields;
    -- if note_count is not available, we fall back to the first model
    -- that has at least one field.
    local primary_mid
    local primary_model
    local max_note_count = -1
    for mid, model in pairs(models) do
        if type(model) == "table" and type(model.fields) == "table" and #model.fields > 0 then
            local note_count = tonumber(model.note_count or 0) or 0
            if note_count > max_note_count then
                max_note_count = note_count
                primary_mid = mid
                primary_model = model
            end
        end
    end
    if not primary_model then
        for mid, model in pairs(models) do
            if type(model) == "table" and type(model.fields) == "table" and #model.fields > 0 then
                primary_mid = mid
                primary_model = model
                break
            end
        end
    end

    local function buildSampleText(field_info)
        local samples = field_info.samples or {}
        if #samples == 0 then
            return ""
        end
        local sample = tostring(samples[1] or "")
        sample = sample:gsub("\n+", " ")
        if #sample > 120 then
            sample = sample:sub(1, 117) .. "..."
        end
        return sample
    end

    if primary_mid and primary_model then
        local saved = existing_models and existing_models[primary_mid] or nil
        local front_index_set = {}
        local back_index_set = {}
        if saved then
            if type(saved.front_indexes) == "table" then
                for _, idx in ipairs(saved.front_indexes) do
                    idx = tonumber(idx)
                    if idx then
                        front_index_set[idx] = true
                    end
                end
            end
            if type(saved.back_indexes) == "table" then
                for _, idx in ipairs(saved.back_indexes) do
                    idx = tonumber(idx)
                    if idx then
                        back_index_set[idx] = true
                    end
                end
            end
        else
            if primary_model.fields[1] then
                front_index_set[1] = true
            end
            if #primary_model.fields > 1 then
                for idx = 2, #primary_model.fields do
                    back_index_set[idx] = true
                end
            end
        end

        local state_for_model = {
            id = primary_mid,
            fields = {},
        }

        for i_field, field_info in ipairs(primary_model.fields) do
            local idx = tonumber(field_info.index or 0) or 0
            if idx > 0 then
                local field_name = field_info.name or tostring(idx)
                local sample_text = buildSampleText(field_info)
                local label_text
                if sample_text ~= "" then
                    label_text = string.format("%s (%s)", field_name, sample_text)
                else
                    label_text = field_name
                end

                local front_cb = CheckButton:new{
                    text = _("Front"),
                    checked = not not front_index_set[idx],
                    width = math.floor(dialog_width * 0.18),
                }
                local back_cb = CheckButton:new{
                    text = _("Back"),
                    checked = not not back_index_set[idx],
                    width = math.floor(dialog_width * 0.18),
                }

                local label_widget = TextBoxWidget:new{
                    face = Font:getFace("smallinfofont"),
                    text = label_text,
                    width = dialog_width - math.floor(dialog_width * 0.18) * 2 - Size.span.horizontal_small * 4,
                }

                local row = HorizontalGroup:new{
                    align = "top",
                    front_cb,
                    HorizontalSpan:new{ width = Size.span.horizontal_small },
                    back_cb,
                    HorizontalSpan:new{ width = Size.span.horizontal_small },
                    label_widget,
                }
                table.insert(content_group, row)

                state_for_model.fields[#state_for_model.fields + 1] = {
                    index = idx,
                    front_cb = front_cb,
                    back_cb = back_cb,
                }
            end
        end

        table.insert(content_group, VerticalSpan:new{ width = VERTICAL_SPAN_SMALL })
        model_state[primary_mid] = state_for_model
    end

    if next(model_state) == nil then
        if on_done then
            on_done(true, nil)
        end
        return
    end

    -- Forward declaration so button callbacks can close the dialog
    local dialog

    local buttons_row = ButtonTable:new{
        shrink_unneeded_width = true,
        width = dialog_width,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        if dialog then
                            UIManager:close(dialog)
                        end
                        UIManager:setDirty(nil, "full")
                        if on_done then
                            on_done(false, nil)
                        end
                    end,
                },
                {
                    text = _("Import"),
                    callback = function()
                        local mapping = {
                            models = {},
                        }
                        for mid, state_for_model in pairs(model_state) do
                            local front_indexes = {}
                            local back_indexes = {}
                            for _, field_state in ipairs(state_for_model.fields) do
                                if field_state.front_cb.checked then
                                    table.insert(front_indexes, field_state.index)
                                end
                                if field_state.back_cb.checked then
                                    table.insert(back_indexes, field_state.index)
                                end
                            end
                            if #front_indexes > 0 or #back_indexes > 0 then
                                mapping.models[mid] = {
                                    front_indexes = front_indexes,
                                    back_indexes = back_indexes,
                                }
                            end
                        end
                        if dialog then
                            UIManager:close(dialog)
                        end
                        UIManager:setDirty(nil, "full")
                        if on_done then
                            if mapping.models and next(mapping.models) ~= nil then
                                on_done(true, mapping)
                            else
                                on_done(true, nil)
                            end
                        end
                    end,
                },
            },
        },
    }

    local layout = VerticalGroup:new{
        align = "left",
        title,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        subtitle,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        description,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        content_group,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        buttons_row,
    }

    local frame = FrameContainer:new{
        padding = Size.padding.large,
        margin = Size.margin.default,
        radius = Size.radius.window,
        bordersize = Size.border.window,
        background = Blitbuffer.COLOR_WHITE,
        layout,
    }

    dialog = InputContainer:new{}
    dialog.covers_fullscreen = true
    local screen_geom = Geom:new{ x = 0, y = 0, w = screen_width, h = screen_height }
    dialog.dimen = screen_geom

    dialog.cropping_widget = ScrollableContainer:new{
        -- Full-screen scrollable area: no horizontal scrolling because
        -- inner frame is narrower than the screen width.
        dimen = Geom:new{ w = screen_width, h = screen_height },
        show_parent = dialog,
        frame,
    }

    -- Reparent checkbuttons so their visual updates go through the dialog
    for _, state_for_model in pairs(model_state) do
        for _, field_state in ipairs(state_for_model.fields) do
            field_state.front_cb.parent = dialog
            field_state.back_cb.parent = dialog
            field_state.front_cb:initCheckButton(field_state.front_cb.checked)
            field_state.back_cb:initCheckButton(field_state.back_cb.checked)
        end
    end

    dialog[1] = CenterContainer:new{
        dimen = screen_geom,
        dialog.cropping_widget,
    }

    function dialog:paintTo(bb, x, y)
        self.dimen.x = x
        self.dimen.y = y
        -- Full-screen white background so the dialog cleanly covers previous UI,
        -- including under the scrollbars.
        bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
        if self[1] then
            self[1]:paintTo(bb, x, y)
        end
    end

    UIManager:show(dialog)
end

function AnkiViewerStudyScreen:refresh()
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function AnkiViewerStudyScreen:onClose()
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    if self.plugin then
        self.plugin:onScreenClosed()
    end
end

function AnkiViewerStudyScreen:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    local layout = self.active_layout or self.front_layout
    local content_size = layout:getSize()
    local offset_x = x + math.floor((self.dimen.w - content_size.w) / 2)
    local offset_y = y + math.floor((self.dimen.h - content_size.h) / 2)
    layout:paintTo(bb, offset_x, offset_y)
end

function AnkiViewer:init()
    self.ui.menu:registerToMainMenu(self)
end

function AnkiViewer:addToMainMenu(menu_items)
    menu_items.ankiviewer = {
        text = _("Anki Viewer"),
        sorting_hint = "tools",
        callback = function()
            self:showLocalStudy()
        end,
    }
end

function AnkiViewer:importLocalApkg()
    local files = AnkiApkgImport.listApkgFiles()
    if not files or #files == 0 then
        local msg = InfoMessage:new{
            text = _("No .apkg files found. Please place .apkg files in the 'ankiviewer/shared' data folder."),
            timeout = 6,
            show_icon = true,
        }
        UIManager:show(msg)
        return
    end

    local items = {}
    for i, file in ipairs(files) do
        table.insert(items, {
            text = file.name,
            file = file,
            callback = function(menu)
                if menu then
                    UIManager:close(menu)
                end

                local analyzing = InfoMessage:new{
                    text = string.format(_("Analyzing %s…"), file.name),
                    timeout = 0,
                }
                UIManager:show(analyzing)

                local ok_pcall, ok_inspect, inspect_payload = pcall(AnkiApkgImport.inspectApkg, file.path)
                UIManager:close(analyzing)

                if not ok_pcall then
                    local msg = InfoMessage:new{
                        text = _("Failed to analyze .apkg: ") .. tostring(ok_inspect or "Lua error"),
                        timeout = 8,
                        show_icon = true,
                    }
                    UIManager:show(msg)
                    return
                end

                if not ok_inspect then
                    local err_text = inspect_payload or "Unknown error"
                    local msg = InfoMessage:new{
                        text = _("Failed to analyze .apkg: ") .. tostring(err_text),
                        timeout = 8,
                        show_icon = true,
                    }
                    UIManager:show(msg)
                    return
                end

                local inspect_info = inspect_payload or {}
                local short_name = inspect_info.short_name or file.name
                saveInspectInfoForKey(short_name, inspect_info)
                local existing_mapping = loadFieldMappingForShortName(short_name)

                self:showApkgFieldMappingDialog(file, inspect_info, existing_mapping, function(apply, mapping)
                    if not apply then
                        return
                    end
                    if mapping and short_name and short_name ~= "" then
                        mapping.short_name = short_name
                        saveFieldMappingForShortName(short_name, mapping)
                    end
                    self:_performApkgImport(file, mapping)
                end)
            end,
        })
    end

    local screen = Device.screen
    local plugin = self
    local menu = Menu:new{
        title = _("Select .apkg to import"),
        item_table = items,
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.9),
        height = math.floor(screen:getHeight() * 0.9),
    }
    function menu:onMenuHold(item)
        local f = item and item.file
        if not f or not f.path then
            return true
        end

        local display_name = f.name or f.path
        UIManager:show(ConfirmBox:new{
            text = string.format(_("Delete file \"%s\"?"), display_name),
            ok_text = _("Delete"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                local ok_remove, err = os.remove(f.path)
                if not ok_remove then
                    local msg = InfoMessage:new{
                        text = _("Failed to delete file: ") .. tostring(err or _("Unknown error")),
                        timeout = 6,
                        show_icon = true,
                    }
                    UIManager:show(msg)
                    return
                end

                local msg = InfoMessage:new{
                    text = _("Deleted file: ") .. display_name,
                    timeout = 4,
                    show_icon = true,
                }
                UIManager:show(msg)

                UIManager:close(self)
                if plugin and plugin.importLocalApkg then
                    plugin:importLocalApkg()
                end
            end,
        })
        return true
    end
    UIManager:show(menu)
end

function AnkiViewer:showHome()
    if self.screen then
        return
    end
    self.screen = AnkiViewerScreen:new{
        plugin = self,
    }
    UIManager:show(self.screen)
end

function AnkiViewer:openLocalStudyFromHome(home_screen)
    UIManager:close(home_screen)
    UIManager:setDirty(nil, "full")
    self.screen = nil
    self:showLocalStudy()
end

function AnkiViewer:showLocalStudy()
    if self.screen then
        return
    end
    self.screen = AnkiViewerStudyScreen:new{
        plugin = self,
    }
    UIManager:show(self.screen)
end

function AnkiViewer:onScreenClosed()
    self.screen = nil
end
return AnkiViewer
