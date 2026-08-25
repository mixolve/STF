-- @description Dock first Monitoring FX editor as a separate docker tab
-- @version 1.3
-- @about
--   The first effect in the Monitoring FX chain is opened and placed in a
--   dedicated docker tab. The REAPER FX header is cropped above the docker.

local MONITOR_FX_OFFSET = 0x1000000
local DEFAULT_DOCKER = 0 -- bottom docker; move the tab afterwards if desired
local MAX_WAIT_CYCLES = 60
local CROP_TOP_PIXELS = 32
local EXTSTATE_SECTION = "custom_dock_first_monitoring_fx"
local run_token = tostring(reaper.time_precise())

-- A new invocation replaces the resize watcher created by an earlier one.
reaper.SetExtState(EXTSTATE_SECTION, "run_token", run_token, false)

if not reaper.APIExists("JS_Window_SetPosition") then
  reaper.ShowMessageBox(
    "This script requires js_ReaScriptAPI.\nRestart REAPER once after installing the extension.",
    "Dock Monitoring FX",
    0
  )
  return
end

-- Undo a window level that may have been left behind by older script versions.
-- This is a one-time correction, not part of the resize watcher.
reaper.JS_Window_SetZOrder(reaper.GetMainHwnd(), "NOTOPMOST")

local master = reaper.GetMasterTrack(0)
local monitoring_fx_count = reaper.TrackFX_GetRecCount(master)

if monitoring_fx_count == 0 then
  reaper.ShowMessageBox("Monitoring FX chain is empty.", "Dock Monitoring FX", 0)
  return
end

-- REAPER indexes the first FX in a chain as zero.
local selected_fx = 0

local fx_index = MONITOR_FX_OFFSET + selected_fx
local _, fx_name = reaper.TrackFX_GetFXName(master, fx_index, "")
local fx_guid = reaper.TrackFX_GetFXGUID(master, fx_index)
local dock_id = "custom_monitoring_fx_" .. (fx_guid or tostring(selected_fx))

-- The stable ID lets REAPER restore the docker placement chosen by the user.
if reaper.GetConfigWantsDock(dock_id) < 0 then
  reaper.Dock_UpdateDockID(dock_id, DEFAULT_DOCKER)
end

-- 3 opens this single FX editor as a floating window.
reaper.TrackFX_Show(master, fx_index, 3)

local wait_cycles = 0

-- The FX header and editor live inside one inner FX container. Move that
-- container up inside its *parent* docker client area. The parent clips the
-- 32 px header, while the editor naturally starts at the docker's top edge.
-- Moving the outer FX host would instead move the whole docker tab.
local function crop_fx_header(host)
  local count, addresses = reaper.JS_Window_ListAllChild(host, "")
  if count <= 0 then return end

  local fx_container
  local best_area = 0
  for address in addresses:gmatch("[^,]+") do
    local child = reaper.JS_Window_HandleFromAddress(address)
    local parent = reaper.JS_Window_GetParent(child)
    if parent == host then
      local child_ok, left, top, right, bottom = reaper.JS_Window_GetRect(child)
      if child_ok then
        local width = math.abs(right - left)
        local height = math.abs(bottom - top)
        if width * height > best_area then
          fx_container = child
          best_area = width * height
        end
      end
    end
  end

  if fx_container then
    -- Keep the crop while the docker is being resized. No Z-order changes are
    -- made, so REAPER does not become an always-on-top window.
    local function maintain_crop()
      if reaper.GetExtState(EXTSTATE_SECTION, "run_token") ~= run_token then return end
      if not reaper.ValidatePtr(fx_container, "HWND") then return end

      local parent = reaper.JS_Window_GetParent(fx_container)
      if not parent then return end
      local ok, left, top, right, bottom = reaper.JS_Window_GetRect(parent)
      if not ok then return end

      local width = math.abs(right - left)
      local height = math.abs(bottom - top)
      local child_ok, child_left, child_top, child_right, child_bottom =
        reaper.JS_Window_GetRect(fx_container)
      if not child_ok then return end

      -- ScreenToClient removes macOS's inverted screen Y-axis from the check.
      -- In parent-client coordinates the desired position is always (0, -32).
      local child_x, child_y = reaper.JS_Window_ScreenToClient(
        parent, child_left, child_top
      )
      local child_width = math.abs(child_right - child_left)
      local child_height = math.abs(child_bottom - child_top)
      local geometry_was_reset =
        math.abs(child_x) > 1 or
        math.abs(child_y + CROP_TOP_PIXELS) > 1 or
        math.abs(child_width - width) > 1 or
        math.abs(child_height - (height + CROP_TOP_PIXELS)) > 1

      if geometry_was_reset then
        -- Omitting Z-order arguments uses NOACTIVATE and NOZORDER internally.
        reaper.JS_Window_SetPosition(
          fx_container, 0, -CROP_TOP_PIXELS,
          width, height + CROP_TOP_PIXELS
        )
      end
      reaper.defer(maintain_crop)
    end
    maintain_crop()
  end
end

local function dock_editor()
  local hwnd = reaper.TrackFX_GetFloatingWindow(master, fx_index)
  if hwnd then
    local dock_index = reaper.DockIsChildOfDock(hwnd)
    if dock_index < 0 then
      reaper.DockWindowAddEx(hwnd, fx_name, dock_id, true)
    end
    reaper.DockWindowActivate(hwnd)
    reaper.DockWindowRefreshForHWND(hwnd)
    reaper.defer(function() crop_fx_header(hwnd) end)
    return
  end

  wait_cycles = wait_cycles + 1
  if wait_cycles < MAX_WAIT_CYCLES then
    reaper.defer(dock_editor)
  else
    reaper.ShowMessageBox(
      "REAPER did not create the FX editor window.\nTry opening the plug-in once manually, then run the action again.",
      "Dock Monitoring FX",
      0
    )
  end
end

reaper.defer(dock_editor)
