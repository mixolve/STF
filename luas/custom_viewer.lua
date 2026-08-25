local SCRIPT_NAME = "LR SPECTRUM VIEWER"
local GMEM_NAME = "ITEM_LR_DELTA_8K"

local FONT_NAME = "Fira Mono"
local FONT_SIZE = 16
local UI_FONT_SIZE = 16

local ctx = reaper.ImGui_CreateContext(SCRIPT_NAME)
local font_ui = reaper.ImGui_CreateFont(FONT_NAME, UI_FONT_SIZE)
local font_menu = reaper.ImGui_CreateFont(FONT_NAME, FONT_SIZE)
reaper.ImGui_Attach(ctx, font_ui)
reaper.ImGui_Attach(ctx, font_menu)

reaper.gmem_attach(GMEM_NAME)

local show_left = false
local show_right = false
local show_stereo = true
local show_mid = false
local show_side = false

local active_tab = 0
local spectrum_peak_mode = math.floor(reaper.gmem_read(14) or 0) == 1

local SLOPE_DB_PER_OCT = 4.5
local slope_input = "4.5"
local SLOPE_REF_FREQ = 632.0
local SLOPE_ENABLED = true

local SPEC_CEIL_DB = -24.0
local SPEC_FLOOR_DB = -48.0
local SPEC_FLOOR_MIN = -99.0
local SPEC_MIN_RANGE_DB = 6.0
local spec_hi_input = "-24"
local spec_lo_input = "-48"

local CORR_TOP = 1.0
local CORR_BOTTOM = -1.0
local CORR_BOTTOM_MIN = -1.0
local CORR_BOTTOM_MAX = 0.0
local CORR_SCROLL_STEP = 0.05

local SMOOTH_FRACTION = 48

local WIN_W = 760
local WIN_H = 420
local BUTTON_H = 26
local INPUT_FRAME_PAD_Y = 3

local TOKEN_DOT_TTL = 2.5
local TOKEN_DOT_RADIUS = 3.0

local function clamp(x, a, b)
  if x < a then return a end
  if x > b then return b end
  return x
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function freq_for_bin(bin_idx, fft_size, sr)
  return ((bin_idx - 1) * sr) / fft_size
end

local function freq_from_plot_x(x, plot_x, plot_w, sr)
  local min_freq = 20.0
  local max_freq = sr * 0.5
  local nx = clamp((x - plot_x) / plot_w, 0.0, 1.0)
  local log_min = math.log(min_freq, 10)
  local log_max = math.log(max_freq, 10)
  return 10 ^ lerp(log_min, log_max, nx)
end

local function format_freq_text(freq)
  if freq >= 1000.0 then
    return string.format("%.2fK", freq / 1000.0)
  else
    return string.format("%.0f", freq)
  end
end

local function parse_slope_value(text)
  local normalized = (text or ""):gsub(",", ".")
  local value = tonumber(normalized)
  if not value then return nil end
  return clamp(value, 0.0, 9.0)
end

local function format_slope_value(value)
  return string.format("%.1f", clamp(value or 0.0, 0.0, 9.0))
end

local function commit_slope_input()
  local slope_value = parse_slope_value(slope_input)
  if slope_value then
    SLOPE_DB_PER_OCT = slope_value
  end
  slope_input = format_slope_value(SLOPE_DB_PER_OCT)
end

local function write_spectrum_mode()
  reaper.gmem_write(14, spectrum_peak_mode and 1 or 0)
end

local function apply_slope(v, freq)
  if not SLOPE_ENABLED then return v end
  if freq <= 0 then return v end
  local oct = math.log(freq / SLOPE_REF_FREQ, 2)
  return v + (SLOPE_DB_PER_OCT * oct)
end

