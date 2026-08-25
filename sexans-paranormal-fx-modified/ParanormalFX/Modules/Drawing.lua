--@noindex
--NoIndex: true

local r = reaper
local os = r.GetOS()
local ImGui = {}
for name, func in pairs(reaper) do
    name = name:match("^ImGui_(.+)$")
    if name then
        ImGui[name] = func
    end
end

new_spacing_x, new_spacing_y = 8, 10
enclose_bnt_offset = 1.3
local LINE_POINTS, PLUGINS

LASTTOUCH_RV, LASTTOUCH_TR_NUM, LASTTOUCH_FX_ID, LASTTOUCH_P_ID = nil, nil, nil

SEL_TBL = {}

local stripped_names = {}

local PALETTE = {
    lavender = 0x9999FFFF,
    peach    = 0xFFCC99FF,
    red      = 0xFF9999FF,
    green    = 0x99CC99FF,
    blue     = 0x99CCCCFF,
    white    = 0xFFFFFFFF,
    gray_l   = 0xCCCCCCFF,
    gray_m   = 0x666666FF,
    gray_d   = 0x333333FF,
}

local COLOR = {
    ["bg"]           = PALETTE.gray_d,
    ["n"]            = PALETTE.green,
    ["Container"]    = PALETTE.green,
    ["enclose"]      = PALETTE.gray_d,
    ["knob_bg"]      = PALETTE.gray_d,
    ["knob_vol"]     = PALETTE.green,
    ["knob_drywet"]  = PALETTE.blue,
    ["midi"]         = PALETTE.lavender,
    ["del"]          = PALETTE.red,
    ["ROOT"]         = PALETTE.green,
    ["add"]          = PALETTE.gray_d,
    ["parallel"]     = PALETTE.gray_d,
    ["bypass"]       = PALETTE.red,
    ["enabled"]      = PALETTE.green,
    ["wire"]         = PALETTE.gray_l,
    ["dnd"]          = PALETTE.blue,
    ["dnd_enclose"]  = PALETTE.green,
    ["dnd_replace"]  = PALETTE.red,
    ["dnd_swap"]     = PALETTE.peach,
    ["sine_anim"]    = PALETTE.blue,
    ["phase"]        = PALETTE.lavender,
    ["cut"]          = PALETTE.green,
    ["menu_txt_col"] = PALETTE.blue,
    ["offline"]      = PALETTE.gray_m,
    ["active_PM"]    = PALETTE.blue,
    ["no_PM"]        = PALETTE.gray_m,
}

function PaletteColor(color)
    if not color then return PALETTE.gray_d end

    local red = (color >> 24) & 0xFF
    local green = (color >> 16) & 0xFF
    local blue = (color >> 8) & 0xFF
    local best, best_dist

    for _, palette_color in pairs(PALETTE) do
        local pr = (palette_color >> 24) & 0xFF
        local pg = (palette_color >> 16) & 0xFF
        local pb = (palette_color >> 8) & 0xFF
        local dist = (red - pr) ^ 2 + (green - pg) ^ 2 + (blue - pb) ^ 2
        if not best_dist or dist < best_dist then
            best, best_dist = palette_color, dist
        end
    end

    return best
end

local function NormalizeColorTbl(tbl)
    for key, value in pairs(tbl) do
        tbl[key] = PaletteColor(value)
    end
    tbl["Container"] = tbl["n"]
    return tbl
end

function GetColorTbl()
    NormalizeColorTbl(COLOR)
    return COLOR
end

function SetColorTbl(tbl)
    COLOR = NormalizeColorTbl(tbl)
end

-----------------------------------------------------------------
ITEM_SPACING_VERTICAL = 4 -- VERTICAL SPACING BETEWEEN ITEMS

CUSTOM_BTN_H = 22
Knob_Radius = CUSTOM_BTN_H // 2

-- INSERT POINT
ADD_BTN_W = 55
ADD_BTN_H = 14
-- SETTINGS
ROUND_CORNER = 2
WireThickness = 1
-----------------------------------------------------------------

local BLACKLIST = {
    "Melodyne",
    "Vocalign",
}

local HELPERS = {
    {
        fx = "JS:Volume/Pan Smoother",
        fx_name = "VOL - PAN",
        name = "Volume/Pan Smoother",
        alt_name = "utility/volume_pan",
        helper = "VOL - PAN",
    },
    {
        fx = "JS:Channel Polarity Control",
        fx_name = "POLARITY",
        name = "Channel Polarity Control",
        alt_name = "IX/StereoPhaseInvert",
        helper = "POLARITY",
    },
    {
        fx = "JS:Time Adjustment Delay",
        fx_name = "TIME DELAY",
        name = "Time Adjustment Delay",
        alt_name = "delay/time_adjustment",
        helper = "TIME DELAY",
    },
    {
        fx = "JS:Saike 4-pole BandSplitter",
        fx_name = "SAIKE SPLITTER",
        alt_name = "Saike Tools/Basics/BandSplitter.jsfx",
        name = "Saike 4-pole BandSplitter",
        helper = "SAIKE SPLITTER",
    },
    {
        name = "3-Band Splitter",
        alt_name = "loser/3BandSplitter",
    },
    {
        name = "4-Band Splitter",
        alt_name = "loser/4BandSplitter",
    },
    {
        name = "5-Band Splitter",
        alt_name = "loser/5BandSplitter",
    },
    {
        fx = "JS:LFO",
        fx_name = "SNJUK2 LFO",
        name = "LFO",
        alt_name = "ReaTeam JSFX/Modulation/snjuk2_LFO.jsfx",
        helper = "SNJUK2 LFO",
    },
    ----------------------------------------
    ----------------------------------------
    {
        fx = "JS:Frequency Splitter (lewloiwc)",
        fx_name = "LEWLOIWC 2-4 BAND MODE SPLITTER",
        alt_name = "Suzuki Scripts/lewloiwc's Splitter Suite/lewloiwc_frequency_splitter.jsfx",
        name = "Frequency Splitter (lewloiwc)",
        helper = "LEWLOIWC 2-4 FREQUENCY MODE SPLITTER",
    },
    {
        fx = "JS:Frequency Splitter - Linkwitz-Riley Minimum Phase (lewloiwc)",
        fx_name = "LEWLOIWC 3 BAND SPLITTER MINIMAL PHASE",
        alt_name = "Suzuki Scripts/lewloiwc's Splitter Suite/lewloiwc_frequency_splitter_linkwitz-riley(minimum_phase).jsfx",
        name = "Frequency Splitter - Linkwitz-Riley Minimum Phase (lewloiwc)",
        helper = "LEWLOIWC 3 FREQUENCY SPLITTER MINIMAL PHASE",
    },
    {
        fx = "JS:Frequency Splitter - Comb and Phaser (lewloiwc)",
        fx_name = "LEWLOIWC 2 BAND COMB/PHASER",
        alt_name = "Suzuki Scripts/lewloiwc's Splitter Suite/lewloiwc_frequency_splitter_comb_and_phaser.jsfx",
        name = "Frequency Splitter - Comb and Phaser (lewloiwc)",
        helper = "LEWLOIWC 2 BAND COMB/PHASER",
    },
    {
        fx = "JS:Frequency Splitter - Band and Notch (lewloiwc)",
        fx_name = "LEWLOIWC 2 BAND BAND/NOTCH",
        alt_name = "Suzuki Scripts/lewloiwc's Splitter Suite/lewloiwc_frequency_splitter_band_and_notch(minimum_phase).jsfx",
        name = "Frequency Splitter - Band and Notch (lewloiwc)",
        helper = "LEWLOIWC 2 BAND BAND/NOTCH",
    },
    {
        fx = "JS:Amplitude Splitter - Gate (lewloiwc)",
        fx_name = "LEWLOIWC GATE SPLITTER",
        alt_name = "Suzuki Scripts/lewloiwc's Splitter Suite/lewloiwc_amplitude_splitter_gate.jsfx",
        name = "Amplitude Splitter - Gate (lewloiwc)",
        helper = "LEWLOIWC GATE SPLITTER",
    },
    {
        fx = "JS:Amplitude Splitter - Transient (lewloiwc)",
        fx_name = "LEWLOIWC TRANSIENT SPLITTER",
        alt_name = "Suzuki Scripts/lewloiwc's Splitter Suite/lewloiwc_amplitude_splitter_transient.jsfx",
        name = "Amplitude Splitter - Transient (lewloiwc)",
        helper = "LEWLOIWC TRANSIENT SPLITTER",
    },
    {
        fx = "JS:Amplitude Splitter - Envelope Follower (lewloiwc)",
        fx_name = "LEWLOIWC ENVELOPE FOLLOWER",
        alt_name = "Suzuki Scripts/lewloiwc's Splitter Suite/lewloiwc_amplitude_splitter_envelope_follower.jsfx",
        name = "Amplitude Splitter - Envelope Follower (lewloiwc)",
        helper = "LEWLOIWC ENVELOPE FOLLOWER",
    },
}

local my_jsfx = {
    ["Sexan_Scripts/ParanormalFX/JSFX/MSMidFX.jsfx"] = "MS Mid FX",
    ["Sexan_Scripts/ParanormalFX/JSFX/MSSideFX.jsfx"] = "MS Side FX",
    ["Saike Tools/Basics/BandSplitter.jsfx"] = "SAIKE SPLITTER",
    ["Suzuki Scripts/lewloiwc's Splitter Suite/lewloiwc_amplitude_splitter_gate.jsfx"] = "GATE SPLITTER",
    ["Suzuki Scripts/lewloiwc's Splitter Suite/lewloiwc_amplitude_splitter_transient.jsfx"] = "TRANSIENT SPLITTER",
    ["Suzuki Scripts/lewloiwc's Splitter Suite/lewloiwc_frequency_splitter.jsfx"] = "ENVELOPE FOLLOWER",
    ["Suzuki Scripts/lewloiwc's Splitter Suite/lewloiwc_amplitude_splitter_envelope_follower.jsfx"] = "LEWLOIWC 2-4 BAND MODE SPLITTER",
    ["Suzuki Scripts/lewloiwc's Splitter Suite/lewloiwc_frequency_splitter_linkwitz-riley(minimum_phase).jsfx"] = "LEWLOIWC 3 FREQUENCY SPLITTER MINIMAL PHASE",
    ["Suzuki Scripts/lewloiwc's Splitter Suite/lewloiwc_frequency_splitter_comb_and_phaser.jsfx"] = "LEWLOIWC 2 BAND COMB/PHASER",
    ["Suzuki Scripts/lewloiwc's Splitter Suite/lewloiwc_frequency_splitter_band_and_notch(minimum_phase).jsfx"] = "LEWLOIWC 2 BAND BAND/NOTCH",
}

local function TrimMyJSName(name)
    local function trim(s)
        -- from PiL2 20.4
        return (s:gsub("^%s*(.-)%s*$", "%1"))
    end
    local new_name = trim(name)
    return my_jsfx[new_name] or name
end

local function DisplayUpperName(name)
    return tostring(name or ""):upper()
end

local function DisplayFxName(fx_name, fx_type)
    if fx_type == "Container" then
        local container_name = tostring(fx_name or ""):gsub("^[Cc][Oo][Nn][Tt][Aa][Ii][Nn][Ee][Rr]:%s*", "")
        if container_name == "" or container_name:lower() == "container" then
            return "CONT"
        end
        return DisplayUpperName(container_name)
    end
    if not stripped_names[fx_name] then
        local new_name = Stripname(fx_name, true, true)
        new_name = TrimMyJSName(new_name)
        stripped_names[fx_name] = DisplayUpperName(new_name)
    end
    return stripped_names[fx_name]
end

function ValidateClipboardFX()
    UpdateFxData()
    --! MAKE SURE FX IS NOT DELETED BEFORE DOING UPDATE
    if not GetFx(CLIPBOARD.guid) then
        ClearExtState()
    end
end

local function FindBlackListedFX(name)
    for i = 1, #BLACKLIST do
        if name:find(BLACKLIST[i]) then
            return true
        end
    end
end

function CalculateInsertContainerPosFromBlacklist(track)
    local tr = track and track or TARGET
    local cont_pos = 0
    for i = 1, API.GetCount(tr) do
        local ret, org_fx_name = API.GetNamedConfigParm(tr, i - 1, "fx_name")
        for j = 1, #BLACKLIST do
            if org_fx_name:find(BLACKLIST[j]) then
                cont_pos = cont_pos + 1
            end
        end
    end
    return -1000 - cont_pos
end

function EndUndoBlock(str)
    r.Undo_EndBlock("PARANORMAL: " .. str, -1)
end

local min, max = math.min, math.max
function IncreaseDecreaseBrightness(color, amt, no_alpha)
    return PaletteColor(color)
end

-- local function CalculateFontColor(color)
--     local alpha = color & 0xFF
--     local blue = (color >> 8) & 0xFF
--     local green = (color >> 16) & 0xFF
--     local red = (color >> 24) & 0xFF

--     local luminance = (0.299 * red + 0.587 * green + 0.114 * blue) / 255
--     return luminance > 0.5 and 0xFF or 0xFFFFFFFF
-- end

local def_s_frame_x, def_s_frame_y = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())
local def_s_spacing_x, def_s_spacing_y = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing())
local def_s_window_x, def_s_window_y = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_WindowPadding())

s_frame_x, s_frame_y = def_s_frame_x, def_s_frame_y
s_spacing_x, S_SPACING_Y = def_s_spacing_x, ITEM_SPACING_VERTICAL and ITEM_SPACING_VERTICAL or def_s_spacing_y
s_window_x, s_window_y = def_s_window_x, def_s_window_y

local function SwapParallelInfo(src, dst)
    local _, src_p = API.GetNamedConfigParm(TARGET, src, "parallel")
    local _, dst_p = API.GetNamedConfigParm(TARGET, dst, "parallel")
    API.SetNamedConfigParm(TARGET, src, "parallel", dst_p)
    API.SetNamedConfigParm(TARGET, dst, "parallel", src_p)
end

local function Swap(src_parrent_guid, prev_src_id, dst_guid)
    -- UPDATE FX TABLE DATA WITH NEW IDS
    UpdateFxData()
    -- GET NEW PARRENT ID
    local src_parrent = GetFx(src_parrent_guid)
    local src_item_id = CalcFxID(src_parrent, prev_src_id)

    -- GET RECALCULATED DST
    local dst_fx = GetFx(dst_guid)
    local dst_parrent = GetParentContainerByGuid(dst_fx)
    local dst_item_id = CalcFxID(dst_parrent, dst_fx.IDX)

    API.CopyToTrack(TARGET, dst_item_id, TARGET, src_item_id, true)
end

function CheckNextItemParallel(i, parrent_container)
    local src = CalcFxID(parrent_container, i)
    local dst = CalcFxID(parrent_container, i + 1)
    if not API.GetFXGUID(TARGET, dst) then
        return
    end
    local _, para = API.GetNamedConfigParm(TARGET, dst, "parallel")
    if para == "1" or para == "2" then
        SwapParallelInfo(src, dst)
    end
end

function CheckSourceNextItemParallel(i, P_TYPE, P_DIFF, P_ID, track)
    local function CalcSrcID(parrent_type, parrent_diff, parrent_id, idx)
        if parrent_type == "Container" then
            return 0x2000000 + parrent_id + (parrent_diff * idx)
        elseif parrent_type == "ROOT" then
            return idx - 1
        end
    end

    local function SwapSrcParallelInfo(src, dst, tr)
        local _, src_p = API.GetNamedConfigParm(tr, src, "parallel")
        local _, dst_p = API.GetNamedConfigParm(tr, dst, "parallel")
        API.SetNamedConfigParm(tr, src, "parallel", dst_p)
        API.SetNamedConfigParm(tr, dst, "parallel", src_p)
    end

    local src = CalcSrcID(P_TYPE, P_DIFF, P_ID, i)
    local dst = CalcSrcID(P_TYPE, P_DIFF, P_ID, i + 1)
    if not API.GetFXGUID(track, dst) then
        return
    end
    local _, para = API.GetNamedConfigParm(track, dst, "parallel")
    if para ~= "0" then
        SwapSrcParallelInfo(src, dst, track)
    end
end

-----------------
--- DND START ---
-----------------
local function DNDTooltips(str)
    return
end

local function CreateCustomPreviewData(tbl, i)
    if tbl[i].type == "ROOT" then
        return
    end
    if not DRAG_PREVIEW then
        DRAG_PREVIEW = Deepcopy(tbl)
        DRAG_PREVIEW.move_guid = tbl[i].guid
        DRAG_PREVIEW[i].guid = "PREVIEW"
        DRAG_PREVIEW.i = i
        DRAG_PREVIEW[i].name = DRAG_PREVIEW[i].name:gsub("^(%S+:)", "")
        DRAG_PREVIEW.x = tbl[i].type ~= "PREVIEW" and r.ImGui_GetCursorScreenPos(ctx) or nil
    end
end

local function DndAddFX_SRC(fx)
    if
        r.ImGui_BeginDragDropSource(
            ctx,
            r.ImGui_DragDropFlags_AcceptBeforeDelivery() | r.ImGui_DragDropFlags_SourceNoPreviewTooltip()
        )
    then
        r.ImGui_SetDragDropPayload(ctx, "DND ADD FX", fx)
        CreateCustomPreviewData({
            [1] = {
                bypass = true,
                wet_val = 0,
                p = 0,
                guid = "BTN_PREVIEW",
                type = "PREVIEW",
                name = Stripname(fx, true, true),
            },
            is_ara = FindBlackListedFX(fx),
        }, 1)
        r.ImGui_EndDragDropSource(ctx)
    end
end

local function DndAddFX_TARGET(tbl, i, parallel)
    if not DND_ADD_FX then
        return
    end
    if ARA_Protection(tbl, i, parallel) then
        return
    end
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_DragDropTarget(), COLOR["dnd"])
    r.ImGui_SetNextWindowBgAlpha(ctx, 0)
    if r.ImGui_BeginDragDropTarget(ctx) then
        if not SHOW_DND_TOOLTIPS then
            SHOW_DND_TOOLTIPS = "ADD TO " .. (parallel and "PARALLEL" or "SERIAL")
        end
        local ret, payload = r.ImGui_AcceptDragDropPayload(ctx, "DND ADD FX")
        r.ImGui_EndDragDropTarget(ctx)
        if ret then
            local parrent_container = GetParentContainerByGuid(tbl[i])
            local item_add_id = CalcFxID(parrent_container, i + 1)
            AddFX(payload, item_add_id, parallel)
        end
    end
    r.ImGui_PopStyleColor(ctx)
