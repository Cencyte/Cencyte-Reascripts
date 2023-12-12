--[[
    @Modified by: Cencyte 
    @Original Author(s): Zaibuyidao
    @Date Created: 11-17-23
    @Description: Selects Note Under Mouse Cursor
    @Version: 1.0
    @License: MIT
]]

EVENT_NOTE_START = 9
EVENT_NOTE_END = 8
EVENT_ARTICULATION = 15
local events
local midi
function print(...)
    local params = {...}
    for i = 1, #params do
        if i ~= 1 then reaper.ShowConsoleMsg(" ") end
        reaper.ShowConsoleMsg(tostring(params[i]))
    end
    reaper.ShowConsoleMsg("\n")
end

function table.print(t)
    local print_r_cache = {}
    local function sub_print_r(t, indent)
        if (print_r_cache[tostring(t)]) then
            print(indent .. "*" .. tostring(t))
        else
            print_r_cache[tostring(t)] = true
            if (type(t) == "table") then
                for pos, val in pairs(t) do
                    if (type(val) == "table") then
                        print(indent .. "[" .. tostring(pos) .. "] => " .. tostring(t) .. " {")
                        sub_print_r(val, indent .. string.rep(" ", string.len(tostring(pos)) + 8))
                        print(indent .. string.rep(" ", string.len(tostring(pos)) + 6) .. "}")
                    elseif (type(val) == "string") then
                        print(indent .. "[" .. tostring(pos) .. '] => "' .. val .. '"')
                    else
                        print(indent .. "[" .. tostring(pos) .. "] => " .. tostring(val))
                    end
                end
            else
                print(indent .. tostring(t))
            end
        end
    end
    if (type(t) == "table") then
        print(tostring(t) .. " {")
        sub_print_r(t, "  ")
        print("}")
    else
        sub_print_r(t, "  ")
    end
end

function Open_URL(url)
    if not OS then local OS = reaper.GetOS() end
    if OS=="OSX32" or OS=="OSX64" then
        os.execute("open ".. url)
    else
        os.execute("start ".. url)
    end
end

if not reaper.SN_FocusMIDIEditor then
    local retval = reaper.ShowMessageBox("This script needs SWS to expand, do you want to download it now?", "Warning", 1)
    if retval == 1 then
        Open_URL("http://www.sws-extension.org/download/pre-release/")
    end
end

local function clone(object)
  local lookup_table = {}
  local function _copy(object)
      if type(object) ~= "table" then
          return object
      elseif lookup_table[object] then
          return lookup_table[object]
      end
      local new_table = {}
      lookup_table[object] = new_table
      for key, value in pairs(object) do
          new_table[_copy(key)] = _copy(value)
      end
      return setmetatable(new_table, getmetatable(object))
  end
  return _copy(object)
end

local EventMeta = {
  __index = function (event, key)
    if (key == "selected") then
      return event.flags & 1 == 1
    elseif key == "pitch" then
      return event.msg:byte(2)
    elseif key == "Velocity" then
      return event.msg:byte(3)
    elseif key == "type" then
      return event.msg:byte(1) >> 4
    elseif key == "articulation" then
      return event.msg:byte(1) >> 4
    end
  end,
  __newindex = function (event, key, value)
    if key == "pitch" then
      event.msg = string.pack("BBB", event.msg:byte(1), value or event.msg:byte(2), event.msg:byte(3))
    elseif key == "Velocity" then
      event.msg = string.pack("BBB", event.msg:byte(1), event.msg:byte(2), value or event.msg:byte(3))
    end
  end
}

function setAllEvents(take, events)
    local lastPos = 0
    for _, event in pairs(events) do
        event.offset = event.pos - lastPos
        lastPos = event.pos
    end

    local tab = {}
    for _, event in pairs(events) do
        table.insert(tab, string.pack("i4Bs4", event.offset, event.flags, event.msg))
    end
    reaper.MIDI_SetAllEvts(take, table.concat(tab))
end

function getAllEvents(take, onEach)
    local events = {}
    local _, MIDIstring = reaper.MIDI_GetAllEvts(take, "")
    local stringPos = 1
    local lastPos = 0
    while stringPos <= MIDIstring:len() do
        local offset, flags, msg
        offset, flags, msg, stringPos = string.unpack("i4Bs4", MIDIstring, stringPos)
        local event = setmetatable({
            offset = offset,
            pos = lastPos + offset,
            flags = flags,
            msg = msg
        }, EventMeta)
        table.insert(events, event)
        onEach(event)
        lastPos = lastPos + offset
    end
    return events
end

