--@noindex
--NoIndex: true
local r = reaper
local FX_DATA
local TR_CONTAINERS = {}

CLIPBOARD = {}

-- Resolve against the source chain, independently of the visible TRACK/ITEM mode.
function GetClipboardSource()
    if CLIPBOARD.take_guid and not CLIPBOARD.take then return end
    local source = CLIPBOARD.take or CLIPBOARD.track
    local kind = CLIPBOARD.take and "TakeFX_" or "TrackFX_"
    local ptr_type = CLIPBOARD.take and "MediaItem_Take*" or "MediaTrack*"
    if not source or not r.ValidatePtr(source, ptr_type) then return end
    local get_guid = r[kind .. "GetFXGUID"]
    local get_config = r[kind .. "GetNamedConfigParm"]
    local function find(ids)
        for i, id in ipairs(ids) do
            if get_guid(source, id) == CLIPBOARD.guid then
                return id, ids[i + 1]
            end
            local ok, count = get_config(source, id, "container_count")
            if ok then
                local children = {}
                for child = 0, tonumber(count) - 1 do
                    local found, child_id = get_config(source, id, "container_item." .. child)
                    if found then children[#children + 1] = tonumber(child_id) end
                end
                local found, next_id = find(children)
                if found then return found, next_id end
            end
        end
    end
    local ids = {}
    for i = 0, r[kind .. "GetCount"](source) - 1 do ids[#ids + 1] = i end
    local id, next_id = find(ids)
    if id == nil then return end
    CLIPBOARD.id = id
    return source, kind, next_id
end

local function CopyClipboardFX(source, src_id, dest_id, is_move)
    local prefix = CLIPBOARD.take and "TakeFX_" or "TrackFX_"
    local suffix = MODE == "ITEM" and "CopyToTake" or "CopyToTrack"
    r[prefix .. suffix](source, src_id, TARGET, dest_id, is_move)
end

local function PrepareClipboardMove(source, kind, next_id, parallel)
    local get = r[kind .. "GetNamedConfigParm"]
    local set = r[kind .. "SetNamedConfigParm"]
    if next_id then
        local _, next_parallel = get(source, next_id, "parallel")
        if next_parallel ~= "0" then
            local _, current_parallel = get(source, CLIPBOARD.id, "parallel")
            set(source, next_id, "parallel", current_parallel)
        end
    end
    set(source, CLIPBOARD.id, "parallel", parallel)
end

function GetFx(guid)
    return FX_DATA[guid]
end

function GetFX_DATA()
    return FX_DATA
end

function GetTRContainerData()
    return TR_CONTAINERS
end

function SetTRContainerData(tbl)
    TR_CONTAINERS = tbl
end

function TrackContainers()
    if not TR_CONTAINERS then
        return
    end
    for k in pairs(FX_DATA) do
        if FX_DATA[k].type == "Container" then
            if not TR_CONTAINERS[k] then
                TR_CONTAINERS[k] = { collapse = false }
            end
        end
    end
end

function CheckIfSafeToExplode(tbl, i)
    if tbl[i].type ~= "Container" then
        return
    end

    if tbl[i].p > 0 then
        if #tbl[i].sub > 1 then
            return
        end
    end
    if tbl[i].p == 0 and tbl[i + 1] and tbl[i + 1].p > 0 then
        if #tbl[i].sub > 1 then
            return
        end
    end
    return true
end

function ExplodeContainer(tbl, i)
    local cont_parent = tbl[i].pid
    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)
    for child_i = 1, #tbl[i].sub do
        UpdateFxData()
        local cont_parent_tbl = GetFx(cont_parent)
        local cont = GetFx(tbl[i].guid)
        local ID = CalcFxID(cont_parent_tbl, cont.IDX)

        local child = GetFx(tbl[i].sub[child_i].guid)
        API.CopyToTrack(TARGET, child.FX_ID, TARGET, ID, true)
        if tbl[i].p > 0 then
            API.SetNamedConfigParm(TARGET, ID, "parallel", tbl[i].p)
        end
    end
    UpdateFxData()
    local cont = GetFx(tbl[i].guid)
    API.Delete(TARGET, cont.FX_ID)
    r.PreventUIRefresh(-1)
    EndUndoBlock("EXPLODE CONTAINER " .. tbl[i].name)
end

function ValidateTrackContainers()
    if not TR_CONTAINERS then
        return
    end
    for k in pairs(TR_CONTAINERS) do
        if not FX_DATA[k] then
            TR_CONTAINERS[k] = nil
        end
    end
end

function AddCollapseData(tbl, id)
    if tbl.type ~= "Container" then
        return
    end
    local guid = API.GetFXGUID(TARGET, id)
    TR_CONTAINERS[guid] = { collapse = CheckCollapse(tbl, 1, 1) }
end

function AddCollapsePASTEData(id)
    if CLIPBOARD.type ~= "Container" then
        return
    end
    local guid = API.GetFXGUID(TARGET, id)
    TR_CONTAINERS[guid] = { collapse = CLIPBOARD.collapsed }
end

function InitTrackContainers()
    UpdateFxData()
    TrackContainers()
end

function GetParentContainerByGuid(tbl)
    if not tbl then
        return
    end
    return tbl.type == "ROOT" and tbl or GetFx(tbl.pid)
end

function CalcFxIDFromParrent(tbl, i)
    local parrent_container = GetParentContainerByGuid(tbl[i])
    local fx_id = CalcFxID(parrent_container, i + 1)
    return fx_id
end

function CalcFxID(tbl, idx)
    if tbl.type == "Container" then
        return 0x2000000 + tbl.ID + (tbl.DIFF * idx)
    elseif tbl.type == "ROOT" then
        return idx - 1
    end
end

local function IsChildOfContainer(parrent, target, parallel_guid)
    local parrent_guid = parrent.guid
    local found
    local dst = target
    while not found do
        if dst.type == "ROOT" then
            break
        end
        if dst.pid == parrent_guid then
            if parallel_guid then
                -- ALLOW MOVING ON PARENTS PARALLEL BUTTON (ADDING IT NEXT TO IT)
                if parallel_guid ~= parrent_guid then
                    found = parrent_guid
                    break
                else
                    dst = GetFx(dst.pid)
                end
            else
                found = parrent_guid
                break
            end
        else
            -- KEEP TRYING UNTIL ROOT IS FOUND
            dst = GetFx(dst.pid)
        end
    end
    return found
end

function GetPayload()
    local retval, dndtype, payload = r.ImGui_GetDragDropPayload(ctx)
    if retval then
        return dndtype, payload
    end
end

function IsChildOfParrent(tbl, i, parallel_guid, serial_insert_point)
    local dndtype, payload = GetPayload()
    if dndtype == "DND MOVE FX" then
        if payload ~= "" then
            if tbl[i].type == "ROOT" then
                return
            end
            local src_guid, src_i = payload:match("(.+),(.+)")
            local src_fx = GetFx(src_guid)
            -- DRAG STARTED WITH CONTAINER - DO NOT MOVE INTO ITS FX CHILDS
            if IsChildOfContainer(src_fx, tbl[i], parallel_guid) then
                return true
            end
            -- EXCLUDE SERIAL POINTS
            if not serial_insert_point then
                -- DRAG STARTED WITH FX - DO NOT MOVE ON PARRENT CONTAINER
                if IsChildOfContainer(tbl[i], src_fx, parallel_guid) then
                    return true
                end
            end
        end
    end
end

function IsOnSameParallelLane(tbl, i, parallel, serial_insert_point)
    --! ALLOW DRAG COPY
    if not parallel then
        return false
    end
    --! IGNORE IF DRAG COPY
    if CTRL_DRAG then
        return false
    end
    local dndtype, payload = GetPayload()
    if dndtype == "DND MOVE FX" then
        if payload ~= "" then
            local src_guid, src_i = payload:match("(.+),(.+)")
            local src_fx = GetFx(src_guid)
            if src_fx.ROW == tbl[i].ROW then
                --! ENSURE THAT ITS IN THE SAME PARRENT
                if tbl[i].pid == src_fx.pid then
                    return true
                end
            end
        end
    end
end

function IsSameSerialPos(tbl, i, serial_insert_point)
    --! ONLY SERIAL BUTTON
    if not serial_insert_point then
        return
    end
    --! IGNORE IF DRAG COPY
    if CTRL_DRAG then
        return false
    end
    local dndtype, payload = GetPayload()
    if dndtype == "DND MOVE FX" then
        if payload ~= "" then
            local src_guid, src_i = payload:match("(.+),(.+)")
            --! PREVIOUS BUTTON
            -- IS NEXT BUTTON OUR DRAG SOURCE
            if tbl[i + 1] and tbl[i + 1].guid == src_guid then
                -- MAKE SURE WE ARE TARGETING ONLY SERIAL LANE
                -- CHECK IF OUR SOURCE (+1) IS SERIAL BY CHECKING IS THE BUTTON AFTER NOT PARALLEL
                if tbl[i + 2] and tbl[i + 2].p == 0 or not tbl[i + 2] then
                    return true
                end
            end
            --! NEXT BUTTON, MAKE SURE ITS NOT PARALLEL
            if src_guid == tbl[i].guid and tbl[i].p == 0 then
                return true
            end
        end
    end
end

function IsOnSelfEncloseButton(tbl, i)
    --! IGNORE IF DRAG_COPY
    if CTRL_DRAG then
        return false
    end
    local dndtype, payload = GetPayload()
    if dndtype == "DND MOVE FX" then
        if payload ~= "" then
            local src_guid, src_i = payload:match("(.+),(.+)")
            if src_guid == tbl[i].guid then
                return true
            end
        end
    end
end

local function CheckIsFirstARA(tbl, i, parallel)
    if tbl[i + 1] and tbl[i + 1].exclude_ara then
        tbl[i].no_draw_s = true
        return true
    end
    if parallel then
        if tbl[i] and tbl[i].exclude_ara then
            tbl[i].no_draw_p = true
            return true
        end
    end
end

function ARA_Protection(tbl, i, parallel)
    if CheckIsFirstARA(tbl, i, parallel) then
        return true
    end
    if DRAG_PREVIEW and DRAG_PREVIEW.is_ara then
        if tbl[i].type ~= "ROOT" then
            tbl[i].no_draw_s = true
            tbl[i].no_draw_p = true
            tbl[i].no_draw_e = true
            return true
        end
    end
end

function CreateContainerAndInsertFX(tbl, i, fx)
    -- ADD CONTAINER AT THE BEGINNING OF THE CHAIN TO MAKE IT EASIER TO INSERT THINGS
    --! CHECK ITS POSITION WITH BLACKLISTED FX (MELODYNE AND SIMILAR NEED TO BE IN SLOT 1 AND CANNOT BE IN CONTAINER)
    --! CREATE CONTAINER IN POSITION ABOVE BLACKLISTED FX
    local cont_insert_id = CalculateInsertContainerPosFromBlacklist()
    local cont_pos = API.AddByName(TARGET, "Container", MODE == "ITEM" and cont_insert_id or false, cont_insert_id)

    -- SWAP PARALLEL DATA WITH TARGET (MAYBE FIRST IN LANE == 0 OR NEXT IN LANE == 1)
    API.SetNamedConfigParm(TARGET, 0x2000000 + cont_pos + 1, "parallel", tbl[i].p)
    UpdateFxData()

    -- ADD NEW FX TO IT
    local cont_id = 0x2000000 + cont_pos + 1 + (API.GetCount(TARGET) + 1)
    API.AddByName(TARGET, fx, MODE == "ITEM" and cont_id or false, cont_id)
    UpdateFxData()

    -- MOVE TARGET FX INTO IT
    local target_fx = GetFx(tbl[i].guid)
    local target_parrent = GetFx(tbl[i].pid)
    local target_id = CalcFxID(target_parrent, target_fx.IDX)
    -- MAKE TARGET FX PARALLEL INFO 0 SINCE IT WILL BE IN SERIAL
    API.SetNamedConfigParm(TARGET, target_id, "parallel", "0")
    API.CopyToTrack(TARGET, target_id, TARGET, cont_id, true)

    UpdateFxData()
    -- GET UPDATED PARRENT
    target_parrent = GetFx(tbl[i].pid)
    -- RECALCULATE ORIGINAL TARGET POS
    local original_pos = CalcFxID(target_parrent, i)
    -- MOVE CONTAINER TO ORIGINAL TARGET
    API.CopyToTrack(TARGET, 0x2000000 + cont_pos + 1, TARGET, original_pos, true)
end

function MoveTargetsToNewContainer(tbl, i, src_guid, src_i)
    local source_parallel_info = tbl[i].p

    local src_fx
    local src_parrent

    local is_move = (not CTRL_DRAG) and true or false

    -- ENCLOSE RIGHT CLICK OPTION IS CALLED IF GUID IS NOT PROVIDED
    if src_guid then
        src_fx = GetFx(src_guid)
        src_parrent = GetFx(src_fx.pid)
        -- SWAP INFO WITH NEXT FX TO KEEP PLUGINS IN PLACE
        if is_move then
            CheckNextItemParallel(src_i, src_parrent)
        end
    end
    -- ADD CONTAINER AT THE BEGINNING OF THE CHAIN TO MAKE IT EASIER TO INSERT THINGS
    --! CHECK ITS POSITION WITH BLACKLISTED FX (MELODYNE AND SIMILAR NEED TO BE IN SLOT 1 AND CANNOT BE IN CONTAINER)
    --! CREATE CONTAINER IN POSITION ABOVE BLACKLISTED FX
    local cont_insert_id = CalculateInsertContainerPosFromBlacklist()

    local cont_pos = API.AddByName(TARGET, "Container", MODE == "ITEM" and cont_insert_id or false, cont_insert_id)
    -- SWAP PARALLEL DATA WITH TARGET (MAYBE FIRST IN LANE == 0 OR NEXT IN LANE == 1)
    API.SetNamedConfigParm(TARGET, 0x2000000 + cont_pos + 1, "parallel", source_parallel_info)

    UpdateFxData()
    local cont_id = 0x2000000 + cont_pos + 1 + (API.GetCount(TARGET) + 1)

    -- ENCLOSE RIGHT CLICK OPTION IS CALLED IS GUID IS NOT PROVIDED
    if src_guid then
        src_fx = GetFx(src_guid)
        src_parrent = GetFx(src_fx.pid)
        local src_id = CalcFxID(src_parrent, src_fx.IDX)

        if is_move then
            -- IF MOVING MAKE SOURCE FX PARALLEL INFO 0 SINCE IT WILL BE IN SERIAL
            API.SetNamedConfigParm(TARGET, src_id, "parallel", "0")
            -- MOVE SOURCE FX INTO IT CONTAINER
            API.CopyToTrack(TARGET, src_id, TARGET, cont_id, true)
        else
            -- COPY SOURCE FX INTO IT CONTAINER
            API.CopyToTrack(TARGET, src_id, TARGET, cont_id, false)
            -- SET COPY PARRALEL INFO 0 SINCE IT WILL BE IN SERIAL
            API.SetNamedConfigParm(TARGET, cont_id, "parallel", "0")
            --! ADD INSERT COLLAPSE DATA IF CONTAINER WAS COPIED
            AddCollapseData(src_fx, cont_id)
        end
    end
    UpdateFxData()
    cont_id = 0x2000000 + cont_pos + 1 + (API.GetCount(TARGET) + 1)

    local target_fx = GetFx(tbl[i].guid)
    local target_parrent = GetFx(tbl[i].pid)
    local target_id = CalcFxID(target_parrent, target_fx.IDX)
    -- MAKE TARGET FX PARALLEL INFO 0 SINCE IT WILL BE IN SERIAL
    API.SetNamedConfigParm(TARGET, target_id, "parallel", "0")
    -- MOVE TARGET INTO CONTAINER
    API.CopyToTrack(TARGET, target_id, TARGET, cont_id, true)

    UpdateFxData()
    -- ORIGINAL FX POS
    local target_pos = i
    -- GET UPDATED PARRENTS
    target_parrent = GetFx(tbl[i].pid)

    -- ENCLOSE RIGHT CLICK OPTION IS CALLED
    if src_guid then
        src_parrent = GetFx(src_fx.pid)
        -- DETERMINE IF FX WAS BEFORE OR AFTER FOR OFFSET
        if src_parrent.guid == target_parrent.guid then
            if is_move then
                target_pos = src_i > i and i or i - 1
            else
                target_pos = i
            end
        else
            target_pos = i
        end
    end
    -- MOVE CONTAINER INTO TARGET POSITION
    local original_pos = CalcFxID(target_parrent, target_pos)
    -- MOVE CONTAINER TO ORIGINAL TARGET
    API.CopyToTrack(TARGET, 0x2000000 + cont_pos + 1, TARGET, original_pos, true)
end

function CopyTargetsToNewContainer(track, tbl, i, src_guid, src_i, is_cut)
    local source_parallel_info = tbl[i].p

    local src_fx
    local src_parrent

    local is_move = is_cut

    -- ADD CONTAINER AT THE BEGINNING OF THE CHAIN TO MAKE IT EASIER TO INSERT THINGS
    --! CHECK ITS POSITION WITH BLACKLISTED FX (MELODYNE AND SIMILAR NEED TO BE IN SLOT 1 AND CANNOT BE IN CONTAINER)
    --! CREATE CONTAINER IN POSITION ABOVE BLACKLISTED FX
    local cont_insert_id = CalculateInsertContainerPosFromBlacklist()

    local cont_pos = API.AddByName(TARGET, "Container", MODE == "ITEM" and cont_insert_id or false, cont_insert_id)
    -- SWAP PARALLEL DATA WITH TARGET (MAYBE FIRST IN LANE == 0 OR NEXT IN LANE == 1)
    API.SetNamedConfigParm(TARGET, 0x2000000 + cont_pos + 1, "parallel", source_parallel_info)

    UpdateFxData()
    local cont_id = 0x2000000 + cont_pos + 1 + (API.GetCount(TARGET) + 1)

    local src_id
    if track == TARGET then
        src_fx = GetFx(src_guid)
        src_parrent = GetFx(src_fx.pid)
        src_id = CalcFxID(src_parrent, src_fx.IDX)
    else
        src_id = CLIPBOARD.id
    end

    -- COPY SOURCE FX INTO IT CONTAINER
    CopyClipboardFX(track, src_id, cont_id, is_move)
    -- SET COPY PARRALEL INFO 0 SINCE IT WILL BE IN SERIAL
    API.SetNamedConfigParm(TARGET, cont_id, "parallel", "0")

    if not is_move then
        --! ADD NEW COLLAPSE DATA IF CONTAINER
        AddCollapsePASTEData(cont_id)
    else
        if track == TARGET then
            AddCollapsePASTEData(src_id)
        else
            AddCollapsePASTEData(cont_id)
        end
    end

    UpdateFxData()
    cont_id = 0x2000000 + cont_pos + 1 + (API.GetCount(TARGET) + 1)

    local target_fx = GetFx(tbl[i].guid)
    local target_parrent = GetFx(tbl[i].pid)
    local target_id = CalcFxID(target_parrent, target_fx.IDX)
    -- MAKE TARGET FX PARALLEL INFO 0 SINCE IT WILL BE IN SERIAL
    API.SetNamedConfigParm(TARGET, target_id, "parallel", "0")
    -- MOVE TARGET INTO CONTAINER
    API.CopyToTrack(TARGET, target_id, TARGET, cont_id, true)

    UpdateFxData()
    -- ORIGINAL FX POS
    local target_pos = i
    -- GET UPDATED PARRENTS
    target_parrent = GetFx(tbl[i].pid)

    -- ENCLOSE RIGHT CLICK OPTION IS CALLED
    if src_guid and track == TARGET then
        src_parrent = GetFx(src_fx.pid)
        -- DETERMINE IF FX WAS BEFORE OR AFTER FOR OFFSET
        if src_parrent.guid == target_parrent.guid then
            if is_move then
                target_pos = src_i > i and i or i - 1
            else
                target_pos = i
            end
        else
            target_pos = i
        end
    end
    -- MOVE CONTAINER INTO TARGET POSITION
    local original_pos = CalcFxID(target_parrent, target_pos)
    -- MOVE CONTAINER TO ORIGINAL TARGET
    API.CopyToTrack(TARGET, 0x2000000 + cont_pos + 1, TARGET, original_pos, true)
end

local function IterateContainerUpdate(depth, track, container_id, parent_fx_count, previous_diff, container_guid)
    local c_ok, c_fx_count = API.GetNamedConfigParm(track, 0x2000000 + container_id, "container_count")
    if not c_ok then
        return
    end
    local diff = depth == 0 and parent_fx_count + 1 or (parent_fx_count + 1) * previous_diff
    local child_guids = {}

    FX_DATA["insertpoint_0" .. container_guid] = {
        IDX = 1,
        name = "DUMMY",
        type = "INSERT_POINT",
        guid = "insertpoint_0" .. container_guid,
        pid = container_guid,
        ROW = 0,
    }

    local row = 1
    for i = 1, c_fx_count do
        local fx_id = container_id + diff * i
        local fx_guid = API.GetFXGUID(TARGET, 0x2000000 + fx_id)
        local _, fx_type = API.GetNamedConfigParm(track, 0x2000000 + fx_id, "fx_type")
        local _, para = API.GetNamedConfigParm(track, 0x2000000 + fx_id, "parallel")

        if i > 1 then
            row = para == "0" and row + 1 or row
        end

        FX_DATA[fx_guid] = {
            type = fx_type,
            IDX = i,
            pid = container_guid,
            guid = fx_guid,
            ROW = row,
            FX_ID = 0x2000000 + fx_id,
        }
        child_guids[#child_guids + 1] = { guid = fx_guid }
        if fx_type == "Container" then
            FX_DATA[fx_guid].depth = depth + 1
            FX_DATA[fx_guid].DIFF = diff * (c_fx_count + 1)
            FX_DATA[fx_guid].ID = fx_id
            IterateContainerUpdate(depth + 1, track, fx_id, c_fx_count, diff, fx_guid)
        end
    end
    return child_guids
end

function UpdateFxData()
    if not TARGET then
        return
    end
    FX_DATA = {}
    FX_DATA = {
        ["ROOT"] = {
            type = "ROOT",
            pid = "ROOT",
            guid = "ROOT",
            ROW = 0,
        },
    }
    local row = 1
    local total_fx_count = API.GetCount(TARGET)
    for i = 1, total_fx_count do
        local _, fx_type = API.GetNamedConfigParm(TARGET, i - 1, "fx_type")
        local _, para = API.GetNamedConfigParm(TARGET, i - 1, "parallel")
        local fx_guid = API.GetFXGUID(TARGET, i - 1)
        if i > 1 then
            row = para == "0" and row + 1 or row
        end

        FX_DATA[fx_guid] = {
            type = fx_type,
            IDX = i,
            FX_ID = i - 1,
            pid = "ROOT",
            guid = fx_guid,
            ROW = row,
        }
        if fx_type == "Container" then
            FX_DATA[fx_guid].depth = 0
            FX_DATA[fx_guid].DIFF = (total_fx_count + 1)
            FX_DATA[fx_guid].ID = i
            IterateContainerUpdate(0, TARGET, i, total_fx_count, 0, fx_guid)
        end
    end
end

function CollectFxData()
    if not TARGET then
        return
    end
    UpdateFxData()
    ValidateTrackContainers()
    TrackContainers()
end

function UpdateClipboardInfo()
    if CLIPBOARD.cut then
        ClearExtState()
        return
    end
    -- DONT RECALCULATE IF PASTING ON DIFFERENT TARGET
    if (CLIPBOARD.take or CLIPBOARD.track) ~= TARGET then
        return
    end

    UpdateFxData()
    local updated = GetFx(CLIPBOARD.tbl[CLIPBOARD.i].guid)
    if not updated then
        ClearExtState()
        return
    end
    local parrent = GetFx(updated.pid)

    local item_id = CalcFxID(parrent, updated.IDX)
    CLIPBOARD.id = item_id
end

local old_copy_id

function ClipBoard()
    if r.HasExtState("PARANORMALFX2", "COPY_BUFFER") then
        local copy_id = r.GetExtState("PARANORMALFX2", "COPY_BUFFER_ID")
        if old_copy_id ~= copy_id then
            local stored = r.GetExtState("PARANORMALFX2", "COPY_BUFFER")
            if stored ~= nil then
                local storedTable = stringToTable(stored)
                if storedTable ~= nil then
                    CLIPBOARD = {
                        tbl = storedTable.tbl,
                        i = storedTable.i,
                        id = storedTable.fx_id,
                        guid = storedTable.guid,
                        cut = storedTable.cut,
                        P_DIFF = storedTable.parrent_DIFF,
                        P_ID = storedTable.parrent_ID,
                        P_TYPE = storedTable.parrent_TYPE,
                        collapsed = storedTable.collapsed,
                        type = storedTable.type,
                        take_guid = storedTable.take_guid,
                        take = storedTable.take_guid and r.GetMediaItemTakeByGUID(0, storedTable.take_guid),
                    }
                    for i = 0, r.CountTracks(0) do
                        local track = i == 0 and r.GetMasterTrack(0) or r.GetTrack(0, i - 1)
                        if storedTable.track_guid == r.GetTrackGUID(track) then
                            CLIPBOARD.track = track
                            break
                        end
                    end
                end
                old_copy_id = copy_id
            end
        end
    end

    if CLIPBOARD.tbl then
        if not GetClipboardSource() then
            ClearExtState()
            return
        end
        local label = "CLIPBOARD: " .. CLIPBOARD.tbl[CLIPBOARD.i].name
        local pad_x, pad_y = 8, 5
        local x, y = r.ImGui_GetContentRegionMax(ctx)
        local min_x, min_y = r.ImGui_GetWindowContentRegionMin(ctx)
        local text_w = r.ImGui_CalcTextSize(ctx, label)
        local width = math.max(1, math.min(text_w + pad_x * 2, x - min_x))
        local available = math.max(1, width - pad_x * 2)
        local _, text_h = r.ImGui_CalcTextSize(ctx, label, nil, nil, false, available)
        local height = text_h + pad_y * 2
        r.ImGui_SetCursorPos(ctx, min_x, math.max(min_y, y - height))
        local flags = r.ImGui_WindowFlags_NoScrollbar() | r.ImGui_WindowFlags_NoScrollWithMouse()
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ChildBg(), 0x222222FF)
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowPadding(), pad_x, pad_y)
        if r.ImGui_BeginChild(ctx, "CLIPBOARD", width, height, 1, flags) then
            r.ImGui_PushTextWrapPos(ctx, available)
            r.ImGui_Text(ctx, label)
            r.ImGui_PopTextWrapPos(ctx)
        end
        r.ImGui_EndChild(ctx)
        r.ImGui_PopStyleVar(ctx)
        r.ImGui_PopStyleColor(ctx)
    end
