module("luci.controller.linkmeter.lmdata", package.seeall)

function index()
  entry({"lm", "hist"}, call("action_hist"))
  entry({"lm", "hmstatus"}, call("action_hmstatus"))
  entry({"lm", "rfstatus"}, call("action_rfstatus"))
end

function lmclient_command(query)
  local client = nixio.socket("unix", "dgram")
  client:bind("")
  if not client:connect("/var/run/linkmeter.sock") then
    client:close()
    return nil
  end
  
  client:send(query)
  local polle = { fd = client, events = nixio.poll_flags("in"), revents = 0 }
  local retVal
  if nixio.poll({polle}, 1000) then
    retVal = client:recv(1024)
  end
  client:close()
  return retVal
end

function lmclient_json(query)
  local result = lmclient_command(query)
  if result then
    luci.http.prepare_content("application/json")
    luci.http.write(result)
    return true
  else
    luci.dispatcher.error500("JSON read failed: " .. query)
  end
end

function action_hmstatus()
  return lmclient_json("$LMSU")
end

function action_rfstatus()
  return lmclient_json("$LMRF")
end

local function hasData(tbl)
  -- Returns true if the table has any non-NaN data in it
  for _,val in ipairs(tbl) do
    -- If val ~= val then val is a NaN, LUA doesn't have isnan()
    -- and NaN ~= NaN by C definition (platform-specific)
    if val == val then
      return true
    end
  end
end

function action_hist()
  local http = require "luci.http"
  local rrd = require "rrd"
  local uci = luci.model.uci.cursor()

  local RRD_FILE = http.formvalue("rrd") or uci:get("linkmeter", "daemon", "rrd_file") 
  local nancnt = tonumber(http.formvalue("nancnt"))
  local start, step, data, soff
  
  if not nixio.fs.access(RRD_FILE) then
    http.status(503, "Database Unavailable")  
    http.prepare_content("text/plain")
    http.write("No database: %q" % RRD_FILE)
    return
  end
  
  local now = rrd.last(RRD_FILE) -- os.time()
  
  if not nancnt then
    -- scroll through the data and find the first line that has data
    -- this should indicate the start of data recording on the largest
    -- step data.  Then use that to determine the smallest step that
    -- includes all the data
    start, step, _, data = rrd.fetch(RRD_FILE, "AVERAGE")
    nancnt = 0
    for _, dp in ipairs(data) do
      if hasData(dp) then break end
      nancnt = nancnt + 1
    end
  end
    
  if nancnt >= 460 then
    step = 10
    soff = 3600
  elseif nancnt >= 360 then
    step = 60
    soff = 21600
  elseif nancnt >= 240 then
    step = 120
    soff = 43200
  else
    step = 180
    soff = 86400
  end

  -- Make sure our end time falls on an exact previous or now time boundary
  now = math.floor(now/step) * step  

  -- Only pull new data if the nancnt probe data isn't what we're looking for 
  if step ~= 180 or not data then
    start, step, _, data = rrd.fetch(RRD_FILE, "AVERAGE",
      "--end", now, "--start", now - soff, "-r", step
    )
  end
  
  local seenData 
  local results = {}
  http.prepare_content("text/plain")
  http.header("Cache-Control", "max-age="..step)
  for _, dp in ipairs(data) do
    -- Skip the first NaN rows until we actually have data and keep
    -- sending until we get to the 1 or 2 rows at the end that are NaN
    if hasData(dp) or (seenData and (start < (now - step))) then
      results[#results+1] = ("%u,%s"):format(start, table.concat(dp, ","))
      seenData = true
    end
    
    start = start + step
  end 
  http.write(table.concat(results, "\n"))
end