local function smooth_octave(arr, fft_size, sr, nbins, fraction)
  if not arr or nbins <= 0 or fraction <= 0 then
    return arr or {}
  end

  local out = {}
  local half_oct = 1.0 / (2.0 * fraction)

  for i = 1, nbins do
    local freq = freq_for_bin(i, fft_size, sr)

    if freq <= 0 then
      out[i] = arr[i] or 0.0
    else
      local f1 = freq / (2 ^ half_oct)
      local f2 = freq * (2 ^ half_oct)

      local bin1 = math.floor((f1 / sr) * fft_size + 1)
      local bin2 = math.ceil((f2 / sr) * fft_size + 1)

      bin1 = clamp(bin1, 1, nbins)
      bin2 = clamp(bin2, 1, nbins)

      local sum = 0.0
      local count = 0

      for k = bin1, bin2 do
        sum = sum + (arr[k] or 0.0)
        count = count + 1
      end

      out[i] = count > 0 and (sum / count) or (arr[i] or 0.0)
    end
  end

  return out
end

local function read_payload()
  local fft_size = math.floor(reaper.gmem_read(0) or 0)
  local nbins = math.floor(reaper.gmem_read(1) or 0)
  local frames = math.floor(reaper.gmem_read(2) or 0)
  local valid = math.floor(reaper.gmem_read(4) or 0)
  local sr = reaper.gmem_read(5) or 44100

  local total_corr = reaper.gmem_read(6) or 0.0
  local rmsL_db    = reaper.gmem_read(7) or 0.0
  local rmsR_db    = reaper.gmem_read(8) or 0.0
  local diff_r_db  = reaper.gmem_read(9) or 0.0
  local peakL_db   = reaper.gmem_read(10) or 0.0
  local peakR_db   = reaper.gmem_read(11) or 0.0
  local crestL_db  = reaper.gmem_read(12) or 0.0
  local crestR_db  = reaper.gmem_read(13) or 0.0

  local payload = {
    valid = false,
    fft_size = fft_size,
    nbins = nbins,
    frames = frames,
    sr = sr,

    total_corr = total_corr,
    rmsL_db = rmsL_db,
    rmsR_db = rmsR_db,
    diff_r_db = diff_r_db,
    peakL_db = peakL_db,
    peakR_db = peakR_db,
    crestL_db = crestL_db,
    crestR_db = crestR_db,

    left = {},
    right = {},
    stereo = {},
    corr = {},
    mid = {},
    side = {},
  }

  if valid ~= 1 or fft_size <= 0 or nbins <= 0 then
    return payload
  end

  local base_left   = 16
  local base_right  = base_left + nbins
  local base_stereo = base_right + nbins
  local base_corr   = base_stereo + nbins
  local base_mid    = base_corr + nbins
  local base_side   = base_mid + nbins

  for i = 1, nbins do
    payload.left[i]   = reaper.gmem_read(base_left   + (i - 1)) or 0.0
    payload.right[i]  = reaper.gmem_read(base_right  + (i - 1)) or 0.0
    payload.stereo[i] = reaper.gmem_read(base_stereo + (i - 1)) or 0.0
    payload.corr[i]   = reaper.gmem_read(base_corr   + (i - 1)) or 0.0
    payload.mid[i]    = reaper.gmem_read(base_mid    + (i - 1)) or 0.0
    payload.side[i]   = reaper.gmem_read(base_side   + (i - 1)) or 0.0
  end

  payload.valid = true
  return payload
end

local function draw_line(draw_list, x1, y1, x2, y2, col, th)
  reaper.ImGui_DrawList_AddLine(draw_list, x1, y1, x2, y2, col, th or 1.0)
end

local function draw_rect(draw_list, x1, y1, x2, y2, col)
  reaper.ImGui_DrawList_AddRect(draw_list, x1, y1, x2, y2, col, 0.0, 0, 1.0)
end

local function draw_rect_filled(draw_list, x1, y1, x2, y2, col)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x1, y1, x2, y2, col, 0.0, 0)
end

local token_dot_until = 0.0

local function draw_token_dot(draw_list, win_x, win_y, win_w, win_h)
  local now = reaper.time_precise()
  local remaining = token_dot_until - now
  if remaining <= 0.0 then return end

  local fade = clamp(remaining / TOKEN_DOT_TTL, 0.0, 1.0)
  local alpha = math.floor((0.35 + 0.65 * fade) * 255 + 0.5)
  local col = 0x9999FF00 + alpha

  local cx = win_x + 6
  local cy = win_y + win_h - 10
  reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, TOKEN_DOT_RADIUS, col, 16)
