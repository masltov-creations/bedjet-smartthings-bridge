local cosock = require "cosock"
local socket = require "cosock.socket"
local json = require "st.json"
local log = require "log"

local M = {}
local LAST_KNOWN_IP_FIELD = "bedjet_last_known_bridge_ip"

local function trim(value)
  return (value or ""):match("^%s*(.-)%s*$")
end

local function is_ipv4(value)
  if not value then
    return false
  end
  local a, b, c, d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then
    return false
  end
  local parts = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
  for _, part in ipairs(parts) do
    if not part or part < 0 or part > 255 then
      return false
    end
  end
  return true
end

local function sanitize_host(value)
  local host = trim(value)
  host = host:gsub("^https?://", "")
  host = host:gsub("/.*$", "")
  return trim(host)
end

local function resolve_ipv4(host)
  local dns = socket.dns
  if not dns or not dns.toip then
    return nil
  end
  local ok, ip = pcall(dns.toip, host)
  if not ok or not is_ipv4(ip) then
    return nil
  end
  return ip
end

local function get_bridge_host(device)
  local value = sanitize_host(device.preferences.bridgeHost)
  if value == "" or value == "bridge-host-or-ip" then
    return "bedjet-bridge.local"
  end
  return value
end

local function get_bridge_port(device)
  return tonumber(device.preferences.bridgePort) or 8787
end

local function get_last_known_ip(device)
  local stored = sanitize_host(device:get_field(LAST_KNOWN_IP_FIELD))
  if is_ipv4(stored) then
    return stored
  end
  return nil
end

local function save_last_known_ip(device, ip)
  if not is_ipv4(ip) then
    return
  end
  local current = get_last_known_ip(device)
  if current ~= ip then
    device:set_field(LAST_KNOWN_IP_FIELD, ip, { persist = true })
  end
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

local function request_json_using_host(host, device, method, path, body)
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

local function request_json(device, method, path, body)
  local configured_host = get_bridge_host(device)
  local hosts = { configured_host }
  local fallback_ip = get_last_known_ip(device)
  if fallback_ip and fallback_ip ~= configured_host then
    table.insert(hosts, fallback_ip)
  end

  local last_err = nil
  for _, host in ipairs(hosts) do
    local ok, result_or_err = pcall(request_json_using_host, host, device, method, path, body)
    if ok then
      if not is_ipv4(configured_host) then
        local resolved_ip = resolve_ipv4(configured_host)
        if resolved_ip then
          save_last_known_ip(device, resolved_ip)
        end
      else
        save_last_known_ip(device, configured_host)
      end
      if host ~= configured_host then
        log.warn(string.format("Bridge host fallback in use: configured=%s fallbackIp=%s", configured_host, host))
      end
      return result_or_err
    end
    last_err = tostring(result_or_err)
  end

  error(last_err or ("Unable to reach bridge host " .. configured_host))
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
