-- Set selected items volume to -inf

reaper.Undo_BeginBlock()

local cnt = reaper.CountSelectedMediaItems(0)

for i = 0, cnt - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    reaper.SetMediaItemInfo_Value(item, "D_VOL", 0.0)
    reaper.UpdateItemInProject(item)
end

reaper.Undo_EndBlock("Set selected items volume to -inf", -1)
reaper.UpdateArrange()