end

local function DndAddReplaceFX_TARGET(tbl, i, parallel)
    if tbl[i].guid == "PREVIEW" then
        return
    end
    if not DND_ADD_FX then
        return
    end
    if tbl[i].type == "ROOT" then
        return
    end
    if tbl[i].exclude_ara then
        return
    end
    --! DONT ALLOW DRAGING ARA PLUGINS OVER OTHERS
    if DRAG_PREVIEW and DRAG_PREVIEW.is_ara then
        return
    end
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_DragDropTarget(), COLOR["dnd_replace"])
    if r.ImGui_BeginDragDropTarget(ctx) then
        if not SHOW_DND_TOOLTIPS then
            SHOW_DND_TOOLTIPS = "REPLACE"
        end
        local ret, payload = r.ImGui_AcceptDragDropPayload(ctx, "DND ADD FX")
        r.ImGui_EndDragDropTarget(ctx)
        if ret then
            REPLACE_FX_POS = { tbl = tbl, i = i }
            local parrent_container = GetParentContainerByGuid(tbl[i])
            local item_add_id = CalcFxID(parrent_container, i)
            r.PreventUIRefresh(1)
            AddFX(payload, item_add_id, parallel)
            r.PreventUIRefresh(-1)
        end
    end
    r.ImGui_PopStyleColor(ctx)
end

local function DndAddFX_ENCLOSE_TARGET(tbl, i)
    if not DND_ADD_FX then
        return
    end
    if tbl[i].exclude_ara then
        return
    end

    if ARA_Protection(tbl, i) then
        return
    end

    if not DND_ADD_FX then
        return
    end
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_DragDropTarget(), COLOR["dnd_enclose"])
    if r.ImGui_BeginDragDropTarget(ctx) then
        if not SHOW_DND_TOOLTIPS then
            SHOW_DND_TOOLTIPS = "INSERT AND ENCLOSE BOTH INTO CONT"
        end
        local ret, payload = r.ImGui_AcceptDragDropPayload(ctx, "DND ADD FX")
        r.ImGui_EndDragDropTarget(ctx)
        if ret then
            r.Undo_BeginBlock()
            r.PreventUIRefresh(1)
            CreateContainerAndInsertFX(tbl, i, payload)
            r.PreventUIRefresh(-1)
            EndUndoBlock("INSERT FX AND ENCLOSE BOTH INTO CONT")
        end
    end
    r.ImGui_PopStyleColor(ctx)
end

local function DndMoveFX_SRC(tbl, i)
    if ALT then
        return
    end
    if tbl[i].exclude_ara then
        return
    end
    if tbl[i].type == "ROOT" then
        return
    end
    if
        r.ImGui_BeginDragDropSource(
            ctx,
            r.ImGui_DragDropFlags_AcceptBeforeDelivery() | r.ImGui_DragDropFlags_SourceNoPreviewTooltip()
        )
    then
        local data = table.concat({ tbl[i].guid, i }, ",")
        r.ImGui_SetDragDropPayload(ctx, "DND MOVE FX", data)
        CreateCustomPreviewData(tbl, i)
        r.ImGui_EndDragDropSource(ctx)
    end
end

local function DndMoveFX_ENCLOSE_TARGET(tbl, i)
    if ALT then
        return
    end
    if tbl[i].exclude_ara then
        return
    end
    if not DND_MOVE_FX then
        return
    end
    --! DO NOT MOVE ON ITSELF UNLESS COPYING
    if IsOnSelfEncloseButton(tbl, i) then
        tbl[i].no_draw_e = true
        return
    end
    --! DO NOT MOVE SELF CONTAINER INTO CHILD ENCLOSE
    if IsChildOfParrent(tbl, i) then
        tbl[i].no_draw_e = true
        return
    end
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_DragDropTarget(), COLOR["dnd_enclose"])
    if r.ImGui_BeginDragDropTarget(ctx) then
        local ret, payload = r.ImGui_AcceptDragDropPayload(ctx, "DND MOVE FX")
        if not SHOW_DND_TOOLTIPS then
            SHOW_DND_TOOLTIPS = (
                CTRL_DRAG and "COPY AND ENCLOSE BOTH INTO CONT" or "MOVE AND ENCLOSE BOTH INTO CONT"
            )
        end
        r.ImGui_EndDragDropTarget(ctx)
        if ret then
            r.Undo_BeginBlock()
            r.PreventUIRefresh(1)
            local src_guid, src_i = payload:match("(.+),(.+)")
            MoveTargetsToNewContainer(tbl, i, src_guid, tonumber(src_i))
            r.PreventUIRefresh(-1)
            EndUndoBlock("MOVE FX AND ENCLOSE BOTH INTO CONT")
        end
    end
    r.ImGui_PopStyleColor(ctx)
end

local function DndMoveFX_TARGET_SERIAL_PARALLEL(tbl, i, parallel, serial_insert_point)
    if not DND_MOVE_FX then
        return
    end
    if ARA_Protection(tbl, i, parallel) then
        return
    end
    --! DO NOT MOVE ON PARALLEL BUTTON WHILE IN SAME PARALLEL LANE
    if IsOnSameParallelLane(tbl, i, parallel) then
        tbl[i].no_draw_p = true
        return
    end
    --! CHECK NOT MOVING CHILD CONTAINERS ON ITS PARRENT CONTAINER OR MOVING PARENT CONTAINER TO ITS CHILD
    if IsChildOfParrent(tbl, i, parallel, serial_insert_point) then
        tbl[i].no_draw_s = true
        tbl[i].no_draw_p = true
        return
    end
    --! DO NOT MOVE ON SAME SERIAL LANE (PREVIOUS + AND NEXT + FROM OUR SOURCE ->  + |BUTTON| +)
    if IsSameSerialPos(tbl, i, serial_insert_point) then
        tbl[i].no_draw_s = true
        return
    end

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_DragDropTarget(), COLOR["dnd"])
    if r.ImGui_BeginDragDropTarget(ctx) then
        local tt_str = CTRL_DRAG and "COPY TO " or "MOVE TO "
        if not SHOW_DND_TOOLTIPS then
            SHOW_DND_TOOLTIPS = (parallel and tt_str .. "PARALLEL" or tt_str .. "SERIAL")
        end
        local ret, payload = r.ImGui_AcceptDragDropPayload(ctx, "DND MOVE FX")
        r.ImGui_EndDragDropTarget(ctx)
        if ret then
            r.Undo_BeginBlock()
            r.PreventUIRefresh(1)
            local src_guid, src_i = payload:match("(.+),(.+)")
            --SRC DATA
            local src_fx = GetFx(src_guid)
            local src_parrent = GetParentContainerByGuid(src_fx)
            local src_item_id = CalcFxID(src_parrent, src_i)
            -- DST DATA
            local dst_fx, dst_i = GetFx(tbl[i].guid), i
            local dst_parrent = GetParentContainerByGuid(dst_fx)
            -- CHECK IF DRAGGING BOT->TOP
            if src_parrent.guid == dst_parrent.guid then
                if not CTRL_DRAG then
                    dst_i = tonumber(src_i) > dst_i and dst_i + 1 or dst_i
                else
                    dst_i = dst_i + 1
                end
            else
                dst_i = dst_i + 1
            end
            -- CALCULATE DST FX ID
            local dst_item_id = CalcFxID(dst_parrent, dst_i)
            -- SET SRC FX TO SERIAL
            local is_move = (not CTRL_DRAG) and true or false
            if is_move then
                -- SWAP INFO WITH NEXT FX TO KEEP PLUGINS IN PLACE
                CheckNextItemParallel(src_i, src_parrent)
                -- SET SOURCE FX TO PARALLEL OR SERIAL
                API.SetNamedConfigParm(TARGET, src_item_id, "parallel", parallel and DEF_PARALLEL or "0")
                -- MOVE
                API.CopyToTrack(TARGET, src_item_id, TARGET, dst_item_id, true)
            else
                -- CRTL DRAG COPY TO DESTINATION
                API.CopyToTrack(TARGET, src_item_id, TARGET, dst_item_id, false)
                -- SET DESTINATION INFO TO PARALLEL OR SERIAL
                API.SetNamedConfigParm(TARGET, dst_item_id, "parallel", parallel and DEF_PARALLEL or "0")

                --! IF COPYING CONTAINER TRANSFER COLLAPSE STATE
                AddCollapseData(src_fx, dst_item_id)
            end
            r.PreventUIRefresh(-1)
            EndUndoBlock(
                (is_move and "MOVE " or "COPY ") .. "PLUGIN TO " .. (parallel and "PARALLEL LANE" or "SERIAL LANE")
            )
        end
    end
    r.ImGui_PopStyleColor(ctx)
end

local function DndMoveFX_TARGET_SWAP(tbl, i)
    if ALT then
        return
    end
    if tbl[i].guid == "PREVIEW" then
        return
    end
    if tbl[i].exclude_ara then
        return
    end
    if not DND_MOVE_FX then
        return
    end
    --! WE ARE SWAPPING FX, NO COPY OPERATION
    if CTRL_DRAG or tbl[i].type == "ROOT" then
        return
    end
    --! CHECK NOT MOVING CHILD CONTAINERS ON ITS PARRENT CONTAINER OR MOVING PARENT CONTAINER TO ITS CHILD
    if IsChildOfParrent(tbl, i) then
        return
    end
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_DragDropTarget(), COLOR["dnd_swap"])
    if r.ImGui_BeginDragDropTarget(ctx) then
        if not SHOW_DND_TOOLTIPS then
            SHOW_DND_TOOLTIPS = "SWAP/EXCHANGE PLACES"
        end
        local ret, payload = r.ImGui_AcceptDragDropPayload(ctx, "DND MOVE FX")
        r.ImGui_EndDragDropTarget(ctx)
        if ret then
            r.Undo_BeginBlock()
            r.PreventUIRefresh(1)
            local src_guid, src_i = payload:match("(.+),(.+)")
            --SRC DATA
            local src_fx = GetFx(src_guid)
            local src_parrent = GetParentContainerByGuid(src_fx)
            local src_item_id = CalcFxID(src_parrent, src_i)
            -- DST DATA
            local dst_guid, dst_fx, dst_i = tbl[i].guid, GetFx(tbl[i].guid), i
            local dst_parrent = GetParentContainerByGuid(dst_fx)
            -- CALCULATE DST FX ID
            local dst_item_id = CalcFxID(dst_parrent, dst_i)
            -- SWAP PARALLEL INFO WITH TARGET
            SwapParallelInfo(src_item_id, dst_item_id)
            -- MOVE SOURCE TO DESTINATION
            API.CopyToTrack(TARGET, src_item_id, TARGET, dst_item_id, true)
            -- MOVE DESTINATION TO SOURCE
            Swap(src_parrent.guid, src_i, dst_guid)
            r.PreventUIRefresh(-1)
            EndUndoBlock("SWAP/EXCHANGE PLUGINS")
        end
    end
    r.ImGui_PopStyleColor(ctx)
end
---------------
--- DND END ---
---------------
local FX_LIST, CAT, FX_SEARCH_LIST

