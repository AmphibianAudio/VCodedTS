-- @description Song Structure Generator
-- @author AmphibianAudio
-- @version 1.0
-- @about
-- Генератор музыкальной структуры

-- ====== ReaImGui ======
if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("ReaImGui не установлен/старый. Установите через ReaPack (>= 0.10).", "ReaImGui", 0)
  return
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui
do
  local ok, err = pcall(function() ImGui = require('imgui')('0.10') end)
  if not ok or not ImGui then
    reaper.MB("ReaImGui не загрузился (нужен >= 0.10).\n" .. tostring(err), "ReaImGui", 0)
    return
  end
end

local FLT_MIN, FLT_MAX = ImGui.NumericLimits_Float()
local CF_BORDERS = ImGui.ChildFlags_Borders or 1
local FONT_SIZE  = 14
local EXT_SEC    = "IdeaPlatformGen2"
local EXT_KEY    = "state_v2"
local EXT_PRE    = "presets"

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function q(s) return string.format("%q", tostring(s)) end
local function dcopy(o) if type(o)=="table" then local c={} for k,v in pairs(o) do c[k]=dcopy(v) end return c end return o end
local function trim(s) return (tostring(s):match("^%s*(.-)%s*$")) end

-- ============ ДЕФОЛТЫ ============
local TS_FULL = { "4/4","3/4","2/4","6/8","9/8","12/8","5/4","7/4","11/4","13/4","5/8","7/8","11/8","13/8" }
local TON_FULL = { "C","C#","D","Eb","E","F","F#","G","Ab","A","Bb","B" }
local SCA_FULL = { "Major","Major pentatonic","Minor","Minor pentatonic","Harmonic Major","Melodic Major",
  "Harmonic Minor","Melodic Minor","Double Harmonic Major","Double Harmonic Minor","Whole-Tone",
  "Augmented 1","Augmented 2","Diminished 1","Diminished 2","Chromatic" }

local function vlist(names, ch) local t={} for i,n in ipairs(names) do t[i]={name=n, chance=ch} end return t end

-- Форма-запись: {name, link, bars(СТРОКА), appear, extra, tchg, schg, kchg, cchg}
local function defaultState()
  local s = {}
  s.tempo_min, s.tempo_max = 90, 140
  s.timesig = vlist(TS_FULL, 100)
  s.tonic   = vlist(TON_FULL, 100)
  s.scale   = vlist(SCA_FULL, 100)
  local raw = {
    {"Интро",     0, 8,100,40,0,0,0,0},
    {"Куплет 1",  0, 8,100,50,0,0,0,0},
    {"Пре-хорус", 0, 4, 70, 0,0,0,0,0},
    {"Хорус",     1, 8,100, 0,0,0,0,0},
    {"Пост-хорус",0, 4, 50, 0,0,0,0,0},
    {"Куплет 2",  0, 8, 80,50,0,0,0,0},
    {"Пре-хорус", 0, 4, 70, 0,0,0,0,0},
    {"Хорус",     1, 8,100, 0,0,0,0,0},
    {"Пост-хорус",0, 4, 50, 0,0,0,0,0},
    {"Бридж",     0, 8, 60,30,0,0,0,0},
    {"Соло",      0, 8, 45,25,0,0,0,0},
    {"Пре-хорус", 0, 4, 60, 0,0,0,0,0},
    {"Хорус",     1, 8,100, 0,0,0,0,0},
    {"Пост-хорус",0, 4, 60, 0,0,0,0,0},
    {"Оутро",     0, 8,100, 0,0,0,0,0},
  }
  s.form = {}
  for _, r in ipairs(raw) do
    s.form[#s.form+1] = { name=r[1], link=r[2], bars=tostring(r[3]), appear=r[4], extra=r[5],
                          tchg=r[6], schg=r[7], kchg=r[8], cchg=r[9] }
  end
  return s
end

local S = defaultState()
local MODE = "chances"
local dirty = false
local TS_LOOKUP = {}

local function rebuildTsLookup()
  TS_LOOKUP = {}
  for _, v in ipairs(S.timesig) do
    local n, d = v.name:match("(%d+)/(%d+)")
    if n then TS_LOOKUP[v.name] = { num=tonumber(n), den=tonumber(d) } end
  end
end
rebuildTsLookup()

-- ============ ПЕРСИСТЕНТНОСТЬ ============
local function serValues(list)
  local p = {}
  for i, v in ipairs(list) do p[i] = ("{name=%s,chance=%d}"):format(q(v.name), v.chance) end
  return "{" .. table.concat(p, ",") .. "}"
end

local function serForm(form)
  local p = {}
  for i, f in ipairs(form) do
    p[i] = ("{name=%s,link=%d,bars=%s,appear=%d,extra=%d,tchg=%d,schg=%d,kchg=%d,cchg=%d}")
      :format(q(f.name), f.link or 0, q(tostring(f.bars or "8")), f.appear, f.extra, f.tchg, f.schg, f.kchg, f.cchg)
  end
  return "{" .. table.concat(p, ",") .. "}"
