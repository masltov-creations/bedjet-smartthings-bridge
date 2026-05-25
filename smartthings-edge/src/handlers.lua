local capabilities = require "st.capabilities"
local log = require "log"
local api = require "bridge_api"
local fields = require "fields"
local device_catalog = require "device_catalog"

local M = {}
local SUPPORTED_THERMOSTAT_MODES = { "off", "cool", "heat" }
local SUPPORTED_OPERATING_STATES = { "idle", "cooling", "heating" }
local COOLING_RANGE_C = { minimum = 18, maximum = 32, step = 1 }
local HEATING_RANGE_C = { minimum = 18, maximum = 38, step = 1 }
local LEVEL_RANGE = { minimum = 1, maximum = 100, step = 5 }
local TEMPERATURE_RANGE_C = { minimum = 18, maximum = 38 }
local DEFAULT_POLL_INTERVAL_SECONDS = 5
local MIN_POLL_INTERVAL_SECONDS = 5
local MAX_POLL_INTERVAL_SECONDS = 120

local function ensure_catalog_devices(driver)
  local ok, err = pcall(device_catalog.ensure_devices, driver)
  if not ok then
    log.warn(string.format("device catalog ensure failed: %s", tostring(err)))
  end
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function poll_interval_seconds(device)
  local gateway_configured = tonumber(device:get_field(fields.POLL_INTERVAL_SECONDS) or 0)
  if gateway_configured then
    return clamp(math.floor(gateway_configured), MIN_POLL_INTERVAL_SECONDS, MAX_POLL_INTERVAL_SECONDS)
  end

  local configured = tonumber((device.preferences and device.preferences.pollIntervalSeconds) or 0)
  if not configured then
    return DEFAULT_POLL_INTERVAL_SECONDS
  end
  return clamp(math.floor(configured), MIN_POLL_INTERVAL_SECONDS, MAX_POLL_INTERVAL_SECONDS)
end

local function safe_refresh(device)
  local ok, err = pcall(M.refresh, nil, device)
  if not ok then
    log.warn(string.format("Refresh failed: %s", tostring(err)))
  end
end

local function schedule_refresh(device, delay_seconds)
  local delay = tonumber(delay_seconds) or 1
  device.thread:call_with_delay(delay, function()
    safe_refresh(device)
  end)
end

local function schedule_refresh_burst(device)
  schedule_refresh(device, 1)
  schedule_refresh(device, 4)
end

local function remember_unit_status(device, status)
  if not status or type(status) ~= "table" then
    return
  end

  device:set_field(fields.LAST_POWER, status.power)
  device:set_field(fields.LAST_MODE, status.mode)
  device:set_field(fields.LAST_FAN_STEP, tonumber(status.fanStep))
  device:set_field(fields.LAST_TARGET_TEMPERATURE_C, tonumber(status.targetTemperatureC))
end

local function get_remembered_unit_status(device)
  local power = device:get_field(fields.LAST_POWER)
  local mode = device:get_field(fields.LAST_MODE)
  local fan_step = tonumber(device:get_field(fields.LAST_FAN_STEP))
  local target_temperature_c = tonumber(device:get_field(fields.LAST_TARGET_TEMPERATURE_C))

  if power == nil and mode == nil and fan_step == nil and target_temperature_c == nil then
    return nil
  end

  return {
    power = power,
    mode = mode,
    fanStep = fan_step,
    targetTemperatureC = target_temperature_c
  }
end

local function start_polling(device)
  local token = (tonumber(device:get_field(fields.POLL_TOKEN) or 0) or 0) + 1
  device:set_field(fields.POLL_TOKEN, token)
  local interval = poll_interval_seconds(device)

  local function tick()
    if (tonumber(device:get_field(fields.POLL_TOKEN) or 0) or 0) ~= token then
      return
    end
    safe_refresh(device)
    device.thread:call_with_delay(interval, tick)
  end

  device.thread:call_with_delay(interval, tick)
end

local function is_heat_mode(mode)
  return mode == "heat" or mode == "extht"
