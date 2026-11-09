.pragma library

function positiveId(value) {
  var id = Number(value)
  return isFinite(id) && Math.floor(id) === id && id > 0 && id <= 2147483647
    ? id : -1
}

function blockOf(id, slotsPerMonitor) {
  id = positiveId(id)
  var slots = Number(slotsPerMonitor)
  if (id < 1 || !isFinite(slots) || Math.floor(slots) !== slots || slots < 1)
    return -1
  return Math.floor((id - 1) / slots)
}

function slotOf(id, slotsPerMonitor) {
  id = positiveId(id)
  var slots = Number(slotsPerMonitor)
  if (id < 1 || !isFinite(slots) || Math.floor(slots) !== slots || slots < 1)
    return -1
  return (id - 1) % slots + 1
}

function parseMonitorBlocks(raw) {
  var blocks = ({})
  var text = String(raw || "")
  if (text.length > 16384) return blocks
  var lines = text.split("\n")
  var lineCount = Math.min(lines.length, 64)
  for (var i = 0; i < lineCount; i++) {
    var fields = lines[i].split("\t")
    if (fields.length < 3 || fields[1] === "" || fields[1].length > 255) continue
    var block = Number(fields[0])
    if (isFinite(block) && Math.floor(block) === block && block >= 0
        && block <= 214748364)
      blocks[fields[1]] = block
  }
  return blocks
}

function entries(workspaces, createdIds, block, monitorName,
                 initialSlots, slotsPerMonitor) {
  var ownIds = []
  var guestIds = []
  var base = Number(block) * Number(slotsPerMonitor)
  var initial = Number(initialSlots)
  var slots = Number(slotsPerMonitor)
  if (!isFinite(base) || !isFinite(initial) || !isFinite(slots)
      || Math.floor(block) !== Number(block) || block < 0
      || initial < 0 || slots < initial || base + slots > 2147483647)
    return []

  for (var slot = 1; slot <= initial; slot++) ownIds.push(base + slot)

  var live = workspaces || []
  for (var i = 0; i < live.length; i++) {
    var workspace = live[i]
    var id = positiveId(workspace && workspace.id)
    if (id < 1) continue
    if (blockOf(id, slots) === block) {
      if (ownIds.indexOf(id) === -1) ownIds.push(id)
    } else if (monitorName && workspace.monitor
               && workspace.monitor.name === monitorName
               && guestIds.indexOf(id) === -1) {
      guestIds.push(id)
    }
  }

  var created = createdIds || []
  for (var createdIndex = 0; createdIndex < created.length; createdIndex++) {
    var createdId = positiveId(created[createdIndex])
    if (createdId > base + initial && blockOf(createdId, slots) === block
        && ownIds.indexOf(createdId) === -1)
      ownIds.push(createdId)
  }

  ownIds.sort(function(left, right) { return left - right })
  guestIds.sort(function(left, right) { return left - right })

  var result = []
  for (var ownIndex = 0; ownIndex < ownIds.length; ownIndex++)
    result.push({ id: ownIds[ownIndex], slot: slotOf(ownIds[ownIndex], slots), guest: false })
  for (var guestIndex = 0; guestIndex < guestIds.length; guestIndex++)
    result.push({ id: guestIds[guestIndex], slot: slotOf(guestIds[guestIndex], slots), guest: true })
  return result
}

function nextFreeId(workspaces, createdIds, block, initialSlots, slotsPerMonitor) {
  var live = workspaces || []
  var created = createdIds || []
  var base = Number(block) * Number(slotsPerMonitor)
  var initial = Number(initialSlots)
  var slots = Number(slotsPerMonitor)
  if (!isFinite(base) || !isFinite(initial) || !isFinite(slots)
      || Math.floor(block) !== Number(block) || block < 0
      || initial < 0 || slots < initial || base + slots > 2147483647)
    return -1

  for (var slot = initial + 1; slot <= slots; slot++) {
    var id = base + slot
    var used = false
    for (var i = 0; i < live.length; i++) {
      if (positiveId(live[i] && live[i].id) === id) {
        used = true
        break
      }
    }
    if (!used && created.indexOf(id) === -1) return id
  }
  return -1
}

function isDeletable(id, block, initialSlots, slotsPerMonitor) {
  return blockOf(id, slotsPerMonitor) === Number(block)
    && slotOf(id, slotsPerMonitor) > Number(initialSlots)
}
