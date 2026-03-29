local M = {}

M.definitions = {
  {
    device_network_id = "bedjet-unit-left",
    label = "Left BedJet",
    profile = "bedjet-unit.v1",
    model = "BedJet Left"
  },
  {
    device_network_id = "bedjet-unit-right",
    label = "Right BedJet",
    profile = "bedjet-unit.v1",
    model = "BedJet Right"
  },
  {
    device_network_id = "bedjet-profile-left",
    label = "Left BedJet Bio",
    profile = "bedjet-nightly-bio.v1",
    model = "BedJet Left Bio"
  },
  {
    device_network_id = "bedjet-profile-right",
    label = "Right BedJet Bio",
    profile = "bedjet-nightly-bio.v1",
    model = "BedJet Right Bio"
  },
  {
    device_network_id = "bedjet-hot-high-left",
    label = "Left BedJet Hot High",
    profile = "bedjet-nightly-bio.v1",
    model = "BedJet Left Hot High"
  },
  {
    device_network_id = "bedjet-hot-high-right",
    label = "Right BedJet Hot High",
    profile = "bedjet-nightly-bio.v1",
    model = "BedJet Right Hot High"
  }
}

function M.ensure_devices(driver, should_continue)
  for _, definition in ipairs(M.definitions) do
    if should_continue and not should_continue() then
      return
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
  end
end

return M