end

local function safe_emit_event(device, event, context)
  local ok, err = pcall(device.emit_event, device, event)
  if not ok then
    log.warn(string.format("emit_event failed (%s): %s", context or "unknown", tostring(err)))
    return false
  end
  return true
end

local function emit_thermostat_mode(device, power, mode)
  if power ~= "on" then
    safe_emit_event(device, capabilities.thermostatMode.thermostatMode.off(), "thermostatMode.off")
    safe_emit_event(device, capabilities.thermostatOperatingState.thermostatOperatingState.idle(), "thermostatOperatingState.idle")
    return
  end

  if is_heat_mode(mode) then
    safe_emit_event(device, capabilities.thermostatMode.thermostatMode.heat(), "thermostatMode.heat")
    safe_emit_event(device, capabilities.thermostatOperatingState.thermostatOperatingState.heating(), "thermostatOperatingState.heating")
    return
  end

  safe_emit_event(device, capabilities.thermostatMode.thermostatMode.cool(), "thermostatMode.cool")
  safe_emit_event(device, capabilities.thermostatOperatingState.thermostatOperatingState.cooling(), "thermostatOperatingState.cooling")
end

local function detect_side(device)
  if string.find(device.device_network_id or "", "right") then
    return "right"
  end
  if string.find(device.device_network_id or "", "left") then
    return "left"
  end
  return "left"
end

local function detect_kind(device)
  if string.find(device.device_network_id or "", "profile") then
    return "profile"
  end
  if string.find(device.device_network_id or "", "hot-high") then
    return "profile"
  end
  return "unit"
end

local function detect_profile_id(device, side)
  local dni = device.device_network_id or ""
  if string.find(dni, "hot-high") then
    return string.format("%s-hot-high", side)
  end
  return string.format("%s-nightly-bio", side)
end

local function is_profile_switch_on(profile_id, run)
  if not run or type(run) ~= "table" then
    return false
  end

  if run.profileId ~= profile_id then
    return false
  end

  return run.status == "running" or run.status == "completed"
end

local function sanitize_label_part(value, fallback)
  local raw = tostring(value or "")
  local cleaned = raw:gsub("[^%w%-_ ]", "")
  cleaned = cleaned:gsub("%s+", " ")
  cleaned = cleaned:match("^%s*(.-)%s*$")
  if cleaned == nil or cleaned == "" then
    return fallback
  end
  return cleaned
end