function getAllTakes()
  tTake = {}
  if reaper.MIDIEditor_EnumTakes then
    local editor = reaper.MIDIEditor_GetActive()
    for i = 0, math.huge do
        take = reaper.MIDIEditor_EnumTakes(editor, i, false)
        if take and reaper.ValidatePtr2(0, take, "MediaItem_Take*") then 
          tTake[take] = true
          tTake[take] = {item = reaper.GetMediaItemTake_Item(take)}
        else
            break
        end
    end
  else
    for i = 0, reaper.CountMediaItems(0)-1 do
      local item = reaper.GetMediaItem(0, i)
      local take = reaper.GetActiveTake(item)
      if reaper.ValidatePtr2(0, take, "MediaItem_Take*") and reaper.TakeIsMIDI(take) and reaper.MIDI_EnumSelNotes(take, -1) == 0 then -- Get potential takes that contain notes. NB == 0 
        tTake[take] = true
      end
    end
  
    for take in next, tTake do
      if reaper.MIDI_EnumSelNotes(take, -1) ~= -1 then tTake[take] = nil end
    end
  end
  if not next(tTake) then return end
  return tTake
end

local sourceLengthTicks = reaper.BR_GetMidiSourceLenPPQ(take)
local notes = {}
local noteLastEventAtPitch = {}
local articulationEventAtPitch = {}
local switch = false
function main(div, take)
    if div == nil then return end
    reaper.MIDI_DisableSort(take)    
    if div == 1 and switch == false then
    events = getAllEvents(take, function(event)
      if event.type == EVENT_NOTE_START then
          noteLastEventAtPitch[event.pitch] = event
      elseif event.type == EVENT_NOTE_END then
          local head = noteLastEventAtPitch[event.pitch]
          if head == nil then error("The notes overlap and cannot be analyzed") end
          local tail = event
          if event.selected and div <= tail.pos - head.pos then
              table.insert(notes, {
                  head = head,
                  tail = tail,
                  articulation = articulationEventAtPitch[event.pitch],
                  pitch = event.pitch
              })
          end
          noteLastEventAtPitch[event.pitch] = nil
          articulationEventAtPitch[event.pitch] = nil
      elseif event.type == EVENT_ARTICULATION then
          if event.msg:byte(1) == 0xFF and not (event.msg:byte(2) == 0x0F) then
              -- text event
          elseif event.msg:find("articulation") then
              local chan, pitch = event.msg:match("NOTE (%d+) (%d+) ")
              articulationEventAtPitch[tonumber(pitch)] = event
          end
      end
  end)
  switch = true