end

function Paste(replace, parallel, serial, enclose)
    if not CLIPBOARD.tbl then
        return
    end

    local source, source_kind, next_id = GetClipboardSource()
    if not source then
        ClearExtState()
        return
    end
    local is_cut = CLIPBOARD.cut and true or false

    local para_info = serial and "0" or ""
    para_info = parallel and DEF_PARALLEL or para_info
    local parrent_container = GetParentContainerByGuid(RC_DATA.tbl[RC_DATA.i])
    local item_id = CalcFxID(parrent_container, (parallel or serial) and RC_DATA.i + 1 or RC_DATA.i)
    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)
    if is_cut then
        PrepareClipboardMove(source, source_kind, next_id, para_info)
    end
    if enclose then
        CopyTargetsToNewContainer(source, RC_DATA.tbl, RC_DATA.i, CLIPBOARD.guid, CLIPBOARD.i, is_cut)
    else
        CopyClipboardFX(source, CLIPBOARD.id, item_id, is_cut)
        API.SetNamedConfigParm(TARGET, item_id, "parallel", para_info)
        AddCollapsePASTEData(item_id)

        if replace then
            UpdateFxData()
            local target_fx = GetFx(RC_DATA.tbl[RC_DATA.i].guid)
            local target_parrent = GetFx(target_fx.pid)
            local del_id = CalcFxID(target_parrent, target_fx.IDX)
            API.Delete(TARGET, del_id)
        end

        if parallel and not is_cut then
            API.SetNamedConfigParm(TARGET, item_id, "parallel", DEF_PARALLEL)
        end
    end

    r.PreventUIRefresh(-1)
    EndUndoBlock((is_cut and "CUT FX: " or "PASTE FX: ") .. RC_DATA.tbl[RC_DATA.i].name)
    UpdateClipboardInfo()
