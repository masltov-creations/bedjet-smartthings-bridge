local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local discovery = require "discovery"
local handlers = require "handlers"

local bedjet_driver = Driver("bedjet-bridge", {
  discovery = discovery,
  lifecycle_handlers = {
    added = handlers.device_added,
    init = handlers.device_init,
    infoChanged = handlers.info_changed,
    removed = handlers.device_removed
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handlers.switch_on,
      [capabilities.switch.commands.off.NAME] = handlers.switch_off
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = handlers.set_level
    },
    [capabilities.thermostatMode.ID] = {
      [capabilities.thermostatMode.commands.setThermostatMode.NAME] = handlers.set_thermostat_mode,
      [capabilities.thermostatMode.commands.off.NAME] = handlers.mode_off,
      [capabilities.thermostatMode.commands.cool.NAME] = handlers.mode_cool,
      [capabilities.thermostatMode.commands.heat.NAME] = handlers.mode_heat
    },
    [capabilities.thermostatCoolingSetpoint.ID] = {
      [capabilities.thermostatCoolingSetpoint.commands.setCoolingSetpoint.NAME] = handlers.set_cooling_setpoint
    },
    [capabilities.thermostatHeatingSetpoint.ID] = {
      [capabilities.thermostatHeatingSetpoint.commands.setHeatingSetpoint.NAME] = handlers.set_heating_setpoint
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handlers.refresh
    }
  }
})

bedjet_driver:run()