elseif div >= 1 and switch == true then
end

    local skipEvents = {}
    local replacementForEvent = {}
    local copyAritulationForEachNote = false -- If it is true, each piece of the cut will be accompanied by the original symbol information
    for _, note in ipairs(notes) do
      local replacement = {}
      skipEvents[note.head] = true
      skipEvents[note.tail] = true
      local len = note.tail.pos - note.head.pos
      local len_div = math.floor(len / div) 
      local mult_len = note.head.pos + div * len_div 
      local first = true -- Is it the first note after cutting
      for j = 1, div do
        local newNote = clone(note)
        newNote.head.pos = note.head.pos + (j - 1) * len_div
        newNote.tail.pos = note.head.pos + (j - 1) * len_div + len_div
        if newNote.articulation then newNote.articulation.pos = newNote.head.pos end
        table.insert(replacement, newNote.head)
        if first or copyAritulationForEachNote then
          table.insert(replacement, newNote.articulation)
        end
        table.insert(replacement, newNote.tail)
        first = false
      end
      if mult_len < note.tail.pos then
        local newNote = clone(note)
        newNote.head.pos = note.head.pos + div * len_div  
        newNote.tail.pos = note.tail.pos
        if newNote.articulation then newNote.articulation.pos = newNote.head.pos end
        table.insert(replacement, newNote.head)
        if first or copyAritulationForEachNote then
          table.insert(replacement, newNote.articulation)
        end
        table.insert(replacement, newNote.tail)
        first = false
      end
      replacementForEvent[note.tail] = replacement
    end
    local newEvents = {}
    local last = events[#events]
    table.remove(events, #events) -- All-Note-Off
    for _, event in ipairs(events) do
      if replacementForEvent[event] then
        for _, e in ipairs(replacementForEvent[event]) do table.insert(newEvents, e) end
      end
      if not skipEvents[event] then
        table.insert(newEvents, event)
      end
    end
    table.insert(newEvents, last) -- All-Note-Off
    table.insert(events, last) -- All-Note-Off
    setAllEvents(take, newEvents)
    reaper.MIDI_Sort(take)
end

  local dy_prev
  local div_prev
  local yprev
  local time
  local time2
  local p_time
  local p_time2
  local next_Int
  local div = 1
  local y_origin
  local midiview = reaper.JS_Window_Find('midiview', true)
  local Hwnd_At_Cursor = reaper.JS_Window_FromPoint(reaper.GetMousePosition())
  local cursor_Int = 10
  local mouseMsg = {}
  local EventMeta2 = {
    __index = function(mouseMsg, key)
       if string.match(key, "^0x%d%d%d%d$") then
          local v1, v2, v3, v4, v5, v6, v7 = reaper.JS_WindowMessage_Peek(Hwnd_At_Cursor, key) --passthrough = true
          local mouseMsg =  { OK = v1, pt = v2 , time = v3, ID = v4, wHigh = v5, x = v6, y = v7 }
          mouseMsg[key] = key
          return mouseMsg
       end
      if key == "OK" then
        return mouseMsg[key].OK
      elseif key == "pt" then
        return mouseMsg[key].pt
      elseif key == "time" then
        return mouseMsg[key].time
      elseif key == "ID" then
        return mouseMsg[key].ID
      elseif key == "wHigh" then
        return mouseMsg[key].wHigh
      elseif key == "x" then
        return mouseMsg[key].x
      elseif key == "y" then
        return mouseMsg[key].y
      end
  end, 
  __newIndex = function(mouseMsg, key, value)
  if key == "intercept" then
    reaper.JS_WindowMessage_Intercept(Hwnd_At_Cursor, value, true)
  elseif key == "release" then
    reaper.JS_WindowMessage_Release(Hwnd_At_Cursor, value, true)
  end
  end,
  __call = function(self, args)
    reaper.JS_WindowMessage_Intercept(Hwnd_At_Cursor, tostring(args), true)
    local v1, v2, v3, v4, v5, v6, v7 = reaper.JS_WindowMessage_Peek(Hwnd_At_Cursor, tostring(args)) --passthrough = true 
    local mouseMsg =  { OK = v1, pt = v2 , time = v3, ID = v4, wHigh = v5, x = v6, y = v7 }
    for k, v in pairs(mouseMsg) do
      if mouseMsg[v].OK then 
        print(args)
        return { OK = v1, pt = v2 , time = v3, ID = v4, wHigh = v5, x = v6, y = v7 }
      end
  end
  end
  } 
  local KeyCodes = { 
    WM_LBUTTONDOWN   = '0x0201',
    WM_LBUTTONUP     = '0x0202',
    WM_LBUTTONDBLCLK = '0x0203',
    WM_MOUSEMOVE     = '0x0200'
    }
  setmetatable(mouseMsg, EventMeta2)
  y_origin = mouseMsg['0x0201'].y
  reaper.DeleteExtState("CC Script", "Released", true)
  reaper.DeleteExtState("CC Script", "Pressed", true)
  reaper.atexit(reaper.JS_WindowMessage_ReleaseAll())
for take, _ in pairs(getAllTakes()) do
  local _, MIDIstring = reaper.MIDI_GetAllEvts(take, "")
  local sourceLengthTicks = reaper.BR_GetMidiSourceLenPPQ(take)
  if not (sourceLengthTicks == reaper.BR_GetMidiSourceLenPPQ(take)) then
    reaper.MIDI_SetAllEvts(take, MIDIstring)
    reaper.ShowMessageBox("The script caused the event to move, and the original MIDI data has been restored", "Error", 0)
  end
  local function OnRelease()
    local time2 = mouseMsg['0x0202'].time
    if p_time2 then print("p_time2 is: " .. p_time2) end
    if mouseMsg['0x0202'].OK and time2 ~= 0.0 and time2 ~= p_time2 and reaper.GetExtState("CC Script", "Pressed") then
      p_time2 = time2
      reaper.SetExtState("CC Script", "Released", "true", true)
      reaper.SetExtState("CC Script", "Pressed", "false", true)
    else 
      local ypos = mouseMsg['0x0200'].y
      if ypos ~= 0 then
      if ypos ~= yprev and mouseMsg['0x0200'].time ~= time then
        local _dy = y_origin - ypos 
        if _dy <= 0 then
          reaper.MIDI_SetAllEvts(take, MIDIstring)
        else
        local dy = math.abs(ypos - y_origin)
        local div = ((dy // cursor_Int) or 1); if div == 0 then div = 1 end
        if not next_Int or (div >= 1 and ((dy > next_Int) or (dy < (next_Int - cursor_Int)))) then 
          local dely = dy - (dy_prev or 0)
          local del_div = div - (div_prev or 0)
          local int_y = dely //  cursor_Int
          next_Int = ((div + 1) * cursor_Int)
          main(div, take)
        end
        div_prev = div
        dy_prev = dy
        yprev = ypos
        end
      end
    end
      if reaper.GetExtState("CC Script", "Released") == "" then
      reaper.defer(OnRelease)
      end
    end
end
  function InnerMain()
    local Hwnd_At_Cursor = reaper.JS_Window_FromPoint(reaper.GetMousePosition())
    local midiview = reaper.JS_Window_Find('midiview', true)
    if Hwnd_At_Cursor ~= midiview then
      error("Cursor outside boundary: midiview")
      return
    else
for k, v in pairs(KeyCodes) do
  if mouseMsg[v].OK == false then
    reaper.JS_WindowMessage_Intercept(Hwnd_At_Cursor, v, true)
  end
end
local time = mouseMsg['0x0201'].time 
if mouseMsg['0x0201'].OK and time ~= p_time then
      if reaper.GetExtState("CC Script", "Pressed") == "" then
        reaper.SetExtState("CC Script", "Pressed", "true", true)
        p_time = time
      end
      OnRelease()
    end
      if reaper.GetExtState("CC Script", "Released") == "true" then
        reaper.SetExtState("CC Script", "Released", "false", true)
        return
      end
    end
  reaper.defer(InnerMain)
  end
end
InnerMain()



