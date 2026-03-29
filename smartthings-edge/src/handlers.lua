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
local DEFAULT_POLL_INTERVAL_SECONDS = 15
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
  local gateway_configured = tonumber(device:get_field(fields.POLL_INTERVAL_SECONDS))
  if gateway_configured then
    return clamp(math.floor(gateway_configured), MIN_POLL_INTERVAL_SECONDS, MAX_POLL_INTERVAL_SECONDS)
  end

  local configured = tonumber(device.preferences.pollIntervalSeconds)
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
  schedule_refresh(device, 3)
end

local function start_polling(device)
  local token = (tonumber(device:get_field(fields.POLL_TOKEN)) or 0) + 1
  device:set_field(fields.POLL_TOKEN, token)
  local interval = poll_interval_seconds(device)

  local function tick()
    if tonumber(device:get_field(fields.POLL_TOKEN)) ~= token then
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

local function emit_thermostat_mode(device, power, mode)
  if power ~= "on" then
    device:emit_event(capabilities.thermostatMode.thermostatMode.off())
    device:emit_event(capabilities.thermostatOperatingState.thermostatOperatingState.idle())
    return
  end

  if is_heat_mode(mode) then
    device:emit_event(capabilities.thermostatMode.thermostatMode.heat())
    device:emit_event(capabilities.thermostatOperatingState.thermostatOperatingState.heating())
    return
  end

  device:emit_event(capabilities.thermostatMode.thermostatMode.cool())
  device:emit_event(capabilities.thermostatOperatingState.thermostatOperatingState.cooling())
end

local function detect_side(device)
  if string.find(device.device_network_id or "", "right") then
    return "right"
  end
  if string.find(device.device_network_id or "", "left") then
    return "left"
  end
  if device.preferences.side == "left" or device.preferences.side == "right" then
    return device.preferences.side
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
    device:emit_event(capabilities.switch.switch.on())
  else
    device:emit_event(capabilities.switch.switch.off())
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
  device:emit_event(capabilities.switchLevel.level(as_fan_level(status.fanStep)))
  device:emit_event(capabilities.temperatureMeasurement.temperature({ value = tonumber(status.currentTemperatureC) or 23, unit = "C" }))

  local target_temperature = tonumber(status.targetTemperatureC) or 24
  device:emit_event(capabilities.thermostatCoolingSetpoint.coolingSetpoint({ value = target_temperature, unit = "C" }))
  device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = target_temperature, unit = "C" }))
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
    device:emit_event(capabilities.thermostatMode.thermostatMode.off())
    device:emit_event(capabilities.thermostatOperatingState.thermostatOperatingState.idle())
    device:emit_event(capabilities.thermostatCoolingSetpoint.coolingSetpoint({ value = 24, unit = "C" }))
    device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = 24, unit = "C" }))
    device:emit_event(capabilities.switchLevel.level(40))
    device:emit_event(capabilities.temperatureMeasurement.temperature({ value = 23, unit = "C" }))
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

  if snapshot and snapshot.run and snapshot.run.status == "running" then
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
    end
    schedule_refresh_burst(device)
    return
  end

  local ok, err = pcall(api.send_power, device, side, "on")
  if not ok then
    log.warn(string.format("switch_on failed for %s: %s", side, tostring(err)))
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
    end
    schedule_refresh_burst(device)
    return
  end

  local ok, err = pcall(api.send_power, device, side, "off")
  if not ok then
    log.warn(string.format("switch_off failed for %s: %s", side, tostring(err)))
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
  local ok, err = pcall(api.send_fan_step, device, side, fan_step)
  if not ok then
    log.warn(string.format("set_level failed for %s: %s", side, tostring(err)))
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
  local ok, err = pcall(api.send_target_temperature, device, side, "cool", target_temperature)
  if not ok then
    log.warn(string.format("set_cooling_setpoint failed for %s: %s", side, tostring(err)))
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
  local ok, err = pcall(api.send_target_temperature, device, side, "heat", target_temperature)
  if not ok then
    log.warn(string.format("set_heating_setpoint failed for %s: %s", side, tostring(err)))
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
  local ok, err = pcall(api.send_mode, device, side, "cool")
  if not ok then
    log.warn(string.format("mode_cool failed for %s: %s", side, tostring(err)))
  end
  schedule_refresh_burst(device)
end

function M.mode_heat(_, device)
  local kind = device:get_field(fields.KIND) or detect_kind(device)
  if kind ~= "unit" then
    return
  end

  local side = device:get_field(fields.SIDE) or detect_side(device)
  local ok, err = pcall(api.send_mode, device, side, "heat")
  if not ok then
    log.warn(string.format("mode_heat failed for %s: %s", side, tostring(err)))
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
