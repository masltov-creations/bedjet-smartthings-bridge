local M = {}

M.definitions = {
  {
    device_network_id = "bedjet-unit-left",
    label = "Left BedJet",
    profile = "bedjet-unit.v1",
    model = "BedJet Left"
  },
  {
    device_network_id = "bedjet-unit-right-v2",
    label = "Right BedJet",
    profile = "bedjet-unit.v1",
    model = "BedJet Right"
  },
  {
    device_network_id = "bedjet-profile-left",
    label = "Left BedJet Nightly Bio",
    profile = "bedjet-nightly-bio.v1",
    model = "BedJet Left Nightly Bio"
  },
  {
    device_network_id = "bedjet-profile-right-v2",
    label = "Right BedJet Nightly Bio",
    profile = "bedjet-nightly-bio.v1",
    model = "BedJet Right Nightly Bio"
  }
}

local function existing_device_network_ids(driver)
  local known = {}
  local ok, devices = pcall(function()
    return driver:get_devices()
  end)

  if not ok or type(devices) ~= "table" then
    return known
  end

  for _, device in ipairs(devices) do
    local dni = device and device.device_network_id
    if dni and dni ~= "" then
      known[dni] = true
    end
  end

  return known
end

function M.ensure_devices(driver, should_continue)
  local known_device_network_ids = existing_device_network_ids(driver)

  for _, definition in ipairs(M.definitions) do
    if should_continue and not should_continue() then
      return
    end

    if known_device_network_ids[definition.device_network_id] then
      goto continue
    end

    driver:try_create_device({
      type = "LAN",
      device_network_id = definition.device_network_id,
      label = definition.label,
      profile = definition.profile,
      manufacturer = "Private Install",
      model = definition.model,
      vendor_provided_label = definition.label
    })

    known_device_network_ids[definition.device_network_id] = true
    ::continue::
  end
end

return M