end

local function value_to_y(v, minv, maxv, plot_y, plot_h)
  local t = (v - minv) / (maxv - minv)
  return plot_y + (1.0 - t) * plot_h
end

local function y_to_value(y, minv, maxv, plot_y, plot_h)
  local t = 1.0 - ((y - plot_y) / plot_h)
  return minv + (t * (maxv - minv))
end

local function corr_to_y(v, plot_y, plot_h)
  local t = (clamp(v, CORR_BOTTOM, CORR_TOP) - CORR_BOTTOM) / (CORR_TOP - CORR_BOTTOM)
  return plot_y + (1.0 - t) * plot_h
end

local function draw_grid(draw_list, plot_x, plot_y, plot_w, plot_h, is_corr_tab)
  local col_bg = 0x333333FF
  local col_border = col_bg
  local col_grid = 0x99999959
  local col_zero = 0xFFFFFFFF

  draw_rect_filled(draw_list, plot_x, plot_y, plot_x + plot_w, plot_y + plot_h, col_bg)
  draw_rect(draw_list, plot_x, plot_y, plot_x + plot_w, plot_y + plot_h, col_border)

  if is_corr_tab then
    local v = -1.0
    while v <= 1.0001 do
      local y = corr_to_y(v, plot_y, plot_h)
      local is_zero = math.abs(v) < 0.0001
      local col = is_zero and col_zero or col_grid
      local th = is_zero and 2.0 or 1.0
      draw_line(draw_list, plot_x, y, plot_x + plot_w, y, col, th)
      v = v + 0.25
    end
    return
  end

end

local function sample_spectrum_nearest(arr, fft_size, sr, nbins, freq)
  if not arr then return 0.0 end
  local binf = (freq / sr) * fft_size + 1.0
  local bin = math.floor(binf + 0.5)
  bin = clamp(bin, 1, nbins)
  return arr[bin] or 0.0
end

local function draw_curve(draw_list, arr, fft_size, sr, nbins, plot_x, plot_y, plot_w, plot_h, minv, maxv, col, thickness, use_slope)
  if not arr then return end

  local min_freq = 20.0
  local max_freq = sr * 0.5
  if max_freq < min_freq then return end

  local log_min = math.log(min_freq, 10)
  local log_max = math.log(max_freq, 10)

  local prev_x, prev_y = nil, nil
  local steps = math.max(2, math.min(1024, math.floor(plot_w)))

  reaper.ImGui_DrawList_PushClipRect(draw_list, plot_x, plot_y, plot_x + plot_w, plot_y + plot_h, true)

  for px = 0, steps do
    local nx = px / steps
    local freq = 10 ^ (log_min + (log_max - log_min) * nx)

    local v = sample_spectrum_nearest(arr, fft_size, sr, nbins, freq)
    if use_slope then
      v = apply_slope(v, freq)
    end

    local x = plot_x + nx * plot_w
    local y = value_to_y(v, minv, maxv, plot_y, plot_h)

    if prev_x then
      draw_line(draw_list, prev_x, prev_y, x, y, col, thickness)
    end

    prev_x, prev_y = x, y
  end

  reaper.ImGui_DrawList_PopClipRect(draw_list)
end

local function draw_corr_curve(draw_list, arr, fft_size, sr, nbins, plot_x, plot_y, plot_w, plot_h, col, thickness)
  if not arr then return end

  local min_freq = 20.0
  local max_freq = sr * 0.5
  if max_freq < min_freq then return end

  local log_min = math.log(min_freq, 10)
  local log_max = math.log(max_freq, 10)

  local prev_x, prev_y = nil, nil
  local steps = math.max(2, math.min(1024, math.floor(plot_w)))

  for px = 0, steps do
    local nx = px / steps
    local freq = 10 ^ (log_min + (log_max - log_min) * nx)
    local v = sample_spectrum_nearest(arr, fft_size, sr, nbins, freq)

    local x = plot_x + nx * plot_w
    local y = corr_to_y(v, plot_y, plot_h)

    if prev_x then
      draw_line(draw_list, prev_x, prev_y, x, y, col, thickness)
    end

    prev_x, prev_y = x, y
  end
