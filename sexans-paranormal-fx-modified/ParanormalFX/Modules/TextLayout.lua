-- Shared geometry for text, icons, frames, menu rows and inputs.
-- Coordinates include the frame's endpoint pixels.
local r = reaper
local metrics = require("Modules/TextMetrics")
PARANORMAL_TEXT_PADDING = 8
PARANORMAL_BORDER_WIDTH = 1
PARANORMAL_ROW_HEIGHT = 30
local cache = {}

function ParaTextBounds(text, icon)
    text = tostring(text):gsub("##.*$", "")
    local key = (icon and "i" or "t") .. text
    if cache[key] then return cache[key] end
    local font = icon and metrics.icon or metrics.text
    local pen, left, top, right, bottom = 0, nil, nil, nil, nil
    for _, code in utf8.codes(text) do
        local g = font.glyphs[code] or font.glyphs[63]
        if g then
            if g[4] > 0 and g[5] > 0 then
                left = math.min(left or math.huge, pen + g[2])
                top = math.min(top or math.huge, g[3])
                right = math.max(right or -math.huge, pen + g[2] + g[4])
                bottom = math.max(bottom or -math.huge, g[3] + g[5])
            end
            pen = pen + g[1]
        end
    end
    local result = {left or 0, top or 0, left and right-left or pen, top and bottom-top or 0}
    cache[key] = result
    return result
end

function ParaTextWidth(text, icon)
    return ParaTextBounds(text, icon)[3]
end

function ParaPaddedWidth(text, icon, border)
    return ParaTextWidth(text, icon) + 2 * (PARANORMAL_TEXT_PADDING + (border or PARANORMAL_BORDER_WIDTH)) - 1
end

function ParaFitText(text, available)
    text = tostring(text):gsub("##.*$", "")
    if ParaTextWidth(text) <= available then return text end
    local chars = {}
    for _, code in utf8.codes(text) do chars[#chars+1] = utf8.char(code) end
    while #chars > 0 do
        table.remove(chars)
        local candidate = table.concat(chars) .. "..."
        if ParaTextWidth(candidate) <= available then return candidate end
    end
    return ""
end

function ParaDrawText(list, text, x1, y1, x2, y2, colour, align, icon, border)
    local inset = (icon and 0 or PARANORMAL_TEXT_PADDING) + (border or 0)
    local available_w = math.max(0, x2-x1+1-2*inset)
    local available_h = math.max(0, y2-y1+1-2*inset)
    local visible = icon and text or ParaFitText(text, available_w)
    local b = ParaTextBounds(visible, icon)
    local x = x1 + inset + (available_w-b[3]) * (align or 0.5) - b[1]
    local y = y1 + inset + (available_h-b[4])/2 - b[2]
    r.ImGui_DrawList_PushClipRect(list, x1+inset, y1+inset, x2+1-inset, y2+1-inset, true)
    r.ImGui_DrawList_AddTextEx(list, icon and ICONS_FONT_SMALL or SYSTEM_FONT_FACTORY,
        icon and ICON_FONT_SIZE or ORG_FONT_SIZE, x, y, colour, visible)
    r.ImGui_DrawList_PopClipRect(list)
end

function ParaDrawFrame(list, x1, y1, x2, y2, fill, border_colour)
    r.ImGui_DrawList_AddRectFilled(list, x1, y1, x2+1, y2+1, border_colour)
    r.ImGui_DrawList_AddRectFilled(list, x1+PARANORMAL_BORDER_WIDTH, y1+PARANORMAL_BORDER_WIDTH,
        x2+1-PARANORMAL_BORDER_WIDTH, y2+1-PARANORMAL_BORDER_WIDTH, fill)
end

function ParaButton(context, label, width, height)
    local visible = label:gsub("##.*$", "")
    local auto_width = ParaPaddedWidth(visible)
    r.ImGui_PushStyleVar(context, r.ImGui_StyleVar_FramePadding(),
        PARANORMAL_TEXT_PADDING+PARANORMAL_BORDER_WIDTH, PARANORMAL_TEXT_PADDING)
    local colour = r.ImGui_GetColor(context, r.ImGui_Col_Text())
    r.ImGui_PushStyleColor(context, r.ImGui_Col_Text(), 0xFFFFFF00)
    local clicked = r.ImGui_Button(context, label, width and width ~= 0 and width or auto_width,
        height and height ~= 0 and height or PARANORMAL_ROW_HEIGHT)
    r.ImGui_PopStyleColor(context)
    r.ImGui_PopStyleVar(context)
    local x1,y1 = r.ImGui_GetItemRectMin(context)
    local x2,y2 = r.ImGui_GetItemRectMax(context)
    ParaDrawText(r.ImGui_GetWindowDrawList(context), visible, x1,y1,x2,y2, colour,0.5,false,1)
    return clicked
end

function ParaInputTextHeight(context, label, text, height, ...)
    local padding_y = height and math.max(0, (height - r.ImGui_GetTextLineHeight(context)) / 2)
        or PARANORMAL_TEXT_PADDING
    local bearing = ParaTextBounds(text)[1]
    r.ImGui_PushStyleVar(context, r.ImGui_StyleVar_FramePadding(),
        PARANORMAL_TEXT_PADDING+PARANORMAL_BORDER_WIDTH-bearing, padding_y)
    local changed, value = r.ImGui_InputText(context, label, text, ...)
    r.ImGui_PopStyleVar(context)
    return changed, value
end

function ParaInputText(context, label, text, ...)
    return ParaInputTextHeight(context, label, text, nil, ...)
end

function ParaSelectable(context, label, selected, flags, width, height)
    local visible = label:gsub("##.*$", "")
    local x,y = r.ImGui_GetCursorScreenPos(context)
    local wx,wy = r.ImGui_GetWindowPos(context)
    local ww = r.ImGui_GetWindowSize(context)
    local _,sy = r.ImGui_GetStyleVar(context, r.ImGui_StyleVar_ItemSpacing())
    local line = r.ImGui_GetTextLineHeight(context)
    local colour = r.ImGui_GetColor(context, r.ImGui_Col_Text())
    r.ImGui_PushStyleColor(context, r.ImGui_Col_Text(), 0xFFFFFF00)
    local clicked = r.ImGui_Selectable(context, label, selected, flags, width, height)
    r.ImGui_PopStyleColor(context)
    ParaDrawText(r.ImGui_GetWindowDrawList(context), visible, wx,y-sy/2,wx+ww-1,y+line+sy/2-1,
        colour,0,false,1)
    return clicked
end