local function pairing_suffix(pairing)
  if not pairing or not pairing.deviceId then
    return nil
  end
  local compact = tostring(pairing.deviceId):gsub("[^%x]", "")
  if compact == "" then
    return nil
  end
  if #compact > 4 then
    return compact:sub(#compact - 3)
  end
  return compact
end

local function desired_label_for_device(device, side, kind, pairing)
  local pairing_name = sanitize_label_part(pairing and pairing.displayName, side == "right" and "Right" or "Left")
  local suffix = pairing_suffix(pairing)
  local base = pairing_name
  if suffix then
    base = string.format("%s-%s", pairing_name, suffix)
  end

  local dni = device.device_network_id or ""
  if kind == "unit" then
    return string.format("%s BedJet", base)
  end
  if string.find(dni, "hot-high") then
    return string.format("%s BedJet Hot High", base)
  end
  return string.format("%s BedJet Nightly Bio", base)
end

local function update_dynamic_label(device, side, kind, pairing)
  local desired = desired_label_for_device(device, side, kind, pairing)
  local prior = device:get_field(fields.LAST_LABEL)
  if prior == desired then
    return
  end

  local ok, err = pcall(device.try_update_metadata, device, {
    vendor_provided_label = desired
  })
  if ok then
    device:set_field(fields.LAST_LABEL, desired)
  else
    log.warn(string.format("label update failed for %s: %s", device.device_network_id or "unknown", tostring(err)))
  end
end

local function as_fan_level(fan_step)
  local clamped = math.max(1, math.min(20, tonumber(fan_step) or 1))
  return math.floor((clamped / 20) * 100)
end

local function as_fan_step(level)
  local clamped = math.max(1, math.min(100, tonumber(level) or 1))
  return math.max(1, math.min(20, math.floor((clamped / 100) * 20 + 0.5)))
end

local function emit_switch(device, is_on)
  if is_on then
    safe_emit_event(device, capabilities.switch.switch.on(), "switch.on")
  else
    safe_emit_event(device, capabilities.switch.switch.off(), "switch.off")
  end
end

local function emit_static_capability_metadata(device)
  local events = {
    capabilities.thermostatMode.supportedThermostatModes({ value = SUPPORTED_THERMOSTAT_MODES }),
    capabilities.thermostatOperatingState.supportedThermostatOperatingStates({ value = SUPPORTED_OPERATING_STATES }),
    capabilities.thermostatCoolingSetpoint.coolingSetpointRange({ value = COOLING_RANGE_C, unit = "C" }),
    capabilities.thermostatHeatingSetpoint.heatingSetpointRange({ value = HEATING_RANGE_C, unit = "C" }),
    capabilities.switchLevel.levelRange({ value = LEVEL_RANGE }),
    capabilities.temperatureMeasurement.temperatureRange({ value = TEMPERATURE_RANGE_C, unit = "C" })
  }

  for _, event in ipairs(events) do
    local ok, err = pcall(device.emit_event, device, event)
    if not ok then
      log.warn(string.format("Skipping unsupported capability metadata event: %s", tostring(err)))
    end
  end
end

local function apply_unit_snapshot(device, snapshot)
  if not snapshot or not snapshot.gateway or not snapshot.gateway.status then
    return
  end

  local status = snapshot.gateway.status

  emit_static_capability_metadata(device)
  emit_switch(device, status.power == "on")
  emit_thermostat_mode(device, status.power, status.mode)
  safe_emit_event(device, capabilities.switchLevel.level(as_fan_level(status.fanStep)), "switchLevel.level")
  safe_emit_event(
    device,
    capabilities.temperatureMeasurement.temperature({ value = tonumber(status.currentTemperatureC) or 23, unit = "C" }),
    "temperatureMeasurement.temperature"
  )

  local target_temperature = tonumber(status.targetTemperatureC) or 24
  safe_emit_event(
    device,
    capabilities.thermostatCoolingSetpoint.coolingSetpoint({ value = target_temperature, unit = "C" }),
    "thermostatCoolingSetpoint.coolingSetpoint"
  )
  safe_emit_event(
    device,
    capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = target_temperature, unit = "C" }),
    "thermostatHeatingSetpoint.heatingSetpoint"
  )
  remember_unit_status(device, status)
end

local function apply_unit_command_response(device, response)
  if not response or type(response) ~= "table" or type(response.status) ~= "table" then
    return false
  end

  apply_unit_snapshot(device, {
    gateway = {
      status = response.status
    }
  })

  return true
end

function M.device_added(_, device)
  local side = detect_side(device)
  local kind = detect_kind(device)
  device:set_field(fields.SIDE, side, { persist = true })
  device:set_field(fields.KIND, kind, { persist = true })
  if kind == "profile" then
    device:set_field(fields.PROFILE_ID, detect_profile_id(device, side), { persist = true })
  end

  emit_switch(device, false)
  if kind == "unit" then
    emit_static_capability_metadata(device)
    safe_emit_event(device, capabilities.thermostatMode.thermostatMode.off(), "device_added.thermostatMode.off")
    safe_emit_event(device, capabilities.thermostatOperatingState.thermostatOperatingState.idle(), "device_added.thermostatOperatingState.idle")
    safe_emit_event(device, capabilities.thermostatCoolingSetpoint.coolingSetpoint({ value = 24, unit = "C" }), "device_added.coolingSetpoint")
    safe_emit_event(device, capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = 24, unit = "C" }), "device_added.heatingSetpoint")
    safe_emit_event(device, capabilities.switchLevel.level(40), "device_added.switchLevel")
    safe_emit_event(device, capabilities.temperatureMeasurement.temperature({ value = 23, unit = "C" }), "device_added.temperature")
  end