end

local draw_value_pill
local draw_labeled_value

local function with_alpha(color, alpha)
  return math.floor(color / 0x100) * 0x100 + alpha
end

local function draw_centered_text(draw_list, x, y, w, h, col, text)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
  local tx = x + (w - tw) * 0.5
  local ty = y + (h - th) * 0.5 + 1
  reaper.ImGui_DrawList_AddText(draw_list, tx, ty, col, text)
end

local function draw_state_button(label, x, y, w, h, active, accent, enabled)
  if enabled == nil then enabled = true end

  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
  local text_col = 0xF2F2F2FF
  local col_btn = 0x333333FF

  if enabled and active and accent then
    col_btn = with_alpha(accent, 0x80)
  elseif enabled and active then
    col_btn = 0x404040FF
  end

  draw_rect_filled(draw_list, x, y, x + w, y + h, col_btn)
  draw_rect(draw_list, x, y, x + w, y + h, 0xFFFFFFFF)
  draw_centered_text(draw_list, x, y, w, h, text_col, label)

  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local pressed = reaper.ImGui_InvisibleButton(ctx, label, w, h)
  return enabled and pressed
end

local function clamp_spec_bounds()
  SPEC_CEIL_DB = clamp(SPEC_CEIL_DB, SPEC_FLOOR_MIN + SPEC_MIN_RANGE_DB, 0.0)
  SPEC_FLOOR_DB = clamp(SPEC_FLOOR_DB, SPEC_FLOOR_MIN, SPEC_CEIL_DB - SPEC_MIN_RANGE_DB)
end

local function format_spec_bound_value(value)
  local rounded = value >= 0 and math.floor(value + 0.5) or math.ceil(value - 0.5)
  if rounded <= 0 then
    return string.format("-%02d", math.abs(rounded))
  end
  return string.format("%02d", rounded)
end

local function parse_spec_bound_value(text)
  local normalized = (text or ""):gsub(",", ".")
  local value = tonumber(normalized)
  if not value then return nil end
  return value
end

local function commit_spec_hi_input()
  local value = parse_spec_bound_value(spec_hi_input)
  if value then
    if value > 0.0 then value = -value end
    SPEC_CEIL_DB = clamp(value, SPEC_FLOOR_DB + SPEC_MIN_RANGE_DB, 0.0)
    clamp_spec_bounds()
  end
  spec_hi_input = format_spec_bound_value(SPEC_CEIL_DB)
end

local function commit_spec_lo_input()
  local value = parse_spec_bound_value(spec_lo_input)
  if value then
    if value > 0.0 then value = -value end
    SPEC_FLOOR_DB = clamp(value, SPEC_FLOOR_MIN, SPEC_CEIL_DB - SPEC_MIN_RANGE_DB)
    clamp_spec_bounds()
  end
  spec_lo_input = format_spec_bound_value(SPEC_FLOOR_DB)
end

local function draw_bound_input(id, x, y, w, h, enabled)
  local input_ref = id == "##spec_hi" and spec_hi_input or spec_lo_input

  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_SetNextItemWidth(ctx, w)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 6, INPUT_FRAME_PAD_Y)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        0x333333FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x333333FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),  0x333333FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),         0xFFFFFFFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),           0xF0F0F0FF)

  local input_flags = reaper.ImGui_InputTextFlags_EnterReturnsTrue()
  local committed, new_value = reaper.ImGui_InputText(ctx, id, input_ref, input_flags)
  if id == "##spec_hi" then
    spec_hi_input = new_value
  else
    spec_lo_input = new_value
  end

  if enabled and (committed or reaper.ImGui_IsItemDeactivatedAfterEdit(ctx)) then
    if id == "##spec_hi" then
      commit_spec_hi_input()
    else
      commit_spec_lo_input()
    end
  end

  reaper.ImGui_PopStyleColor(ctx, 5)
  reaper.ImGui_PopStyleVar(ctx, 2)
end