FILTER = ""
local PROCESSING_SETUP_SEARCH_ITEMS = {
    { display = "3-BAND SPLITTER STOCK", name = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/3BANDSTOCK.RfxChain" },
    { display = "4-BAND SPLITTER STOCK", name = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/4BANDSTOCK.RfxChain" },
    { display = "5-BAND SPLITTER STOCK", name = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/5BANDSTOCK.RfxChain" },
    { display = "2-BAND SPLITTER ADVANCE", name = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/SAIKE_2_SETUP.RfxChain" },
    { display = "3-BAND SPLITTER ADVANCE", name = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/SAIKE_3_SETUP.RfxChain" },
    { display = "4-BAND SPLITTER ADVANCE", name = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/SAIKE_4_SETUP.RfxChain" },
    { display = "5-BAND SPLITTER ADVANCE", name = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/SAIKE_5_SETUP.RfxChain" },
    { display = "2-4 BAND CONFIGURABLE MODE SPLITTER", name = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/LEWLOIWC_2_4_MODE_SETUP.RfxChain" },
    { display = "2 BAND/NOTCH SPLITTER", name = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/LEWLOIWC_2_BANDNOTCH_SETUP.RfxChain" },
    { display = "2 COMB/PHASER SPLITTER", name = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/LEWLOIWC_2_COMBPHASE_SETUP.RfxChain" },
    { display = "3 BAND MINIMAL PHASE SPLITTER", name = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/LEWLOIWC_3_MIN_PHASE_SETUP.RfxChain" },
    { display = "TRANSIENT SPLITTER", name = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/LEWLOIWC_TRANSIENT_SETUP.RfxChain" },
    { display = "GATE SPLITTER", name = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/LEWLOIWC_GATE_SETUP.RfxChain" },
    { display = "ENVELOPE SPLITTER", name = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/LEWLOIWC_ENVELOPE_SETUP.RfxChain" },
    { display = "MID-SIDE SETUP", name = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/MS_SETUP.RfxChain" },
}

local function ShowAddFxMenuCategory(name)
    if name == "ALL PLUGINS" then return SHOW_ADD_FX_ALL_PLUGINS end
    if name == "CATEGORY" then return SHOW_ADD_FX_CATEGORY end
    if name == "DEVELOPER" then return SHOW_ADD_FX_DEVELOPER end
    if name == "FX CHAINS" then return SHOW_ADD_FX_CHAINS end
    if name == "PLUG-INS" then return SHOW_ADD_FX_AUDIO_PLUGINS end
    return true
end

local function AddFxSearchItem(out, seen, item)
    local key = type(item) == "table" and item.name or item
    if key == "Container" and not SHOW_ADD_FX_CONT then return end
    if key and not seen[key] then
        out[#out + 1] = item
        seen[key] = true
    end
end

local function DisplayRecentFxName(name)
    local recent_name = name:gsub("^(%S+:)", "")
    if recent_name:find(".RfxChain") then
        local chain_name = os:match("Win") and recent_name:reverse():match("(.-)\\")
            or recent_name:reverse():match("(.-)/")
        if chain_name then
            recent_name = chain_name:reverse()
        end
    end
    return DisplayUpperName(recent_name)
end

ADD_FX_MARKED = ADD_FX_MARKED or {}
local ADD_FX_LONG_PRESS
local ADD_FX_LONG_PRESS_TIME = 0.3
local ADD_FX_CLOSE_POPUP
local ADD_FX_ITEM_RECTS = {}

local function StartAddFxLongPress(key, x1, y1, x2, y2)
    ADD_FX_LONG_PRESS = {
        key = key,
        start = r.time_precise(),
        x1 = x1,
        y1 = y1,
        x2 = x2,
        y2 = y2,
    }
end

local function AddFxSelectableLabel(label, key, hide_text)
    local visible, id = label:match("^(.-)(##.*)$")
    if not visible then
        visible = label
        id = "##add_fx_" .. key
    end
    return (hide_text and "" or visible) .. id
end

local function DrawAddFxSelectable(label, fx_name, selected, width)
    local key = tostring(fx_name or label)
    local marked = ADD_FX_MARKED[key]
    local held = ADD_FX_LONG_PRESS and ADD_FX_LONG_PRESS.key == key
    local mouse_x, mouse_y = r.ImGui_GetMousePos(ctx)
    local previous_rect = ADD_FX_ITEM_RECTS[key]
    if not held and previous_rect and r.ImGui_IsMouseClicked(ctx, 0)
        and mouse_x >= previous_rect.x1 and mouse_x <= previous_rect.x2
        and mouse_y >= previous_rect.y1 and mouse_y <= previous_rect.y2 then
        StartAddFxLongPress(
            key,
            previous_rect.window_x1,
            previous_rect.y1,
            previous_rect.window_x2,
            previous_rect.y2
        )
        held = true
    end
    local prompt = held and r.time_precise() - ADD_FX_LONG_PRESS.start >= ADD_FX_LONG_PRESS_TIME
    if marked then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x99CCCCFF)
    end

    local flags = r.ImGui_SelectableFlags_DontClosePopups()
    local style_count = 1
    if prompt then
        style_count = 3
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Header(), 0x333333FF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x333333FF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x333333FF)
    else
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x666666FF)
    end
    local clicked = r.ImGui_Selectable(ctx, AddFxSelectableLabel(label, key, prompt), selected, flags)
    r.ImGui_PopStyleColor(ctx, style_count)
    if marked then
        r.ImGui_PopStyleColor(ctx)
    end

    local item_x1, item_y1 = r.ImGui_GetItemRectMin(ctx)
    local item_x2, item_y2 = r.ImGui_GetItemRectMax(ctx)
    local window_x = r.ImGui_GetWindowPos(ctx)
    local window_w = r.ImGui_GetWindowSize(ctx)
    if prompt then
        local prompt_text = marked and "UNMARK?" or "MARK?"
        local text_w, text_h = r.ImGui_CalcTextSize(ctx, prompt_text)
        local draw_list = r.ImGui_GetWindowDrawList(ctx)
        r.ImGui_DrawList_AddText(
            draw_list,
            window_x + (window_w - text_w) / 2,
            item_y1 + (item_y2 - item_y1 - text_h) / 2,
            0xFFFFFFFF,
            prompt_text
        )
    end
    ADD_FX_ITEM_RECTS[key] = {
        x1 = item_x1,
        y1 = item_y1,
        x2 = item_x2,
        y2 = item_y2,
        window_x1 = window_x,
        window_x2 = window_x + window_w,
    }
    local inside_item = mouse_x >= item_x1 and mouse_x <= item_x2 and mouse_y >= item_y1 and mouse_y <= item_y2
    local item_active = r.ImGui_IsItemActive(ctx)
    if inside_item and not held and (r.ImGui_IsMouseClicked(ctx, 0) or item_active) then
        StartAddFxLongPress(key, window_x, item_y1, window_x + window_w, item_y2)
        held = true
    end

    if held then
        clicked = false
        local active = ADD_FX_LONG_PRESS
        local release_inside = mouse_x >= active.x1 and mouse_x <= active.x2
            and mouse_y >= active.y1 and mouse_y <= active.y2
        if r.ImGui_IsMouseReleased(ctx, 0) then
            local is_long = r.time_precise() - active.start >= ADD_FX_LONG_PRESS_TIME
            if release_inside then
                if is_long then
                    ADD_FX_MARKED[key] = not ADD_FX_MARKED[key] or nil
                    if StoreSettings then StoreSettings() end
                else
                    clicked = true
                end
            end
            ADD_FX_LONG_PRESS = nil
        end
    end

    if clicked then
        ADD_FX_CLOSE_POPUP = true
    end

    return clicked
end

local function CollectFxChainSearchItems(tbl, path, out, seen)
    local extension = ".RfxChain"
    path = path or ""
    for i = 1, #tbl do
        if tbl[i].dir then
            CollectFxChainSearchItems(tbl[i], table.concat({ path, os_separator, tbl[i].dir }), out, seen)
        elseif type(tbl[i]) ~= "table" then
            AddFxSearchItem(out, seen, table.concat({ path, os_separator, tbl[i], extension }))
        end
    end
end

local function CollectCatSearchItems(category, out, seen)
    if category.name == "FX CHAINS" then
        CollectFxChainSearchItems(category.list, nil, out, seen)
        return
    end
    for i = 1, #(category.list or {}) do
        for j = 1, #(category.list[i].fx or {}) do
            AddFxSearchItem(out, seen, category.list[i].fx[j])
        end
    end
end

local function BuildFxSearchList(fx_list, cat)
    local search_list, seen = {}, {}
    if #(cat or {}) == 0 and SHOW_ADD_FX_ALL_PLUGINS then
        for i = 1, #(fx_list or {}) do
            AddFxSearchItem(search_list, seen, fx_list[i])
        end
    end
    for i = 1, #(cat or {}) do
        if cat[i].name ~= "TRACK TEMPLATES" and ShowAddFxMenuCategory(cat[i].name) then
            CollectCatSearchItems(cat[i], search_list, seen)
        end
    end
    if SHOW_ADD_FX_UTILITY then
        for i = 1, #HELPERS do
            if HELPERS[i].fx_name and HELPERS[i].fx then
                AddFxSearchItem(search_list, seen, {
                    name = HELPERS[i].fx,
                    display = HELPERS[i].fx_name,
                    search = table.concat({ HELPERS[i].fx_name, HELPERS[i].fx, HELPERS[i].name or "", HELPERS[i].alt_name or "" }, " "),
                })
            end
        end
        AddFxSearchItem(search_list, seen, { name = "JS:MS MID FX", display = "MS MID FX", search = "MS MID FX JS:MS MID FX" })
        AddFxSearchItem(search_list, seen, { name = "JS:MS SIDE FX", display = "MS SIDE FX", search = "MS SIDE FX JS:MS SIDE FX" })
    end
    if SHOW_ADD_FX_PROCESSING then
        for i = 1, #PROCESSING_SETUP_SEARCH_ITEMS do
            local item = PROCESSING_SETUP_SEARCH_ITEMS[i]
            AddFxSearchItem(search_list, seen, {
                name = item.name,
                display = item.display,
                search = item.display .. " " .. item.name,
            })
        end
    end
    if SHOW_ADD_FX_CONT then
        AddFxSearchItem(search_list, seen, { name = "Container", display = "CONT", search = "CONT Container" })
    end
    if SHOW_ADD_FX_RECENT and LAST_USED_FX then
        local recent_display = "RECENT: " .. DisplayRecentFxName(LAST_USED_FX)
        AddFxSearchItem(search_list, seen, { name = LAST_USED_FX, display = recent_display, search = recent_display .. " " .. LAST_USED_FX })
    end
    return search_list
end

local function DisplaySearchFxName(name)
    if name == "Container" then
        return "CONT"
    end
    if name:find(".RfxChain", nil, true) then
        local chain_name = name:gsub("%.RfxChain$", "")
        chain_name = chain_name:match(".*" .. Literalize(os_separator) .. "(.+)$") or chain_name
        return DisplayUpperName(chain_name)
    end
    return DisplayUpperName(name)
end

local function FilterBox()
    local MAX_FX_SIZE = 300
    if FOCUS_FX_FILTER or r.ImGui_IsWindowAppearing(ctx) then
        r.ImGui_SetKeyboardFocusHere(ctx)
        FOCUS_FX_FILTER = nil
    end
    r.ImGui_PushItemWidth(ctx, -FLT_MIN)
    _, FILTER = r.ImGui_InputText(ctx, "##input", FILTER)
    local filter_active = r.ImGui_IsItemActive(ctx)
    TEXT_INPUT_ACTIVE = filter_active
    if filter_active then
        r.ImGui_SetNextFrameWantCaptureKeyboard(ctx, false)
    end
    local filtered_fx = Filter_actions(FILTER, FX_SEARCH_LIST or FX_LIST)
    local filter_h = #filtered_fx == 0 and 0 or (#filtered_fx > 40 and 20 * 17 or (17 * #filtered_fx))
    ADDFX_Sel_Entry = SetMinMax(ADDFX_Sel_Entry or 1, 1, #filtered_fx)
    if #filtered_fx ~= 0 then
        if r.ImGui_BeginChild(ctx, "##popupp", MAX_FX_SIZE, filter_h) then
            for i = 1, #filtered_fx do
                local visible_name = DisplaySearchFxName(filtered_fx[i].display or filtered_fx[i].name) .. "##filtered_fx" .. i
                if DrawAddFxSelectable(visible_name, filtered_fx[i].name, i == ADDFX_Sel_Entry) then
                    AddFX(filtered_fx[i].name)
                    r.ImGui_CloseCurrentPopup(ctx)
                end
                DndAddFX_SRC(filtered_fx[i].name)
            end
            r.ImGui_EndChild(ctx)
        end
        local enter_pressed = r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter())
            or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter())
        if enter_pressed then
            AddFX(filtered_fx[ADDFX_Sel_Entry].name)
            ADDFX_Sel_Entry = nil
            FILTER = ""
            r.ImGui_CloseCurrentPopup(ctx)
        elseif filter_active and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_UpArrow()) then
            ADDFX_Sel_Entry = ADDFX_Sel_Entry - 1
        elseif filter_active and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_DownArrow()) then
            ADDFX_Sel_Entry = ADDFX_Sel_Entry + 1
        end
    end
    if filter_active and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
        FILTER = ""
        r.ImGui_CloseCurrentPopup(ctx)
    end
    return #filtered_fx ~= 0
end

local function DrawFxChains(tbl, path)
    local extension = ".RfxChain"
    path = path or ""
    for i = 1, #tbl do
        if tbl[i].dir then
            if r.ImGui_BeginMenu(ctx, tbl[i].dir) then
                DrawFxChains(tbl[i], table.concat({ path, os_separator, tbl[i].dir }))
                r.ImGui_EndMenu(ctx)
            end
        end
        if type(tbl[i]) ~= "table" then
            local chain_src = table.concat({ path, os_separator, tbl[i], extension })
            if DrawAddFxSelectable(DisplayUpperName(tbl[i]), chain_src) then
                AddFX(chain_src)
            end
            DndAddFX_SRC(chain_src)
        end
    end
end

local function LoadTemplate(template, replace)
    local track_template_path = r.GetResourcePath() .. "/TrackTemplates" .. template
    if replace then
        if not TARGET then
            return
        end
        local chunk = GetFileContext(track_template_path)
        r.SetTrackStateChunk(TARGET, chunk, true)
    else
        r.Main_openProject(track_template_path)
    end
end

local function DrawTrackTemplates(tbl, path)
    local extension = ".RTrackTemplate"
    path = path or ""
    for i = 1, #tbl do
        if tbl[i].dir then
            if r.ImGui_BeginMenu(ctx, tbl[i].dir) then
                local cur_path = table.concat({ path, os_separator, tbl[i].dir })
                DrawTrackTemplates(tbl[i], cur_path)
                r.ImGui_EndMenu(ctx)
            end
        end
        if type(tbl[i]) ~= "table" then
            if r.ImGui_Selectable(ctx, tbl[i]) then
                local template_str = table.concat({ path, os_separator, tbl[i], extension })
                LoadTemplate(template_str) -- ADD NEW TARGET FROM TEMPLATE
            end
        end
    end
end

local function DrawItems(tbl, main_cat_name)
    for i = 1, #tbl do
        if #(tbl[i].fx or {}) == 0 then
            r.ImGui_MenuItem(ctx, tbl[i].name, nil, false, false)
        elseif r.ImGui_BeginMenu(ctx, tbl[i].name) then
            for j = 1, #tbl[i].fx do
                if tbl[i].fx[j] then
                    local name = tbl[i].fx[j]

                    if main_cat_name == "ALL PLUGINS" and tbl[i].name ~= "INSTRUMENTS" then
                        -- STRIP PREFIX IN "ALL PLUGINS" CATEGORIES EXCEPT INSTRUMENT WHERE THERE CAN BE MIXED ONES
                        name = name:gsub("^(%S+:)", "")
                    elseif main_cat_name == "DEVELOPER" then
                        -- STRIP SUFFIX (DEVELOPER) FROM THESE CATEGORIES
                        name = name:gsub(" %(" .. Literalize(tbl[i].name) .. "%)", "")
                    end
                    local display_name = DisplayUpperName(name)
                    local tw = r.ImGui_CalcTextSize(ctx, display_name)
                    if DrawAddFxSelectable(display_name, tbl[i].fx[j], nil, tw > 500 and 500 or tw) then
                        AddFX(tbl[i].fx[j])
                    end
                    DndAddFX_SRC(tbl[i].fx[j])
                end
            end
            r.ImGui_EndMenu(ctx)
        end
    end
end

function DrawFXList()
    FX_LIST, CAT = GetFXBrowserData()
    FX_SEARCH_LIST = BuildFxSearchList(FX_LIST, CAT)
    local search = FilterBox()
    if search then
        if ADD_FX_LONG_PRESS and r.ImGui_IsMouseReleased(ctx, 0) then
            ADD_FX_LONG_PRESS = nil
        end
        ADD_FX_CLOSE_POPUP = nil
        return
    end
    for i = 1, #CAT do
        if CAT[i].name ~= "TRACK TEMPLATES" and ShowAddFxMenuCategory(CAT[i].name) then
            if #CAT[i].list ~= 0 then
                if r.ImGui_BeginMenu(ctx, CAT[i].name) then
                    if CAT[i].name == "FX CHAINS" then
                        DrawFxChains(CAT[i].list)
                        --elseif CAT[i].name == "TARGET TEMPLATES" then
                        --    DrawTrackTemplates(CAT[i].list)
                    else
                        DrawItems(CAT[i].list, CAT[i].name)
                    end
                    r.ImGui_EndMenu(ctx)
                end
            end
        end
    end

    if SHOW_ADD_FX_UTILITY and r.ImGui_BeginMenu(ctx, "UTILITY") then
        for i = 1, #HELPERS do
            if HELPERS[i].fx_name then
                if DrawAddFxSelectable(DisplayUpperName(HELPERS[i].fx_name), HELPERS[i].fx) then
                    AddFX(HELPERS[i].fx)
                end
                DndAddFX_SRC(HELPERS[i].fx)
            end
        end
        if DrawAddFxSelectable("MS MID FX", "JS:MS MID FX") then
            AddFX("JS:MS MID FX")
        end
        DndAddFX_SRC("JS:MS MID FX")
        if DrawAddFxSelectable("MS SIDE FX", "JS:MS SIDE FX") then
            AddFX("JS:MS SIDE FX")
        end
        DndAddFX_SRC("JS:MS SIDE FX")

        r.ImGui_EndMenu(ctx)
    end

    if SHOW_ADD_FX_PROCESSING and r.ImGui_BeginMenu(ctx, "PROCESSING SETUPS") then
        r.ImGui_SeparatorText(ctx, "STOCK")
        if r.ImGui_Selectable(ctx, "3-BAND SPLITTER STOCK") then
            local chain_src = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/3BANDSTOCK.RfxChain"
            AddFX(chain_src)
        end
        DndAddFX_SRC("../Scripts/Sexan_Scripts/ParanormalFX/FXChains/3BANDSTOCK.RfxChain")
        if r.ImGui_Selectable(ctx, "4-BAND SPLITTER STOCK") then
            local chain_src = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/4BANDSTOCK.RfxChain"
            AddFX(chain_src)
        end
        DndAddFX_SRC("../Scripts/Sexan_Scripts/ParanormalFX/FXChains/4BANDSTOCK.RfxChain")
        if r.ImGui_Selectable(ctx, "5-BAND SPLITTER STOCK") then
            local chain_src = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/5BANDSTOCK.RfxChain"
            AddFX(chain_src)
        end
        DndAddFX_SRC("../Scripts/Sexan_Scripts/ParanormalFX/FXChains/5BANDSTOCK.RfxChain")
        r.ImGui_SeparatorText(ctx, "LINEAR PHASE - 24/12dB SLOPE")
        if r.ImGui_Selectable(ctx, "2-BAND SPLITTER ADVANCE") then
            local chain_src = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/SAIKE_2_SETUP.RfxChain"
            AddFX(chain_src)
        end
        DndAddFX_SRC("../Scripts/Sexan_Scripts/ParanormalFX/FXChains/SAIKE_2_SETUP.RfxChain")
        if r.ImGui_Selectable(ctx, "3-BAND SPLITTER ADVANCE") then
            local chain_src = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/SAIKE_3_SETUP.RfxChain"
            AddFX(chain_src)
        end
        DndAddFX_SRC("../Scripts/Sexan_Scripts/ParanormalFX/FXChains/SAIKE_3_SETUP.RfxChain")
        if r.ImGui_Selectable(ctx, "4-BAND SPLITTER ADVANCE") then
            local chain_src = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/SAIKE_4_SETUP.RfxChain"
            AddFX(chain_src)
        end
        DndAddFX_SRC("../Scripts/Sexan_Scripts/ParanormalFX/FXChains/SAIKE_4_SETUP.RfxChain")
        if r.ImGui_Selectable(ctx, "5-BAND SPLITTER ADVANCE") then
            local chain_src = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/SAIKE_5_SETUP.RfxChain"
            AddFX(chain_src)
        end
        DndAddFX_SRC("../Scripts/Sexan_Scripts/ParanormalFX/FXChains/SAIKE_5_SETUP.RfxChain")
        r.ImGui_SeparatorText(ctx, "CUSTOM ADVANCE")
        if r.ImGui_Selectable(ctx, "2-4 BAND CONFIGURABLE MODE SPLITTER") then
            local chain_src = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/LEWLOIWC_2_4_MODE_SETUP.RfxChain"
            AddFX(chain_src)
        end
        if r.ImGui_Selectable(ctx, "2 BAND/NOTCH SPLITTER") then
            local chain_src = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/LEWLOIWC_2_BANDNOTCH_SETUP.RfxChain"
            AddFX(chain_src)
        end
        if r.ImGui_Selectable(ctx, "2 COMB/PHASER SPLITTER") then
            local chain_src = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/LEWLOIWC_2_COMBPHASE_SETUP.RfxChain"
            AddFX(chain_src)
        end
        if r.ImGui_Selectable(ctx, "3 BAND MINIMAL PHASE SPLITTER") then
            local chain_src = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/LEWLOIWC_3_MIN_PHASE_SETUP.RfxChain"
            AddFX(chain_src)
        end

        r.ImGui_SeparatorText(ctx, "AMPLITUDE")
        if r.ImGui_Selectable(ctx, "TRANSIENT SPLITTER") then
            local chain_src = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/LEWLOIWC_TRANSIENT_SETUP.RfxChain"
            AddFX(chain_src)
        end
        if r.ImGui_Selectable(ctx, "GATE SPLITTER") then
            local chain_src = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/LEWLOIWC_GATE_SETUP.RfxChain"
            AddFX(chain_src)
        end
        if r.ImGui_Selectable(ctx, "ENVELOPE SPLITTER") then
            local chain_src = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/LEWLOIWC_ENVELOPE_SETUP.RfxChain"
            AddFX(chain_src)
        end
        DndAddFX_SRC("../Scripts/Sexan_Scripts/ParanormalFX/FXChains/SAIKE_5_SETUP.RfxChain")

        r.ImGui_SeparatorText(ctx, "MID-SIDE")
        if r.ImGui_Selectable(ctx, "MID-SIDE SETUP") then
            local chain_src = "../Scripts/Sexan_Scripts/ParanormalFX/FXChains/MS_SETUP.RfxChain"
            AddFX(chain_src)
        end
        DndAddFX_SRC("../Scripts/Sexan_Scripts/ParanormalFX/FXChains/MS_SETUP.RfxChain")

        r.ImGui_EndMenu(ctx)
    end

    if SHOW_ADD_FX_CONT then
        if DrawAddFxSelectable("CONT", "Container") then
            AddFX("Container")
        end
        DndAddFX_SRC("Container")
    end
    if SHOW_ADD_FX_RECENT and LAST_USED_FX then
        r.ImGui_Separator(ctx)
        if DrawAddFxSelectable("RECENT: " .. DisplayRecentFxName(LAST_USED_FX), LAST_USED_FX) then
            AddFX(LAST_USED_FX)
        end
        DndAddFX_SRC(LAST_USED_FX)
    end
    if IS_DRAGGING_RIGHT_CANVAS then
        r.ImGui_CloseCurrentPopup(ctx)
    end
    if ADD_FX_LONG_PRESS and r.ImGui_IsMouseReleased(ctx, 0) then
        ADD_FX_LONG_PRESS = nil
    end
    if ADD_FX_CLOSE_POPUP then
        r.ImGui_CloseCurrentPopup(ctx)
        ADD_FX_CLOSE_POPUP = nil
    end
end

function CalculateItemWH(tbl)
    r.ImGui_PushFont(ctx, CUSTOM_FONT and SYSTEM_FONT_FACTORY or DEFAULT_FONT_FACTORY)
    local tw, th = r.ImGui_CalcTextSize(ctx, tbl.name)
    r.ImGui_PopFont(ctx)
    local iw, ih = tw + (s_frame_x * 2), th + (s_frame_y * 2)
    return iw, CUSTOM_BTN_H and CUSTOM_BTN_H or ih
end

para_btn_size = CalculateItemWH({ name = "||" })
def_btn_h = CUSTOM_BTN_H and CUSTOM_BTN_H or ({ CalculateItemWH({ name = "||" }) })[2]
mute = para_btn_size
volume = 0
enclose_btn = para_btn_size
peak_btn_size = para_btn_size
collapse_btn_size = para_btn_size
peak_width = 10
name_margin = 35
FIXED_NODE_W = 100
local function Tooltip(str, force)
    return
end

local function MyKnob(label, style, p_value, v_min, v_max, knob_type)
    local radius_outer = Knob_Radius * CANVAS.scale
    local pos = { r.ImGui_GetCursorScreenPos(ctx) }
    local center = { pos[1] + radius_outer, pos[2] + radius_outer }
    local item_inner_spacing = { r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_ItemInnerSpacing()) }
    local mouse_delta = { r.ImGui_GetMouseDelta(ctx) }

    local ANGLE_MIN = 3.141592 * 0.75
    local ANGLE_MAX = 3.141592 * 2.25

    r.ImGui_InvisibleButton(ctx, label, radius_outer * 2, radius_outer * 2)
    local value_changed = false
    local is_active = r.ImGui_IsItemActive(ctx)
    local is_hovered = r.ImGui_IsItemHovered(ctx)
    if IS_DRAGGING_RIGHT_CANVAS then
        is_hovered = false
    end
    if is_active and mouse_delta[2] ~= 0.0 then
        local step = (v_max - v_min) / (CTRL and 1000 or 200.0)
        p_value = p_value + (-mouse_delta[2] * step)
        if p_value < v_min then
            p_value = v_min
        end
        if p_value > v_max then
            p_value = v_max
        end
        value_changed = true
    end

    local mwheel = r.ImGui_GetMouseWheel(ctx)
    if is_hovered and mwheel ~= 0 then
        local step = (v_max - v_min) / (CTRL and 1000 or 200.0)
        p_value = p_value + (mwheel * step)
        if p_value < v_min then
            p_value = v_min
        end
        if p_value > v_max then
            p_value = v_max
        end
        value_changed = true
    end

    local t = (p_value - v_min) / (v_max - v_min)
    local angle = ANGLE_MIN + (ANGLE_MAX - ANGLE_MIN) * t
    local angle_cos, angle_sin = math.cos(angle), math.sin(angle)
    local radius_inner = radius_outer / 2.5
    r.ImGui_DrawList_AddCircleFilled(draw_list, center[1], center[2], radius_outer - 1, COLOR["knob_bg"])
    if style == "knob" then
        local color = is_active and IncreaseDecreaseBrightness(COLOR["ROOT"], 30) or COLOR["ROOT"]
        r.ImGui_DrawList_AddLine(
            draw_list,
            center[1] + angle_cos * radius_inner,
            center[2] + angle_sin * radius_inner,
            center[1] + angle_cos * (radius_outer - 2),
            center[2] + angle_sin * (radius_outer - 2),
            color,
            2.0
        )
        r.ImGui_DrawList_AddCircleFilled(
            draw_list,
            center[1],
            center[2],
            radius_inner,
            PaletteColor(r.ImGui_GetColor(
                ctx,
                is_active and r.ImGui_Col_FrameBgActive() or r.ImGui_Col_FrameBg()
            )),
            16
        )
        r.ImGui_DrawList_AddText(
            draw_list,
            pos[1],
            pos[2] + radius_outer * 2 + item_inner_spacing[2],
            PaletteColor(r.ImGui_GetColor(ctx, r.ImGui_Col_Text())),
            label
        )
    elseif style == "arc" then
        local color = is_active and IncreaseDecreaseBrightness(COLOR["knob_vol"], 30)
            or COLOR["knob_vol"]
        r.ImGui_DrawList_PathArcTo(draw_list, center[1], center[2], radius_outer / 1.5, ANGLE_MIN, angle)
        r.ImGui_DrawList_PathStroke(draw_list, r.ImGui_GetColorEx(ctx, color), nil, radius_inner)
        r.ImGui_DrawList_PathClear(draw_list)
        r.ImGui_DrawList_PathArcTo(draw_list, center[1], center[2], radius_outer / 1.5, ANGLE_MAX, angle)
        r.ImGui_DrawList_PathStroke(draw_list, r.ImGui_GetColorEx(ctx, 0x333333FF), nil, radius_inner)
        r.ImGui_DrawList_PathClear(draw_list)
    elseif style == "dry_wet" then
        local color = is_active and IncreaseDecreaseBrightness(COLOR["knob_drywet"], 30)
            or COLOR["knob_drywet"]
        r.ImGui_DrawList_PathArcTo(draw_list, center[1], center[2], radius_outer / 1.5, ANGLE_MIN, angle)
        r.ImGui_DrawList_PathStroke(draw_list, r.ImGui_GetColorEx(ctx, color), nil, radius_inner)
        r.ImGui_DrawList_PathClear(draw_list)
        r.ImGui_DrawList_PathArcTo(draw_list, center[1], center[2], radius_outer / 1.5, ANGLE_MAX, angle)
        r.ImGui_DrawList_PathStroke(draw_list, r.ImGui_GetColorEx(ctx, 0x333333FF), nil, radius_inner)
        r.ImGui_DrawList_PathClear(draw_list)
    end

    if is_active or is_hovered then
        if not IS_DRAGGING_RIGHT_CANVAS then
            if knob_type == "vol" then
                Tooltip("VOL " .. ("%.0f"):format(p_value))
            elseif knob_type == "pan" then
                Tooltip("PAN " .. ("%.0f"):format(p_value))
            elseif knob_type == "dry_wet" then
                Tooltip(("%.0f"):format(100 - p_value) .. " DRY / WET " .. ("%.0f"):format(p_value))
            elseif knob_type == "ms" then
                Tooltip("MS " .. ("%.0f"):format(p_value))
            elseif knob_type == "sample" then
                Tooltip("SAMPLE " .. ("%.0f"):format(p_value))
            elseif knob_type == "freq" then
                local srate = r.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
                local freq_max = 0.5 * srate
                local norm_freq_min = 20.0 / 22050.0

                local val = freq_max * math.exp((1.0 - p_value) * math.log(norm_freq_min))
                Tooltip("FREQ " .. ("%.0f"):format(val))
            elseif knob_type == "freq3" then
                Tooltip("FREQ " .. ("%.0f"):format(p_value))
            end
        end
    end

    return value_changed, p_value, is_hovered
end

local function HelperWidth(tbl, width)
    --if DRAG_PREVIEW then return width end
    if tbl.type == "Container" then
        return width
    end
    if not tbl.is_helper then
        return width
    end

    if tbl.name == "VOL - PAN" then
        width = width + name_margin * 2
    elseif tbl.name == "POLARITY" then
        width = width + name_margin
    elseif tbl.name == "TIME DELAY" then
        width = width + name_margin * 2
    elseif tbl.name == "SAIKE SPLITTER" then
        local cuts = API.GetParam(TARGET, tbl.FX_ID, 0) -- NUMBER OF CUTS
        width = (width + 80) + (name_margin + 5) * cuts
    elseif tbl.name:find("3-Band Splitter", nil, true) then
        width = width + name_margin * 2
    elseif tbl.name:find("4-Band Splitter", nil, true) then
        width = width + name_margin * 3
    elseif tbl.name:find("5-Band Splitter", nil, true) then
        width = width + name_margin * 4
    elseif tbl.name:find("SNJUK2 LFO", nil, true) then
        width = width + name_margin * 2.5
    end
    return width
end

function CheckCollapse(tbl, w, h)
    local CONT_COL_DATA = GetTRContainerData()
    local guid = tbl.guid == "PREVIEW" and DRAG_PREVIEW.move_guid or tbl.guid
    local is_collapsed = CONT_COL_DATA[guid] and CONT_COL_DATA[guid].collapse
    h = is_collapsed and def_btn_h or h
    w = is_collapsed and FIXED_NODE_W or w
    return is_collapsed, w, h
end

local function ItemFullSize(tbl)
    local _, h = CalculateItemWH(tbl)
    local w = FIXED_NODE_W
    if tbl.type == "ROOT" then
        w = FIXED_NODE_W
    elseif tbl.type == "Container" then
        local is_collapsed, cw, ch = CheckCollapse(tbl, w, h)
        if is_collapsed then
            w, h = cw, ch
        else
            w, h = math.max(tbl.W or FIXED_NODE_W, FIXED_NODE_W), tbl.H
        end
    else
        w = FIXED_NODE_W
    end
    w = HelperWidth(tbl, w)
    return w, h
end

function EncloseAllIntoCont()
    if API.GetCount(TARGET) == 0 then
        return
    end
    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()
    local cont_insert_id = CalculateInsertContainerPosFromBlacklist()
    local cont_id = API.AddByName(TARGET, "Container", MODE == "ITEM" and cont_insert_id or false, cont_insert_id)
    for j = API.GetCount(TARGET), cont_id + 1, -1 do
        local id = 0x2000000 + cont_id + 1 + (API.GetCount(TARGET) + 1)
        API.CopyToTrack(TARGET, j, TARGET, id, true)
    end
    EndUndoBlock("ENCLOSE ALL INTO CONT")
    r.PreventUIRefresh(-1)
end

local function IsFXSoloInParaLane(tbl, i)
    if tbl[i].type == "Container" then
        return
    end
    if tbl[i + 1] and tbl[i + 1].p > 0 or tbl[i].p > 0 and (not tbl[i + 1] or tbl[i + 1].p == 0) then
        return true
    end
end

--! I NEVER WANT TO VISIT THIS FUNCTION EVER AGAIN WHILE IM ALIVE
local function CalcContainerWH(fx_items)
    local rows = {}
    local W, H = 0, 0
    for i = 1, #fx_items do
        if fx_items[i].p == 0 or (i == 1 and fx_items[i].p > 0) then
            rows[#rows + 1] = {}
            table.insert(rows[#rows], i)
        else
            table.insert(rows[#rows], i)
        end
    end

    local btn_total_size = def_btn_h + new_spacing_y
    local start_n_add_btn_size = new_spacing_y + (def_btn_h + ADD_BTN_H)
    local insert_point_size = ADD_BTN_H
    local solo_parallel_fx_add = (ADD_BTN_H + new_spacing_y)

    for i = 1, #rows do
        local col_w, col_h = 0, 0
        if #rows[i] > 1 then
            for j = 1, #rows[i] do
                local w, h = ItemFullSize(fx_items[rows[i][j]])
                w = fx_items[rows[i][j]].W and w
                    or w + (fx_items[rows[i][j]].sc_tracks and peak_btn_size + def_s_spacing_x or 0)
                h = fx_items[rows[i][j]].H and h + new_spacing_y + insert_point_size
                    or (btn_total_size + insert_point_size) + solo_parallel_fx_add

                col_w = col_w + w
                if h > col_h then
                    col_h = h
                end
            end
            col_w = col_w + (def_s_spacing_x * (#rows[i] - 1))
            col_w = col_w + (para_btn_size / 2)
        else
            local w, h = ItemFullSize(fx_items[rows[i][1]])
            w = fx_items[rows[i][1]].W and w + mute + def_s_spacing_x
                or w + (fx_items[rows[i][1]].sc_tracks and peak_btn_size + def_s_spacing_x or 0)
            h = fx_items[rows[i][1]].H and h + new_spacing_y + insert_point_size or (btn_total_size + insert_point_size)

            H = H + h
            if w > col_w then
                col_w = w
            end
        end
        if col_w > W then
            W = col_w
        end
        H = H + col_h
    end
    W = W + (def_s_window_x * 2) + def_s_spacing_x + mute + volume + para_btn_size

    H = H + start_n_add_btn_size
    return W, H
end

--! I NEVER WANT TO VISIT THIS FUNCTION EVER AGAIN WHILE IM ALIVE
local function CalcContainerWH_H(fx_items)
    local rows = {}
    local W, H = 0, 0
    for i = 1, #fx_items do
        if fx_items[i].p == 0 or (i == 1 and fx_items[i].p > 0) then
            rows[#rows + 1] = {}
            table.insert(rows[#rows], i)
        else
            table.insert(rows[#rows], i)
        end
    end

    local btn_total_size = def_btn_h + new_spacing_y
    local start_n_add_btn_size = new_spacing_y + (def_btn_h + ADD_BTN_H)
    local insert_point_size = ADD_BTN_H
    local solo_parallel_fx_add = (ADD_BTN_W + def_s_spacing_x)

    for i = 1, #rows do
        local col_w, col_h = 0, 0
        if #rows[i] > 1 then
            -- PARALLEL (BELOW EACH OTHER)
            for j = 1, #rows[i] do
                local w, h = ItemFullSize(fx_items[rows[i][j]])
                w = fx_items[rows[i][j]].W and w + ADD_BTN_W + def_s_spacing_x * 2
                    or w + def_s_spacing_x * 2 + solo_parallel_fx_add + ADD_BTN_W
                h = fx_items[rows[i][j]].H and h + new_spacing_y or btn_total_size

                col_w = col_w < w and w or col_w
                col_h = col_h + h
            end
            col_h = col_h + (new_spacing_y * (#rows[i] - 1))
        else
            --SERIAL (NEXT TO EACH OTHER)
            local w, h = ItemFullSize(fx_items[rows[i][1]])
            w = w + ADD_BTN_W + def_s_spacing_x * 2

            h = fx_items[rows[i][1]].H and h + new_spacing_y or btn_total_size

            col_w = col_w + w
            col_h = col_h < h and h or col_h
        end
        W = W + col_w
        H = H < col_h and col_h or H
    end
    W = W + def_s_spacing_x + ADD_BTN_W + def_s_spacing_x

    H = H + para_btn_size + (para_btn_size / 2) + (ADD_BTN_H / 2) + (new_spacing_y * 2)
    return W, H
end

function ResetStrippedNames()
    stripped_names = {}
end

local sub = string.sub
local function IterateContainer(depth, track, container_id, parent_fx_count, previous_diff, container_guid)
    local c_ok, container_fx_count = API.GetNamedConfigParm(track, 0x2000000 + container_id, "container_count")
    local row = 1
    local child_fx = {
        [0] = {
            IDX = 1,
            name = "DUMMY",
            type = "INSERT_POINT",
            p = 0,
            guid = "insertpoint_0" .. container_guid,
            pid = container_guid,
            ROW = 0,
        },
    }

    local diff = depth == 0 and parent_fx_count + 1 or (parent_fx_count + 1) * previous_diff

    -- CALCULATER DEFAULT WIDTH
    local _, parrent_cont_name = API.GetFXName(track, 0x2000000 + container_id)
    local total_w, name_h = FIXED_NODE_W, ({ CalculateItemWH({ name = DisplayFxName(parrent_cont_name, "Container") }) })[2]
    -- CALCULATER DEFAULT WIDTH
    if not c_ok then
        return child_fx, total_w, name_h + (def_s_window_y * 2)
    end
    for i = 1, container_fx_count do
        local fx_id = container_id + (diff * i)
        local fx_guid = API.GetFXGUID(track, 0x2000000 + fx_id)
        local _, fx_name = API.GetFXName(track, 0x2000000 + fx_id)
        local _, original_fx_name = API.GetNamedConfigParm(track, 0x2000000 + fx_id, "fx_name")
        local _, fx_type = API.GetNamedConfigParm(track, 0x2000000 + fx_id, "fx_type")
        local _, fx_ident = API.GetNamedConfigParm(track, 0x2000000 + fx_id, "fx_ident")

        local is_helper
        if fx_type ~= "Container" then
            for h = 1, #HELPERS do
                if HELPERS[h].alt_name == fx_ident then
                    fx_name = HELPERS[h].helper or fx_name
                    is_helper = true
                end
                -- if fx_name:find(HELPERS[h].name, nil, true) then
                --     fx_name = HELPERS[h].helper or fx_name
                --     is_helper = true
                -- elseif HELPERS[h].alt_name and fx_name:find(HELPERS[h].alt_name, nil, true) then
                --     fx_name = HELPERS[h].helper or fx_name
                --     is_helper = true
                -- end
            end
        end
        local display_name = DisplayFxName(fx_name, fx_type)

        local _, para = API.GetNamedConfigParm(track, 0x2000000 + fx_id, "parallel")
        local wetparam = API.GetParamFromIdent(track, 0x2000000 + fx_id, ":wet")
        local wet_val = API.GetParam(track, 0x2000000 + fx_id, wetparam)
        local bypass = API.GetEnabled(track, 0x2000000 + fx_id)
        local offline = API.GetOffline(track, 0x2000000 + fx_id)

        --local sc_tracks, sc_channels = GetActiveSideChain(0x2000000 + fx_id)
        para = i == 1 and "0" or para -- MAKE FIRST ITEMS ALWAYS SERIAL (FIRST ITEMS ARE SAME IF IN PARALELL OR SERIAL)

        --local h = pearson8(fx_name)
        --local rr, gg, bb = r.ImGui_ColorConvertHSVtoRGB(h / 0xFF, 1, 1)
        --local color = r.ImGui_ColorConvertDouble4ToU32(rr, gg, bb, 1)
        if i > 1 then
            row = para == "0" and row + 1 or row
        end

        child_fx[#child_fx + 1] = {
            FX_ID = 0x2000000 + fx_id,
            type = fx_type,
            name = display_name,
            IDX = i,
            pid = container_guid,
            guid = fx_guid,
            p = tonumber(para),
            bypass = bypass,
            ROW = row,
            INSERT_POINT = { pid = container_guid },
            wetparam = wetparam,
            wet_val = wet_val,
            offline = offline,
            exclude_ara = FindBlackListedFX(original_fx_name),
            is_helper = is_helper,
            -- PM_active = CheckPMActive(0x2000000 + fx_id),
            auto_color = color,
            sc_tracks = sc_tracks,
            sc_channels = sc_channels,
        }

        if fx_type == "Container" then
            local sub_tbl, sub_W, sub_H = IterateContainer(depth + 1, track, fx_id, container_fx_count, diff, fx_guid)
            if sub_tbl then
                child_fx[#child_fx].sub = sub_tbl
                child_fx[#child_fx].depth = depth + 1
                child_fx[#child_fx].DIFF = diff * (container_fx_count + 1)
                child_fx[#child_fx].ID = fx_id -- CONTAINER ID (HERE ITS NOT THE SAME AS IDX WHICH IS FOR FX ITEMS)
                child_fx[#child_fx].W = sub_W
                child_fx[#child_fx].H = sub_H
            end
        end
    end

    total_w = total_w + (def_s_window_x * 2)

    local C_W, C_H

    if V_LAYOUT then
        C_W, C_H = CalcContainerWH(child_fx)
    else
        C_W, C_H = CalcContainerWH_H(child_fx)
    end
    if C_W > total_w then
        total_w = C_W
    end

    return child_fx, total_w, C_H
end

local function GenerateFXData()
    PLUGINS = {}
    local track = TARGET
    PLUGINS[0] = {
        FX_ID = -1,
        name = "CHAIN",
        type = "ROOT",
        guid = "ROOT",
        pid = "ROOT",
        ID = -1,
        p = 0,
        ROW = 0,
        bypass = r.GetMediaTrackInfo_Value(TRACK, "I_FXEN") == 1,
    }

    local row = 1
    local total_fx_count = API.GetCount(track)
    for i = 1, total_fx_count do
        local fx_guid = API.GetFXGUID(track, i - 1)
        local _, fx_type = API.GetNamedConfigParm(track, i - 1, "fx_type")
        local _, fx_name = API.GetFXName(track, i - 1)
        local _, original_fx_name = API.GetNamedConfigParm(track, i - 1, "fx_name")
        local _, fx_ident = API.GetNamedConfigParm(track, i - 1, "fx_ident")

        local is_helper
        if fx_type ~= "Container" then
            for h = 1, #HELPERS do
                if HELPERS[h].alt_name == fx_ident then
                    fx_name = HELPERS[h].helper or fx_name
                    is_helper = true
                end
                -- if fx_name:find(HELPERS[h].name, nil, true) then
                --     fx_name = HELPERS[h].helper or fx_name
                --     is_helper = true
                -- elseif HELPERS[h].alt_name and fx_name:find(HELPERS[h].alt_name, nil, true) then
                --     fx_name = HELPERS[h].helper or fx_name
                --     is_helper = true
                -- end
            end
        end

        local display_name = DisplayFxName(fx_name, fx_type)

        local _, para = API.GetNamedConfigParm(track, i - 1, "parallel")
        local wetparam = API.GetParamFromIdent(track, i - 1, ":wet")
        local wet_val = API.GetParam(track, i - 1, wetparam)
        local bypass = API.GetEnabled(track, i - 1)
        local offline = API.GetOffline(track, i - 1)

        --local sc_tracks, sc_channels = GetActiveSideChain(i - 1)
        --local h = pearson8(fx_name)
        --local rr, gg, bb = r.ImGui_ColorConvertHSVtoRGB(h / 0xFF, 1, 1)
        --local color = r.ImGui_ColorConvertDouble4ToU32(rr, gg, bb, 1)

        if i > 1 then
            row = para == "0" and row + 1 or row
        end

        para = i == 1 and "0" or para -- MAKE FIRST ITEMS ALWAYS SERIAL (FIRST ITEMS ARE SAME IF IN PARALELL OR SERIAL)

        PLUGINS[#PLUGINS + 1] = {
            FX_ID = i - 1,
            type = fx_type,
            name = display_name,
            IDX = i,
            guid = fx_guid,
            pid = "ROOT",
            p = tonumber(para),
            bypass = bypass,
            ROW = row,
            INSERT_POINT = { pid = "ROOT" },
            wetparam = wetparam,
            wet_val = wet_val,
            offline = offline,
            exclude_ara = FindBlackListedFX(original_fx_name),
            is_helper = is_helper,
            -- PM_active = CheckPMActive(i - 1),
            auto_color = color,
            sc_tracks = sc_tracks,
            sc_channels = sc_channels,
        }

        if fx_type == "Container" then
            local sub_plugins, W, H = IterateContainer(0, track, i, total_fx_count, 0, fx_guid)
            if sub_plugins then
                PLUGINS[#PLUGINS].sub = sub_plugins
                PLUGINS[#PLUGINS].depth = 0
                PLUGINS[#PLUGINS].DIFF = (total_fx_count + 1)
                PLUGINS[#PLUGINS].ID = i -- CONTAINER ID (AT ROOT LEVEL SAME AS IDX BUT FOR READABILITY WILL KEEP IT)
                PLUGINS[#PLUGINS].W = W
                PLUGINS[#PLUGINS].H = H
            end
        end
        -- if TMP then
        --     if TMP.guid == fx_guid then
        --         PLUGINS[#PLUGINS].W = TMP.W
        --         PLUGINS[#PLUGINS].H = TMP.H
        --     end
        -- end
    end
end

function FindNextPrevRow(tbl, i, next, highest)
    local target
    local idx = i + next
    local row = tbl[i].ROW
    local last_in_row = i
    local number_of_parallels = 1
    while not target do
        if not tbl[idx] then
            last_in_row = idx + -next
            target = tbl[idx]
            break
        end
        if row ~= tbl[idx].ROW then
            if highest then
                if tbl[idx].biggest then
                    target = tbl[idx]
                else
                    if tbl[idx].p == 0 then
                        target = tbl[idx]
                        break
                    end
                    idx = idx + next
                end
            else
                target = tbl[idx]
                last_in_row = idx + -next
            end
        else
            idx = idx + next
            number_of_parallels = number_of_parallels + 1
        end
    end
    return target, last_in_row, number_of_parallels
end

local function SoloInLane(parrent, cur_fx_id, cur_tbl, cur_i)
    local _, first = FindNextPrevRow(cur_tbl, cur_i, -1)
    local _, last = FindNextPrevRow(cur_tbl, cur_i, 1)

    for i = first, last do
        local id = CalcFxID(parrent, i)
        API.SetEnabled(TARGET, id, false)
    end
    API.SetEnabled(TARGET, cur_fx_id, true)
end

local ROUND_FLAG = {
    ["L"] = r.ImGui_DrawFlags_RoundCornersTopLeft() | r.ImGui_DrawFlags_RoundCornersBottomLeft(),
    ["R"] = r.ImGui_DrawFlags_RoundCornersTopRight() | r.ImGui_DrawFlags_RoundCornersBottomRight(),
}

local sin = math.sin
local function SineColorBrightness(color, org_col)
    if not ANIMATED_HIGLIGHT then
        return org_col
    end
    local color_over_time = ((sin(r.time_precise() * 4) - 0.5) * 40) // 1
    return IncreaseDecreaseBrightness(color, color_over_time, "no_alpha")
end

function DrawListButton(name, color, hover, icon, round_side, shrink, active, txt_align, guid, right_shrink)
    local function CalculateFontColor(org_color)
        local alpha = org_color & 0xFF
        local blue = (org_color >> 8) & 0xFF
        local green = (org_color >> 16) & 0xFF
        local red = (org_color >> 24) & 0xFF

        local luminance = (0.299 * red + 0.587 * green + 0.114 * blue) / 255
        return luminance > 0.5 and 0x333333FF or 0xFFFFFFFF
    end
    local rect_col = color
    local xs, ys = r.ImGui_GetItemRectMin(ctx)
    local xe, ye = r.ImGui_GetItemRectMax(ctx)
    local w = xe - xs
    local h = ye - ys
    local left_shrink = shrink or 0
    right_shrink = right_shrink == nil and left_shrink or right_shrink
    local draw_xs = xs + left_shrink
    local draw_xe = xe - right_shrink

    local round_flag = round_side and ROUND_FLAG[round_side] or nil
    local round_amt = round_flag and ROUND_CORNER or 0.5

    r.ImGui_DrawList_AddRectFilled(
        draw_list,
        draw_xs,
        ys,
        draw_xe,
        ye,
        r.ImGui_GetColorEx(ctx, rect_col),
        round_amt * CANVAS.scale,
        round_flag
    )
    if icon then
        r.ImGui_PushFont(ctx, ICONS_FONT_SMALL)
    end

    local function FitLabel(label, max_w)
        local label_w = r.ImGui_CalcTextSize(ctx, label)
        if label_w <= max_w then
            return label, label_w
        end
        local suffix = " ..."
        local suffix_w = r.ImGui_CalcTextSize(ctx, suffix)
        local clipped = label
        while #clipped > 0 do
            clipped = clipped:sub(1, -2)
            label_w = r.ImGui_CalcTextSize(ctx, clipped)
            if label_w + suffix_w <= max_w then
                return clipped .. suffix, label_w + suffix_w
            end
        end
        return "", 0
    end

    local label_padding = 6 * CANVAS.scale
    local label_xs = draw_xs + label_padding
    local label_xe = draw_xe - label_padding
    local label_w = math.max(0, label_xe - label_xs)
    local max_label_w = label_w
    local display_name, label_size = FitLabel(name, max_label_w)
    local font_size = (ORG_FONT_SIZE * CANVAS.scale) // 1
    local font_color = CalculateFontColor(color)

    local txt_x = label_xs + (label_w / 2) - (label_size / 2)
    txt_x = txt_align == "L" and label_xs or txt_x
    txt_x = txt_align == "R" and label_xe - label_size or txt_x
    txt_x = txt_align == "LC" and label_xs + (label_w / 2) - (label_size / 2) - (collapse_btn_size / 4) or txt_x

    local line_height = r.ImGui_GetTextLineHeight(ctx)
    local txt_y = ys + (h / 2) - (line_height / 2)

    --    local txt_y = ys + (h / 2) - (font_size / 2)
    r.ImGui_DrawList_AddTextEx(draw_list, nil, font_size, txt_x, txt_y, r.ImGui_GetColorEx(ctx, font_color), display_name)

    if icon then
        r.ImGui_PopFont(ctx)
    end
end

local function SerialButton(tbl, i, x, y)
    r.ImGui_SetCursorScreenPos(ctx, x, y)

    r.ImGui_PushID(ctx, tbl[i].guid .. "insert_point")
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_Alpha(), DRAG_ADD_FX and (DRAG_ADD_FX and not CTRL and 1 or 0.3) or 1)
    if
        r.ImGui_InvisibleButton(ctx, "+", ADD_BTN_W * CANVAS.scale, ADD_BTN_H * CANVAS.scale)
        and not ALT
        and not CTRL
        and not SHIFT
    then
        CLICKED = { guid = tbl[i].guid, lane = "s" }
        INSERT_FX_SERIAL_POS = CalcFxIDFromParrent(tbl, i)
        OPEN_FX_LIST = true
    end
    r.ImGui_PopID(ctx)
    local is_hovered = r.ImGui_IsItemHovered(ctx)
    if not IS_DRAGGING_RIGHT_CANVAS and is_hovered and r.ImGui_IsMouseReleased(ctx, 1) then
        OPEN_INSERT_POINTS_MENU = true
        RC_DATA = {
            type = tbl[i].type,
            tbl = tbl,
            i = i,
            lane = "s",
        }
    end
    DndAddFX_TARGET(tbl, i, nil)
    DndMoveFX_TARGET_SERIAL_PARALLEL(tbl, i, nil, "insert_point_serial")
    if IS_DRAGGING_RIGHT_CANVAS or MARQUEE then
        is_hovered = false
    end
    local is_active = (CLICKED and CLICKED.guid == tbl[i].guid and CLICKED.lane == "s") and true
        or r.ImGui_IsItemActive(ctx)
    is_active = (
        RC_DATA
        and RC_DATA.tbl[RC_DATA.i].guid == tbl[i].guid
        and RC_DATA.lane == "s"
        and not RC_DATA.is_fx_button
    ) or is_active
    local color = is_active and COLOR["n"] or COLOR["parallel"]
    if DND_MOVE_FX or DND_ADD_FX then
        color = SineColorBrightness(COLOR["sine_anim"], color)
    end
    if not tbl[i].no_draw_s then
        DrawListButton("+", color, false, nil, nil, nil, is_active)
        Tooltip("INSERT NEW SERIAL FX")
    end
    r.ImGui_PopStyleVar(ctx)
end

local function ParallelButton(tbl, i, x, y)
    if V_LAYOUT then
        r.ImGui_SameLine(ctx)
    else
        r.ImGui_SetCursorScreenPos(ctx, x, y)
    end
    r.ImGui_PushID(ctx, tbl[i].guid .. "parallel")
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_Alpha(), (DRAG_ADD_FX and (DRAG_ADD_FX and not CTRL and 1 or 0.3)) or 1) -- alpha
    if
        r.ImGui_InvisibleButton(ctx, "||", para_btn_size * CANVAS.scale, def_btn_h * CANVAS.scale)
        and not ALT
        and not CTRL
        and not SHIFT
    then
        CLICKED = { guid = tbl[i].guid, lane = "p" }
        INSERT_FX_PARALLEL_POS = CalcFxIDFromParrent(tbl, i)
        OPEN_FX_LIST = true
    end
    r.ImGui_PopID(ctx)
    local is_hovered = (r.ImGui_IsItemHovered(ctx) and not MARQUEE)
    if not IS_DRAGGING_RIGHT_CANVAS and is_hovered and r.ImGui_IsMouseReleased(ctx, 1) then
        OPEN_INSERT_POINTS_MENU = true
        RC_DATA = {
            type = tbl[i].type,
            tbl = tbl,
            i = i,
            lane = "p",
        }
    end
    DndAddFX_TARGET(tbl, i, "parallel")
    DndMoveFX_TARGET_SERIAL_PARALLEL(tbl, i, tbl[i].guid)
    if IS_DRAGGING_RIGHT_CANVAS then
        is_hovered = false
    end
    local is_active = (CLICKED and CLICKED.guid == tbl[i].guid and CLICKED.lane == "p") and true
        or r.ImGui_IsItemActive(ctx)
    is_active = (
        RC_DATA
        and RC_DATA.tbl[RC_DATA.i].guid == tbl[i].guid
        and RC_DATA.lane == "p"
        and not RC_DATA.is_fx_button
    ) or is_active
    local color = is_active and COLOR["n"] or COLOR["parallel"]
    if DND_MOVE_FX or DND_ADD_FX then
        color = SineColorBrightness(COLOR["sine_anim"], color)
    end
    if not tbl[i].no_draw_p then
        DrawListButton("||", color, false, nil, nil, nil, is_active)
        Tooltip("INSERT NEW PARALLEL FX")
    end
    r.ImGui_PopStyleVar(ctx)
end

local function SerialInsertParaLane(tbl, i, w, h, x, y)
    if IsFXSoloInParaLane(tbl, i) then
        if V_LAYOUT then
            r.ImGui_SetCursorScreenPos(
                ctx,
                x + ((w / 2) - (ADD_BTN_W / 2)) * CANVAS.scale,
                y + (new_spacing_y / 2) * CANVAS.scale
            )
        else
            r.ImGui_SameLine(ctx)
        end
        r.ImGui_PushID(ctx, tbl[i].guid .. "insert_point_para_lane")
        if
            r.ImGui_InvisibleButton(ctx, "+", ADD_BTN_W * CANVAS.scale, ADD_BTN_H * CANVAS.scale)
            and not ALT
            and not CTRL
            and not SHIFT
        then
            CLICKED = { guid = tbl[i].guid, lane = "sc" }
            INSERT_FX_ENCLOSE_POS = { tbl = tbl, i = i }
            OPEN_FX_LIST = true
        end
        r.ImGui_PopID(ctx)
        local is_hovered = (r.ImGui_IsItemHovered(ctx) and not MARQUEE)
        if not IS_DRAGGING_RIGHT_CANVAS and is_hovered and r.ImGui_IsMouseReleased(ctx, 1) then
            OPEN_INSERT_POINTS_MENU = true
            RC_DATA = {
                type = tbl[i].type,
                tbl = tbl,
                i = i,
                lane = "sc",
            }
        end
        DndAddFX_ENCLOSE_TARGET(tbl, i)
        DndMoveFX_ENCLOSE_TARGET(tbl, i)
        if IS_DRAGGING_RIGHT_CANVAS then
            is_hovered = false
        end
        local is_active = (CLICKED and CLICKED.guid == tbl[i].guid and CLICKED.lane == "sc") and CLICKED
            or r.ImGui_IsItemActive(ctx)
        is_active = (
            RC_DATA
            and RC_DATA.tbl[RC_DATA.i].guid == tbl[i].guid
            and RC_DATA.lane == "sc"
            and not RC_DATA.is_fx_button
        ) or is_active

        local color = is_active and COLOR["n"] or COLOR["parallel"]
        if DND_MOVE_FX or DND_ADD_FX then
            color = SineColorBrightness(COLOR["sine_anim"], color)
        end
        if not tbl[i].no_draw_e then
            DrawListButton("H", color, false, true, nil, nil, is_active)
        end
        Tooltip("INSERT NEW SERIAL\nENCLOSE BOTH TO CONT")
        return true
    end
end

local function IsLastParallel(tbl, i)
    if i == 0 then
        return
    end
    if tbl[i].p == 0 then
        if (tbl[i + 1] and tbl[i + 1].p + tbl[i].p == 0) or not tbl[i + 1] then
            return true
        end
    else
        if tbl[i + 1] and tbl[i + 1].p == 0 and tbl[i].p > 0 or not tbl[i + 1] then
            return true
        end
    end
end

local function IsLastSerial(tbl, i)
    if tbl[i + 1] and tbl[i + 1].p == 0 or not tbl[i + 1] then
        return true
    end
end

local function AddLaneSeparatorLineH(A, B, bot)
    if A.FX_ID == B.FX_ID then
        return
    end
    local x1 = A.xs - (def_s_spacing_x + ADD_BTN_W / 2) * CANVAS.scale
    local y1 = A.ys + (A.ye - A.ys) / 2
    local x2 = x1
    local y2 = B.ye - (B.ye - B.ys) / 2
    LINE_POINTS[#LINE_POINTS + 1] = { x1, y1, x2, y2 }

    x1 = bot.x
    y1 = A.ys + (A.ye - A.ys) / 2
    x2 = x1
    y2 = B.ye - (B.ye - B.ys) / 2
    LINE_POINTS[#LINE_POINTS + 1] = { x1, y1, x2, y2 }
end

local function AddLaneSeparatorLine(A, B, bot)
    if A.FX_ID == B.FX_ID then
        return
    end
    local x1 = A.x
    local y1 = bot.ys - (new_spacing_y / 2 + ADD_BTN_H / 2) * CANVAS.scale
    local x2 = B.x
    local y2 = y1
    LINE_POINTS[#LINE_POINTS + 1] = { x1, y1, x2, y2 }

    x1 = A.x
    y1 = A.ys - ((new_spacing_y / 2) + (ADD_BTN_H / 2)) * CANVAS.scale
    x2 = B.x
    y2 = y1
    LINE_POINTS[#LINE_POINTS + 1] = { x1, y1, x2, y2 }
end

local function CreateLinesH(top, cur, bot, tbl, i)
    if top then
        local x1 = cur.xs - (def_s_spacing_x + ADD_BTN_W / 2) * CANVAS.scale
        local y1 = cur.ys + (cur.ye - cur.ys) / 2
        local x2 = cur.xs + (def_s_spacing_x + ADD_BTN_W / 2) * CANVAS.scale
        local y2 = y1
        LINE_POINTS[#LINE_POINTS + 1] = { x1, y1, x2, y2 }
    end
    if bot then
        local x1 = cur.xe
        local y1 = cur.ys + (cur.ye - cur.ys) / 2
        local x2 = bot.x
        local y2 = y1
        LINE_POINTS[#LINE_POINTS + 1] = { x1, y1, x2, y2 }
    end
end

local function CreateLines(top, cur, bot, tbl, i)
    if top then
        local x1 = cur.x
        local y1 = cur.ys - ((new_spacing_y / 2) + (ADD_BTN_H / 2)) * CANVAS.scale
        local x2 = x1
        local y2 = cur.ys
        LINE_POINTS[#LINE_POINTS + 1] = { x1, y1, x2, y2 }
    end
    if bot then
        local x1 = cur.x
        local y1 = IsFXSoloInParaLane(tbl, i) and cur.ys or cur.ye
        local x2 = x1
        local y2 = bot.ys - ((new_spacing_y / 2) + (ADD_BTN_H / 2)) * CANVAS.scale
        LINE_POINTS[#LINE_POINTS + 1] = { x1, y1, x2, y2 }
    end
end

local function GenerateCoordinatesH(tbl, i, last, enclose)
    local xs, ys = r.ImGui_GetItemRectMin(ctx)
    local xe, ye = r.ImGui_GetItemRectMax(ctx)

    if last then
        return { x = xe - (ADD_BTN_W / 2) * CANVAS.scale, ys = ye + (new_spacing_y / 2) * CANVAS.scale, ye = ye }
    end
    if tbl[i].type == "Container" then
        if #tbl[i].sub == 0 and not CheckCollapse(tbl[i], 1, 1) then
            ys = ys + new_spacing_y * CANVAS.scale
        elseif #tbl[i].sub ~= 0 and not CheckCollapse(tbl[i], 1, 1) then
            ys = ys + (new_spacing_y / 2) * CANVAS.scale
        end
    end
    tbl[i].x, tbl[i].xs, tbl[i].xe, tbl[i].ys, tbl[i].ye =
        xs - (def_s_spacing_x + ADD_BTN_W / 2) * CANVAS.scale,
        xs,
        xe - ((enclose and tbl[i].type ~= "Container") and (ADD_BTN_W + def_s_spacing_x) * CANVAS.scale or 0),
        ys,
        ye
end

local function GenerateCoordinates(tbl, i, last)
    local xs, ys = r.ImGui_GetItemRectMin(ctx)
    local xe, ye = r.ImGui_GetItemRectMax(ctx)

    local x = xs + ((xe - xs) / 2)
    if last then
        return { x = x, ys = ye + (new_spacing_y / 2) * CANVAS.scale, ye = ye }
    end
    tbl[i].x, tbl[i].xs, tbl[i].xe, tbl[i].ys, tbl[i].ye = x, xs, xe, ys, ye
end

local function ParallelRowHeight(tbl, i, item_width, item_height)
    local total_w, total_h = item_width, item_height
    local idx = i + 1
    local last_big_idx = not CheckCollapse(tbl[i], 1, 1) and i
    while true do
        if not tbl[idx] then
            break
        end
        if tbl[idx].p == 0 then
            break
        else
            local width, height = ItemFullSize(tbl[idx])
            if total_w <= width and tbl[idx].W then
                total_w = width
                last_big_idx = idx
            end
            total_h = total_h + height + new_spacing_y * 2
            idx = idx + 1
        end
    end
    if last_big_idx then
        tbl[last_big_idx].biggest = true
    end
    return total_h, total_w
end

local function ParallelRowWidth(tbl, i, item_width, item_height)
    local total_w, total_h = item_width, item_height and item_height or 0
    local idx = i + 1
    local last_big_idx = not CheckCollapse(tbl[i], 1, 1) and i
    while true do
        if not tbl[idx] then
            break
        end
        if tbl[idx].p == 0 then
            break
        else
            local width, height = ItemFullSize(tbl[idx])

            if total_h < height then
                total_h = height
                if not CheckCollapse(tbl[idx], 1, 1) then
                    last_big_idx = idx
                end
            end
            total_w = total_w + def_s_spacing_x + width
            idx = idx + 1
        end
    end
    if last_big_idx then
        tbl[last_big_idx].biggest = true
    end
    return total_w - para_btn_size, (last_big_idx and tbl[last_big_idx].H)
end

local function SetItemPos_H(tbl, i, x, y, item_w, item_h, prev_x, prev_y)
    if tbl[i].type == "INSERT_POINT" then
        return prev_x, prev_y, prev_x, prev_y
    end
    local new_x, new_y, largest_w
    -- SERIAL LANE
    if tbl[i].p == 0 then
        local height, max_w = ParallelRowHeight(tbl, i, item_w, item_h)
        if max_w then
            largest_w = max_w
        end
        new_x = prev_x + def_s_spacing_x * CANVAS.scale
        -- Keep the row anchored at the top so expanded containers only grow downward.
        new_y = prev_y

        r.ImGui_SetCursorScreenPos(ctx, new_x, new_y)
    else
        -- PARALLEL LANE
        new_x = prev_x
        new_y = prev_y + new_spacing_y * CANVAS.scale
        r.ImGui_SetCursorScreenPos(ctx, new_x, new_y)
    end
    return new_x, new_y, new_x + (item_w * CANVAS.scale), new_y + (item_h * CANVAS.scale), largest_w
end

local function SetItemPos(tbl, i, x, item_w, item_h, prev_x, prev_y)
    if tbl[i].type == "INSERT_POINT" then
        return prev_x, prev_y, prev_x + item_w * CANVAS.scale, prev_y + item_h * CANVAS.scale
    end
    local new_x, new_y, largest_h
    -- PARALLEL LANE
    if tbl[i].p > 0 then
        --! ANIMATED COLLAPSE
        --r.ImGui_SameLine(ctx,(TMP and tbl[i].pid == TMP.guid)and -FLT_MIN or nil)
        r.ImGui_SameLine(ctx)
        new_x, new_y = r.ImGui_GetCursorScreenPos(ctx)
    else
        --SERIAL
        local width, max_h = ParallelRowWidth(tbl, i, item_w, item_h)
        if max_h then
            largest_h = max_h
        end
        --! ANIMATED COLLAPSE
        -- if TMP then
        --     if tbl[i].pid == TMP.guid then
        --         width = TMP.W
        --         if largest_h then
        --             largest_h = largest_h * (TMP.W / TMP.tbl[TMP.i].W)
        --         end
        --     end
        -- end
        new_x = x - (((width / 2) - (para_btn_size / 2)) * CANVAS.scale)
        new_y = prev_y + new_spacing_y * CANVAS.scale
        r.ImGui_SetCursorScreenPos(ctx, new_x, new_y)
    end
    return new_x, new_y, new_x + item_w * CANVAS.scale, new_y + item_h * CANVAS.scale, largest_h
end

local function TypToColor(tbl)
    local color = COLOR[tbl.type] and COLOR[tbl.type] or COLOR["n"]
    return tbl.bypass and color or COLOR["bypass"]
end

local function ToggleButtonBypass(tbl, i)
    local cur = tbl[i]
    if cur.type == "ROOT" then
        if MODE == "TRACK" then
            r.SetMediaTrackInfo_Value(TARGET, "I_FXEN", cur.bypass and 0 or 1)
        end
        return
    end

    local enabled = not cur.bypass
    if SEL_TBL[cur.guid] and next(SEL_TBL) then
        for _, selected_fx in pairs(SEL_TBL) do
            API.SetEnabled(TARGET, selected_fx.FX_ID, enabled)
        end
    else
        local parrent_container = GetParentContainerByGuid(cur)
        local item_id = CalcFxID(parrent_container, i)
        API.SetEnabled(TARGET, item_id, enabled)
    end
end

local function OpenButtonRename(tbl, i)
    if tbl[i].type == "ROOT" then return end
    RENAME_DATA = { tbl = tbl, i = i }
    OPEN_RENAME = true
end

local function ButtonAction(tbl, i)
    local parrent_container = GetParentContainerByGuid(tbl[i])
    local item_id = CalcFxID(parrent_container, i)
    if ALT then
        if tbl[i].type == "ROOT" then
            RemoveAllFX()
        else
            if not SEL_TBL[tbl[i].guid] then
                r.Undo_BeginBlock()
                r.PreventUIRefresh(1)
                CheckNextItemParallel(i, parrent_container)
                API.Delete(TARGET, item_id)
                r.PreventUIRefresh(-1)
                EndUndoBlock("DELETE FX: " .. tbl[i].name)
            else
                if next(SEL_TBL) then
                    r.Undo_BeginBlock()
                    r.PreventUIRefresh(1)

                    for k in pairs(SEL_TBL) do
                        UpdateFxData()
                        local updated_fx = GetFx(k)
                        local parrent_container_sel = GetParentContainerByGuid(updated_fx)
                        local item_id_sel = CalcFxID(parrent_container_sel, updated_fx.IDX)
                        CheckNextItemParallel(updated_fx.IDX, parrent_container_sel)
                        API.Delete(TARGET, item_id_sel)
                    end
                    r.PreventUIRefresh(-1)

                    EndUndoBlock("DELETE SELECTED FX")
                    SEL_TBL = {}
                end
            end
        end
        ValidateClipboardFX()
    else
        OpenFX(item_id)
    end
end

local function DrawPreviewHideOriginal(guid)
    if (DRAG_PREVIEW and DRAG_PREVIEW.move_guid == guid) and not CTRL_DRAG then
        return false
    else
        return true
    end
end

function Clamp(x, min_x, max_x)
    if x < min_x then
        return min_x
    end
    if x > max_x then
        return max_x
    end
    return x
end

local function DrawHelper(tbl, i, w)
    if not tbl[i].is_helper then
        return
    end
    if not DrawPreviewHideOriginal(tbl[i].guid) then
        return
    end
    local btn_hover, new_width
    if tbl[i].name:find("VOL - PAN", nil, true) then
        local vol_val = API.GetParam(TARGET, tbl[i].FX_ID, 0) -- 0 IS VOL IDENTIFIER
        r.ImGui_SameLine(ctx, -FLT_MIN, (mute * 2) * CANVAS.scale)
        r.ImGui_PushID(ctx, tbl[i].guid .. "helper_vol")
        local rvh_v, v = MyKnob("", "arc", vol_val, -60, 12, "vol")
        if rvh_v then
            API.SetParam(TARGET, tbl[i].FX_ID, 0, v)
        end
        local vol_hover = r.ImGui_IsItemHovered(ctx)
        if not btn_hover then
            btn_hover = vol_hover
        end
        if vol_hover and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
            API.SetParam(TARGET, tbl[i].FX_ID, 0, 0)
        end
        r.ImGui_PopID(ctx)
        r.ImGui_SameLine(ctx, -FLT_MIN, (w - (mute * 3)) * CANVAS.scale)
        local pan_val = API.GetParam(TARGET, tbl[i].FX_ID, 1) -- 1 IS PAN IDENTIFIER
        r.ImGui_PushID(ctx, tbl[i].guid .. "helper_pan")
        local rvh_p, p = MyKnob("", "knob", pan_val, -100, 100, "pan")
        if rvh_p then
            API.SetParam(TARGET, tbl[i].FX_ID, 1, p)
        end
        local pan_hover = r.ImGui_IsItemHovered(ctx)
        if pan_hover and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
            API.SetParam(TARGET, tbl[i].FX_ID, 1, 0)
        end
        if not btn_hover then
            btn_hover = pan_hover
        end
        r.ImGui_PopID(ctx)
        r.ImGui_SetCursorPos(ctx, r.ImGui_GetCursorPosX(ctx), r.ImGui_GetCursorPosY(ctx))
    elseif tbl[i].name:find("POLARITY", nil, true) then
        r.ImGui_SameLine(ctx, -FLT_MIN, (w - (mute * 2) - (mute / 2)) * CANVAS.scale)
        r.ImGui_PushID(ctx, tbl[i].guid .. "helper_phase")
        local phase_val = API.GetParam(TARGET, tbl[i].FX_ID, 0) -- 0 POLARITY NORMAL
        local pos = { r.ImGui_GetCursorScreenPos(ctx) }
        if r.ImGui_InvisibleButton(ctx, "PHASE", mute * CANVAS.scale, mute * CANVAS.scale) then
            API.SetParam(TARGET, tbl[i].FX_ID, 0, phase_val == 0 and 3 or 0)
        end
        Tooltip(phase_val == 0 and "NORMAL" or "INVERTED")
        local phase_hover = r.ImGui_IsItemHovered(ctx)
        local center = { pos[1] + Knob_Radius * CANVAS.scale, pos[2] + Knob_Radius * CANVAS.scale }
        r.ImGui_DrawList_AddCircleFilled(
            draw_list,
            center[1],
            center[2],
            (Knob_Radius - 2) * CANVAS.scale,
            COLOR["knob_bg"]
        )
        local phase_icon = phase_val == 0 and '"' or "Q"
        DrawListButton(phase_icon, 0, nil, true)
        r.ImGui_PopID(ctx)
        if not btn_hover then
            btn_hover = phase_hover
        end
    elseif tbl[i].name:find("TIME", nil, true) then
        local vol_val = API.GetParam(TARGET, tbl[i].FX_ID, 0) -- 0 POLARITY NORMAL
        r.ImGui_SameLine(ctx, -FLT_MIN, (mute * 2) * CANVAS.scale)
        r.ImGui_PushID(ctx, tbl[i].guid .. "helper_time")
        local rvh_v, v = MyKnob("", "arc", vol_val, -1000, 1000, "ms")
        if rvh_v then
            API.SetParam(TARGET, tbl[i].FX_ID, 0, v)
        end
        local vol_hover = r.ImGui_IsItemHovered(ctx)
        if vol_hover and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
            API.SetParam(TARGET, tbl[i].FX_ID, 0, 0)
        end
        if not btn_hover then
            btn_hover = vol_hover
        end
        r.ImGui_PopID(ctx)
        r.ImGui_SameLine(ctx, -FLT_MIN, (w - (mute * 3)) * CANVAS.scale)
        local pan_val = API.GetParam(TARGET, tbl[i].FX_ID, 3) -- 3 IS POLARITY INVERT
        r.ImGui_PushID(ctx, tbl[i].guid .. "helper_time2")
        local rvh_p, p = MyKnob("", "knob", pan_val, -40000, 40000, "sample")
        if rvh_p then
            API.SetParam(TARGET, tbl[i].FX_ID, 3, p) -- 3 IS POLARITY INVERT
        end
        local pan_hover = r.ImGui_IsItemHovered(ctx)
        if pan_hover and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
            API.SetParam(TARGET, tbl[i].FX_ID, 3, 0)
        end
        if not btn_hover then
            btn_hover = pan_hover
        end
        r.ImGui_PopID(ctx)
    elseif tbl[i].name:find("SAIKE SPLITTER", nil, true) then
        new_width = true
        local cuts = API.GetParam(TARGET, tbl[i].FX_ID, 0) -- NUMBER OF CUTS
        for c = 1, cuts do
            r.ImGui_SameLine(ctx, 0, (mute / 3) * CANVAS.scale)

            r.ImGui_PushID(ctx, tbl[i].guid .. "saike" .. c)
            local cf, minf, maxf = API.GetParam(TARGET, tbl[i].FX_ID, c) -- SLIDERS
            local prev_v, next_v

            prev_v = c > 1 and API.GetParam(TARGET, tbl[i].FX_ID, c - 1) or 0
            next_v = c < cuts and API.GetParam(TARGET, tbl[i].FX_ID, c + 1) or 1

            local val = Clamp(cf, prev_v, next_v)

            local rvc, freq = MyKnob("", "knob", val, minf, maxf, "freq")
            if rvc then
                API.SetParam(TARGET, tbl[i].FX_ID, c, freq)
            end
            r.ImGui_PopID(ctx)
            if not btn_hover then
                btn_hover = r.ImGui_IsItemHovered(ctx)
            end
        end
        r.ImGui_SameLine(ctx, 0, (mute / 3) * CANVAS.scale)
        local fir_val = API.GetParam(TARGET, tbl[i].FX_ID, 13) -- NUMBER OF FIR
        r.ImGui_PushID(ctx, tbl[i].guid .. "saike" .. "FIR_IIR")
        if
            r.ImGui_InvisibleButton(
                ctx,
                fir_val == 1 and "FIR" or "IIR",
                (mute + 10) * CANVAS.scale,
                mute * CANVAS.scale
            )
        then
            API.SetParam(TARGET, tbl[i].FX_ID, 13, fir_val == 1 and 0 or 1)
        end
        r.ImGui_PopID(ctx)

        local fir_hover = r.ImGui_IsItemHovered(ctx)
        if not btn_hover then
            btn_hover = fir_hover
        end
        DrawListButton(fir_val == 1 and "FIR" or "IIR", 0x99CCCCFF, false)
        Tooltip(fir_val == 1 and "LINEAR PHASE" or "NON LINEAR PHASE")

        r.ImGui_SameLine(ctx, 0, (mute / 3) * CANVAS.scale)

        local pole_val = API.GetParam(TARGET, tbl[i].FX_ID, 15) -- NUMBER OF FIR
        local pol_name = pole_val == 1 and "12dB" or "24dB"
        r.ImGui_PushID(ctx, tbl[i].guid .. "saike" .. "12_24")
        if r.ImGui_InvisibleButton(ctx, pol_name, (mute + 15) * CANVAS.scale, mute * CANVAS.scale) then
            API.SetParam(TARGET, tbl[i].FX_ID, 15, pole_val == 1 and 0 or 1)
        end
        r.ImGui_PopID(ctx)

        local pol_hover = r.ImGui_IsItemHovered(ctx)
        if not btn_hover then
            btn_hover = pol_hover
        end
        DrawListButton(pol_name, 0x99CCCCFF, false)
    elseif tbl[i].name:find("3-Band Splitter", nil, true) then
        new_width = true
        for c = 1, 2 do
            r.ImGui_SameLine(ctx, 0, (mute / 3) * CANVAS.scale)

            r.ImGui_PushID(ctx, tbl[i].guid .. "3band_splitter" .. c)
            local cf, minf, maxf = API.GetParam(TARGET, tbl[i].FX_ID, c - 1) -- SLIDERS

            local rvc, freq = MyKnob("", "knob", cf, minf, maxf, "freq3")
            if rvc then
                API.SetParam(TARGET, tbl[i].FX_ID, c - 1, freq)
            end
            r.ImGui_PopID(ctx)
            if not btn_hover then
                btn_hover = r.ImGui_IsItemHovered(ctx)
            end
        end
        if not btn_hover then
            btn_hover = r.ImGui_IsItemHovered(ctx)
        end
    elseif tbl[i].name:find("4-Band Splitter", nil, true) then
        new_width = true
        for c = 1, 3 do
            r.ImGui_SameLine(ctx, 0, (mute / 3) * CANVAS.scale)

            r.ImGui_PushID(ctx, tbl[i].guid .. "3band_splitter" .. c)
            local cf, minf, maxf = API.GetParam(TARGET, tbl[i].FX_ID, c - 1) -- SLIDERS

            local rvc, freq = MyKnob("", "knob", cf, minf, maxf, "freq3")
            if rvc then
                API.SetParam(TARGET, tbl[i].FX_ID, c - 1, freq)
            end
            r.ImGui_PopID(ctx)
            if not btn_hover then
                btn_hover = r.ImGui_IsItemHovered(ctx)
            end
        end
        if not btn_hover then
            btn_hover = r.ImGui_IsItemHovered(ctx)
        end
    elseif tbl[i].name:find("5-Band Splitter", nil, true) then
        new_width = true
        for c = 1, 4 do
            r.ImGui_SameLine(ctx, 0, (mute / 3) * CANVAS.scale)

            r.ImGui_PushID(ctx, tbl[i].guid .. "3band_splitter" .. c)
            local cf, minf, maxf = API.GetParam(TARGET, tbl[i].FX_ID, c - 1) -- SLIDERS

            local rvc, freq = MyKnob("", "knob", cf, minf, maxf, "freq3")
            if rvc then
                API.SetParam(TARGET, tbl[i].FX_ID, c - 1, freq)
            end
            r.ImGui_PopID(ctx)
            if not btn_hover then
                btn_hover = r.ImGui_IsItemHovered(ctx)
            end
        end
        if not btn_hover then
            btn_hover = r.ImGui_IsItemHovered(ctx)
        end
    elseif tbl[i].name:find("SNJUK2 LFO", nil, true) then
        new_width = true
        local xx, yy = r.ImGui_GetCursorScreenPos(ctx)
        local x = API.GetParam(TARGET, tbl[i].FX_ID, 27) -- x
        local y = API.GetParam(TARGET, tbl[i].FX_ID, 23) -- y
        local lfo_shape = API.GetParam(TARGET, tbl[i].FX_ID, 2) -- shape
        xx = xx + (mute * 2) * CANVAS.scale
        r.ImGui_DrawList_AddCircleFilled(
            draw_list,
            xx + (x * (w / 6)) * CANVAS.scale,
            yy + (def_btn_h / 2) * CANVAS.scale + (-y * (def_btn_h / 3)) * CANVAS.scale,
            4 * CANVAS.scale,
            0xFF9999FF
        )
        local aw = w / 6

        local points2, y_pos = GetWaveType(tonumber(lfo_shape), 1, xx, yy, aw, (21 - 2), "invert")
        if y_pos then
            if tonumber(lfo_shape) ~= 0 then
                for j = 1, #points2 do
                    r.ImGui_DrawList_AddLine(
                        draw_list,
                        xx + points2[j][1],
                        yy + points2[j][2],
                        xx + points2[j][3],
                        yy + points2[j][4],
                        0xFFFFFFFF
                    )
                end
            else
                r.ImGui_DrawList_AddPolyline(draw_list, points2, 0xFFFFFFFF, 0, 1)
            end
        end
        r.ImGui_SameLine(ctx, 0, 50 * CANVAS.scale)
        r.ImGui_PushID(ctx, tbl[i].guid .. "LINK")
        if r.ImGui_Button(ctx, "LINK", 0, def_btn_h * CANVAS.scale) and (tbl[i].FX_ID ~= LASTTOUCH_FX_ID) then
            local src_param = 23 -- LFO MODULATOR
            local src_fx_id, buf = MapToParents(TARGET, tbl[i].FX_ID, src_param)
            if buf then
                -- LFO IN CONTAINER
                LinkLastTouched(TARGET, src_fx_id, buf)
            else
                -- LFO OUTSIDE CONTAINER
                local cur_fx_id_target, buf_target = MapToParents(TARGET, LASTTOUCH_FX_ID, LASTTOUCH_P_ID)
                if buf_target then
                    -- FX IN CONTAINER
                    API.SetNamedConfigParm(TARGET, cur_fx_id_target, "param." .. buf_target .. ".plink.active", 1)
                    API.SetNamedConfigParm(
                        TARGET,
                        cur_fx_id_target,
                        "param." .. buf_target .. ".plink.effect",
                        tbl[i].FX_ID
                    )
                    API.SetNamedConfigParm(
                        TARGET,
                        cur_fx_id_target,
                        "param." .. buf_target .. ".plink.param",
                        src_param
                    )
                else
                    API.SetNamedConfigParm(TARGET, LASTTOUCH_FX_ID, "param." .. LASTTOUCH_P_ID .. ".plink.active", 1)
                    API.SetNamedConfigParm(
                        TARGET,
                        LASTTOUCH_FX_ID,
                        "param." .. LASTTOUCH_P_ID .. ".plink.effect",
                        tbl[i].FX_ID
                    )
                    API.SetNamedConfigParm(
                        TARGET,
                        LASTTOUCH_FX_ID,
                        "param." .. LASTTOUCH_P_ID .. ".plink.param",
                        src_param
                    )
                end
            end
        end
        r.ImGui_PopID(ctx)
        if not btn_hover then
            btn_hover = r.ImGui_IsItemHovered(ctx)
        end
    end
    return btn_hover, new_width
end

function generateWave(w, h, shape)
    local samples = {}

    for i = 1, w do
        local t = i / w
        local sample
        if shape == 0 then
            sample = Sine(t, h, 1)
        elseif shape == 1 then
            sample = -Square(t, h, 1)
        elseif shape == 2 then
            sample = SawtL(t, h, 1)
        elseif shape == 3 then
            sample = SawtR(t, h, 1)
        elseif shape == 4 then
            sample = -Triangle(t, h, 1)
        elseif shape == 5 then
            sample = Square(t, h, 1)
        end
        --Sine(t, def_btn_h/3, 1)
        table.insert(samples, sample)
    end

    return samples
end

function SetCollapseData(dollapse_tbl, tbl, i)
    if dollapse_tbl[tbl[i].guid] then
        if #tbl[i].sub ~= 0 then
            dollapse_tbl[tbl[i].guid].collapse = not dollapse_tbl[tbl[i].guid].collapse
        end
    end
end

local function DrawButton(tbl, i, name, width, fade, parrent_color, cx, cy)
    local is_cut = (CLIPBOARD and CLIPBOARD.cut and CLIPBOARD.guid == tbl[i].guid)
    local expanded_container = tbl[i].type == "Container" and not CheckCollapse(tbl[i], 1, 1)
    local button_width = (tbl[i].is_helper or expanded_container) and width or FIXED_NODE_W
    local SPLITTER = r.ImGui_CreateDrawListSplitter(draw_list)
    r.ImGui_DrawListSplitter_Split(SPLITTER, 2)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_Alpha(), fade)
    r.ImGui_DrawListSplitter_SetCurrentChannel(SPLITTER, 1)
    local color = tbl[i].bypass and COLOR["enabled"] or COLOR["bypass"]
    color = tbl[i].offline and COLOR["offline"] or color
    color = is_cut and IncreaseDecreaseBrightness(color, -40) or color
    local bypass_hover = false
    local pm_hover = false

    -------------------
    local hlp_vol_hover, is_saike = DrawHelper(tbl, i, width)
    ------------------
    local vol_or_enclose_hover
    local collapse_hover
    if tbl[i].type ~= "ROOT" then
        --! COLLAPSE
        -- PEAK_INTO_TOOLTIP = nil
        if tbl[i].type == "Container" then
            --! SHOW COLLAPSE ONLY IF THERE ARE CHILDS INSIDE
            if #tbl[i].sub ~= 0 then
                -- r.ImGui_SameLine(ctx, 0, width - volume - (mute * 2) - def_s_window_x)
                r.ImGui_SetCursorScreenPos(ctx, cx + (button_width - mute) * CANVAS.scale, cy)
                r.ImGui_PushID(ctx, tbl[i].guid .. "COLAPSE")
                local TR_CONT = GetTRContainerData()
                if r.ImGui_InvisibleButton(ctx, "C", mute * CANVAS.scale, def_btn_h * CANVAS.scale) then
                    --! ANIMATED COLLAPSE
                    SetCollapseData(TR_CONT, tbl, i)
                    --TMP = {tbl = tbl, i = i, guid = tbl[i].guid, W = tbl[i].W, H = tbl[i].H}
                    --FLUX.to(TMP, 0.5, { W = 175, H = 20 }):ease("cubicout"):oncomplete(test)
                end
                local collapse_state = (TR_CONT[tbl[i].guid] and TR_CONT[tbl[i].guid].collapse) and true or false
                local icon = collapse_state and "@" or "?"
                collapse_hover = (r.ImGui_IsItemHovered(ctx) and not MARQUEE)
                PEAK_INTO_TOOLTIP = collapse_hover and true or PEAK_INTO_TOOLTIP
                Tooltip(collapse_state and "EXPAND CONT" or "COLLAPSE CONT")
                --! PEAK INSIDE CONTAINER TOOLTIP
                --if not PEAK_INTO_TOOLTIP then
                --    PEAK_INTO_TOOLTIP = (collapse_state and collapse_hover) and true
                --end
                if SHOW_C_CONTENT_TOOLTIP and not PREVIEW_TOOLTIP then
                    if collapse_state and collapse_hover then
                        PREVIEW_TOOLTIP = tbl
                        PREVIEW_TOOLTIP.i = i
                        PREVIEW_TOOLTIP.start = r.time_precise()
                    end
                end
                DrawListButton(icon, color, collapse_hover, true, "R")
                r.ImGui_PopID(ctx)
            end
        end
    end
    r.ImGui_SetCursorScreenPos(ctx, cx, cy)
    --r.ImGui_SameLine(ctx, nil,-width  )
    --! PLUGIN BUTTON
    r.ImGui_DrawListSplitter_SetCurrentChannel(SPLITTER, 0)
    --r.ImGui_SameLine(ctx, -FLT_MIN, tbl[i].type == "Container" and s_window_x or 0)
    r.ImGui_PushID(ctx, tbl[i].guid .. "button")
    --if r.ImGui_InvisibleButton(ctx, name, tbl[i].type == "Container" and width * CANVAS.scale or width * CANVAS.scale, def_btn_h * CANVAS.scale) then
    if r.ImGui_InvisibleButton(ctx, name, button_width * CANVAS.scale, def_btn_h * CANVAS.scale) then
        if CTRL_KEY then
            ToggleButtonBypass(tbl, i)
        elseif SHIFT then
            OpenButtonRename(tbl, i)
        else
            ButtonAction(tbl, i)
        end
    end
    CheckOverlap(tbl[i], i)
    --local mrq_selected = tbl[i].type ~= "ROOT" and CheckOverlap(tbl[i])
    --local mrq_selected = SEL_TBL[tbl[i].guid]
    r.ImGui_PopID(ctx)
    local btn_hover = (r.ImGui_IsItemHovered(ctx) and not MARQUEE)
    local is_active = r.ImGui_IsItemActive(ctx)
    is_active = (RC_DATA and RC_DATA.tbl[RC_DATA.i].guid == tbl[i].guid and RC_DATA.is_fx_button) or is_active
    is_active = (REPLACE_FX_POS and REPLACE_FX_POS.tbl[REPLACE_FX_POS.i].guid == tbl[i].guid) or is_active
    --is_active = mrq_selected or is_active

    --! SHORTCUT COLLAPSE
    if
        btn_hover
        and not bypass_hover
        and not vol_or_enclose_hover
        and not hlp_vol_hover
        and not collapse_hover
        and not pm_hover
    then
        if C then
            local TR_CONT = GetTRContainerData()
            SetCollapseData(TR_CONT, tbl, i)
        end
    end
    -----------------------
    DndMoveFX_SRC(tbl, i)
    DndMoveFX_TARGET_SWAP(tbl, i)
    if CTRL_DRAG_AUTOCONTAINER and CTRL_DRAG then
        DndMoveFX_ENCLOSE_TARGET(tbl, i)
    end
    if DEFAULT_DND then
        DndAddReplaceFX_TARGET(tbl, i, tbl[i].p > 0)
    else
        DndAddFX_ENCLOSE_TARGET(tbl, i)
    end
    ---------------------
    if
        (
            btn_hover
            and not bypass_hover
            and not vol_or_enclose_hover
            and not hlp_vol_hover
            and not collapse_hover
            and not pm_hover
        )
        and not IS_DRAGGING_RIGHT_CANVAS
        and r.ImGui_IsMouseReleased(ctx, 1)
    then --r.ImGui_IsItemClicked(ctx, 1) then
        OPEN_RIGHT_CLICK_MENU = true
        RC_DATA = {
            type = tbl[i].type,
            tbl = tbl,
            i = i,
            is_fx_button = true,
            is_helper = tbl[i].is_helper,
            para_info = tbl[i].p,
        }
    end
    -----------------------

    color = parrent_color and parrent_color
        or (ALT and btn_hover and not bypass_hover and not vol_or_enclose_hover and not collapse_hover and not pm_hover) and COLOR["del"]
        or TypToColor(tbl[i])

    color = tbl[i].offline and COLOR["offline"] or color
    color = is_cut and IncreaseDecreaseBrightness(color, -40) or color

    if DrawPreviewHideOriginal(tbl[i].guid) then
        local txt_align = is_saike and "R"
        --txt_align = tbl[i].type == "Container" and "LC" or txt_align
        local right_shrink = (tbl[i].type == "Container" and tbl[i].sub and #tbl[i].sub ~= 0) and mute * CANVAS.scale or 0
        DrawListButton(
            name,
            color,
            false,
            nil,
            tbl[i].type ~= "ROOT" and "R",
            0,
            is_active,
            txt_align,
            tbl[i].guid,
            right_shrink
        )
    end
    if
        ALT
        and (
            btn_hover
            and not bypass_hover
            and not vol_or_enclose_hover
            and not hlp_vol_hover
            and not collapse_hover
            and not pm_hover
        )
    then
        Tooltip(
            "DELETE "
                .. (
                    tbl[i].type == "Container" and "CONT WITH CONTENT"
                    or tbl[i].type == "ROOT" and "CHAIN"
                    or "FX"
                )
        )
    end

    r.ImGui_PopStyleVar(ctx)
    r.ImGui_DrawListSplitter_Merge(SPLITTER)
    return (btn_hover and not bypass_hover and not vol_or_enclose_hover and not collapse_hover and not pm_hover)
end

local function DrawPluginsH(x, y, tbl, fade, parrent_pass_color)
    local last
    local prev_xs, prev_ys = x, y
    local prev_xe, prev_ye
    local large
    local enclosed
    local largest_xe
    for i = 0, #tbl do
        local width, height = ItemFullSize(tbl[i])
        local new_xs, new_ys, new_xe, new_ye, lw = SetItemPos_H(tbl, i, x, y, width, height, prev_xs, prev_ys)

        prev_xs = new_xs and new_xs or prev_xs
        prev_ys = new_ys and new_ys or prev_ys
        prev_xe = new_xe and new_xe or prev_xe
        prev_ye = new_ye and new_ye or prev_ye

        if lw then
            large = lw
        end

        if tbl[i].type ~= "Container" and tbl[i].type ~= "INSERT_POINT" then
            r.ImGui_BeginGroup(ctx)
            local button_hovered = DrawButton(tbl, i, tbl[i].name, width, fade, parrent_pass_color, prev_xs, prev_ys)
            parrent_pass_color = (tbl[i].type == "ROOT" and button_hovered and ALT) and COLOR["bypass"]
                or parrent_pass_color
            enclosed = SerialInsertParaLane(tbl, i, width, height)
            if enclosed then
                local next_xe = prev_xe + (ADD_BTN_W + def_s_spacing_x) * CANVAS.scale
                if not largest_xe then
                    largest_xe = next_xe
                else
                    if largest_xe < next_xe then
                        largest_xe = next_xe
                    end
                end
            end
            r.ImGui_EndGroup(ctx)
        end
        if tbl[i].type == "ROOT" then
            local xs, ys = r.ImGui_GetItemRectMin(ctx)
            local xe, ye = r.ImGui_GetItemRectMax(ctx)
            OFF_SCREEN = r.ImGui_IsRectVisibleEx(ctx, xs, ys, xe, ye)
        end
        if tbl[i].type == "Container" then
            --! USED FOR ANIMATED COLLAPSE
            --r.ImGui_PushClipRect( ctx, prev_xs, prev_ys, prev_xs + (width * CANVAS.scale),prev_ys + (height * CANVAS.scale) ,true)
            r.ImGui_BeginGroup(ctx)
            r.ImGui_PushID(ctx, tbl[i].guid .. "container")
            local is_collapsed = CheckCollapse(tbl[i], 1, 1)
            --! MAKE FIRST  INSERT POINT DISABLED
            if tbl[i].offline then
                tbl[i].sub[0].no_draw_s = true
            end
            if DrawPreviewHideOriginal(tbl[i].guid) then
                local button_hovered =
                    DrawButton(tbl, i, tbl[i].name, width, fade, parrent_pass_color, prev_xs, prev_ys)
                local del_color = parrent_pass_color and parrent_pass_color
                    or button_hovered and ALT and COLOR["bypass"]
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_Alpha(), not tbl[i].bypass and 0.5 or fade)
                local fade_alpha = not tbl[i].bypass and 0.5 or fade
                if not is_collapsed then
                    local content_y = prev_ys + (def_btn_h + new_spacing_y) * CANVAS.scale
                    DrawPluginsH(prev_xs, content_y, tbl[i].sub, fade_alpha, del_color)
                end
                r.ImGui_PopStyleVar(ctx)
            else
                r.ImGui_Dummy(ctx, width * CANVAS.scale, height * CANVAS.scale)
            end
            r.ImGui_DrawList_AddRect(
                draw_list,
                prev_xs,
                prev_ys,
                prev_xs + (width * CANVAS.scale),
                prev_ys + (height * CANVAS.scale),
                0xCCCCCCFF,
                ROUND_CORNER * CANVAS.scale,
                nil,
                1 * CANVAS.scale
            )
            r.ImGui_EndGroup(ctx)
            r.ImGui_PopID(ctx)
            --r.ImGui_PopClipRect( ctx)
        end
        prev_ys = prev_ye + new_spacing_y * CANVAS.scale
        GenerateCoordinatesH(tbl, i, nil, enclosed)
        enclosed = nil
        if IsLastParallel(tbl, i) then
            --! CENTER PARALLEL BUTTON
            --ParallelButton(tbl, i, prev_xs + (width / 2 - para_btn_size / 2) * CANVAS.scale, prev_ye + (new_spacing_y) * CANVAS.scale)
            ParallelButton(tbl, i, prev_xs, prev_ye + new_spacing_y * CANVAS.scale)
            prev_ys = prev_ye + (para_btn_size + new_spacing_y) * CANVAS.scale
        end
        if IsLastSerial(tbl, i) then
            local serial_x = largest_xe or prev_xe
            serial_x = (large and prev_xs + (large * CANVAS.scale) > serial_x) and prev_xs + (large * CANVAS.scale)
                or serial_x

            SerialButton(tbl, i, serial_x + def_s_spacing_x * CANVAS.scale, y)
            prev_xs = serial_x + (ADD_BTN_W + def_s_spacing_x) * CANVAS.scale
            prev_ys = y

            largest_xe = nil
            large = nil
        end
        last = GenerateCoordinatesH(tbl, i, "last")
    end

    local last_row, first_in_row
    for i = 0, #tbl do
        if last_row ~= tbl[i].ROW then
            first_in_row = tbl[i]
            last_row = tbl[i].ROW
        end
        local top = FindNextPrevRow(tbl, i, -1, "HIGHEST")
        local cur = tbl[i]
        local bot = FindNextPrevRow(tbl, i, 1) or last
        CreateLinesH(top, cur, bot, tbl, i)

        if tbl[i + 1] and tbl[i + 1].ROW ~= last_row or not tbl[i + 1] then
            local last_in_row = tbl[i]
            AddLaneSeparatorLineH(first_in_row, last_in_row, bot)
            first_in_row = nil
        end
    end
end

local function DrawPlugins(x, y, tbl, fade, parrent_pass_color)
    local last
    local prev_xs, prev_ys = x, y
    local prev_xe, prev_ye
    local large
    local enclosed
    for i = 0, #tbl do
        local width, height = ItemFullSize(tbl[i])
        local new_xs, new_ys, new_xe, new_ye, lh = SetItemPos(tbl, i, x, width, height, prev_xs, prev_ys)

        prev_xs = new_xs and new_xs or prev_xs
        prev_ys = new_ys and new_ys or prev_ys
        prev_xe = new_xe and new_xe or prev_xe
        prev_ye = new_ye and new_ye or prev_ye
        if lh then
            large = lh
        end
        if tbl[i].type ~= "Container" and tbl[i].type ~= "INSERT_POINT" then
            r.ImGui_BeginGroup(ctx)
            local button_hovered = DrawButton(tbl, i, tbl[i].name, width, fade, parrent_pass_color, prev_xs, prev_ys)
            parrent_pass_color = (tbl[i].type == "ROOT" and button_hovered and ALT) and COLOR["bypass"]
                or parrent_pass_color
            enclosed = SerialInsertParaLane(tbl, i, width, height, prev_xs, prev_ye)
            r.ImGui_EndGroup(ctx)
        end
        if tbl[i].type == "ROOT" then
            local xs, ys = r.ImGui_GetItemRectMin(ctx)
            local xe, ye = r.ImGui_GetItemRectMax(ctx)
            OFF_SCREEN = r.ImGui_IsRectVisibleEx(ctx, xs, ys, xe, ye)
        end
        if tbl[i].type == "Container" then
            --! USED FOR ANIMATED COLLAPSE
            --r.ImGui_PushClipRect( ctx, prev_xs, prev_ys, prev_xs + (width * CANVAS.scale),prev_ys + (height * CANVAS.scale) ,true)
            r.ImGui_BeginGroup(ctx)
            r.ImGui_PushID(ctx, tbl[i].guid .. "container")
            local is_collapsed = CheckCollapse(tbl[i], 1, 1)
            --! MAKE FIRST  INSERT POINT DISABLED
            if tbl[i].offline then
                tbl[i].sub[0].no_draw_s = true
            end
            if DrawPreviewHideOriginal(tbl[i].guid) then
                local button_hovered =
                    DrawButton(tbl, i, tbl[i].name, width, fade, parrent_pass_color, prev_xs, prev_ys)
                local del_color = parrent_pass_color and parrent_pass_color
                    or button_hovered and ALT and COLOR["bypass"]
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_Alpha(), not tbl[i].bypass and 0.5 or fade)
                local fade_alpha = not tbl[i].bypass and 0.5 or fade
                if not is_collapsed then
                    DrawPlugins(
                        prev_xs + (width / 2 - para_btn_size) * CANVAS.scale,
                        prev_ys,
                        tbl[i].sub,
                        fade_alpha,
                        del_color
                    )
                end
                r.ImGui_PopStyleVar(ctx)
            else
                r.ImGui_Dummy(ctx, width * CANVAS.scale, height * CANVAS.scale)
            end
            r.ImGui_DrawList_AddRect(
                draw_list,
                prev_xs,
                prev_ys,
                prev_xs + (width * CANVAS.scale),
                prev_ys + (height * CANVAS.scale),
                0xCCCCCCFF,
                ROUND_CORNER * CANVAS.scale,
                nil,
                1 * CANVAS.scale
            )
            r.ImGui_EndGroup(ctx)
            r.ImGui_PopID(ctx)
            --r.ImGui_PopClipRect( ctx)
        end
        GenerateCoordinates(tbl, i)
        if IsLastParallel(tbl, i) then
            ParallelButton(tbl, i)
        end

        if IsLastSerial(tbl, i) then
            if large then
                prev_ye = prev_ys + large * CANVAS.scale
                large = nil
            elseif enclosed then
                prev_ys = prev_ye
                prev_ye = prev_ys + (ADD_BTN_H + new_spacing_y) * CANVAS.scale
            end
            SerialButton(
                tbl,
                i,
                x + (22 * CANVAS.scale) - (ADD_BTN_W / 2 * CANVAS.scale),
                prev_ye + (new_spacing_y / 2) * CANVAS.scale
            )
            prev_ys = prev_ye + ADD_BTN_H * CANVAS.scale
        end
        last = GenerateCoordinates(tbl, i, "last")
    end

    local last_row, first_in_row
    for i = 0, #tbl do
        if last_row ~= tbl[i].ROW then
            first_in_row = tbl[i]
            last_row = tbl[i].ROW
        end
        local top = FindNextPrevRow(tbl, i, -1, "HIGHEST")
        local cur = tbl[i]
        local bot = FindNextPrevRow(tbl, i, 1) or last
        CreateLines(top, cur, bot, tbl, i)

        if tbl[i + 1] and tbl[i + 1].ROW ~= last_row or not tbl[i + 1] then
            local last_in_row = tbl[i]
            AddLaneSeparatorLine(first_in_row, last_in_row, bot)
            first_in_row = nil
        end
    end
end

local function DrawVH(x, y, tbl, fade, parrent_pass_color)
    if V_LAYOUT then
        DrawPlugins(x, y, tbl, fade, parrent_pass_color)
    else
        DrawPluginsH(x, y, tbl, fade, parrent_pass_color)
    end
end

local function DrawLines()
    local function round_c(num)
        return (num + 0.5) // 1
    end
    for i = 1, #LINE_POINTS do
        local p_tbl = LINE_POINTS[i]
        r.ImGui_DrawList_AddLine(
            draw_list,
            round_c(p_tbl[1]),
            p_tbl[2],
            round_c(p_tbl[3]),
            p_tbl[4],
            COLOR["wire"],
            WireThickness * CANVAS.scale
        )
    end
end

local function CheckDNDType()
    local dnd_type = GetPayload()
    DND_ADD_FX = dnd_type == "DND ADD FX"
    DND_MOVE_FX = dnd_type == "DND MOVE FX"

    if DND_MOVE_FX then
        if next(SEL_TBL) then
            SEL_TBL = {}
        end
    end
end

local function CustomDNDPreview()
    if not DRAG_PREVIEW and not PREVIEW_TOOLTIP then
        return
    end
    --local MX, MY = r.ImGui_GetMousePos(ctx)
    local off_x, off_y = 25 * CANVAS.scale, 28 * CANVAS.scale

    if DRAG_PREVIEW then
        --! CENTER THE BUTTON AT MOUSE CURSOR IF THERE ARE NO TOOLTIPS
        if not TOOLTIPS then
            local click_x = r.ImGui_GetMouseClickedPos(ctx, 0)
            off_x = DRAG_PREVIEW.x and -(click_x - DRAG_PREVIEW.x) * CANVAS.scale or -20 * CANVAS.scale
            off_y = 20 * CANVAS.scale
        end

        r.ImGui_SetNextWindowBgAlpha(ctx, 0.3)
        r.ImGui_SetNextWindowPos(ctx, MX + off_x, MY + off_y)
        if DRAG_PREVIEW[DRAG_PREVIEW.i].type == "Container" then
            local is_collapsed = CheckCollapse(DRAG_PREVIEW[DRAG_PREVIEW.i], 1, 1)
            local w, h = ItemFullSize(DRAG_PREVIEW[DRAG_PREVIEW.i])
            if
                r.ImGui_BeginChild(
                    ctx,
                    "##PREVIEW_DRAW_CONTAINER",
                    (w + def_s_window_x) * CANVAS.scale,
                    (h + (def_s_window_y * 2)) * CANVAS.scale,
                    false,
                    r.ImGui_WindowFlags_NoBackground()
                )
            then
                local x, y = r.ImGui_GetCursorScreenPos(ctx)
                DrawButton(
                    DRAG_PREVIEW,
                    DRAG_PREVIEW.i,
                    DRAG_PREVIEW[DRAG_PREVIEW.i].name,
                    w - def_s_spacing_x,
                    1,
                    nil,
                    x,
                    y
                )
                if not is_collapsed then
                    if V_LAYOUT == true then
                        DrawPlugins(
                            MX + off_x + (w / 2.2) * CANVAS.scale,
                            MY + def_btn_h * CANVAS.scale,
                            DRAG_PREVIEW[DRAG_PREVIEW.i].sub,
                            1
                        )
                    else
                        DrawPluginsH(
                            x - (para_btn_size / 2) * CANVAS.scale,
                            y + ((h / 2) - (para_btn_size / 2)) * CANVAS.scale,
                            DRAG_PREVIEW[DRAG_PREVIEW.i].sub,
                            1
                        )
                    end
                end
                r.ImGui_EndChild(ctx)
            end
        else
            local width, height = ItemFullSize(DRAG_PREVIEW[DRAG_PREVIEW.i])
            --width = HelperWidth(DRAG_PREVIEW[DRAG_PREVIEW.i], width)
            if
                r.ImGui_BeginChild(
                    ctx,
                    "##PREVIEW_DRAW_FX",
                    (width + def_s_window_x * 2) * CANVAS.scale,
                    (height + def_s_window_y * 2) * CANVAS.scale,
                    false,
                    r.ImGui_WindowFlags_NoBackground()
                )
            then
                local x, y = r.ImGui_GetCursorScreenPos(ctx)
                --r.ImGui_SetCursorScreenPos(ctx,0,0)
                DrawButton(DRAG_PREVIEW, DRAG_PREVIEW.i, DRAG_PREVIEW[DRAG_PREVIEW.i].name, width, 1, nil, x, y)
                r.ImGui_EndChild(ctx)
            end
        end
    elseif PREVIEW_TOOLTIP then
        if SHOW_C_CONTENT_TOOLTIP then
            if r.time_precise() - PREVIEW_TOOLTIP.start > 0.25 then
                local px = (PREVIEW_TOOLTIP[PREVIEW_TOOLTIP.i].W / 2) * CANVAS.scale
                r.ImGui_SetNextWindowBgAlpha(ctx, 0.6)
                r.ImGui_SetCursorScreenPos(ctx, MX - px, MY + off_y)
                local H_OFF = not V_LAYOUT and para_btn_size or 0
                if
                    r.ImGui_BeginChild(
                        ctx,
                        "##PEAK_DRAW_CONTAINER",
                        PREVIEW_TOOLTIP[PREVIEW_TOOLTIP.i].W * CANVAS.scale,
                        (H_OFF + PREVIEW_TOOLTIP[PREVIEW_TOOLTIP.i].H) * CANVAS.scale,
                        true
                    )
                then
                    local x, y = r.ImGui_GetCursorScreenPos(ctx)
                    DrawButton(
                        PREVIEW_TOOLTIP,
                        PREVIEW_TOOLTIP.i,
                        PREVIEW_TOOLTIP[PREVIEW_TOOLTIP.i].name,
                        PREVIEW_TOOLTIP[PREVIEW_TOOLTIP.i].W - s_window_x,
                        1,
                        nil,
                        x,
                        y
                    )
                    if V_LAYOUT == true then
                        DrawPlugins(
                            MX - (def_s_window_x * 4) * CANVAS.scale,
                            MY + def_btn_h * CANVAS.scale,
                            PREVIEW_TOOLTIP[PREVIEW_TOOLTIP.i].sub,
                            1
                        )
                    else
                        DrawPluginsH(
                            x - (para_btn_size / 2) * CANVAS.scale,
                            y + ((PREVIEW_TOOLTIP[PREVIEW_TOOLTIP.i].H / 2) - (para_btn_size / 2)) * CANVAS.scale,
                            PREVIEW_TOOLTIP[PREVIEW_TOOLTIP.i].sub,
                            1
                        )
                    end
                    r.ImGui_EndChild(ctx)
                end
            end
        end
    end
end

function Draw()
    PEAK_INTO_TOOLTIP = false
    LINE_POINTS = {}
    if not TARGET then
        return
    end
    GenerateFXData()
    CheckDNDType()
    r.ImGui_PushStyleVar(
        ctx,
        r.ImGui_StyleVar_ItemSpacing(),
        def_s_spacing_x * CANVAS.scale,
        def_s_spacing_y * CANVAS.scale
    )
    r.ImGui_PushStyleVar(
        ctx,
        r.ImGui_StyleVar_WindowPadding(),
        def_s_window_x * CANVAS.scale,
        def_s_window_y * CANVAS.scale
    )
    if r.ImGui_BeginChild(ctx, "##MAIN", nil, nil, nil, WND_FLAGS) then
        local sx, sy = r.ImGui_GetCursorScreenPos(ctx)
        MAIN_CANVAS_SCREEN_X, MAIN_CANVAS_SCREEN_Y = sx, sy
        local x, y = sx + CANVAS.off_x, sy + CANVAS.off_y
        r.ImGui_SetCursorScreenPos(ctx, x, y)
        local bypass = PLUGINS[0].bypass and 1 or 0.5
        DrawVH(x, y, PLUGINS, bypass)
        Draw_MARQUEE()
        UpdateScroll()
        updateZoom()
        if r.ImGui_IsWindowHovered(ctx, r.ImGui_HoveredFlags_AllowWhenBlockedByPopup()) then
            if not OPEN_FM then
                if
                    r.ImGui_IsMouseReleased(ctx, 0)
                    and (DRAGX == 0 and DRAGY == 0)
                    and not r.ImGui_IsAnyItemHovered(ctx)
                then
                    if not SHIFT and not CTRL then
                        SEL_TBL = {}
                    end
                end
            end
        end
        r.ImGui_EndChild(ctx)
    end
    if SHOW_DND_TOOLTIPS then SHOW_DND_TOOLTIPS = nil end
    CustomDNDPreview()
    r.ImGui_PopStyleVar(ctx)
    r.ImGui_PopStyleVar(ctx)

    DrawLines()
end

--profiler.attachToWorld() -- after all functions have been defined
