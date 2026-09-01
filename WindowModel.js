.pragma library

function normalizedAddress(value) {
  var address = String(value || "").trim().toLowerCase()
  if (!address.match(/^(0x)?[0-9a-f]+$/)) return ""
  return address.indexOf("0x") === 0 ? address : "0x" + address
}

function toplevelAddress(toplevel) {
  if (!toplevel) return ""
  var ipc = toplevel.lastIpcObject
  return normalizedAddress(toplevel.address || (ipc && ipc.address))
}

function groupAddresses(toplevel) {
  var ipc = toplevel && toplevel.lastIpcObject
  var grouped = ipc && ipc.grouped && typeof ipc.grouped.length === "number"
    ? ipc.grouped : []
  var addresses = []
  for (var i = 0; i < grouped.length; i++) {
    var address = normalizedAddress(grouped[i])
    if (address && addresses.indexOf(address) === -1) addresses.push(address)
  }
  var ownAddress = toplevelAddress(toplevel)
  if (ownAddress && addresses.indexOf(ownAddress) === -1) addresses.push(ownAddress)
  return addresses.length > 1 ? addresses : []
}

function componentRoot(parents, address) {
  var root = address
  while (parents[root] && parents[root] !== root) root = parents[root]
  return root
}

function unionAddresses(parents, left, right) {
  if (!parents[left]) parents[left] = left
  if (!parents[right]) parents[right] = right
  var leftRoot = componentRoot(parents, left)
  var rightRoot = componentRoot(parents, right)
  if (leftRoot !== rightRoot) parents[rightRoot] = leftRoot
}

function betterRepresentative(candidate, current, activeAddress) {
  if (!current) return true
  var candidateIpc = candidate.lastIpcObject || {}
  var currentIpc = current.lastIpcObject || {}
  if (candidateIpc.hidden !== true && currentIpc.hidden === true) return true
  if (candidateIpc.hidden === true && currentIpc.hidden !== true) return false

  var active = normalizedAddress(activeAddress)
  var candidateAddress = toplevelAddress(candidate)
  var currentAddress = toplevelAddress(current)
  if (active) {
    if (candidateAddress === active && currentAddress !== active) return true
    if (candidateAddress !== active && currentAddress === active) return false
  }
  if (candidateIpc.acceptsInput === true && currentIpc.acceptsInput !== true) return true
  if (candidateIpc.acceptsInput !== true && currentIpc.acceptsInput === true) return false
  return false
}

function resolveWorkspacePreviews(clients, activeAddress) {
  var values = clients || []
  var parents = {}
  var ownAddresses = []

  for (var i = 0; i < values.length; i++) {
    var ownAddress = toplevelAddress(values[i])
    ownAddresses[i] = ownAddress
    var addresses = groupAddresses(values[i])
    for (var j = 0; j < addresses.length; j++)
      unionAddresses(parents, ownAddress, addresses[j])
  }

  var membersByGroup = {}
  var representativeByGroup = {}
  var keys = []
  for (var k = 0; k < values.length; k++) {
    var address = ownAddresses[k]
    var key = address && parents[address] ? componentRoot(parents, address) : ""
    keys[k] = key
    if (key) {
      if (!membersByGroup[key]) membersByGroup[key] = []
      membersByGroup[key].push(values[k])
      if (betterRepresentative(values[k], representativeByGroup[key], activeAddress))
        representativeByGroup[key] = values[k]
    }
  }

  var result = []
  var seenGroups = {}
  for (var n = 0; n < values.length; n++) {
    var client = values[n]
    var groupKey = keys[n]
    if (!groupKey) {
      result.push({
        type: "window",
        isGroup: false,
        toplevel: client,
        activeMember: client,
        members: client ? [client] : [],
        memberCount: client ? 1 : 0,
        address: toplevelAddress(client),
        lastIpcObject: client ? client.lastIpcObject : null,
        monitor: client ? client.monitor : null,
        wayland: client ? client.wayland : null,
        title: client ? (client.title || "") : ""
      })
    } else if (!seenGroups[groupKey]) {
      seenGroups[groupKey] = true
      var representative = representativeByGroup[groupKey] || client
      var members = membersByGroup[groupKey] || [representative]
      result.push({
        type: members.length > 1 ? "group" : "window",
        isGroup: members.length > 1,
        toplevel: representative,
        activeMember: representative,
        members: members,
        memberCount: members.length,
        address: toplevelAddress(representative),
        lastIpcObject: representative.lastIpcObject,
        monitor: representative.monitor,
        wayland: representative.wayland,
        title: representative.title || ""
      })
    }
  }
  return result
}