local function draw_slope_input(x, y, w, h, enabled)
  if enabled then
    reaper.ImGui_SetCursorScreenPos(ctx, x, y)
    reaper.ImGui_SetNextItemWidth(ctx, w)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1.0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 6, INPUT_FRAME_PAD_Y)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        0x333333FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x333333FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),  0x333333FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),         0xFFFFFFFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),           0xF0F0F0FF)

    local input_flags = reaper.ImGui_InputTextFlags_EnterReturnsTrue()
                      | reaper.ImGui_InputTextFlags_CharsDecimal()
    local committed
    committed, slope_input = reaper.ImGui_InputText(ctx, "##slope_input", slope_input, input_flags)
    if committed or reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
      commit_slope_input()
    end

    reaper.ImGui_PopStyleColor(ctx, 5)
    reaper.ImGui_PopStyleVar(ctx, 2)
  else
    draw_state_button(format_slope_value(SLOPE_DB_PER_OCT), x, y, w, h, false, nil, false)
  end
end

local function draw_toolbar(content_x, content_y, content_w, cached, right_controls_x)
  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
  local x = content_x + 6
  local y = content_y + 6
  local h = BUTTON_H
  local gap = 4
  local spectrum_to_range_gap = 40
  local spectrum_controls_enabled = active_tab == 0
  local spectrum_group_w = 52 + gap + 52 + gap + 36 + gap + 36 + gap + 36 + gap + 36
  local spectrum_group_x = right_controls_x and (right_controls_x - spectrum_to_range_gap - spectrum_group_w) or x

  if draw_state_button("SPEC", x, y, 52, h, active_tab == 0, 0xFFFFFFFF) then
    active_tab = 0
  end
  x = x + 52 + gap

  if draw_state_button("PHCOR", x, y, 64, h, active_tab == 1, 0x9999FFFF) then
    active_tab = 1
  end
  x = x + 64 + gap

  if draw_state_button("VOL", x, y, 52, h, active_tab == 2, 0xFFFFFFFF) then
    active_tab = 2
  end

  local dr_text = cached.valid and string.format("%+06.2f", cached.diff_r_db or 0.0) or ""
  local c_text = cached.valid and string.format("%+06.2f", cached.total_corr or 0.0) or ""
  local dr_w = select(1, reaper.ImGui_CalcTextSize(ctx, "DR: +00.00")) + 12
  local c_w = select(1, reaper.ImGui_CalcTextSize(ctx, "C: +00.00")) + 12
  local values_w = dr_w + gap + c_w
  local values_x = content_x + (content_w - values_w) * 0.5

  draw_labeled_value(draw_list, values_x, y, "DR:", dr_text, "DR: +00.00")
  draw_labeled_value(draw_list, values_x + dr_w + gap, y, "C:", c_text, "C: +00.00")

  if active_tab == 0 then
    x = spectrum_group_x

    if draw_state_button("PEAK", x, y, 52, h, spectrum_peak_mode, 0xFFFFFFFF, spectrum_controls_enabled) then
      spectrum_peak_mode = not spectrum_peak_mode
      write_spectrum_mode()
    end
    x = x + 52 + gap

    if draw_state_button("LR", x, y, 52, h, show_stereo, 0xE6E6E6FF, spectrum_controls_enabled) then
      show_stereo = not show_stereo
    end
    x = x + 52 + gap

    if draw_state_button("L", x, y, 36, h, show_left, 0x99CC99FF, spectrum_controls_enabled) then
      show_left = not show_left
    end
    x = x + 36 + gap

    if draw_state_button("R", x, y, 36, h, show_right, 0xFF9999FF, spectrum_controls_enabled) then
      show_right = not show_right
    end
    x = x + 36 + gap

    if draw_state_button("M", x, y, 36, h, show_mid, 0x99CCCCFF, spectrum_controls_enabled) then
      show_mid = not show_mid
    end
    x = x + 36 + gap

    if draw_state_button("S", x, y, 36, h, show_side, 0xFFCC99FF, spectrum_controls_enabled) then
      show_side = not show_side
    end
  end
end

