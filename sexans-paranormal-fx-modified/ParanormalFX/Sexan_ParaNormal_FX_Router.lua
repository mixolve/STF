-- @description Sexan ParaNormal FX Router
-- @author Sexan
-- @license GPL v3
-- @version 1.45
-- @changelog
--  Fix text alingment for new imgui
-- @provides
--   Modules/*.lua
--   Fonts/*.ttf
--   JSFX/*.jsfx
--   FXChains/*.RfxChain
--   [effect] JSFX/*.jsfx

local r = reaper
dofile(r.GetResourcePath() .. '/Scripts/ReaTeam Extensions/API/imgui.lua')('0.9.3')
local ImGui     = {}
local track_api = {}
local take_api  = {}
for name, func in pairs(r) do
    local track_name = name:match('^TrackFX_(.+)$')
    local take_name = name:match('^TakeFX_(.+)$')
    if track_name then track_api[track_name] = func end
    if take_name then take_api[take_name] = func end
end

take_api["CopyToTrack"] = r.TakeFX_CopyToTake
take_api["GetFXEnvelope"] = r.TakeFX_GetEnvelope
track_api["GetFXEnvelope"] = r.GetFXEnvelope

API = track_api
AW, AH = 0, 0
for name, func in pairs(reaper) do
    name = name:match('^ImGui_(.+)$')
    if name then ImGui[name] = func end
end

os_separator      = package.config:sub(1, 1)
script_path       = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]]
local reaper_path = r.GetResourcePath()

FX_FILE           = script_path .. "/FX_LIST.txt"
FX_CAT_FILE       = script_path .. "/FX_CAT_FILE.txt"
FX_DEV_LIST_FILE  = script_path .. "/FX_DEV_LIST_FILE.txt"

package.path      = script_path .. "?.lua;" -- GET DIRECTORY FOR REQUIRE
if DBG then dofile("C:/Users/Gokily/Documents/ReaGit/ReaScripts/Debug/LoadDebug.lua") end
if not r.GetAppVersion():match("^7%.") then
    r.ShowMessageBox("This script requires Reaper V7", "WRONG REAPER VERSION", 0)
    return
else
    if r.GetAppVersion():match("%.(%d+)") < "11" then
        r.ShowMessageBox("Reaper version V7.11 is minimal requirement.\n", "UPDATE REAPER", 0)
        return
    end
end

-- JSFX paths
local saike_splitter_path = reaper_path .. "/Effects/Saike Tools/Basics/BandSplitter.jsfx"
local lfos_path           = reaper_path .. "/Effects/ReaTeam JSFX/Modulation/snjuk2_LFO.jsfx"
local splitters_path      = reaper_path ..
    "/Effects/Suzuki Scripts/lewloiwc's Splitter Suite/lewloiwc_frequency_splitter.jsfx"


--local fx_browser_script_path = "C:/Users/Gokily/Documents/ReaGit/ReaScripts/FX/Sexan_FX_Browser_ParserV7.lua" -- DEV
--local fm_script_path         = "C:/Users/Gokily/Documents/ReaGit/ReaScripts/ImGui_Tools/FileManager.lua" -- DEV
local fx_browser_script_path = reaper_path .. "/Scripts/Sexan_Scripts/FX/Sexan_FX_Browser_ParserV7.lua"
local fm_script_path         = reaper_path .. "/Scripts/Sexan_Scripts/ImGui_Tools/FileManager.lua"

function ThirdPartyDeps()
    local reapack_process
    local repos = {
        { name = "Saike Tools",    url = 'https://raw.githubusercontent.com/JoepVanlier/JSFX/master/index.xml' },
        { name = "Suzuki Scripts", url = "https://github.com/Suzuki-Re/Suzuki-Scripts/raw/master/index.xml" },
    }

    for i = 1, #repos do
        local retinfo, url, enabled, autoInstall = r.ReaPack_GetRepositoryInfo(repos[i].name)
        if not retinfo then
            retval, error = r.ReaPack_AddSetRepository(repos[i].name, repos[i].url, true, 0)
            reapack_process = true
        end
    end

    -- ADD NEEDED REPOSITORIES
    if reapack_process then
        --r.ShowMessageBox("Added Third-Party ReaPack Repositories", "ADDING REPACK REPOSITORIES", 0)
        r.ReaPack_ProcessQueue(true)
        reapack_process = nil
    end
end

local function CheckDeps()
    --'Sexan FX Browser Parser V7' OR 'Sexan ImGui FileManager' OR 'Dear Imgui' OR 'Saike 4-pole BandSplitter'
    ThirdPartyDeps()
    local deps = {}

    if not r.ImGui_GetVersion then
        deps[#deps + 1] = '"Dear Imgui"'
    end
    if not r.file_exists(fx_browser_script_path) then
        deps[#deps + 1] = '"FX Browser Parser V7"'
    end
    if not r.file_exists(fm_script_path) then
        deps[#deps + 1] = '"Sexan ImGui FileManager"'
    end
    if not r.file_exists(lfos_path) then
        deps[#deps + 1] = '"Snjuk2"'
    end
    if not r.file_exists(splitters_path) then
        deps[#deps + 1] = [["lewloiwc's Splitter Suite"]]
    end
    if not r.file_exists(saike_splitter_path) then
        deps[#deps + 1] = '"Saike 4-pole BandSplitter"'
        r.SetExtState("PARANORMALFX2", "UPDATEFX", "true", false)
    end

    if #deps ~= 0 then
        r.ShowMessageBox("Need Additional Packages.\nPlease Install it in next window", "MISSING DEPENDENCIES", 0)
        r.ReaPack_BrowsePackages(table.concat(deps, " OR "))
        return true
    end
end

if CheckDeps() then return end

dofile(r.GetResourcePath() .. '/Scripts/ReaTeam Extensions/API/imgui.lua')('0.8.7')
--if ThirdPartyDeps() then return end

ctx = ImGui.CreateContext('ParaNormalFX Router')

local shortcut_state
local function UpdateReaperShortcuts(focused, capture)
    REAPER_SHORTCUT_BRIDGE = r.GetExtState("CustomWebBrowser", "paranormalShortcutBridge") == "1"
    local state = (focused and "1" or "0") .. (capture and "1" or "0")
    if state ~= shortcut_state then
        r.SetExtState("CustomWebBrowser", "paranormalFocused", focused and "1" or "0", false)
        r.SetExtState("CustomWebBrowser", "paranormalCapture", capture and "1" or "0", false)
        shortcut_state = state
    end
    if REAPER_SHORTCUT_BRIDGE then ImGui.SetNextFrameWantCaptureKeyboard(ctx, capture) end
end

ImGui.SetConfigVar(ctx, ImGui.ConfigVar_WindowsMoveFromTitleBarOnly(), 1)
WND_FLAGS = ImGui.WindowFlags_NoScrollbar() | ImGui.WindowFlags_NoScrollWithMouse()
FLT_MIN, FLT_MAX = ImGui.NumericLimits_Float()

draw_list = r.ImGui_GetWindowDrawList(ctx)

ORG_FONT_SIZE = 17
FONT_SIZE = ORG_FONT_SIZE
local TEXT_FONT_FILE = script_path .. 'Fonts/IosevkaCharonMono-Bold.ttf'

TABLER_ICON = require("Modules/TablerIcons")
ICON_FONT_SIZE = 18
ICONS_FONT_SMALL = ImGui.CreateFont(script_path .. 'Fonts/TablerIcons-P0.ttf', ICON_FONT_SIZE)
ImGui.Attach(ctx, ICONS_FONT_SMALL)
ICONS_FONT_SMALL_FACTORY = ICONS_FONT_SMALL
ICONS_FONT_LARGE = ICONS_FONT_SMALL

SYSTEM_FONT = ImGui.CreateFont(TEXT_FONT_FILE, FONT_SIZE)
ImGui.Attach(ctx, SYSTEM_FONT)
-- One font instance for widgets, menus and custom draw-list labels.
DEFAULT_FONT = SYSTEM_FONT
DEFAULT_FONT_FACTORY = SYSTEM_FONT
SYSTEM_FONT_FACTORY = SYSTEM_FONT
TOOLBAR_TEXT_FONT = SYSTEM_FONT

DEF_PARALLEL            = "2"
ESC_CLOSE               = false
AUTO_COLORING           = false
CUSTOM_FONT             = nil
ANIMATED_HIGLIGHT       = true
DEFAULT_DND             = true
CTRL_DRAG_AUTOCONTAINER = false
TOOLTIPS                = false
SHOW_C_CONTENT_TOOLTIP  = false
V_LAYOUT                = true
CENTER_RESET            = false
STARTUP_CENTER_RESET    = true
PENDING_CENTER_RESET    = 0
SHOW_ADD_FX_ALL_PLUGINS   = true
SHOW_ADD_FX_CATEGORY      = true
SHOW_ADD_FX_DEVELOPER     = true
SHOW_ADD_FX_CHAINS        = true
SHOW_ADD_FX_UTILITY       = true
SHOW_ADD_FX_PROCESSING    = true
SHOW_ADD_FX_CONT          = true
SHOW_ADD_FX_RECENT        = true
SHOW_ADD_FX_AUDIO_PLUGINS = false


OPEN_PM_INSPECTOR = false
MODE              = "TRACK"

--profiler = dofile(reaper.GetResourcePath() ..
--  '/Scripts/ReaTeam Scripts/Development/cfillion_Lua profiler.lua')
--reaper.defer = profiler.defer

if r.file_exists(fx_browser_script_path) then
    dofile(fx_browser_script_path)
end
if r.file_exists(fm_script_path) then
    dofile(fm_script_path)
end

require("Modules/TextLayout")
require("Modules/Utils")
require("Modules/Drawing")
require("Modules/Canvas")
require("Modules/ContainerCode")
require("Modules/Functions")
FLUX = require("Modules/flux")

if r.HasExtState("PARANORMALFX2", "SETTINGS") then
    local stored = r.GetExtState("PARANORMALFX2", "SETTINGS")
    if stored ~= nil then
        local storedTable = stringToTable(stored)
        if storedTable ~= nil then
            local COLOR = GetColorTbl()
            local function StoredBool(value, fallback)
                if value ~= nil then return value end
                return fallback
            end
            -- SETTINGS
            --V_LAYOUT = storedTable.v_layout ~= nil and storedTable.v_layout or V_LAYOUT
            if storedTable.v_layout ~= nil then
                V_LAYOUT = storedTable.v_layout
            end
            SHOW_C_CONTENT_TOOLTIP = storedTable.show_c_content_tooltips ~= nil and storedTable.show_c_content_tooltips
            TOOLTIPS = storedTable.tooltips ~= nil and storedTable.tooltips
            ANIMATED_HIGLIGHT = storedTable.animated_highlight
            CTRL_DRAG_AUTOCONTAINER = storedTable.ctrl_autocontainer
            ESC_CLOSE = storedTable.esc_close
            CUSTOM_FONT = storedTable.custom_font
            AUTO_COLORING = storedTable.auto_color
            new_spacing_y = storedTable.spacing
            ZOOM_MAX = storedTable.zoom_max and storedTable.zoom_max or 1
            ZOOM_DEFAULT = storedTable.zoom_default and storedTable.zoom_default or 1
            ADD_BTN_H = storedTable.add_btn_h
            ADD_BTN_W = storedTable.add_btn_w
            CENTER_RESET = storedTable.center_reset ~= nil and storedTable.center_reset or CENTER_RESET
            SHOW_ADD_FX_ALL_PLUGINS = StoredBool(storedTable.show_add_fx_all_plugins, SHOW_ADD_FX_ALL_PLUGINS)
            SHOW_ADD_FX_CATEGORY = StoredBool(storedTable.show_add_fx_category, SHOW_ADD_FX_CATEGORY)
            SHOW_ADD_FX_DEVELOPER = StoredBool(storedTable.show_add_fx_developer, SHOW_ADD_FX_DEVELOPER)
            SHOW_ADD_FX_CHAINS = StoredBool(storedTable.show_add_fx_chains, SHOW_ADD_FX_CHAINS)
            SHOW_ADD_FX_UTILITY = StoredBool(storedTable.show_add_fx_utility, SHOW_ADD_FX_UTILITY)
            SHOW_ADD_FX_PROCESSING = StoredBool(storedTable.show_add_fx_processing, SHOW_ADD_FX_PROCESSING)
            SHOW_ADD_FX_CONT = StoredBool(storedTable.show_add_fx_cont, SHOW_ADD_FX_CONT)
            SHOW_ADD_FX_RECENT = StoredBool(storedTable.show_add_fx_recent, SHOW_ADD_FX_RECENT)
            SHOW_ADD_FX_AUDIO_PLUGINS = StoredBool(storedTable.show_add_fx_audio_plugins, SHOW_ADD_FX_AUDIO_PLUGINS)
            ADD_FX_MARKED = type(storedTable.add_fx_marked) == "table" and storedTable.add_fx_marked or ADD_FX_MARKED
            WireThickness = storedTable.wirethickness
            COLOR["wire"] = storedTable.wire_color
            COLOR["n"] = storedTable.fx_color
            if COLOR["n"] == 0x9999FFFF then COLOR["n"] = 0xBBBBBBFF end
            COLOR["bypass"] = storedTable.bypass_color
            COLOR["Container"] = storedTable.container_color
            COLOR["parallel"] = storedTable.parallel_color
            COLOR["knob_vol"] = storedTable.knobvol_color
            COLOR["knob_drywet"] = storedTable.drywet_color
            COLOR["knob_drywet"] = storedTable.drywet_color
            COLOR["sine_anim"] = storedTable.anim_color
            COLOR["offline"] = storedTable.offline_color and storedTable.offline_color or COLOR["offline"]
            COLOR["bg"] = storedTable.background and storedTable.background or COLOR["bg"]
            SetColorTbl(COLOR)
        end
    end
end
TOOLTIPS = false
SHOW_C_CONTENT_TOOLTIP = false

SELECTED_FONT = CUSTOM_FONT and SYSTEM_FONT or DEFAULT_FONT

local function pdefer(func)
    reaper.defer(function()
        local status, err = xpcall(func, debug.traceback)
        if not status then
            local byLine = "([^\r\n]*)\r?\n?"
            local trimPath = "[\\/]([^\\/]-:%d+:.+)$"
            local stack = {}
            for line in string.gmatch(err, byLine) do
                local str = string.match(line, trimPath) or line
                stack[#stack + 1] = str
            end
            r.ShowConsoleMsg(
                "Error: " .. stack[1] .. "\n\n" ..
                "Stack traceback:\n\t" .. table.concat(stack, "\n\t", 3) .. "\n\n" ..
                "Reaper:       \t" .. r.GetAppVersion() .. "\n" ..
                "Platform:     \t" .. r.GetOS()
            )
            ClearExtState()
        end
    end)
end

function StoreToPEXT(last_target)
    if not last_target then return end
    local storedTable = {}
    if r.ValidatePtr(last_target, "MediaTrack*") then
        storedTable.CANVAS = CANVAS
        storedTable.CONTAINERS = GetTRContainerData()
    elseif r.ValidatePtr(last_target, "MediaItem_Take*") then
        storedTable.CANVAS = CANVAS
        storedTable.CONTAINERS = GetTRContainerData()
    end
    local serialized = tableToString(storedTable)
    if r.ValidatePtr(last_target, "MediaTrack*") then
        r.GetSetMediaTrackInfo_String(last_target, "P_EXT:PARANORMAL_FX2", serialized, true)
    elseif r.ValidatePtr(last_target, "MediaItem_Take*") then
        r.GetSetMediaItemTakeInfo_String(last_target, "P_EXT:PARANORMAL_FX2", serialized, true)
    end
end

local function QueueCenterReset(frames)
    PENDING_CENTER_RESET = math.max(PENDING_CENTER_RESET, frames or 8)
end

local function RunPendingCenterReset()
    if PENDING_CENTER_RESET <= 0 or not CANVAS then return end
    ResetView(true)
    PENDING_CENTER_RESET = PENDING_CENTER_RESET - 1
end

function RestoreFromPEXT(mode)
    local rv, stored
    local reset_restored_view = CENTER_RESET or STARTUP_CENTER_RESET
    if mode == "TRACK" and r.ValidatePtr(TRACK, "MediaTrack*") then
        rv, stored = r.GetSetMediaTrackInfo_String(TRACK, "P_EXT:PARANORMAL_FX2", "", false)
    elseif mode == "ITEM" and r.ValidatePtr(TAKE, "MediaItem_Take*") then
        rv, stored = r.GetSetMediaItemTakeInfo_String(TAKE, "P_EXT:PARANORMAL_FX2", "", false)
    end
    if rv == true and stored ~= nil then
        local storedTable = stringToTable(stored)
        if storedTable ~= nil then
            if mode == "TRACK" and r.ValidatePtr(TRACK, "MediaTrack*") then
                CANVAS = storedTable.CANVAS
                SetTRContainerData(storedTable.CONTAINERS)
                if reset_restored_view and CANVAS then QueueCenterReset() end
            elseif mode == "ITEM" and r.ValidatePtr(TAKE, "MediaItem_Take*") then
                CANVAS = storedTable.CANVAS
                SetTRContainerData(storedTable.CONTAINERS)
                if reset_restored_view and CANVAS then QueueCenterReset() end
            end
            STARTUP_CENTER_RESET = false
            return true
        end
    end
end

local FX_LIST, CAT = MakeFXFiles()

if not FX_LIST or not CAT then
    FX_LIST, CAT = ReadFXFile()
end

if r.HasExtState("PARANORMALFX2", "UPDATEFX") then
    r.DeleteExtState("PARANORMALFX2", "UPDATEFX", false)
end

function GetFXBrowserData()
    return FX_LIST, CAT
end

function UpdateFXBrowserData()
    FX_LIST, CAT = ReadFXFile()
end

function RescanFxList()
    FX_LIST, CAT = MakeFXFiles()
end

UpdateChainsTrackTemplates(CAT)

-- local function CheckReaperIODnd()
--     M_TEST()
--     local mx, my = r.GetMousePosition()
--     if LAST_CLICK and not A_X then
--         A_X, A_Y = mx, my
--     end

--     if A_X then
--         local tr, buf = r.GetThingFromPoint(A_X, A_Y)
--         if buf == "tcp.io" and not REAPER_DND then
--             REAPER_DND = buf == "tcp.io" and tr or nil
--         end
--     end
--     return mx, my
-- end

-- img = r.ImGui_CreateImage( script_path .. "SchwaARM.png")
-- r.ImGui_Attach(ctx, img)

function UpdateZoomFont()
    if not CANVAS then return end
    local new_font_size = ORG_FONT_SIZE
    if FONT_SIZE ~= new_font_size then
        if NEXT_FRAME then
            if DEFAULT_FONT then
                r.ImGui_Detach(ctx, ICONS_FONT_SMALL)
                r.ImGui_Detach(ctx, SYSTEM_FONT)
                r.ImGui_Detach(ctx, DEFAULT_FONT)
            end
            ICONS_FONT_SMALL = ImGui.CreateFont(script_path .. 'Fonts/TablerIcons-P0.ttf', ICON_FONT_SIZE)
            ImGui.Attach(ctx, ICONS_FONT_SMALL)
            SYSTEM_FONT = ImGui.CreateFont(TEXT_FONT_FILE, new_font_size)
            ImGui.Attach(ctx, SYSTEM_FONT)
            DEFAULT_FONT = ImGui.CreateFont(TEXT_FONT_FILE, new_font_size)
            ImGui.Attach(ctx, DEFAULT_FONT)
            FONT_SIZE = new_font_size
            SELECTED_FONT = CUSTOM_FONT and SYSTEM_FONT or DEFAULT_FONT
            NEXT_FRAME = nil
        end
    end
end

local old_time = r.time_precise()
local start_time = old_time
local old_play = r.GetPlayState() & 1
local old_ex_pos = r.GetCursorPosition()
local function UpdateDeltaTime()
    local now_time = r.time_precise()
    TIME_SINCE_START = now_time - start_time

    if r.GetPlayState() & 1 ~= old_play or old_ex_pos ~= r.GetCursorPosition() then
        start_time = r.time_precise()
        old_play = r.GetPlayState() & 1
        old_ex_pos = r.GetCursorPosition()
    end

    DT = now_time - old_time
    old_time = now_time
    FLUX.update(DT)
end

function DrawPopupRowBackground(context, colour, y1, y2)
    local list = r.ImGui_GetWindowDrawList(context)
    local wx, wy = r.ImGui_GetWindowPos(context)
    local ww, wh = r.ImGui_GetWindowSize(context)
    local cx = r.ImGui_GetCursorScreenPos(context)
    local available_w = r.ImGui_GetContentRegionAvail(context)
    local right = math.min(wx + ww - 1, cx + available_w + PARANORMAL_TEXT_PADDING + PARANORMAL_BORDER_WIDTH)
    r.ImGui_DrawList_PushClipRect(list, wx + 1, wy + 1, right, wy + wh - 1, false)
    r.ImGui_DrawList_AddRectFilled(list, wx + 1, y1, right, y2, r.ImGui_GetColorEx(context, colour))
    r.ImGui_DrawList_PopClipRect(list)
end

local menu_item_rects = {}
local menu_open_state = {}
local function MenuRowHovered(key)
    local rect = menu_item_rects[key]
    local mx, my = r.ImGui_GetMousePos(ctx)
    return rect and mx >= rect[1] and mx <= rect[3] and my >= rect[2] and my <= rect[4]
end
local function RememberMenuRow(key)
    local x1, y1 = r.ImGui_GetItemRectMin(ctx)
    local x2, y2 = r.ImGui_GetItemRectMax(ctx)
    menu_item_rects[key] = {x1, y1, x2, y2}
end
function MonoMenuItem(context, label, shortcut, selected, enabled)
    local wx, wy = r.ImGui_GetWindowPos(context)
    local key = tostring(wx) .. ":" .. tostring(wy) .. ":" .. label
    local highlighted = enabled ~= false and MenuRowHovered(key)
    r.ImGui_PushStyleColor(context, r.ImGui_Col_Text(), 0xFFFFFF00)
    local _, row_y = r.ImGui_GetCursorScreenPos(context)
    local _, spacing_y = r.ImGui_GetStyleVar(context, r.ImGui_StyleVar_ItemSpacing())
    if highlighted then
        DrawPopupRowBackground(context, 0xBBBBBBFF, row_y - spacing_y / 2,
            row_y + r.ImGui_GetTextLineHeight(context) + spacing_y / 2)
    end
    local clicked, checked = r.ImGui_MenuItem(context, label, shortcut, selected, enabled)
    r.ImGui_PopStyleColor(context)
    RememberMenuRow(key)
    local ww = r.ImGui_GetWindowSize(context)
    ParaDrawText(r.ImGui_GetWindowDrawList(context), label, wx, row_y-spacing_y/2,
        wx+ww-1,row_y+r.ImGui_GetTextLineHeight(context)+spacing_y/2-1,
        enabled == false and 0xBBBBBBFF or highlighted and 0x000000FF or 0xFFFFFFFF,0,false,1)
    return clicked, checked
end
local menu_label_stack = {}
local function DrawMonoMenuLabel(entry)
    if entry.highlighted then
        r.ImGui_DrawList_PushClipRect(entry.list, entry.wx + 1, entry.wy + 1,
            entry.wx + entry.ww - 1, entry.wy + entry.wh - 1, false)
        r.ImGui_DrawList_AddRectFilled(entry.list, entry.wx + 1, entry.y - 4,
            entry.wx + entry.ww - 1, entry.y + entry.font_h + 4, 0xBBBBBBFF)
        r.ImGui_DrawList_PopClipRect(entry.list)
    end
    ParaDrawText(entry.list, entry.label, entry.wx, entry.y - PARANORMAL_TEXT_PADDING,
        entry.wx + entry.ww - 1, entry.y + entry.font_h + PARANORMAL_TEXT_PADDING - 1,
        entry.colour, 0, false, 1)
end
function BeginMonoMenu(context, label, enabled)
    local wx, wy = r.ImGui_GetWindowPos(context)
    local ww, wh = r.ImGui_GetWindowSize(context)
    local key = tostring(wx) .. ":" .. tostring(wy) .. ":" .. label
    local list = r.ImGui_GetWindowDrawList(context)
    local x, y = r.ImGui_GetCursorScreenPos(context)
    local font_h = r.ImGui_GetTextLineHeight(context)
    local mx, my = r.ImGui_GetMousePos(context)
    local hovered = enabled ~= false and mx >= wx and mx < wx + ww
        and my >= y - 4 and my < y + font_h + 4
    -- Native arrows use Text; make that pass invisible and draw only the label.
    r.ImGui_PushStyleColor(context, r.ImGui_Col_Text(), 0xFFFFFF00)
    r.ImGui_PushStyleColor(context, r.ImGui_Col_TextDisabled(), 0xFFFFFF00)
    local _, inner_y = r.ImGui_GetStyleVar(context, r.ImGui_StyleVar_ItemInnerSpacing())
    -- ImGui uses this value as submenu overlap; negative overlap creates an 8px gap.
    r.ImGui_PushStyleVar(context, r.ImGui_StyleVar_ItemInnerSpacing(), -8, inner_y)
    r.ImGui_PushStyleVar(context, r.ImGui_StyleVar_WindowPadding(), PARANORMAL_TEXT_PADDING + PARANORMAL_BORDER_WIDTH, PARANORMAL_TEXT_PADDING)
    local open = r.ImGui_BeginMenu(context, label, enabled)
    r.ImGui_PopStyleVar(context, 2)
    r.ImGui_PopStyleColor(context, 2)
    local entry = {list = list, x = x, y = y, wx = wx, wy = wy, ww = ww, wh = wh, font_h = font_h, highlighted = hovered or open, label = (label:gsub("##.*$", "")),
        colour = enabled == false and 0xBBBBBBFF or (hovered or open) and 0x000000FF or 0xFFFFFFFF}
    if open then menu_label_stack[#menu_label_stack + 1] = entry
    else DrawMonoMenuLabel(entry) end
    return open
end
function EndMonoMenu(context)
    r.ImGui_EndMenu(context)
    local entry = table.remove(menu_label_stack)
    if entry then DrawMonoMenuLabel(entry) end
end

local function PushPaletteStyle()
    local colors = GetColorTbl()
    local count = 0
    local function push(col_fn, color)
        if col_fn then
            r.ImGui_PushStyleColor(ctx, col_fn(), color)
            count = count + 1
        end
    end

    push(r.ImGui_Col_WindowBg, colors["bg"])
    push(r.ImGui_Col_PopupBg, 0x222222FF)
    push(r.ImGui_Col_TitleBg, 0x222222FF)
    push(r.ImGui_Col_TitleBgActive, 0x666666FF)
    push(r.ImGui_Col_TitleBgCollapsed, 0x222222FF)
    push(r.ImGui_Col_Border, 0xBBBBBBFF)
    push(r.ImGui_Col_Separator, 0x666666FF)
    push(r.ImGui_Col_Text, 0xFFFFFFFF)
    push(r.ImGui_Col_TextDisabled, 0x666666FF)
    push(r.ImGui_Col_TextSelectedBg, 0x666666FF)
    push(r.ImGui_Col_FrameBg, 0x222222FF)
    push(r.ImGui_Col_FrameBgHovered, 0x222222FF)
    push(r.ImGui_Col_FrameBgActive, 0x9999FFFF)
    push(r.ImGui_Col_CheckMark, 0xBBBBBBFF)
    push(r.ImGui_Col_Button, 0x222222FF)
    push(r.ImGui_Col_ButtonHovered, 0x222222FF)
    push(r.ImGui_Col_ButtonActive, 0x222222FF)
    push(r.ImGui_Col_Header, 0xBBBBBBFF)
    push(r.ImGui_Col_HeaderHovered, 0xBBBBBBFF)
    push(r.ImGui_Col_HeaderActive, 0xBBBBBBFF)
    push(r.ImGui_Col_ScrollbarBg, 0x222222FF)
    push(r.ImGui_Col_ScrollbarGrab, 0x666666FF)
    push(r.ImGui_Col_ScrollbarGrabHovered, 0x666666FF)
    push(r.ImGui_Col_ScrollbarGrabActive, 0xCCCCCCFF)
    push(r.ImGui_Col_SliderGrab, 0x9999FFFF)
    push(r.ImGui_Col_SliderGrabActive, 0x99CCCCFF)
    push(r.ImGui_Col_DragDropTarget, 0x99CCCCFF)
    push(r.ImGui_Col_NavHighlight, 0x9999FFFF)
    return count
end

TOOLBAR_BUTTON_HEIGHT = PARANORMAL_ROW_HEIGHT
PARANORMAL_SPACING = 8

function GetToolbarButtonWidth(label)
    return ParaPaddedWidth(label)
end

local mode_button_draws = {}
local function PaintToolbarButton(button, selected)
    ParaDrawFrame(button.list,button.x1,button.y1,button.x2,button.y2,
        selected and 0xBBBBBBFF or 0x444444FF,0xBBBBBBFF)
    ParaDrawText(button.list,button.label,button.x1,button.y1,button.x2,button.y2,
        selected and 0x000000FF or 0xFFFFFFFF,0.5,false,1)
end

function DrawToolbarButton(label, id, active)
    local width = GetToolbarButtonWidth(label)
    local clicked = r.ImGui_InvisibleButton(ctx, "##" .. id, width, TOOLBAR_BUTTON_HEIGHT)
    local x1,y1 = r.ImGui_GetItemRectMin(ctx)
    local x2,y2 = r.ImGui_GetItemRectMax(ctx)
    local button = {label=label,x1=x1,y1=y1,x2=x2,y2=y2,list=r.ImGui_GetWindowDrawList(ctx),
        held=r.ImGui_IsItemActive(ctx)}
    if id:match("^MODE_") then
        mode_button_draws[#mode_button_draws+1] = button
    else
        local selected
        if id == "settings" and clicked then selected = not active
        else selected = active or button.held or clicked end
        PaintToolbarButton(button, selected)
    end
    return clicked
end

local function PaintModeButtons()
    for _,button in ipairs(mode_button_draws) do
        PaintToolbarButton(button, button.label == MODE or button.held)
    end
    mode_button_draws = {}
end

local function ModeButton(label, active)
    return DrawToolbarButton(label, "MODE_" .. label, active)
end

function test()
    local TR_CONT = GetTRContainerData()
    SetCollapseData(TR_CONT, TMP.tbl, TMP.i)
    if TMP then TMP = nil end
end

local function UpdateTarget()
    if MODE == "ITEM" then
        TARGET = TAKE
        TRACK = TARGET and r.GetMediaItemTake_Track(TARGET)
    else
        TARGET = TRACK
    end
end

local function UpdateLastTargetCanvas()
    if MODE == "TRACK" and LAST_TRACK ~= TRACK then
        ResetStrippedNames()
        StoreToPEXT(LAST_TRACK)
        LAST_TRACK = TRACK
        LASTTOUCH_RV, LASTTOUCH_TR_NUM, LASTTOUCH_FX_ID, LASTTOUCH_P_ID = nil, nil, nil, nil
        if not RestoreFromPEXT(MODE) then
            CANVAS = InitCanvas()
            QueueCenterReset()
            STARTUP_CENTER_RESET = false
            InitTrackContainers()
        end
    elseif MODE == "ITEM" and LAST_TAKE ~= TAKE then
        ResetStrippedNames()
        StoreToPEXT(LAST_TAKE)
        LAST_TAKE = TAKE
        LASTTOUCH_RV, LASTTOUCH_TR_NUM, LASTTOUCH_FX_ID, LASTTOUCH_P_ID = nil, nil, nil, nil
        if not RestoreFromPEXT(MODE) then
            CANVAS = InitCanvas()
            QueueCenterReset()
            STARTUP_CENTER_RESET = false
            InitTrackContainers()
        end
    end
end

local function Main()
    UpdateDeltaTime()
    UpdateZoomFont()
    if WANT_REFRESH then
        WANT_REFRESH = nil
        UpdateChainsTrackTemplates(CAT)
    end

    TRACK = PIN and SEL_LIST_TRACK or r.GetSelectedTrack2(0, 0, true)
    ITEM = r.GetSelectedMediaItem(0, 0)
    TAKE = PIN and SEL_LIST_TAKE or (ITEM and r.GetActiveTake(ITEM))
    UpdateTarget()
    --UpdateLastTargetCanvas()

    -- if REAPER_DND then
    --     ImGui.SetNextWindowSizeConstraints(ctx, 500, 500, FLT_MAX, FLT_MAX)
    --     ImGui.SetNextWindowSize(ctx, 150, 150, ImGui.Cond_FirstUseEver())
    --     r.ImGui_SetNextWindowPos(ctx, mx-25, my-25)
    --     if r.ImGui_Begin(ctx, 'REAPERDND', false, r.ImGui_WindowFlags_NoInputs() | r.ImGui_WindowFlags_NoDecoration() |  r.ImGui_WindowFlags_NoBackground() |  r.ImGui_WindowFlags_AlwaysAutoResize() | r.ImGui_WindowFlags_NoMove()) then
    --             if r.ImGui_IsMouseDown(ctx,0) then
    --                 r.ShowConsoleMsg("DOWN")
    --             end
    --             r.ImGui_Image( ctx, img, 182//3, 125//3 )
    --         ImGui.End(ctx)
    --     end
    -- end

    local palette_style_count = PushPaletteStyle()
    ImGui.SetNextWindowSizeConstraints(ctx, 500, 500, FLT_MAX, FLT_MAX)
    ImGui.SetNextWindowSize(ctx, 500, 500, ImGui.Cond_FirstUseEver())

    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), PARANORMAL_SPACING, PARANORMAL_SPACING)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), PARANORMAL_TEXT_PADDING, PARANORMAL_TEXT_PADDING)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowPadding(), PARANORMAL_SPACING, PARANORMAL_SPACING)
    local shortcuts_focused = false
    local visible, open = r.ImGui_Begin(ctx, 'PARANORMAL FX ROUTER###PARANORMALFX', true, WND_FLAGS)
    r.ImGui_PopStyleVar(ctx)

    if visible then
        AW, AH = r.ImGui_GetContentRegionAvail(ctx)
        WX, WY = r.ImGui_GetWindowPos(ctx)
        MX, MY = r.ImGui_GetMousePos(ctx)
        DRAGX, DRAGY = r.ImGui_GetMouseDragDelta(ctx, nil, nil, 0)
        UpdateLastTargetCanvas()

        r.ImGui_PushFont(ctx, CUSTOM_FONT and SYSTEM_FONT_FACTORY or DEFAULT_FONT_FACTORY)

        if ModeButton("TRACK", MODE == "TRACK") and MODE ~= "TRACK" then
            StoreToPEXT(TAKE)
            MODE = "TRACK"
            API = track_api
            ClearExtState()
            UpdateTarget()
            RestoreFromPEXT(MODE)
        end
        r.ImGui_SameLine(ctx)
        if ModeButton("ITEM", MODE == "ITEM") and MODE ~= "ITEM" then
            StoreToPEXT(TRACK)
            MODE = "ITEM"
            API = take_api
            ClearExtState()
            UpdateTarget()
            RestoreFromPEXT(MODE)
        end

        PaintModeButtons()
        RunPendingCenterReset()

        MonitorLastTouchedFX()
        -- AW, AH = r.ImGui_GetContentRegionAvail(ctx)
        -- WX, WY = r.ImGui_GetWindowPos(ctx)
        -- MX, MY = r.ImGui_GetMousePos(ctx)
        -- DRAGX, DRAGY = r.ImGui_GetMouseDragDelta(ctx, nil, nil, 0)
        --r.ImGui_PushFont(ctx, CUSTOM_FONT and SYSTEM_FONT_FACTORY or DEFAULT_FONT_FACTORY)
        CanvasLoop()
        r.ImGui_PopFont(ctx)
        CollectFxData()
        r.ImGui_PushFont(ctx, SELECTED_FONT)
        if CANVAS then
            Draw()
        end
        r.ImGui_PopFont(ctx)
        r.ImGui_PushFont(ctx, SYSTEM_FONT_FACTORY)
        UI()
        r.ImGui_PopFont(ctx)
        r.ImGui_PushFont(ctx, CUSTOM_FONT and SYSTEM_FONT_FACTORY or DEFAULT_FONT_FACTORY)
        if OPEN_SETTINGS then
            DrawUserSettings()
            if OPEN_PM_INSPECTOR then OPEN_PM_INSPECTOR = nil end
        end
        if OPEN_PM_INSPECTOR then
            DrawPMInspector()
        else
            if PM_INSPECTOR_FXID then PM_INSPECTOR_FXID = nil end
        end

        if HasMultiple(SEL_TBL) then
            r.ImGui_SetCursorPos(ctx, 270, 25)
            r.ImGui_Button(ctx, "MARQUEE MOVE/COPY IS NOT SUPPORTED")
        end

        ClipBoard()
        r.ImGui_PopFont(ctx)
        --if OPEN_SLOTS then SlotsMenu() end
        if not IS_DRAGGING_RIGHT_CANVAS and r.ImGui_IsMouseReleased(ctx, 1) and
            not r.ImGui_IsAnyItemHovered(ctx) and
            not r.ImGui_IsPopupOpen(ctx, "RIGHT_CLICK_MENU") and
            not r.ImGui_IsPopupOpen(ctx, "INSERT_POINTS_MENU") and
            not DND_MOVE_FX and
            not DND_ADD_FX and
            not INSPECTOR_HOVERED and
            not UI_HOVERED and
            not SETTINGS_HOVERED then
            FOCUS_FX_FILTER = true
            r.ImGui_OpenPopup(ctx, 'FX LIST')
        end
        IS_DRAGGING_RIGHT_CANVAS = r.ImGui_IsMouseDragging(ctx, 1, 2)
        FX_OPENED = r.ImGui_IsPopupOpen(ctx, "FX LIST")
        RENAME_OPENED = r.ImGui_IsPopupOpen(ctx, "RENAME")
        FILE_MANAGER_OPENED = r.ImGui_IsPopupOpen(ctx, "File Dialog")

        shortcuts_focused = ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows())
        CheckStaleData()
        ImGui.End(ctx)
    end
    r.ImGui_PopStyleVar(ctx, 2) -- shared frame padding and toolbar item spacing
    r.ImGui_PopStyleColor(ctx, palette_style_count)
    UpdateReaperShortcuts(shortcuts_focused, TEXT_INPUT_ACTIVE or FX_OPENED or RENAME_OPENED or FILE_MANAGER_OPENED or false)
    if ESC and ESC_CLOSE then open = nil end

    if open then
        if DBG then
            DEBUG.defer(Main)
        else
            pdefer(Main)
        end
    end

    if FONT_UPDATE then FONT_UPDATE = nil end
    NEXT_FRAME = true
    -- if MOUSE_UP then
    --     if A_X then A_X, A_Y = nil,nil end
    --     if REAPER_DND then
    --         REAPER_DND = nil
    --     end
    -- end
end

function Exit()
    UpdateReaperShortcuts(false, false)
    if StoreSettings then
        StoreSettings()
    end
    if CLIPBOARD.tbl and CLIPBOARD.track == TRACK then
        ClearExtState()
    end
    if MODE == "TRACK" then
        StoreToPEXT(LAST_TRACK)
    else
        StoreToPEXT(LAST_TAKE)
    end
end

r.atexit(Exit)

if DBG then
    DEBUG.defer(Main)
else
    pdefer(Main)
end

--profiler.attachToWorld() -- after all functions have been defined
--profiler.run()