end

function M.device_init(driver, device)
  ensure_catalog_devices(driver)
  local side = detect_side(device)
  local kind = detect_kind(device)
  device:set_field(fields.SIDE, side, { persist = true })
  device:set_field(fields.KIND, kind, { persist = true })
  if kind == "profile" then
    device:set_field(fields.PROFILE_ID, detect_profile_id(device, side), { persist = true })
  end
  start_polling(device)
  schedule_refresh(device, 1)
end

function M.info_changed(_, device)
  local side = detect_side(device)
  local kind = detect_kind(device)
  device:set_field(fields.SIDE, side, { persist = true })
  if kind == "profile" then
    device:set_field(fields.PROFILE_ID, detect_profile_id(device, side), { persist = true })
  end
  start_polling(device)
end

function M.refresh(_, device)
  if device.driver then
    ensure_catalog_devices(device.driver)
  end

  local side = device:get_field(fields.SIDE) or detect_side(device)
  local kind = device:get_field(fields.KIND) or detect_kind(device)
  local ok, snapshot_or_err = pcall(api.fetch_side, device, side)
  if not ok then
    log.warn(string.format("refresh failed for %s: %s", side, tostring(snapshot_or_err)))
    return
  end
  local snapshot = snapshot_or_err
  local configured_poll = snapshot and snapshot.gatewayConfig and tonumber(snapshot.gatewayConfig.pollIntervalSeconds) or nil
  if configured_poll then
    configured_poll = clamp(math.floor(configured_poll), MIN_POLL_INTERVAL_SECONDS, MAX_POLL_INTERVAL_SECONDS)
    local prior_poll = tonumber(device:get_field(fields.POLL_INTERVAL_SECONDS))
    if prior_poll ~= configured_poll then
      device:set_field(fields.POLL_INTERVAL_SECONDS, configured_poll)
      start_polling(device)
    end
  end

  if kind == "unit" then
    apply_unit_snapshot(device, snapshot)
    return
  end

  local profile_id = device:get_field(fields.PROFILE_ID) or detect_profile_id(device, side)
  if is_profile_switch_on(profile_id, snapshot and snapshot.run) then
    emit_switch(device, true)
  else
    emit_switch(device, false)
  end
end

function M.switch_on(_, device)
  local side = device:get_field(fields.SIDE) or detect_side(device)
  local kind = device:get_field(fields.KIND) or detect_kind(device)

  if kind == "profile" then
    local profile_id = device:get_field(fields.PROFILE_ID) or detect_profile_id(device, side)
    local ok, err = pcall(api.start_profile, device, profile_id)
    if not ok then
      log.warn(string.format("switch_on profile failed for %s (%s): %s", side, profile_id, tostring(err)))
    else
      emit_switch(device, true)
    end
    schedule_refresh_burst(device)
    return
  end

  local ok, response_or_err = pcall(api.send_power, device, side, "on")
  if not ok then
    log.warn(string.format("switch_on failed for %s: %s", side, tostring(response_or_err)))
    schedule_refresh_burst(device)
    return
  end

  if not apply_unit_command_response(device, response_or_err) then
    log.warn(string.format("switch_on returned no usable status for %s", side))
  end

  schedule_refresh_burst(device)
end

function M.switch_off(_, device)
  local side = device:get_field(fields.SIDE) or detect_side(device)
  local kind = device:get_field(fields.KIND) or detect_kind(device)

  if kind == "profile" then
    local profile_id = device:get_field(fields.PROFILE_ID) or detect_profile_id(device, side)
    local ok, err = pcall(api.stop_profile, device, profile_id)
    if not ok then
      log.warn(string.format("switch_off profile failed for %s (%s): %s", side, profile_id, tostring(err)))
    else
      emit_switch(device, false)
    end
    schedule_refresh_burst(device)
    return
  end

  local ok, response_or_err = pcall(api.send_power, device, side, "off")
  if not ok then
    log.warn(string.format("switch_off failed for %s: %s", side, tostring(response_or_err)))
    schedule_refresh_burst(device)
    return
  end

  if not apply_unit_command_response(device, response_or_err) then
    log.warn(string.format("switch_off returned no usable status for %s", side))
  end

  schedule_refresh_burst(device)