draw_value_pill = function(draw_list, x, y, text)
  local text_col = 0xF2F2F2FF
  local border = 0xFFFFFFFF

  local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
  draw_rect(draw_list, x, y, x + tw + 16, y + th + 8, border)
  draw_centered_text(draw_list, x, y, tw + 16, th + 8, text_col, text)

  return tw + 16, th + 8
end

draw_labeled_value = function(draw_list, x, y, label, value, sample)
  local text_col = 0xF2F2F2FF
  local border = 0xFFFFFFFF
  local label_w = select(1, reaper.ImGui_CalcTextSize(ctx, label))
  local sample_w = select(1, reaper.ImGui_CalcTextSize(ctx, sample))
  local w = sample_w + 12
  local h = BUTTON_H

  draw_rect(draw_list, x, y, x + w, y + h, border)
  local _, th = reaper.ImGui_CalcTextSize(ctx, sample)
  local ty = y + (h - th) * 0.5 + 1
  reaper.ImGui_DrawList_AddText(draw_list, x + 6, ty, text_col, label)
  reaper.ImGui_DrawList_AddText(draw_list, x + label_w + 10, ty, text_col, value)

  return w, h
end

local last_token = -1
local cached = read_payload()

local smooth_left = {}
local smooth_right = {}
local smooth_stereo = {}
local smooth_corr = {}
local smooth_mid = {}
local smooth_side = {}

local function rebuild_smoothed()
  if cached.valid then
    smooth_left   = smooth_octave(cached.left,   cached.fft_size, cached.sr, cached.nbins, SMOOTH_FRACTION)
    smooth_right  = smooth_octave(cached.right,  cached.fft_size, cached.sr, cached.nbins, SMOOTH_FRACTION)
    smooth_stereo = smooth_octave(cached.stereo, cached.fft_size, cached.sr, cached.nbins, SMOOTH_FRACTION)
    smooth_corr   = smooth_octave(cached.corr,   cached.fft_size, cached.sr, cached.nbins, SMOOTH_FRACTION)
    smooth_mid    = smooth_octave(cached.mid,    cached.fft_size, cached.sr, cached.nbins, SMOOTH_FRACTION)
    smooth_side   = smooth_octave(cached.side,   cached.fft_size, cached.sr, cached.nbins, SMOOTH_FRACTION)
  else
    smooth_left = {}
    smooth_right = {}
    smooth_stereo = {}
    smooth_corr = {}
    smooth_mid = {}
    smooth_side = {}
  end
end

rebuild_smoothed()

