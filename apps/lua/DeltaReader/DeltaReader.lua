-- Delta Reader  -  live delta overlay for Assetto Corsa (Custom Shaders Patch Lua app)
--
-- How it works
--   * Every lap is recorded as a "trace": the lap time at N evenly spaced points
--     around the track (using the car's spline position, 0..1).
--   * Live delta = current lap time - reference trace time at the same track position.
--   * Session optimal = best time through each of SECTORS mini-sectors, stitched together.
--   * Predicted lap = reference lap time + current delta.
--   * Valid laps are saved per car/track to Documents/Assetto Corsa/DeltaReader so
--     past laps (and your personal best) are read back next time you drive that combo.

local N = 1000          -- trace resolution (points per lap)
local SECTORS = 40      -- mini-sectors for the optimal lap (N must divide evenly)
local MAX_SAVED = 30    -- saved laps kept per car/track (ring buffer)
local PER = N / SECTORS

local settings = ac.storage({
  refMode = 1,          -- 1 session best, 2 session optimal, 3 personal best, 4 picked saved lap
  range = 1.0,          -- seconds for a full arc
  trackLimits = true,   -- laps with 3+ wheels off are not counted
  optimalAllTime = false, -- include saved laps in the optimal
  smoothing = 10        -- delta display smoothing (higher = snappier)
})

local REF_NAMES = { 'SESSION BEST', 'SESSION OPTIMAL', 'PERSONAL BEST', 'SAVED LAP' }
local REF_SHORT = { 'BEST', 'OPTIMAL', 'PB', 'SAVED' }

-- ---------------------------------------------------------------- state
local session = { laps = {}, best = nil, optimal = nil }
local saved = {}            -- laps read from disk for this combo (slot -> lap)
local pb = nil              -- personal best lap
local picked = nil          -- saved lap chosen as reference (refMode 4)
local allTimeOptimal = nil
local comboKey, comboDir, nextSlot = nil, nil, 1

local rec = { t = {}, last = -1, prevPos = 0, prevT = 0, valid = false, active = false }
local lastLapCount, lastT = nil, 0
local live = { delta = nil, shown = nil, second = nil, predicted = nil, valid = true }

-- ---------------------------------------------------------------- helpers
local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end

local function fmtLap(ms)
  if not ms or ms <= 0 then return '--:--.---' end
  ms = math.floor(ms + 0.5)
  local m = math.floor(ms / 60000)
  local s = (ms - m * 60000) / 1000
  return string.format('%02d:%06.3f', m, s)
end

local function fmtDelta(d)
  if not d then return '-.---' end
  if math.abs(d) < 0.0005 then return '0.000' end
  return string.format('%+.3f', d)
end

local function sanitize(s)
  s = tostring(s or 'unknown')
  return (s:gsub('[^%w%-_%.]', '_'))
end

local function safe(f, ...)
  local ok, r = pcall(f, ...)
  if ok then return r end
  return nil
end

local function writeFile(path, data)
  return pcall(function()
    if io.save then io.save(path, data)
    else
      local f = assert(io.open(path, 'w')); f:write(data); f:close()
    end
  end)
end

local function readFile(path)
  local data = nil
  pcall(function()
    if io.load then data = io.load(path)
    else
      local f = io.open(path, 'r')
      if f then data = f:read('*a'); f:close() end
    end
  end)
  if data == '' then return nil end
  return data
end

local function makeDir(path)
  pcall(function()
    if io.createDir then io.createDir(path)
    elseif os.execute then os.execute('mkdir "' .. path .. '"') end
  end)
end

-- ---------------------------------------------------------------- lap (de)serialisation
local function serialize(lap)
  local parts = {}
  for i = 0, N do parts[#parts + 1] = tostring(math.floor(lap.t[i] + 0.5)) end
  return 'DR1\n' .. tostring(math.floor(lap.time + 0.5)) .. '\n' .. (lap.date or '') .. '\n' .. table.concat(parts, ',')
end

local function parse(data)
  if not data or data:sub(1, 3) ~= 'DR1' then return nil end
  local lines = {}
  for line in (data .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = line end
  local time = tonumber(lines[2])
  if not time or not lines[4] then return nil end
  local t, i = {}, 0
  for v in lines[4]:gmatch('[^,]+') do t[i] = tonumber(v); i = i + 1 end
  if i ~= N + 1 then return nil end
  return { time = time, date = lines[3], t = t }
end

-- ---------------------------------------------------------------- reference maths
local function traceAt(lap, pos)
  if not lap then return nil end
  local x = clamp(pos, 0, 1) * N
  local i = math.floor(x)
  if i >= N then return lap.t[N] end
  local f = x - i
  return lap.t[i] + (lap.t[i + 1] - lap.t[i]) * f
end

local function buildOptimal(pool)
  if #pool == 0 then return nil end
  local opt, acc = { [0] = 0 }, 0
  for k = 0, SECTORS - 1 do
    local a, b = k * PER, (k + 1) * PER
    local bestLap, bestDt = nil, nil
    for _, lap in ipairs(pool) do
      local d = lap.t[b] - lap.t[a]
      if d > 0 and (not bestDt or d < bestDt) then bestDt, bestLap = d, lap end
    end
    if not bestLap then return nil end
    for i = a + 1, b do opt[i] = acc + (bestLap.t[i] - bestLap.t[a]) end
    acc = acc + bestDt
  end
  return { time = acc, t = opt }
end

local function savedList()
  local list = {}
  for slot = 1, MAX_SAVED do if saved[slot] then list[#list + 1] = saved[slot] end end
  table.sort(list, function(a, b) return a.time < b.time end)
  return list
end

local function rebuildOptimal()
  session.optimal = buildOptimal(session.laps)
  local pool = {}
  for _, l in ipairs(session.laps) do pool[#pool + 1] = l end
  for slot = 1, MAX_SAVED do if saved[slot] then pool[#pool + 1] = saved[slot] end end
  if pb then pool[#pool + 1] = pb end
  allTimeOptimal = buildOptimal(pool)
end

local function optimalRef()
  if settings.optimalAllTime then return allTimeOptimal end
  return session.optimal
end

local function reference(mode)
  mode = mode or settings.refMode
  if mode == 1 then return session.best
  elseif mode == 2 then return optimalRef()
  elseif mode == 3 then return pb
  elseif mode == 4 then return picked end
end

-- the mode actually shown: falls back to PB (then all-time data) when the chosen one has no laps yet
local function activeMode()
  if reference(settings.refMode) then return settings.refMode end
  if pb then return 3 end
  if reference(2) then return 2 end
  return settings.refMode
end

-- ---------------------------------------------------------------- car / track combo
local function currentCombo()
  local car = safe(ac.getCarID, 0) or 'car'
  local track = safe(ac.getTrackID) or 'track'
  local layout = safe(ac.getTrackLayout) or ''
  if layout ~= '' then track = track .. '-' .. layout end
  return sanitize(car) .. '@' .. sanitize(track)
end

local function loadCombo(key)
  comboKey = key
  session = { laps = {}, best = nil, optimal = nil }
  saved, pb, picked, allTimeOptimal, nextSlot = {}, nil, nil, nil, 1

  local root = safe(function() return ac.getFolder(ac.FolderID.ACDocuments) end)
  if not root or root == '' then root = __dirname or '.' end
  local base = root .. '/DeltaReader'
  makeDir(base)
  comboDir = base .. '/' .. key
  makeDir(comboDir)

  pb = parse(readFile(comboDir .. '/pb.txt'))
  local newest, newestSlot = nil, 0
  for slot = 1, MAX_SAVED do
    local lap = parse(readFile(comboDir .. '/lap_' .. slot .. '.txt'))
    if lap then
      lap.slot = slot
      saved[slot] = lap
      if not newest or (lap.date or '') > newest then newest, newestSlot = lap.date or '', slot end
    end
  end
  nextSlot = (newestSlot % MAX_SAVED) + 1
  rebuildOptimal()
end

-- ---------------------------------------------------------------- recording
local function startLap(pos, t)
  rec.t = { [0] = 0 }
  rec.last = 0
  rec.prevPos, rec.prevT = 0, 0
  rec.active = true
  rec.valid = true
  -- a lap that starts far from the line (pit exit, session restart mid-track) is an out-lap
  if pos > 0.05 and pos < 0.95 then rec.valid = false end
  if t > 3000 then rec.valid = false end
end

local function recordSample(pos, t)
  local b = math.floor(pos * N)
  if b > N - 1 then b = N - 1 end
  if b <= rec.last then
    if b < rec.last - N * 0.02 then rec.valid = false end    -- went backwards
    return
  end
  if b - rec.last > N * 0.05 then rec.valid = false end      -- teleport / big jump
  local p0, t0 = rec.prevPos, rec.prevT
  for i = rec.last + 1, b do
    local f = 1
    if pos - p0 > 1e-9 then f = clamp((i / N - p0) / (pos - p0), 0, 1) end
    rec.t[i] = t0 + (t - t0) * f
  end
  rec.last = b
  rec.prevPos, rec.prevT = pos, t
end

local function addLap(lap)
  lap.date = os.date('%Y-%m-%d %H:%M:%S')
  table.insert(session.laps, lap)
  if not session.best or lap.time < session.best.time then session.best = lap end

  if comboDir then
    lap.slot = nextSlot
    saved[nextSlot] = lap
    writeFile(comboDir .. '/lap_' .. nextSlot .. '.txt', serialize(lap))
    nextSlot = (nextSlot % MAX_SAVED) + 1
    if not pb or lap.time < pb.time then
      pb = lap
      writeFile(comboDir .. '/pb.txt', serialize(lap))
    end
  end
  rebuildOptimal()
end

local function finishLap(ms)
  if not rec.active or not rec.valid or not ms or ms <= 0 then return end
  if rec.last < N * 0.95 then return end
  local p0, t0 = rec.prevPos, rec.prevT
  for i = rec.last + 1, N do
    local f = 1
    if 1 - p0 > 1e-9 then f = clamp((i / N - p0) / (1 - p0), 0, 1) end
    rec.t[i] = t0 + (ms - t0) * f
  end
  rec.t[N] = ms
  for i = 1, N do
    if not rec.t[i] or rec.t[i] < rec.t[i - 1] - 1 then return end
  end
  addLap({ time = ms, t = rec.t })
end

-- ---------------------------------------------------------------- per-frame update
function script.update(dt)
  local car = ac.getCar(0)
  if not car then return end
  local sim = ac.getSim()
  if sim and sim.isReplayActive then return end

  local key = currentCombo()
  if key ~= comboKey then loadCombo(key); lastLapCount = nil end

  local t = car.lapTimeMs or 0
  local pos = car.splinePosition or 0
  local lapCount = car.lapCount or 0

  if lastLapCount == nil then
    lastLapCount = lapCount
    startLap(pos, t)
    rec.valid = false               -- joined mid-lap
  elseif lapCount ~= lastLapCount then
    if lapCount == lastLapCount + 1 then finishLap(car.previousLapTimeMs) end
    lastLapCount = lapCount
    startLap(pos, t)
  elseif t + 1000 < lastT then
    startLap(pos, t)                -- timer reset (restart, back to pits)
    rec.valid = false
  end
  lastT = t

  if car.isInPitlane then rec.valid = false end
  if settings.trackLimits and (car.wheelsOutside or 0) > 2 then rec.valid = false end

  -- spline 0 and the timing line are not always exactly aligned: ignore the wrap region
  local refPos = pos
  if t < 8000 and pos > 0.5 then refPos = nil                   -- just over the line, spline not wrapped yet
  elseif rec.last > N * 0.8 and pos < 0.2 then refPos = 1 end   -- spline wrapped, timing line not reached yet
  if refPos == pos and rec.active then recordSample(pos, t) end

  -- live numbers
  live.valid = rec.valid
  local mode = activeMode()
  local ref = reference(mode)
  if not ref then
    live.delta, live.predicted, live.second = nil, nil, nil
  elseif refPos and (rec.last > 2 or refPos == 1) then
    live.delta = (t - traceAt(ref, refPos)) / 1000
    live.predicted = ref.time + live.delta * 1000
    local ref2 = reference(mode == 2 and 1 or 2)
    live.second = ref2 and (t - traceAt(ref2, refPos)) / 1000 or nil
  elseif t > 8000 then
    live.delta, live.predicted, live.second = nil, nil, nil
  end
  -- otherwise (first seconds of a lap) the last lap's final delta stays on screen

  if live.delta then
    if not live.shown then live.shown = live.delta
    else live.shown = live.shown + (live.delta - live.shown) * math.min(1, dt * settings.smoothing) end
  else
    live.shown = nil
  end
end

-- ---------------------------------------------------------------- drawing
local C = {
  panel   = rgbm(0.075, 0.08, 0.09, 0.94),
  panel2  = rgbm(0.11, 0.115, 0.125, 0.96),
  bezel   = rgbm(0.05, 0.055, 0.06, 1),
  face    = rgbm(0.09, 0.095, 0.105, 1),
  stripe  = rgbm(1, 1, 1, 0.035),
  track   = rgbm(1, 1, 1, 0.10),
  green   = rgbm(0.18, 0.92, 0.25, 1),
  red     = rgbm(1.0, 0.16, 0.16, 1),
  purple  = rgbm(0.75, 0.35, 1.0, 1),
  white   = rgbm(0.97, 0.97, 0.97, 1),
  label   = rgbm(0.92, 0.92, 0.92, 1),
  dim     = rgbm(0.62, 0.64, 0.66, 1),
  gold    = rgbm(0.98, 0.70, 0.12, 1),
  box     = rgbm(0.015, 0.018, 0.02, 0.96),
}

local function withAlpha(c, a) return rgbm(c.r, c.g, c.b, (c.mult or 1) * a) end

local function text(str, size, x, y, col, align)
  local w = ui.measureDWriteText(str, size).x
  if align == 'right' then x = x - w elseif align == 'center' then x = x - w / 2 end
  ui.dwriteDrawText(str, size, vec2(x, y), col)
end

-- diagonal carbon stripes inside a circle
local function carbonCircle(cx, cy, r, spacing, col, thick)
  local k = 0.70710678
  local d = -r + spacing * 0.5
  while d < r do
    local h = math.sqrt(r * r - d * d)
    local px, py = cx + k * d, cy - k * d
    ui.drawLine(vec2(px - k * h, py - k * h), vec2(px + k * h, py + k * h), col, thick)
    d = d + spacing
  end
end

-- diagonal carbon stripes inside a rectangle
local function carbonRect(x1, y1, x2, y2, spacing, col, thick)
  local kk = x1 - y2
  while kk < x2 - y1 do
    local xa = math.max(x1, y1 + kk)
    local xb = math.min(x2, y2 + kk)
    if xb > xa then ui.drawLine(vec2(xa, xa - kk), vec2(xb, xb - kk), col, thick) end
    kk = kk + spacing
  end
end

local function arc(cx, cy, r, a1, a2, col, thick)
  ui.pathClear()
  ui.pathArcTo(vec2(cx, cy), r, a1, a2, math.max(8, math.floor(math.abs(a2 - a1) * 20)))
  ui.pathStroke(col, false, thick)
end

local BASE_W, BASE_H = 620, 340

function script.windowMain(dt)
  local size = ui.windowSize()
  local s = math.min(size.x / BASE_W, size.y / BASE_H)
  local function S(v) return v * s end

  ui.pushDWriteFont('Segoe UI;Weight=Bold')

  -- ---------- right timing panel
  local px1, py1, px2, py2 = S(205), S(6), S(612), S(334)
  ui.drawRectFilled(vec2(px1, py1), vec2(px2, py2), C.panel, S(26))
  carbonRect(px1 + S(10), py1 + S(4), px2 - S(10), py2 - S(4), S(5), C.stripe, S(1.4))

  local mode = activeMode()
  local ref = reference(mode)
  local optRef = optimalRef()
  local rows = {
    { optRef and optRef.time, settings.optimalAllTime and 'ALL-TIME OPTIMAL' or 'SESSION OPTIMAL', C.white, true },
    { session.best and session.best.time, 'SESSION BEST', C.white, true },
    { live.predicted, 'PREDICTED LAP', C.white, false },
    { pb and pb.time, 'PERSONAL BEST', C.white, false },
  }
  -- predicted lap colour: purple = beats PB, green = faster than reference, red = slower
  if live.predicted and live.shown then
    if pb and live.predicted < pb.time then rows[3][3] = C.purple
    elseif live.shown <= 0 then rows[3][3] = C.green
    else rows[3][3] = C.red end
  end

  local rowH = S(80)
  for i, row in ipairs(rows) do
    local y = py1 + S(4) + (i - 1) * rowH
    if row[4] then
      ui.drawRectFilled(vec2(S(395), y + S(2)), vec2(px2 - S(4), y + rowH - S(2)), withAlpha(C.panel2, 0.55), S(4))
      ui.drawLine(vec2(S(395), y + S(2)), vec2(px2 - S(14), y + S(2)), C.gold, S(3))
    end
    text(fmtLap(row[1]), S(46), px2 - S(20), y + S(4), row[3], 'right')
    text(row[2], S(15), px2 - S(22), y + S(54), C.label, 'right')
  end

  -- ---------- gauge
  local cx, cy, R = S(152), S(170), S(138)
  ui.drawCircleFilled(vec2(cx, cy), R + S(14), C.panel, 64)          -- merges gauge into panel
  ui.drawCircleFilled(vec2(cx, cy), R, C.bezel, 64)
  carbonCircle(cx, cy, R - S(1), S(5), C.stripe, S(1.4))
  ui.drawCircle(vec2(cx, cy), R, rgbm(1, 1, 1, 0.06), 64, S(1.5))

  -- lighter right half of the face
  ui.pathClear()
  ui.pathArcTo(vec2(cx, cy), S(108), -math.pi / 2, math.pi / 2, 40)
  ui.pathFillConvex(rgbm(1, 1, 1, 0.025))

  local ar = S(112)
  arc(cx, cy, ar, 0, math.pi * 2, C.track, S(3))

  local top = -math.pi / 2
  local maxA = math.pi * 0.92
  if live.shown then
    local frac = clamp(math.abs(live.shown) / math.max(0.05, settings.range), 0, 1)
    local col = live.shown <= 0 and C.green or C.red
    if frac > 0.003 then
      local a1, a2
      if live.shown <= 0 then a1, a2 = top, top + frac * maxA else a1, a2 = top - frac * maxA, top end
      arc(cx, cy, ar, a1, a2, withAlpha(col, 0.18), S(14))   -- glow
      arc(cx, cy, ar, a1, a2, col, S(7))
      local ea = live.shown <= 0 and a2 or a1
      ui.drawCircleFilled(vec2(cx + math.cos(ea) * ar, cy + math.sin(ea) * ar), S(3.5), col, 16)
    end
  end

  -- diamond marker at zero
  local dx, dy, dr = cx, cy - ar, S(8)
  ui.pathClear()
  ui.pathLineTo(vec2(dx, dy - dr)); ui.pathLineTo(vec2(dx + dr, dy))
  ui.pathLineTo(vec2(dx, dy + dr)); ui.pathLineTo(vec2(dx - dr, dy))
  ui.pathFillConvex(C.bezel)
  ui.pathClear()
  ui.pathLineTo(vec2(dx, dy - dr)); ui.pathLineTo(vec2(dx + dr, dy))
  ui.pathLineTo(vec2(dx, dy + dr)); ui.pathLineTo(vec2(dx - dr, dy))
  ui.pathStroke(C.white, true, S(2.2))

  -- label + value box
  text('DELTA · ' .. REF_SHORT[mode], S(14), cx, cy - S(62), C.dim, 'center')
  local bw, bh = S(96), S(37)
  ui.drawRectFilled(vec2(cx - bw, cy - bh), vec2(cx + bw, cy + bh), C.box, S(10))
  local dcol = C.white
  if live.shown then dcol = live.shown <= 0 and C.green or C.red end
  if live.shown and not live.valid then dcol = withAlpha(dcol, 0.55) end
  text(fmtDelta(live.shown), S(58), cx, cy - S(36), dcol, 'center')

  -- secondary delta (vs optimal, or vs best when the main one is optimal)
  if live.second then
    local lbl = (mode == 2 and 'BEST ' or 'OPT ') .. fmtDelta(live.second)
    text(lbl, S(15), cx, cy + S(44), live.second <= 0 and C.green or C.red, 'center')
  elseif not ref then
    text('DRIVE A CLEAN LAP', S(13), cx, cy + S(46), C.dim, 'center')
  end
  if live.shown and not live.valid then
    text('INVALID', S(13), cx, cy + S(66), withAlpha(C.red, 0.9), 'center')
  else
    -- small original mark
    local mx, my, mr = cx, cy + S(80), S(9)
    ui.pathClear()
    ui.pathLineTo(vec2(mx, my - mr)); ui.pathLineTo(vec2(mx + mr, my + mr * 0.7)); ui.pathLineTo(vec2(mx - mr, my + mr * 0.7))
    ui.pathStroke(rgbm(1, 1, 1, 0.75), true, S(2))
  end

  ui.popDWriteFont()

  -- click the gauge to cycle the reference
  ui.setCursor(vec2(cx - R, cy - R))
  if ui.invisibleButton('##gauge', vec2(R * 2, R * 2)) then
    local m = settings.refMode
    for _ = 1, 4 do
      m = (m % 4) + 1
      if reference(m) or m == 1 then break end
    end
    settings.refMode = m
  end
end

-- ---------------------------------------------------------------- settings window
function script.windowSettings(dt)
  ui.text('Main delta reference (or click the gauge to cycle):')
  for m = 1, 4 do
    local avail = reference(m) ~= nil
    local lbl = (settings.refMode == m and '> ' or '   ') .. REF_NAMES[m] .. (avail and '' or '  (no data yet)') .. '##ref' .. m
    if ui.button(lbl) then settings.refMode = m end
  end
  ui.separator()

  local v, changed = ui.slider('##range', settings.range, 0.2, 3.0, 'Arc range: ±%.1f s')
  if changed then settings.range = v end
  local sm, ch2 = ui.slider('##smooth', settings.smoothing, 2, 30, 'Delta smoothing: %.0f')
  if ch2 then settings.smoothing = sm end
  if ui.checkbox('Discard laps with 3+ wheels off track', settings.trackLimits) then
    settings.trackLimits = not settings.trackLimits
  end
  if ui.checkbox('Optimal uses saved laps too (all-time optimal)', settings.optimalAllTime) then
    settings.optimalAllTime = not settings.optimalAllTime
  end
  ui.separator()

  ui.text('Saved laps for this car/track (fastest first):')
  local list = savedList()
  if #list == 0 then ui.text('   none yet - complete a clean lap') end
  for i, lap in ipairs(list) do
    if i > 15 then break end
    local mark = (picked == lap and settings.refMode == 4) and '> ' or '   '
    if ui.button(mark .. fmtLap(lap.time) .. '   ' .. (lap.date or '') .. '##lap' .. lap.slot) then
      picked = lap
      settings.refMode = 4
    end
  end
  ui.separator()
  if ui.button('Reset session') then
    session = { laps = {}, best = nil, optimal = nil }
    rebuildOptimal()
  end
  ui.text('Data folder: ' .. tostring(comboDir))
end

-- exposed for testing only
script._debug = function() return session, pb, live, rec end
