--[[--
AnkiDrawOverlay: transparent handwriting layer for the Anki Viewer study screen.

It sits over the card frame and paints ink on top of the card text. It is not
part of the layout tree: the study screen paints it after the layout and
forwards gestures to it first (see AnkiViewerStudyScreen:handleEvent).

Input paths, best first:
  1. Stylus callback (Input:registerStylusCallback, newer KOReader builds).
     Raw pen samples arrive before gesture detection, one per input frame,
     tagged with the tool type (pen / eraser / highlighter). On the Kindle
     Scribe, KOReader turns on `input.wacom_protocol`, so the Premium Pen
     shows up here. Finger touches never do, which gives clean pen-only
     drawing, and recent pen activity is used for palm rejection.
  2. Gesture fallback (older builds without the stylus callback, or when
     "finger drawing" is on): draws from touch / pan / swipe / release
     gestures. This path cannot tell the pen from a finger.

KOReader does not keep pen pressure or tilt (ABS_PRESSURE is not stored per
slot), so strokes have a fixed width.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Screen = Device.screen

-- Seconds since an arbitrary origin, as a float.
local now_s
do
    local ok, time = pcall(require, "ui/time")
    if ok and time and time.now and time.to_s then
        now_s = function() return time.to_s(time.now()) end
    else
        now_s = function() return os.time() end
    end
end

-- Finger input is ignored for this long after the last pen sample (hover or
-- contact). The pen reports hover positions continuously while in range, so
-- this covers "palm resting while writing".
local PALM_REJECT_WINDOW_S = 1.0
-- After a pen tap outside the canvas (e.g. on the Good button), let gestures
-- through for this long so the button still gets its tap.
local PEN_PASSTHROUGH_GRACE_S = 0.6

local AnkiDrawOverlay = InputContainer:extend{
    host = nil,          -- window-level widget (the study screen)
    frame = nil,         -- widget whose dimen is the canvas (card frame)
    inset = 0,           -- keep ink inside the frame border
    stroke_radius = nil, -- half pen width in px
    eraser_radius = nil,
    allow_finger = false,
    enabled = true,
}

function AnkiDrawOverlay:init()
    self.strokes = {}
    self.current = nil
    self.dimen = Geom:new{ x = 0, y = 0, w = 0, h = 0 }
    self.stroke_radius = self.stroke_radius or math.max(1, Screen:scaleByDPI(2))
    self.eraser_radius = self.eraser_radius or Screen:scaleByDPI(12)
    self.last_pen_time = 0
    self.passthrough_until = 0
    self.pen_owner = nil      -- "draw" | "erase" | "pass" while the pen is down
    self.stylus_attached = false
end

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------

-- Canvas rectangle in screen coordinates, or nil before the first paint.
function AnkiDrawOverlay:getRect()
    local d = self.frame and self.frame.dimen
    if not d or not d.x or not d.y or not d.w or d.w <= 0 then
        return nil
    end
    local i = self.inset
    return Geom:new{ x = d.x + i, y = d.y + i, w = d.w - 2 * i, h = d.h - 2 * i }
end

function AnkiDrawOverlay:contains(x, y)
    local r = self:getRect()
    return r ~= nil and x ~= nil and y ~= nil
        and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

-- Raw slot coordinates are in panel orientation; gestures are already
-- rotated. Reuse KOReader's own rotation mapping for stylus samples.
local function adjustRawPos(input, x, y)
    local gd = input and input.gesture_detector
    if gd and gd.adjustGesCoordinate then
        local ges = { ges = "touch", pos = Geom:new{ x = x, y = y, w = 0, h = 0 } }
        local ok, res = pcall(gd.adjustGesCoordinate, gd, ges)
        local pos = (ok and res and res.pos) or ges.pos
        return pos.x, pos.y
    end
    return x, y
end

---------------------------------------------------------------------------
-- Painting
---------------------------------------------------------------------------

local function stamp(bb, x, y, r, color)
    bb:paintRect(x - r, y - r, 2 * r + 1, 2 * r + 1, color)
end

local function drawSegment(bb, x0, y0, x1, y1, r, color)
    local dx, dy = x1 - x0, y1 - y0
    local len = math.max(math.abs(dx), math.abs(dy))
    local step = math.max(1, math.floor(r / 2))
    local n = math.max(1, math.ceil(len / step))
    for i = 0, n do
        local t = i / n
        stamp(bb, math.floor(x0 + dx * t + 0.5), math.floor(y0 + dy * t + 0.5), r, color)
    end
end

local function paintStroke(bb, ox, oy, stroke, r)
    local pts = stroke.points
    if #pts == 1 then
        stamp(bb, ox + pts[1].x, oy + pts[1].y, r, Blitbuffer.COLOR_BLACK)
        return
    end
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        drawSegment(bb, ox + a.x, oy + a.y, ox + b.x, oy + b.y, r, Blitbuffer.COLOR_BLACK)
    end
end

-- Called by the host after it paints its layout. Ink coordinates are stored
-- relative to the canvas, so they follow the card frame when the front and
-- back layouts place it at different heights.
function AnkiDrawOverlay:paintTo(bb, x, y)
    local r = self:getRect()
    if not r then return end
    self.dimen = r
    for _, s in ipairs(self.strokes) do
        paintStroke(bb, r.x, r.y, s, self.stroke_radius)
    end
    if self.current and self.current.points then
        paintStroke(bb, r.x, r.y, self.current, self.stroke_radius)
    end
end

---------------------------------------------------------------------------
-- Stroke building
---------------------------------------------------------------------------

function AnkiDrawOverlay:_clampRel(x, y)
    local r = self:getRect()
    local rad = self.stroke_radius
    local rx = math.min(math.max(x - r.x, rad), r.w - 1 - rad)
    local ry = math.min(math.max(y - r.y, rad), r.h - 1 - rad)
    return math.floor(rx + 0.5), math.floor(ry + 0.5), r
end

-- Paint straight to the framebuffer and refresh only the touched area, so the
-- line follows the pen without repainting the whole study screen.
function AnkiDrawOverlay:_liveDraw(r, a, b)
    local bb = Screen.bb
    if not bb then return end
    local rad = self.stroke_radius
    local x0, y0 = r.x + a.x, r.y + a.y
    local x1, y1 = r.x + b.x, r.y + b.y
    if a == b then
        stamp(bb, x0, y0, rad, Blitbuffer.COLOR_BLACK)
    else
        drawSegment(bb, x0, y0, x1, y1, rad, Blitbuffer.COLOR_BLACK)
    end
    local pad = rad + 1
    local minx, miny = math.min(x0, x1) - pad, math.min(y0, y1) - pad
    local seg = Geom:new{ x = minx, y = miny,
        w = math.max(x0, x1) + pad - minx + 1, h = math.max(y0, y1) + pad - miny + 1 }
    local cur = self.current
    cur.bbox = cur.bbox and cur.bbox:combine(seg) or seg
    -- A2 is a black/white-only waveform: fastest e-ink update, made for ink.
    UIManager:setDirty(nil, "a2", seg)
end

function AnkiDrawOverlay:beginStroke(x, y, source)
    if not self:getRect() then return end
    local rx, ry, r = self:_clampRel(x, y)
    local p = { x = rx, y = ry }
    self.current = { points = { p }, source = source }
    self:_liveDraw(r, p, p)
end

function AnkiDrawOverlay:addPoint(x, y)
    local cur = self.current
    if not cur then return end
    local rx, ry, r = self:_clampRel(x, y)
    local last = cur.points[#cur.points]
    if last.x == rx and last.y == ry then return end
    local p = { x = rx, y = ry }
    table.insert(cur.points, p)
    self:_liveDraw(r, last, p)
end

function AnkiDrawOverlay:endStroke(x, y)
    local cur = self.current
    if not cur then return end
    if x and y then self:addPoint(x, y) end
    table.insert(self.strokes, { points = cur.points })
    self.current = nil
    -- Clean up A2 artifacts on the anti-aliased card text under the stroke.
    if cur.bbox then
        UIManager:setDirty(nil, "ui", cur.bbox)
    end
end

-- Stroke-level eraser: removes every stroke that passes near (x, y).
function AnkiDrawOverlay:eraseAt(x, y)
    local r = self:getRect()
    if not r then return end
    local ex, ey = x - r.x, y - r.y
    local lim = (self.eraser_radius + self.stroke_radius) ^ 2
    local kept, removed = {}, false
    for _, s in ipairs(self.strokes) do
        local hit = false
        for _, p in ipairs(s.points) do
            if (p.x - ex) ^ 2 + (p.y - ey) ^ 2 <= lim then hit = true break end
        end
        if hit then removed = true else table.insert(kept, s) end
    end
    if removed then
        self.strokes = kept
        UIManager:setDirty(self.host, "ui", r)
    end
end

function AnkiDrawOverlay:hasInk()
    return #self.strokes > 0 or self.current ~= nil
end

-- Drops all ink. Doesn't refresh by itself: the card transitions that call
-- this already repaint the host. Pass repaint = true from a Clear button.
function AnkiDrawOverlay:clear(repaint)
    local had = self:hasInk()
    self.strokes = {}
    self.current = nil
    self.pen_owner = nil
    if repaint and had and self.host then
        UIManager:setDirty(self.host, "ui", self:getRect())
    end
end

---------------------------------------------------------------------------
-- Stylus path (raw pen samples, before gesture detection)
---------------------------------------------------------------------------

function AnkiDrawOverlay:isHostOnTop()
    if not self.host then return false end
    if UIManager.getTopmostVisibleWidget then
        return UIManager:getTopmostVisibleWidget() == self.host
    end
    local stack = UIManager._window_stack
    local top = stack and stack[#stack]
    return top ~= nil and top.widget == self.host
end

function AnkiDrawOverlay:stylusSupported()
    local input = Device.input
    return input ~= nil and type(input.registerStylusCallback) == "function"
end

function AnkiDrawOverlay:attach()
    if self.stylus_attached or not self:stylusSupported() then return end
    local input = Device.input
    self.prev_stylus_callback = input.stylus_callback
    input:registerStylusCallback(function(inp, slot)
        local ok, consumed = pcall(self.onStylusSlot, self, inp, slot)
        if not ok then
            logger.warn("AnkiDrawOverlay: stylus handler error:", consumed)
            return false
        end
        if consumed then return true end
        if self.prev_stylus_callback then
            return self.prev_stylus_callback(inp, slot)
        end
        return false
    end)
    self.stylus_attached = true
    logger.dbg("AnkiDrawOverlay: stylus callback attached")
end

function AnkiDrawOverlay:detach()
    if not self.stylus_attached then return end
    local input = Device.input
    if self.prev_stylus_callback then
        input:registerStylusCallback(self.prev_stylus_callback)
    elseif input.unregisterStylusCallback then
        input:unregisterStylusCallback()
    end
    self.prev_stylus_callback = nil
    self.stylus_attached = false
end

-- Returns true to consume the pen sample (the gesture detector never sees it).
function AnkiDrawOverlay:onStylusSlot(input, slot)
    local t = now_s()
    local tool = slot.tool
    local is_pen_tool = tool ~= nil and tool ~= input.TOOL_TYPE_FINGER
    -- Any pen sample (hover included) keeps palm rejection active.
    if is_pen_tool or slot.slot == input.pen_slot then
        self.last_pen_time = t
    end

    if not self.enabled or not self:isHostOnTop() then
        self.pen_owner = nil
        return false
    end

    local down = slot.id ~= nil and slot.id >= 0
    local x, y = slot.x, slot.y
    if x and y then x, y = adjustRawPos(input, x, y) end

    -- Continue (or finish) a contact we already own.
    local owner = self.pen_owner
    if owner then
        if down then
            if owner == "draw" and x then
                self:addPoint(x, y)
            elseif owner == "erase" and x then
                self:eraseAt(x, y)
            end
        else
            if owner == "draw" then self:endStroke() end
            if owner == "pass" then
                self.passthrough_until = t + PEN_PASSTHROUGH_GRACE_S
            end
            self.pen_owner = nil
        end
        return owner ~= "pass"
    end

    if not down or not x then
        return false -- hovering
    end

    -- New pen contact.
    if self:contains(x, y) then
        if tool == input.TOOL_TYPE_ERASER then
            self.pen_owner = "erase"
            self:eraseAt(x, y)
        else -- pen, or highlighter (side button) treated as pen
            self.pen_owner = "draw"
            self:beginStroke(x, y, "pen")
        end
        return true
    end

    -- Pen touched outside the canvas: let it act like a finger on buttons.
    self.pen_owner = "pass"
    self.passthrough_until = math.huge
    return false
end

---------------------------------------------------------------------------
-- Gesture path (fallback, and palm rejection)
---------------------------------------------------------------------------

local function gesInside(self, ges)
    return ges.pos and self:contains(ges.pos.x, ges.pos.y)
end

-- Called by the host before normal gesture dispatch. Returns true to swallow.
function AnkiDrawOverlay:handleGesture(ges)
    if not self.enabled or not ges or not ges.ges then return false end
    local t = now_s()

    -- Palm rejection: while the pen is near the screen, finger gestures are
    -- dropped everywhere, except the tap from a pen press on a button.
    if self.stylus_attached and t >= self.passthrough_until then
        if t - self.last_pen_time < PALM_REJECT_WINDOW_S then
            return true
        end
    end

    local name = ges.ges
    local cur = self.current
    local drawing = cur ~= nil and cur.source == "gesture"

    -- With the stylus path active, gestures are fingers (or pen passthrough).
    local finger_draw = (not self.stylus_attached) or self.allow_finger
    if not finger_draw then
        -- Swallow finger input on the canvas so a resting hand can't open
        -- the full-text popup; leave the rest of the screen alone.
        return gesInside(self, ges) or false
    end

    if name == "touch" then
        if gesInside(self, ges) then
            self:beginStroke(ges.pos.x, ges.pos.y, "gesture")
            return true
        end
        return false
    elseif name == "pan" or name == "hold_pan" then
        if not drawing then
            local sp = ges.start_pos or ges.pos
            if not (sp and self:contains(sp.x, sp.y)) then return false end
            self:beginStroke(sp.x, sp.y, "gesture")
        end
        self:addPoint(ges.pos.x, ges.pos.y)
        return true
    elseif name == "hold" then
        if drawing then return true end
        if gesInside(self, ges) then
            self:beginStroke(ges.pos.x, ges.pos.y, "gesture")
            return true
        end
        return false
    elseif name == "pan_release" or name == "hold_release" then
        if drawing then
            self:endStroke(ges.pos.x, ges.pos.y)
            return true
        end
        return gesInside(self, ges) or false
    elseif name == "swipe" then
        -- Fast strokes (< 900 ms) end as a swipe instead of pan_release.
        if drawing then
            local e = ges.end_pos or ges.pos
            self:endStroke(e.x, e.y)
            return true
        end
        if gesInside(self, ges) then
            self:beginStroke(ges.pos.x, ges.pos.y, "gesture")
            local e = ges.end_pos or ges.pos
            self:endStroke(e.x, e.y)
            return true
        end
        return false
    elseif name == "tap" or name == "double_tap" then
        -- Short marks under the pan threshold arrive only as a tap.
        if drawing then
            self:endStroke()
            return true
        end
        if gesInside(self, ges) then
            self:beginStroke(ges.pos.x, ges.pos.y, "gesture")
            self:endStroke()
            return true
        end
        return false
    end

    -- Multi-finger and anything else: swallow on the canvas, ignore elsewhere.
    if drawing then return true end
    return gesInside(self, ges) or false
end

return AnkiDrawOverlay