local function loop()
  reaper.ImGui_SetNextWindowSize(ctx, WIN_W, WIN_H, reaper.ImGui_Cond_Once())

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 4, 2)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 4, 4)

  local window_flags =
      reaper.ImGui_WindowFlags_NoScrollbar()
    | reaper.ImGui_WindowFlags_NoResize()
    | reaper.ImGui_WindowFlags_NoCollapse()

  local visible, open = reaper.ImGui_Begin(ctx, SCRIPT_NAME, true, window_flags)

  if visible then
    reaper.ImGui_PushFont(ctx, font_menu, FONT_SIZE)

    local token = math.floor(reaper.gmem_read(3) or 0)
    if token ~= last_token then
      if last_token >= 0 then
        token_dot_until = reaper.time_precise() + TOKEN_DOT_TTL
      end
      cached = read_payload()
      last_token = token
      rebuild_smoothed()
    end

    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    local content_x, content_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)

    local win_x, win_y = reaper.ImGui_GetWindowPos(ctx)
    local win_w, win_h = reaper.ImGui_GetWindowSize(ctx)

    local plot_x = content_x
    local plot_y = content_y + 38
    local plot_w = avail_w
    local plot_h = avail_h - 38
    if plot_h < 1 then plot_h = 1 end

    local col_cross = 0xFFFFFF2E

    local range_btn_w = 44
    local range_btn_x = plot_x + plot_w - range_btn_w - 10

    draw_rect_filled(draw_list, content_x, content_y, content_x + avail_w, plot_y, 0x333333FF)
    draw_toolbar(content_x, content_y, avail_w, cached, range_btn_x)

	    if active_tab == 0 then
	      local minv, maxv = SPEC_FLOOR_DB, SPEC_CEIL_DB
	      draw_grid(draw_list, plot_x, plot_y, plot_w, plot_h, false)

      if cached.valid then
        local col_left    = 0x99CC99FF
        local col_right   = 0xFF9999FF
        local col_stereo  = 0xE6E6E6FF
        local col_mid     = 0x99CCCCFF
        local col_side    = 0xFFCC99FF

        if show_left then
          draw_curve(draw_list, smooth_left, cached.fft_size, cached.sr, cached.nbins,
            plot_x, plot_y, plot_w, plot_h, minv, maxv, col_left, 2.0, true)
        end

        if show_right then
          draw_curve(draw_list, smooth_right, cached.fft_size, cached.sr, cached.nbins,
            plot_x, plot_y, plot_w, plot_h, minv, maxv, col_right, 2.0, true)
        end

        if show_stereo then
          draw_curve(draw_list, smooth_stereo, cached.fft_size, cached.sr, cached.nbins,
            plot_x, plot_y, plot_w, plot_h, minv, maxv, col_stereo, 2.0, true)
        end

        if show_mid then
          draw_curve(draw_list, smooth_mid, cached.fft_size, cached.sr, cached.nbins,
            plot_x, plot_y, plot_w, plot_h, minv, maxv, col_mid, 2.0, true)
        end

        if show_side then
          draw_curve(draw_list, smooth_side, cached.fft_size, cached.sr, cached.nbins,
            plot_x, plot_y, plot_w, plot_h, minv, maxv, col_side, 2.0, true)
        end
      end

      local range_btn_h = BUTTON_H
      local range_hi_y = content_y + 6
      local range_lo_y = plot_y + plot_h - range_btn_h - 10
      local range_slope_y = range_hi_y + (range_lo_y - range_hi_y - range_btn_h) * 0.5
      local plot_mouse_w = math.max(1, plot_w - range_btn_w - 20)

      reaper.ImGui_SetCursorScreenPos(ctx, plot_x, plot_y)
      reaper.ImGui_InvisibleButton(ctx, "plot_mouse_zone_spectrum", plot_mouse_w, plot_h)

      local mx, my = reaper.ImGui_GetMousePos(ctx)
      local inside = mx >= plot_x and mx <= plot_x + plot_w
        and my >= plot_y and my <= plot_y + plot_h

      if inside and cached.valid then
        draw_line(draw_list, mx, plot_y, mx, plot_y + plot_h, col_cross, 1.0)
        draw_line(draw_list, plot_x, my, plot_x + plot_w, my, col_cross, 1.0)
      end

      if cached.valid and inside then
        local freq = freq_from_plot_x(mx, plot_x, plot_w, cached.sr)
        local freq_text = format_freq_text(freq)
        local level_value = y_to_value(my, minv, maxv, plot_y, plot_h)

        local text_col = 0xF2F2F2FF
        local bg_col = 0x00000000

        local tw, th = reaper.ImGui_CalcTextSize(ctx, freq_text)
        local tx = plot_x + 10
        local ty = plot_y + plot_h - th - 10

        draw_rect_filled(draw_list, tx - 4, ty - 2, tx + tw + 4, ty + th + 2, bg_col)
        reaper.ImGui_DrawList_AddText(draw_list, tx, ty, text_col, freq_text)

        local level_text = string.format("%.2f", level_value)
        local level_w, level_h = reaper.ImGui_CalcTextSize(ctx, level_text)
        local level_x = plot_x + plot_w - range_btn_w - level_w - 20
        local level_y = plot_y + 10

        draw_rect_filled(draw_list, level_x - 4, level_y - 2, level_x + level_w + 4, level_y + level_h + 2, bg_col)
        reaper.ImGui_DrawList_AddText(draw_list, level_x, level_y, text_col, level_text)
      end

      draw_bound_input("##spec_hi", range_btn_x, range_hi_y, range_btn_w, range_btn_h, true)
      draw_slope_input(range_btn_x, range_slope_y, range_btn_w, range_btn_h, true)
      draw_bound_input("##spec_lo", range_btn_x, range_lo_y, range_btn_w, range_btn_h, true)

    elseif active_tab == 1 then
      draw_grid(draw_list, plot_x, plot_y, plot_w, plot_h, true)

      if cached.valid then
        local col_corr = 0x9999FFFF
        draw_corr_curve(draw_list, smooth_corr, cached.fft_size, cached.sr, cached.nbins,
          plot_x, plot_y, plot_w, plot_h, col_corr, 2.0)
      end

      reaper.ImGui_SetCursorScreenPos(ctx, plot_x, plot_y)
      reaper.ImGui_InvisibleButton(ctx, "plot_mouse_zone_corr", plot_w, plot_h)

      local mx, my = reaper.ImGui_GetMousePos(ctx)
      local inside = mx >= plot_x and mx <= plot_x + plot_w
        and my >= plot_y and my <= plot_y + plot_h

      if inside then
        local wheel = reaper.ImGui_GetMouseWheel(ctx)
        if wheel ~= 0.0 then
          CORR_BOTTOM = clamp(
            CORR_BOTTOM + wheel * CORR_SCROLL_STEP,
            CORR_BOTTOM_MIN,
            CORR_BOTTOM_MAX
          )
        end
      end

      if inside and cached.valid then
        draw_line(draw_list, mx, plot_y, mx, plot_y + plot_h, col_cross, 1.0)
        draw_line(draw_list, plot_x, my, plot_x + plot_w, my, col_cross, 1.0)
      end

      if cached.valid and inside then
        local freq = freq_from_plot_x(mx, plot_x, plot_w, cached.sr)
        local freq_text = format_freq_text(freq)

        local text_col = 0xF2F2F2FF
        local bg_col = 0x00000000

        local tw, th = reaper.ImGui_CalcTextSize(ctx, freq_text)
        local tx = plot_x + 10
        local ty = plot_y + plot_h - th - 10

        draw_rect_filled(draw_list, tx - 4, ty - 2, tx + tw + 4, ty + th + 2, bg_col)
        reaper.ImGui_DrawList_AddText(draw_list, tx, ty, text_col, freq_text)
      end

    else
      local bg = 0x333333FF
      local border = 0x2E2E33FF

      draw_rect_filled(draw_list, plot_x, plot_y, plot_x + plot_w, plot_y + plot_h, bg)
      draw_rect(draw_list, plot_x, plot_y, plot_x + plot_w, plot_y + plot_h, border)

      local panel_x = plot_x + 18
      local panel_y = plot_y + 52

      if cached.valid then
        local label_col = 0xBFBFCCFF

        local col_w = 200
        local x1 = panel_x + 20
        local x2 = x1 + col_w
        local x3 = x2 + col_w
        local x4 = x3 + col_w

        local y1 = panel_y + 20
        local y2 = y1 + 40

        local function row(x, y, label, value)
          reaper.ImGui_DrawList_AddText(draw_list, x, y, label_col, label)
          draw_value_pill(draw_list, x + 80, y - 4, value)
        end

        row(x1, y1, "RMS-L",   string.format("%+06.2f", cached.rmsL_db   or 0.0))
        row(x1, y2, "RMS-R",   string.format("%+06.2f", cached.rmsR_db   or 0.0))

        row(x2, y1, "PEAK-L",  string.format("%+06.2f", cached.peakL_db  or 0.0))
        row(x2, y2, "PEAK-R",  string.format("%+06.2f", cached.peakR_db  or 0.0))

        row(x3, y1, "CREST-L", string.format("%+06.2f", cached.crestL_db or 0.0))
        row(x3, y2, "CREST-R", string.format("%+06.2f", cached.crestR_db or 0.0))

        row(x4, y1, "RMS-D-R", string.format("%+06.2f", cached.diff_r_db or 0.0))
      end
    end

    draw_token_dot(draw_list, win_x, win_y, win_w, win_h)

    reaper.ImGui_PopFont(ctx)
    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopStyleVar(ctx, 4)

  if open then
    reaper.defer(loop)
  else
    reaper.ImGui_DestroyContext(ctx)
  end
end

reaper.defer(loop)