end

function SetContainerSurround(fx_id, ch_num)
    API.SetNamedConfigParm(TARGET, fx_id, "container_nch", ch_num)
    API.SetNamedConfigParm(TARGET, fx_id, "container_nch_in", ch_num)
    API.SetNamedConfigParm(TARGET, fx_id, "container_nch_out", ch_num)
end

local surround_mapping = {
    [1] = 1,
    [2] = 3,
    [3] = 5,
    [4] = 7,
    [5] = 9,
    [6] = 11,
}

function SetChildSurround(fx_tbl, max_ch)
    local max_allowed = max_ch / 2
    for i = 1, #fx_tbl do
        local child = GetFx(fx_tbl[i].guid)
        if surround_mapping[i] then
            local pin = surround_mapping[i]
            API.SetNamedConfigParm(TARGET, child.FX_ID, "container_nch", max_ch)
            -- IN
            API.SetPinMappings(TARGET, child.FX_ID, 0, 0, 2 ^ (pin - 1), 0) --Set pin
            API.SetPinMappings(TARGET, child.FX_ID, 0, 1, 2 ^ pin, 0) --Set pin
            -- OUT
            API.SetPinMappings(TARGET, child.FX_ID, 1, 0, 2 ^ (pin - 1), 0) --Set pin
            API.SetPinMappings(TARGET, child.FX_ID, 1, 1, 2 ^ pin, 0) --Set pin
        end
    end
end

--profiler.attachToWorld() -- after all functions have been defined
