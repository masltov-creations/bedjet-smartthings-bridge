local cosock = require "cosock"
local socket = require "cosock.socket"
local json = require "st.json"

local M = {}

local function get_bridge_host(device)
  local value = device.preferences.bridgeHost or "bedjet-bridge.local"
  value = value:gsub("^https?://", "")
  value = value:gsub("/.*$", "")
  return value
end

local function get_bridge_port(device)
  return tonumber(device.preferences.bridgePort) or 8787
end

local function receive_line(client)
  local line, err, partial = client:receive("*l")
  if line then
    return line
  end

  if partial and #partial > 0 and err == "closed" then
    return partial
  end

  return nil, err or "unknown receive error"
end

local function receive_exact(client, size)
  if size <= 0 then
    return ""
  end

  local chunks = {}
  local remaining = size

  while remaining > 0 do
    local chunk, err, partial = client:receive(remaining)

    if chunk and #chunk > 0 then
      table.insert(chunks, chunk)
      remaining = remaining - #chunk
    end

    if partial and #partial > 0 then
      table.insert(chunks, partial)
      remaining = remaining - #partial
    end

    if err and err ~= "timeout" then
      return nil, err
    end
  end

  return table.concat(chunks)
end

local function receive_until_close(client)
  local chunks = {}

  while true do
    local chunk, err, partial = client:receive(1024)
    if chunk and #chunk > 0 then
      table.insert(chunks, chunk)
    end
    if partial and #partial > 0 then
      table.insert(chunks, partial)
    end
    if err == "closed" then
      break
    end
    if err and err ~= "timeout" then
      return nil, err
    end
  end

  return table.concat(chunks)
end

local function read_response_head(client)
  local status_line, err = receive_line(client)
  if not status_line then
    return nil, nil, err
  end

  local headers = {}
  while true do
    local line, line_err = receive_line(client)
    if not line then
      return nil, nil, line_err
    end
    if line == "" then
      break
    end

    local name, value = line:match("^([^:]+):%s*(.*)$")
    if name then
      headers[name:lower()] = value
    end
  end

  return status_line, headers
end

local function receive_chunked_body(client)
  local chunks = {}

  while true do
    local size_line, err = receive_line(client)
    if not size_line then
      return nil, err
    end

    local size_hex = size_line:match("^%s*([0-9A-Fa-f]+)")
    local chunk_size = tonumber(size_hex, 16)
    if not chunk_size then
      return nil, "invalid chunk size"
    end

    if chunk_size == 0 then
      while true do
        local trailer_line, trailer_err = receive_line(client)
        if not trailer_line then
          return nil, trailer_err
        end
        if trailer_line == "" then
          break
        end
      end
      break
    end

    local chunk, chunk_err = receive_exact(client, chunk_size)
    if not chunk then
      return nil, chunk_err
    end
    table.insert(chunks, chunk)

    local _, crlf_err = receive_exact(client, 2)
    if crlf_err then
      return nil, crlf_err
    end
  end

  return table.concat(chunks)
end

local function request_json(device, method, path, body)
  local host = get_bridge_host(device)
  local port = get_bridge_port(device)

  local client = assert(socket.tcp())
  client:settimeout(3)
  assert(client:connect(host, port))

  local payload = body and json.encode(body) or ""
  local request = string.format("%s %s HTTP/1.1\r\nHost: %s\r\nAccept: application/json\r\nConnection: close\r\n", method, path, host)

  if #payload > 0 then
    request = request .. string.format("Content-Type: application/json\r\nContent-Length: %d\r\n", #payload)
  end
  request = request .. "\r\n" .. payload

  assert(client:send(request))
  local status_line, headers, head_err = read_response_head(client)
  assert(status_line, head_err)

  local status_code = tonumber(status_line:match("%s(%d%d%d)%s"))
  if not status_code then
    client:close()
    error("Unable to parse bridge response")
  end

  local response_body = ""
  local transfer_encoding = headers["transfer-encoding"] and headers["transfer-encoding"]:lower() or nil
  local content_length = headers["content-length"] and tonumber(headers["content-length"]) or nil

  if transfer_encoding and transfer_encoding:find("chunked", 1, true) then
    local body_text, body_err = receive_chunked_body(client)
    client:close()
    assert(body_text, body_err)
    response_body = body_text
  elseif content_length ~= nil then
    local body_text, body_err = receive_exact(client, content_length)
    client:close()
    assert(body_text, body_err)
    response_body = body_text
  else
    local body_text, body_err = receive_until_close(client)
    client:close()
    assert(body_text, body_err)
    response_body = body_text
  end

  if response_body == nil or response_body == "" then
    if status_code >= 400 then
      error("Bridge returned HTTP " .. tostring(status_code))
    end
    return {}
  end

  local decoded = json.decode(response_body)
  if status_code >= 400 then
    error(decoded.error or ("Bridge returned HTTP " .. tostring(status_code)))
  end
  return decoded
end

function M.fetch_side(device, side)
  return request_json(device, "GET", "/v1/bedjets/" .. side)
end

function M.send_power(device, side, power_state)
  return request_json(device, "POST", "/v1/bedjets/" .. side .. "/command", { power = power_state })
end

function M.send_fan_step(device, side, fan_step)
  return request_json(device, "POST", "/v1/bedjets/" .. side .. "/command", { fanStep = fan_step })
end

function M.send_mode(device, side, mode)
  return request_json(device, "POST", "/v1/bedjets/" .. side .. "/command", { mode = mode })
end

function M.send_target_temperature(device, side, mode, target_temperature_c)
  return request_json(device, "POST", "/v1/bedjets/" .. side .. "/command", {
    mode = mode,
    targetTemperatureC = target_temperature_c
  })
end

function M.start_profile(device, profile_id)
  return request_json(device, "POST", "/v1/profiles/" .. profile_id .. "/start", {})
end

function M.stop_profile(device, profile_id)
  return request_json(device, "POST", "/v1/profiles/" .. profile_id .. "/stop", {})
end

return M
