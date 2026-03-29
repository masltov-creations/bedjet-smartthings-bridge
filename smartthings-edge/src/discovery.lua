local log = require "log"
local device_catalog = require "device_catalog"

return function(driver, _, should_continue)
  log.info("BedJet bridge discovery started")
  device_catalog.ensure_devices(driver, should_continue)
end