end

function M.set_level(_, device, command)
  local kind = device:get_field(fields.KIND) or detect_kind(device)
  if kind ~= "unit" then
    return
  end

  local side = device:get_field(fields.SIDE) or detect_side(device)
  local fan_step = as_fan_step(command.args.level)
  local ok, response_or_err = pcall(api.send_fan_step, device, side, fan_step)
  if not ok then
    log.warn(string.format("set_level failed for %s: %s", side, tostring(response_or_err)))
  else
    apply_unit_command_response(device, response_or_err)
  end
  schedule_refresh_burst(device)
end

function M.set_cooling_setpoint(_, device, command)
  local kind = device:get_field(fields.KIND) or detect_kind(device)
  if kind ~= "unit" then
    return
  end

  local side = device:get_field(fields.SIDE) or detect_side(device)
  local target_temperature = tonumber(command.args.setpoint) or tonumber(command.args.temperature) or 24
  local ok, response_or_err = pcall(api.send_target_temperature, device, side, "cool", target_temperature)
  if not ok then
    log.warn(string.format("set_cooling_setpoint failed for %s: %s", side, tostring(response_or_err)))
  else
    apply_unit_command_response(device, response_or_err)
  end
  schedule_refresh_burst(device)
end

function M.set_heating_setpoint(_, device, command)
  local kind = device:get_field(fields.KIND) or detect_kind(device)
  if kind ~= "unit" then
    return
  end

  local side = device:get_field(fields.SIDE) or detect_side(device)
  local target_temperature = tonumber(command.args.setpoint) or tonumber(command.args.temperature) or 24
  local ok, response_or_err = pcall(api.send_target_temperature, device, side, "heat", target_temperature)
  if not ok then
    log.warn(string.format("set_heating_setpoint failed for %s: %s", side, tostring(response_or_err)))
  else
    apply_unit_command_response(device, response_or_err)
  end
  schedule_refresh_burst(device)
end

function M.mode_off(_, device)
  M.switch_off(_, device)
end

function M.mode_cool(_, device)
  local kind = device:get_field(fields.KIND) or detect_kind(device)
  if kind ~= "unit" then
    return
  end

  local side = device:get_field(fields.SIDE) or detect_side(device)
  local ok, response_or_err = pcall(api.send_mode, device, side, "cool")
  if not ok then
    log.warn(string.format("mode_cool failed for %s: %s", side, tostring(response_or_err)))
  else
    apply_unit_command_response(device, response_or_err)
  end
  schedule_refresh_burst(device)
end

function M.mode_heat(_, device)
  local kind = device:get_field(fields.KIND) or detect_kind(device)
  if kind ~= "unit" then
    return
  end

  local side = device:get_field(fields.SIDE) or detect_side(device)
  local ok, response_or_err = pcall(api.send_mode, device, side, "heat")
  if not ok then
    log.warn(string.format("mode_heat failed for %s: %s", side, tostring(response_or_err)))
  else
    apply_unit_command_response(device, response_or_err)
  end
  schedule_refresh_burst(device)
end

function M.set_thermostat_mode(_, device, command)
  local requested_mode = command.args.mode or command.args[1]
  if requested_mode == "off" then
    M.mode_off(_, device)
    return
  end
  if requested_mode == "heat" then
    M.mode_heat(_, device)
    return
  end
  M.mode_cool(_, device)
end

function M.device_removed(_, device)
  local token = (tonumber(device:get_field(fields.POLL_TOKEN)) or 0) + 1
  device:set_field(fields.POLL_TOKEN, token)
  log.info("BedJet device removed", { device = device.device_network_id })
end

return M