end

local function saveState()
  if not reaper.SetExtState then return end
  local s = "return {\n"
  s = s .. ("tempo_min=%d,\ntempo_max=%d,\n"):format(S.tempo_min, S.tempo_max)
  s = s .. ("timesig=%s,\n"):format(serValues(S.timesig))
  s = s .. ("tonic=%s,\n"):format(serValues(S.tonic))
  s = s .. ("scale=%s,\n"):format(serValues(S.scale))
  s = s .. ("form=%s,\n"):format(serForm(S.form))
  s = s .. "}\n"
  reaper.SetExtState(EXT_SEC, EXT_KEY, s, true)
  dirty = false
end

-- ПОЛНАЯ замена списка сохранённым (а не merge в дефолтный).
-- Очищаем dst и переписываем из src — иначе удалённые/добавленные
-- значения теряются при перезапуске.
local function applyValues(dst, src)
  while #dst > 0 do dst[#dst] = nil end
  for _, sv in ipairs(src) do
    dst[#dst+1] = { name = sv.name, chance = sv.chance or 0 }
  end
end

-- ПОЛНАЯ замена формы сохранённой.
local function applyForm(dst, src)
  while #dst > 0 do dst[#dst] = nil end
  for _, sf in ipairs(src) do
    dst[#dst+1] = {
      name   = sf.name or "?",
      link   = sf.link or 0,
      bars   = tostring((sf.bars ~= nil and sf.bars) or "8"),
      appear = sf.appear or 100,
      extra  = sf.extra or 0,
      tchg   = sf.tchg or 0,
      schg   = sf.schg or 0,
      kchg   = sf.kchg or 0,
      cchg   = sf.cchg or 0,
    }
  end
end

local function loadState()
  if not reaper.GetExtState then return end
  local raw = reaper.GetExtState(EXT_SEC, EXT_KEY)
  if not raw or raw == "" then return end
  local fn = load(raw)
  if not fn then return end
  local ok, st = pcall(fn)
  if not ok or type(st) ~= "table" then return end
  if type(st.tempo_min)=="number" then S.tempo_min = st.tempo_min end
  if type(st.tempo_max)=="number" then S.tempo_max = st.tempo_max end
  if type(st.timesig)=="table" then applyValues(S.timesig, st.timesig) end
  if type(st.tonic)=="table"   then applyValues(S.tonic,   st.tonic)   end
  if type(st.scale)=="table"   then applyValues(S.scale,   st.scale)   end
  if type(st.form)=="table"    then applyForm(S.form, st.form)         end
  rebuildTsLookup()
end
loadState()

-- ============ ПРЕСЕТЫ ============
local function getPresetNames()
  local raw = reaper.GetExtState and reaper.GetExtState(EXT_SEC, EXT_PRE) or ""
  if raw == "" then return {} end
  local fn = load(raw)
  if not fn then return {} end
  local ok, t = pcall(fn)
  if not ok or type(t) ~= "table" then return {} end
  local names = {}
  for k in pairs(t) do names[#names+1] = k end
  table.sort(names)
  return names, t
end

local function savePresetRaw(t)
  local parts = {}
  for name, p in pairs(t) do
    parts[#parts+1] = ("[%s]={tempo_min=%d,tempo_max=%d,timesig=%s,tonic=%s,scale=%s,form=%s}")
      :format(q(name), p.tempo_min or 90, p.tempo_max or 140,
              serValues(p.timesig or {}), serValues(p.tonic or {}), serValues(p.scale or {}), serForm(p.form or {}))
  end
  reaper.SetExtState(EXT_SEC, EXT_PRE, "return {" .. table.concat(parts, ",") .. "}", true)
end

local function savePreset(name)
  local _, t = getPresetNames()
  t = t or {}
  local ok, err = pcall(function()
    t[name] = {
      tempo_min = S.tempo_min, tempo_max = S.tempo_max,
      timesig = dcopy(S.timesig), tonic = dcopy(S.tonic),
      scale = dcopy(S.scale), form = dcopy(S.form),
    }
    savePresetRaw(t)
  end)
  if not ok then
    statusText = "ОШИБКА сохранения пресета: " .. tostring(err)
    statusError = true
  end
  return ok
end

local function loadPreset(name)
  local _, t = getPresetNames()
  local p = t and t[name]
  if not p then return false end
  if type(p.tempo_min)=="number" then S.tempo_min = p.tempo_min end
  if type(p.tempo_max)=="number" then S.tempo_max = p.tempo_max end
  if type(p.timesig)=="table" then applyValues(S.timesig, p.timesig); rebuildTsLookup() end
  if type(p.tonic)=="table"   then applyValues(S.tonic,   p.tonic)   end
  if type(p.scale)=="table"   then applyValues(S.scale,   p.scale)   end
  if type(p.form)=="table" then
    applyForm(S.form, p.form)
  end
  saveState()
  return true
end

local function deletePreset(name)
  local _, t = getPresetNames()
  if not t then return end
  t[name] = nil
  savePresetRaw(t)
end

-- ============ РАЗБОР ПОЛЯ «ТАКТЫ» ============
-- "8" -> {8};  "4,8,16" -> {4,8,16};  "4-8" -> {4,5,6,7,8};
-- "4,6-8,16" -> {4,6,7,8,16}.  Разделители , ; диапазон - или –
local function parseBars(s)
  local result = {}
  for token in tostring(s):gmatch("[^,;]+") do
    local part = token:match("^%s*(.-)%s*$") or token
    if part ~= "" then
      local a, b = part:match("^(%d+)%s*[-–]%s*(%d+)$")
      if a and b then
        a, b = tonumber(a), tonumber(b)
        if a and b then
          local lo, hi = math.min(a, b), math.max(a, b)
          for v = lo, hi do result[#result+1] = v end
        end
      else
        local n = tonumber(part)
        if n then result[#result+1] = clamp(math.floor(n), 1, 999) end
      end
    end
  end
  if #result == 0 then return nil end
  local seen, uniq = {}, {}
  for _, v in ipairs(result) do
    if not seen[v] then seen[v] = true; uniq[#uniq+1] = v end
  end
  table.sort(uniq)
  return uniq
end

-- выбрать случайную длину из раскрытого набора; запас 8 при пустом/кривом вводе
local function pickBars(barsStr)
  local list = parseBars(barsStr)
  if not list or #list == 0 then return 8 end
  return list[math.random(1, #list)]
end

-- ============ ГЕНЕРАЦИЯ ============
local function roll(p) return math.random(1, 100) <= p end

local function weightedPick(list)
  local total = 0
  for _, it in ipairs(list) do if it.chance and it.chance > 0 then total = total + it.chance end end
  if total <= 0 then return nil end
  local r = math.random(1, total)
  local acc = 0
  for _, it in ipairs(list) do
    if it.chance and it.chance > 0 then
      acc = acc + it.chance
      if r <= acc then return it.name end
    end
  end
  return nil
end

local function tsOf(name)
  local ts = TS_LOOKUP[name]
  if ts then return ts end
  local n, d = name:match("(%d+)/(%d+)")
  return { num = tonumber(n) or 4, den = tonumber(d) or 4 }
end

-- HSV -> RGB (h,s,v в 0..1 → r,g,b в 0..255)
local function hsv2rgb(h, s, v)
  local i = math.floor(h * 6) % 6
  local f = h * 6 - math.floor(h * 6)
  local p = v * (1 - s)
  local q = v * (1 - f * s)
  local t = v * (1 - (1 - f) * s)
  local r, g, b
  if     i == 0 then r, g, b = v, t, p
  elseif i == 1 then r, g, b = q, v, p
  elseif i == 2 then r, g, b = p, v, t
  elseif i == 3 then r, g, b = p, q, v
  elseif i == 4 then r, g, b = t, p, v
  else               r, g, b = v, p, q
  end
  return math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5)
end

-- случайный «песенный» цвет: случайный тон, насыщенный и яркий — чтобы
-- отличать разные генерации (песни) на таймлайне.
local function randomSongColor()
  local r, g, b = hsv2rgb(math.random(), 0.7, 0.9)
  return reaper.ColorToNative(r, g, b) | 0x1000000
end

local statusText = ""
local statusError = false
local lastSongColor = 0   -- для дампа в консоль (цвет последней генерации)

-- значения секций: с учётом Δ-наследования и линков.
-- Линк: ПЕРВОЕ появление секции в группе фиксирует ВСЕ значения
-- (темп/размер/тоника/лад/длина в тактах); последующие залинкованные
-- секции повторяют их один-в-один.
local function buildSections()
  local out = {}
  local cur = { tempo=nil, timesig=nil, tonic=nil, scale=nil }
  local first = true
  local link_groups = {}  -- link_id -> {tempo,timesig,tonic,scale,bars}
  local tlo, thi = math.min(S.tempo_min, S.tempo_max), math.max(S.tempo_min, S.tempo_max)
  for _, sec in ipairs(S.form) do
    if roll(sec.appear) then
      local bars
      if sec.link and sec.link > 0 and link_groups[sec.link] then
        -- ЗАЛИНКОВАНО: повторяем ПЕРВОЕ появление полностью, включая такты
        local g = link_groups[sec.link]
        cur.tempo, cur.timesig, cur.tonic, cur.scale = g.tempo, g.timesig, g.tonic, g.scale
        bars = g.bars
      else
        -- ПЕРВОЕ появление в группе (или линка нет): генерируем значения
        if first or roll(sec.tchg) then cur.tempo = math.random(tlo, thi) end
        if first or roll(sec.schg) then cur.timesig = weightedPick(S.timesig) end
        if first or roll(sec.kchg) then cur.tonic   = weightedPick(S.tonic)   end
        if first or roll(sec.cchg) then cur.scale   = weightedPick(S.scale)   end
        bars = pickBars(sec.bars)
        if roll(sec.extra) then bars = bars + (math.random() < 0.5 and 1 or 2) end
        if sec.link and sec.link > 0 then
          link_groups[sec.link] = { tempo=cur.tempo, timesig=cur.timesig, tonic=cur.tonic, scale=cur.scale, bars=bars }
        end
      end
      first = false
      if not (cur.tempo and cur.timesig and cur.tonic and cur.scale) then
        return nil, "Не хватает значений: задайте шанс > 0 хотя бы одному Размеру, Тонике и Ладу."
      end
      local ts = tsOf(cur.timesig)
      out[#out+1] = { name=sec.name, tempo=cur.tempo, ts=ts, tonic=cur.tonic, scale=cur.scale, bars=bars }
    end
  end
  if #out == 0 then return nil, "Ни одна секция не появилась — поднимите шансы появления." end
  return out
end

local function sectionDuration(tempo, ts, bars)
  local bpb = ts.num
  if ts.den == 8 then bpb = bpb / 2 end
  return (60 / tempo) * bpb * bars
end

local function removeMarkersAtPosition(position)
  local n = reaper.CountProjectMarkers(0)
  local i = 0
  while i < n do
    local retval, isrgn, pos, rgnend, name, idx = reaper.EnumProjectMarkers(i)
    if retval >= 0 then
      if math.abs(pos - position) < 0.001 then
        reaper.DeleteProjectMarker(0, idx, isrgn); n = n - 1
      else i = i + 1 end
    else i = i + 1 end
  end
end

local function applyToProject(sections, showMsg)
  local cursor = reaper.GetCursorPosition()
  removeMarkersAtPosition(cursor)
  local songColor = randomSongColor()   -- один цвет на всю песню (генерацию)
  lastSongColor = songColor
  local pos = cursor
  local prev_t, prev_ts = nil, nil
  local prev_key = nil
  for _, sec in ipairs(sections) do
    if (not prev_t) or sec.tempo ~= prev_t or sec.ts.num ~= prev_ts.num or sec.ts.den ~= prev_ts.den then
      local ok = reaper.SetTempoTimeSigMarker(0, -1, pos, -1, -1, sec.tempo, sec.ts.num, sec.ts.den, false)
      if not ok then
        local _, measures, _, fullbeats = reaper.TimeMap2_timeToBeats(0, pos)
        reaper.AddTempoTimeSigMarker(0, pos, sec.tempo, fullbeats, measures, false, sec.ts.num, sec.ts.den, false)
      end
      prev_t, prev_ts = sec.tempo, sec.ts
    end
    local dur = sectionDuration(sec.tempo, sec.ts, sec.bars)
    local key = sec.tonic .. " " .. sec.scale
    if key ~= prev_key then
      reaper.AddProjectMarker2(0, false, pos, 0, key, -1, songColor)
      prev_key = key
    end
    reaper.AddProjectMarker2(0, true, pos, pos + dur, sec.name, -1, songColor)
    pos = pos + dur
  end
  reaper.GetSet_LoopTimeRange(true, false, cursor, pos, false)
  reaper.SetProjectGrid(0, 1 / (sections[1].ts.den))
  reaper.SetEditCurPos(pos, true, true)
  reaper.UpdateTimeline(); reaper.UpdateArrange()
  local first = sections[1]
  statusText = ("Сгенерировано секций: %d | старт %d BPM %d/%d | %s %s")
    :format(#sections, first.tempo, first.ts.num, first.ts.den, first.tonic, first.scale)
  statusError = false
  if showMsg then
    local lines = {}
    for i, sec in ipairs(sections) do
      lines[i] = ("%d. %s - %d тактов | %d BPM | %d/%d | %s %s")
        :format(i, sec.name, sec.bars, sec.tempo, sec.ts.num, sec.ts.den, sec.tonic, sec.scale)
    end
    reaper.MB(table.concat(lines, "\n"), "Сгенерированная форма", 0)
  end
end

-- ============ ОТЛАДКА: ДАМП В КОНСОЛЬ ============
-- Выводит в ReaScript console полные настройки генерации и итог.
local function fmtList(list)  -- "4/4=100, 3/4=0, ..."
  local p = {}
  for _, it in ipairs(list) do p[#p+1] = it.name .. "=" .. (it.chance or 0) end
  return table.concat(p, ", ")
end

local function dumpToConsole(sections, songColor, startPos, endPos)
  local L = {}
  local function w(s) L[#L+1] = s end
  local function bar() w(string.rep("─", 70)) end
  local sep = "\n"

  bar()
  w("═══ IDEA PLATFORM GENERATOR — ДАМП ГЕНЕРАЦИИ ═══")
  w(os.date("Время: %Y-%m-%d %H:%M:%S"))
  bar()

  -- НАСТРОЙКИ
  w("▼ НАСТРОЙКИ ГЕНЕРАЦИИ")
  w(("  Темп: %d-%d BPM"):format(S.tempo_min, S.tempo_max))
  w(("  Размер (вес): %s"):format(fmtList(S.timesig)))
  w(("  Тоника (вес): %s"):format(fmtList(S.tonic)))
  w(("  Лад    (вес): %s"):format(fmtList(S.scale)))
  w("")
  w("  ФОРМА (настройка секций):")
  w(("    %-3s %-14s %-8s %-6s %-6s %-8s %-6s %-6s %-6s %-6s %-5s")
    :format("#", "Секция", "Такты", "Появл", "Доп", "ΔТемп", "ΔРазм", "ΔТон", "ΔЛад", "Линк", "(линк→такты в наборе)"))
  for i, sec in ipairs(S.form) do
    local set = parseBars(sec.bars)
    local setstr = set and ("{" .. table.concat(set, ",") .. "}") or "—"
    w(("    %-3d %-14s %-8s %-6d %-6d %-8d %-6d %-6d %-6d %-5d %s")
      :format(i, sec.name, sec.bars or "?", sec.appear or 0, sec.extra or 0,
              sec.tchg or 0, sec.schg or 0, sec.kchg or 0, sec.cchg or 0,
              sec.link or 0, setstr))
  end
  bar()

  -- ИТОГ ГЕНЕРАЦИИ
  local totalBars = 0
  for _, sec in ipairs(sections) do totalBars = totalBars + sec.bars end
  w("▼ ИТОГ ГЕНЕРАЦИИ")
  w(("  Сгенерировано секций: %d   |   Всего тактов: %d"):format(#sections, totalBars))
  w(("  Позиция: %s  →  %s  (%.2f сек)")
    :format(reaper.format_timestr_pos(startPos, "", -1),
            reaper.format_timestr_pos(endPos, "", -1),
            endPos - startPos))
  local r, g, b = reaper.ColorFromNative(songColor)
  w(("  Цвет генерации: RGB(%d, %d, %d)"):format(r, g, b))
  w("")
  w("  РАЗВЁРТКА:")
  w(("    %-3s %-16s %-8s %-8s %-8s %-10s %-12s")
    :format("#", "Секция", "Такты", "BPM", "Размер", "Старт", "Тоника/Лад"))
  for i, sec in ipairs(sections) do
    local key = sec.tonic .. " " .. sec.scale
    w(("    %-3d %-16s %-8d %-8d %d/%-6d %-10s %s")
      :format(i, sec.name, sec.bars, sec.tempo, sec.ts.num, sec.ts.den,
              reaper.format_timestr_pos(sec.pos, "", -1), key))
  end
  bar()
  w("")

  reaper.ShowConsoleMsg(table.concat(L, sep))
end

local function generate(showMsg)
  rebuildTsLookup()
  local sections, err = buildSections()
  if not sections then
    statusText = "ОШИБКА: " .. (err or "ошибка генерации")
    statusError = true
    reaper.ShowConsoleMsg("\n⚠ ГЕНЕРАЦИЯ НЕ СОСТОЯЛАСЬ: " .. (err or "ошибка") .. "\n")
    return
  end
  reaper.Undo_BeginBlock2(0); reaper.PreventUIRefresh(1)
  applyToProject(sections, showMsg)
  reaper.PreventUIRefresh(-1); reaper.Undo_EndBlock2(0, "Random Generator (form)", -1)

  -- позиций секций в applyToProject не сохранялось — пересчитаем для дампа
  local cursor = reaper.GetCursorPosition()
  local pos = cursor
  for _, sec in ipairs(sections) do
    sec.pos = pos
    pos = pos + sectionDuration(sec.tempo, sec.ts, sec.bars)
  end
  dumpToConsole(sections, lastSongColor, cursor, pos)
end

-- ============ UI: ХЕЛПЕРЫ ============
local function sectionTitle(ctx, t)
  if ImGui.SeparatorText then ImGui.SeparatorText(ctx, t)
  else ImGui.Separator(ctx); ImGui.Text(ctx, t) end
end

local function chanceField(ctx, id, val, onChange)
  ImGui.SetNextItemWidth(ctx, 56)
  local _, v = ImGui.InputInt(ctx, "##"..id, val, 0, 0)
  v = clamp(v, 0, 100)
  if v ~= val then onChange(v) end
  return v
end

local function drawTextInput(ctx, id, buf, width)
  if width then ImGui.SetNextItemWidth(ctx, width) end
  local _, newbuf = ImGui.InputText(ctx, id, buf or "")
  local focused = ImGui.IsItemFocused(ctx)
  local enter = focused and
    (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter, false) or
     ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter, false))
  return newbuf or "", enter
end

local function deleteCross(ctx, id, onDelete)
  local w = ImGui.GetTextLineHeight(ctx) + 8
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x6B2020FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x8C2929FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFFFFFFF)
  local clicked = ImGui.Button(ctx, "x##"..id, w, 0)
  ImGui.PopStyleColor(ctx, 3)
  if clicked then onDelete() end
end

-- ============ UI: КОЛОНКИ ЗНАЧЕНИЙ ============
addbuf = {}

local function drawValueColumn(ctx, key, list)
  if MODE == "chances" then
    for i, it in ipairs(list) do
      ImGui.PushID(ctx, key.."_"..i)
      local nv = chanceField(ctx, "ch", it.chance, function(v) it.chance=v; dirty=true end)
      it.chance = nv
      ImGui.SameLine(ctx, 0, 8)
      ImGui.Text(ctx, it.name)
      ImGui.PopID(ctx)
    end
  else
    local toRemove = {}
    for i, it in ipairs(list) do
      ImGui.PushID(ctx, key.."_"..i)
      local delw = ImGui.GetTextLineHeight(ctx) + 8
      ImGui.SetNextItemWidth(ctx, -FLT_MIN - delw - 4)
      local _, nm = ImGui.InputText(ctx, "##nm", it.name)
      if nm ~= it.name then it.name = nm; dirty=true; if key=="timesig" then rebuildTsLookup() end end
      ImGui.SameLine(ctx, 0, 4)
      deleteCross(ctx, "del", function() toRemove[#toRemove+1] = i end)
      ImGui.PopID(ctx)
    end
    if #toRemove > 0 then
      table.sort(toRemove, function(a,b) return a>b end)
      for _, i in ipairs(toRemove) do table.remove(list, i) end
      if key=="timesig" then rebuildTsLookup() end; dirty=true
    end
    ImGui.Dummy(ctx, 0, 3); ImGui.Separator(ctx)
    local t, enter = drawTextInput(ctx, "##add_"..key, addbuf[key] or "", -FLT_MIN)
    addbuf[key] = t
    if (ImGui.Button(ctx, "+", -FLT_MIN, 0) or enter) and t:match("%S") then
      local exists=false; for _, it in ipairs(list) do if it.name==t then exists=true end end
      if not exists then list[#list+1]={name=t, chance=100}; dirty=true; if key=="timesig" then rebuildTsLookup() end end
      addbuf[key] = ""
    end
  end
end

local function drawTempo(ctx)
  ImGui.Text(ctx, "От:"); ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, -FLT_MIN)
  local _, mn = ImGui.SliderInt(ctx, "##tmin", S.tempo_min, 60, 240, "%d")
  if mn ~= S.tempo_min then S.tempo_min = mn; dirty=true end
  ImGui.Text(ctx, "До:"); ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, -FLT_MIN)
  local _, mx = ImGui.SliderInt(ctx, "##tmax", S.tempo_max, 60, 240, "%d")
  if mx ~= S.tempo_max then S.tempo_max = mx; dirty=true end
end

-- ============ UI: ФОРМА (таблица) ============
local FORM_COLS = { "Секция", "Тактов", "Появл.", "Доп.такты", "ΔТемп", "ΔРазмер", "ΔТоника", "ΔЛад", "Линк" }
local CH_KEYS  = { "appear", "extra", "tchg", "schg", "kchg", "cchg" }

local function drawBarsCell(ctx, id, sec)
  ImGui.SetNextItemWidth(ctx, 70)
  local _, b = ImGui.InputText(ctx, id, sec.bars or "8")
  if b ~= sec.bars then sec.bars = b; dirty=true end
end

local function drawForm(ctx)
  local base_flags = (ImGui.TableFlags_Borders or 0)
                  | (ImGui.TableFlags_Resizable or 0)
                  | (ImGui.TableFlags_RowBg or 0)
  if MODE == "chances" then
    local flags = base_flags | (ImGui.TableFlags_SizingFixedFit or 0)
    if ImGui.BeginTable(ctx, "formtbl", #FORM_COLS, flags) then
      for _, c in ipairs(FORM_COLS) do
        ImGui.TableSetupColumn(ctx, c, ImGui.TableColumnFlags_WidthFixed or 0)
      end
      ImGui.TableHeadersRow(ctx)
      for i, sec in ipairs(S.form) do
        ImGui.PushID(ctx, "f"..i)
        ImGui.TableNextRow(ctx)
        ImGui.TableNextColumn(ctx); ImGui.Text(ctx, sec.name)
        ImGui.TableNextColumn(ctx); drawBarsCell(ctx, "##b", sec)
        for _, k in ipairs(CH_KEYS) do
          ImGui.TableNextColumn(ctx)
          ImGui.PushID(ctx, k)
          ImGui.SetNextItemWidth(ctx, 56)
          local _, v = ImGui.InputInt(ctx, "##c", sec[k], 0, 0); v = clamp(v, 0, 100)
          if v ~= sec[k] then sec[k] = v; dirty=true end
          ImGui.PopID(ctx)
        end
        ImGui.TableNextColumn(ctx)
        ImGui.SetNextItemWidth(ctx, 42)
        local _, lk = ImGui.InputInt(ctx, "##lk", sec.link or 0, 0, 0); lk = clamp(lk, 0, 99)
        if lk ~= (sec.link or 0) then sec.link = lk; dirty=true end
        ImGui.PopID(ctx)
      end
      ImGui.EndTable(ctx)
    end
    ImGui.TextDisabled(ctx, "Такты: 8 | 4,8,16 | 4-8 | 4,6-8,16 — случайный выбор из набора")
  else
    local stretch = ImGui.TableColumnFlags_WidthStretch or 0
    local fixed   = ImGui.TableColumnFlags_WidthFixed or 0
    if ImGui.BeginTable(ctx, "formtbl_edit", 3, base_flags | (ImGui.TableFlags_SizingFixedFit or 0)) then
      ImGui.TableSetupColumn(ctx, "Секция",  stretch)
      ImGui.TableSetupColumn(ctx, "Тактов",  fixed)
      ImGui.TableSetupColumn(ctx, "Порядок", fixed)
      ImGui.TableHeadersRow(ctx)
      local toRemove = {}
      for i, sec in ipairs(S.form) do
        ImGui.PushID(ctx, "fe"..i)
        ImGui.TableNextRow(ctx)
        ImGui.TableNextColumn(ctx)
        local delw = ImGui.GetTextLineHeight(ctx) + 10
        local availw = ImGui.GetContentRegionAvail(ctx)
        ImGui.SetNextItemWidth(ctx, availw - delw - 6)
        local _, nm = ImGui.InputText(ctx, "##nm", sec.name)
        if nm ~= sec.name then sec.name = nm; dirty=true end
        ImGui.SameLine(ctx, 0, 6)
        deleteCross(ctx, "del", function() toRemove[#toRemove+1] = i end)
        ImGui.TableNextColumn(ctx); drawBarsCell(ctx, "##b", sec)
        ImGui.TableNextColumn(ctx)
        if ImGui.Button(ctx, "^", 26, 0) and i > 1 then S.form[i], S.form[i-1] = S.form[i-1], S.form[i]; dirty=true end
        ImGui.SameLine(ctx, 0, 2)
        if ImGui.Button(ctx, "v", 26, 0) and i < #S.form then S.form[i], S.form[i+1] = S.form[i+1], S.form[i]; dirty=true end
        ImGui.PopID(ctx)
      end
      if #toRemove > 0 then
        table.sort(toRemove, function(a,b) return a>b end)
        for _, i in ipairs(toRemove) do table.remove(S.form, i) end; dirty=true
      end
      ImGui.EndTable(ctx)
    end
    local t, enter = drawTextInput(ctx, "##newsec", addbuf["form"] or "", 220)
    addbuf["form"] = t
    ImGui.SameLine(ctx, 0, 4)
    if (ImGui.Button(ctx, "+ Секция") or enter) and t:match("%S") then
      S.form[#S.form+1] = { name=t, link=0, bars="8", appear=100, extra=0, tchg=0, schg=0, kchg=0, cchg=0 }
      addbuf["form"] = ""; dirty=true
    end
  end
end

-- ============ UI: ПРЕСЕТЫ ============
local preset_name = ""
local preset_current = ""

local function drawPresets(ctx)
  ImGui.TextDisabled(ctx, "Пресеты (снимок всех чисел-шансов):")
  local newname, enter = drawTextInput(ctx, "##pname", preset_name, 180)
  preset_name = newname
  ImGui.SameLine(ctx, 0, 4)
  if ImGui.Button(ctx, "Сохранить") or enter then
    local name = trim(preset_name)
    if name ~= "" then
      if savePreset(name) then
        preset_current = name
        preset_name = ""
        statusText = "Пресет «" .. name .. "» сохранён"
        statusError = false
      end
    else
      statusText = "Введите имя пресета"
      statusError = true
    end
  end
  ImGui.SameLine(ctx, 0, 12)
  local names = getPresetNames()
  if #names == 0 then
    ImGui.TextDisabled(ctx, "(нет сохранённых пресетов)")
  else
    ImGui.SetNextItemWidth(ctx, 200)
    if ImGui.BeginCombo(ctx, "##psel", preset_current ~= "" and preset_current or "-- выбрать --") then
      for _, nm in ipairs(names) do
        if ImGui.Selectable(ctx, nm, nm == preset_current) then
          if loadPreset(nm) then
            preset_current = nm
            statusText = "Пресет «" .. nm .. "» загружен"
            statusError = false
          end
        end
      end
      ImGui.EndCombo(ctx)
    end
    ImGui.SameLine(ctx, 0, 4)
    if ImGui.Button(ctx, "Удалить") and preset_current ~= "" then
      deletePreset(preset_current)
      statusText = "Пресет «" .. preset_current .. "» удалён"
      statusError = false
      preset_current = ""
    end
  end
end

-- ============ ГЛАВНЫЙ КАДР ============
local footer_h

local function frame(ctx)
  ImGui.TextDisabled(ctx, "Режим:")
  ImGui.SameLine(ctx)
  if ImGui.RadioButton(ctx, "Шансы", MODE == "chances") then MODE = "chances" end
  ImGui.SameLine(ctx)
  if ImGui.RadioButton(ctx, "Редактирование", MODE == "edit") then MODE = "edit" end
  ImGui.SameLine(ctx, 0, 24)
  if dirty then
    if ImGui.SmallButton(ctx, "Сохранить##top") then saveState() end
  else
    ImGui.TextDisabled(ctx, "всё сохранено")
  end
  ImGui.Separator(ctx)

  local avail_x, avail_y = ImGui.GetContentRegionAvail(ctx)
  local lineH = ImGui.GetTextLineHeightWithSpacing(ctx)
  local spacing = 8
  local w_each = (avail_x - spacing * 3) / 4
  if not footer_h then footer_h = lineH * 6 end

  local columns_h = math.max(lineH * 7, 160)
  local cols = {
    { "c_t",   "Темп",    function() drawTempo(ctx) end },
    { "c_ts",  "Размер",  function() drawValueColumn(ctx, "timesig", S.timesig) end },
    { "c_to",  "Тоника",  function() drawValueColumn(ctx, "tonic",   S.tonic)   end },
    { "c_sc",  "Лад",     function() drawValueColumn(ctx, "scale",   S.scale)   end },
  }
  for i, c in ipairs(cols) do
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, 0x1B1B2266)
    local vis = ImGui.BeginChild(ctx, c[1], w_each, columns_h, CF_BORDERS)
    if vis then
      sectionTitle(ctx, c[2]); c[3]()
      ImGui.EndChild(ctx)
    end
    ImGui.PopStyleColor(ctx, 1)
    if i < #cols then ImGui.SameLine(ctx, 0, spacing) end
  end

  ImGui.Dummy(ctx, 0, 4)
  local form_h = avail_y - columns_h - footer_h - 8
  if form_h < lineH * 5 then form_h = lineH * 5 end
  if ImGui.BeginChild(ctx, "c_form", 0, form_h, CF_BORDERS) then
    sectionTitle(ctx, "Форма (генерация сверху вниз)")
    drawForm(ctx)
    ImGui.EndChild(ctx)
  end

  local fb_start = ImGui.GetCursorPosY(ctx)
  drawPresets(ctx)
  ImGui.Separator(ctx)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0xB5651DFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0xD17B22FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x8A4D14FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFFFFFFF)
  local gen = ImGui.Button(ctx, "СГЕНЕРИРОВАТЬ  (создать регионы на курсоре)", -FLT_MIN, lineH * 2)
  ImGui.PopStyleColor(ctx, 4)
  if gen then generate(false) end
  if statusText ~= "" then
    if statusError then ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xE53935FF)
    else                 ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x66BB6AFF) end
    ImGui.Text(ctx, statusText)
    ImGui.PopStyleColor(ctx, 1)
  end
  footer_h = ImGui.GetCursorPosY(ctx) - fb_start
end

-- ============ КОНТЕКСТ И ЦИКЛ ============
local ctx, font
local idle = 0

local function loop()
  ImGui.PushFont(ctx, font, FONT_SIZE)
  ImGui.SetNextWindowSizeConstraints(ctx, 1060, 520, FLT_MAX, FLT_MAX)
  ImGui.SetNextWindowSize(ctx, 1240, 640, ImGui.Cond_FirstUseEver)

  local winflags = (ImGui.WindowFlags_NoCollapse or 0)
                 | (ImGui.WindowFlags_NoScrollbar or 0)
  local visible, open = ImGui.Begin(ctx, "Idea Platform Generator", true, winflags)
  if visible then
    frame(ctx)
    ImGui.End(ctx)
  end
  ImGui.PopFont(ctx)

  if dirty then
    idle = idle + 1
    if idle > 60 then saveState(); idle = 0 end
  else idle = 0 end

  if open then
    reaper.defer(loop)
  else
    -- окно закрыто: принудительно сохранить несохранённое состояние
    if dirty then saveState() end
  end
end

local function init()
  math.randomseed(os.time())
  for _ = 1, 5 do math.random() end
  local ctxflags = ImGui.ConfigFlags_DockingEnable or 0
  ctx  = ImGui.CreateContext("Idea Platform Generator v2", ctxflags)
  font = ImGui.CreateFont("sans-serif")
  ImGui.Attach(ctx, font)
  reaper.defer(loop)
end

init()
