.pragma library

function finiteNumber(value) {
  var number = Number(value)
  return isFinite(number) ? number : NaN
}

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(value, maximum))
}

function insetGeometry(width, height, requestedInset) {
  var safeWidth = Math.max(1, finiteNumber(width) || 1)
  var safeHeight = Math.max(1, finiteNumber(height) || 1)
  var inset = Math.max(0, finiteNumber(requestedInset) || 0)
  var x = Math.min(inset, Math.max(0, (safeWidth - 1) / 2))
  var y = Math.min(inset, Math.max(0, (safeHeight - 1) / 2))

  return {
    x: x,
    y: y,
    width: Math.max(1, safeWidth - x * 2),
    height: Math.max(1, safeHeight - y * 2)
  }
}

function logicalMonitorGeometry(monitor, screen) {
  if (!monitor) return null

  var x = finiteNumber(monitor.x)
  var y = finiteNumber(monitor.y)
  var scale = finiteNumber(monitor.scale)
  var width = screen && screen.name === monitor.name
    ? finiteNumber(screen.width) : finiteNumber(monitor.width) / (scale > 0 ? scale : 1)
  var height = screen && screen.name === monitor.name
    ? finiteNumber(screen.height) : finiteNumber(monitor.height) / (scale > 0 ? scale : 1)

  if (!isFinite(x) || !isFinite(y) || !isFinite(width) || !isFinite(height)
      || width <= 0 || height <= 0)
    return null

  return { x: x, y: y, width: width, height: height }
}

function clientGeometry(ipcObject) {
  if (!ipcObject || !ipcObject.at || !ipcObject.size
      || ipcObject.at.length < 2 || ipcObject.size.length < 2)
    return null

  var x = finiteNumber(ipcObject.at[0])
  var y = finiteNumber(ipcObject.at[1])
  var width = finiteNumber(ipcObject.size[0])
  var height = finiteNumber(ipcObject.size[1])
  if (!isFinite(x) || !isFinite(y) || !isFinite(width) || !isFinite(height)
      || width <= 0 || height <= 0)
    return null

  return { x: x, y: y, width: width, height: height }
}

function monitorReservedInsets(monitor) {
  if (!monitor) return { left: 0, top: 0, right: 0, bottom: 0 }
  var res = monitor.reserved || (monitor.lastIpcObject ? monitor.lastIpcObject.reserved : null)
  if (res && typeof res.length === "number") {
    return {
      left: Math.max(0, finiteNumber(res[0]) || 0),
      top: Math.max(0, finiteNumber(res[1]) || 0),
      right: Math.max(0, finiteNumber(res[2]) || 0),
      bottom: Math.max(0, finiteNumber(res[3]) || 0)
    }
  }
  if (res) {
    return {
      left: Math.max(0, finiteNumber(res.left) || 0),
      top: Math.max(0, finiteNumber(res.top) || 0),
      right: Math.max(0, finiteNumber(res.right) || 0),
      bottom: Math.max(0, finiteNumber(res.bottom) || 0)
    }
  }
  return { left: 0, top: 0, right: 0, bottom: 0 }
}

function usableMonitorGeometry(monitor, screen) {
  var logical = logicalMonitorGeometry(monitor, screen)
  if (!logical) return null

  var reserved = monitorReservedInsets(monitor)
  var x = logical.x + reserved.left
  var y = logical.y + reserved.top
  var width = Math.max(1, logical.width - reserved.left - reserved.right)
  var height = Math.max(1, logical.height - reserved.top - reserved.bottom)

  return {
    x: x,
    y: y,
    width: width,
    height: height,
    reserved: reserved
  }
}

function workspaceTransform(monitor, screen, areaWidth, areaHeight) {
  var usable = usableMonitorGeometry(monitor, screen)
  var targetWidth = finiteNumber(areaWidth)
  var targetHeight = finiteNumber(areaHeight)
  if (!usable || !isFinite(targetWidth) || !isFinite(targetHeight)
      || targetWidth <= 0 || targetHeight <= 0)
    return null

  // Preserve the monitor aspect ratio inside the card. The card is usually
  // closer to square than a 16:9 monitor, so use a uniform scale and center
  // the workspace with letterbox margins instead of stretching it.
  var scaleX = targetWidth / usable.width
  var scaleY = targetHeight / usable.height
  if (!isFinite(scaleX) || !isFinite(scaleY) || scaleX <= 0 || scaleY <= 0) return null
  var scale = Math.min(scaleX, scaleY)
  var renderedWidth = usable.width * scale
  var renderedHeight = usable.height * scale

  return {
    scale: scale,
    scaleX: scale,
    scaleY: scale,
    originX: usable.x,
    originY: usable.y,
    usableWidth: usable.width,
    usableHeight: usable.height,
    offsetX: (targetWidth - renderedWidth) / 2,
    offsetY: (targetHeight - renderedHeight) / 2,
    canvasWidth: targetWidth,
    canvasHeight: targetHeight
  }
}

function previewGeometry(ipcObject, monitor, screen, areaWidth, areaHeight,
                         minimumWidth, minimumHeight) {
  var client = clientGeometry(ipcObject)
  var transform = workspaceTransform(monitor, screen, areaWidth, areaHeight)
  if (!client || !transform)
    return { valid: false, x: 0, y: 0, width: 0, height: 0 }

  var workspaceLeft = transform.originX
  var workspaceTop = transform.originY
  var workspaceRight = workspaceLeft + transform.usableWidth
  var workspaceBottom = workspaceTop + transform.usableHeight
  var coversWorkspace = client.x <= workspaceLeft + 2
    && client.y <= workspaceTop + 2
    && client.x + client.width >= workspaceRight - 2
    && client.y + client.height >= workspaceBottom - 2

  // A maximized/fullscreen client is meant to cover the rendered workspace
  // area, while the card's letterbox margins remain visible.
  if (coversWorkspace) {
    return {
      valid: true,
      x: transform.offsetX,
      y: transform.offsetY,
      width: transform.usableWidth * transform.scale,
      height: transform.usableHeight * transform.scale,
      rawX: transform.offsetX,
      rawY: transform.offsetY,
      rawWidth: transform.usableWidth * transform.scale,
      rawHeight: transform.usableHeight * transform.scale
    }
  }

  var left = clamp(client.x, workspaceLeft, workspaceRight)
  var top = clamp(client.y, workspaceTop, workspaceBottom)
  var right = clamp(client.x + client.width, workspaceLeft, workspaceRight)
  var bottom = clamp(client.y + client.height, workspaceTop, workspaceBottom)
  if (right <= left || bottom <= top)
    return { valid: false, x: 0, y: 0, width: 0, height: 0 }

  var rawX = transform.offsetX + (left - workspaceLeft) * transform.scaleX
  var rawY = transform.offsetY + (top - workspaceTop) * transform.scaleY
  var rawWidth = (right - left) * transform.scaleX
  var rawHeight = (bottom - top) * transform.scaleY
  var minWidth = finiteNumber(minimumWidth) || 0
  var minHeight = finiteNumber(minimumHeight) || 0
  var displayWidth = Math.min(transform.canvasWidth, Math.max(minWidth, rawWidth))
  var displayHeight = Math.min(transform.canvasHeight, Math.max(minHeight, rawHeight))

  return {
    valid: true,
    x: clamp(rawX + (rawWidth - displayWidth) / 2, 0, transform.canvasWidth - displayWidth),
    y: clamp(rawY + (rawHeight - displayHeight) / 2, 0, transform.canvasHeight - displayHeight),
    width: displayWidth,
    height: displayHeight,
    rawX: rawX,
    rawY: rawY,
    rawWidth: rawWidth,
    rawHeight: rawHeight
  }
}

function fallbackGeometry(index, count, areaWidth, areaHeight, spacing) {
  var safeCount = Math.max(1, Number(count) || 1)
  var columns = Math.max(1, Math.ceil(Math.sqrt(safeCount)))
  var rows = Math.max(1, Math.ceil(safeCount / columns))
  var gap = Math.max(0, finiteNumber(spacing) || 0)
  var regionWidth = Math.max(1, finiteNumber(areaWidth) * 0.42)
  var regionHeight = Math.max(1, finiteNumber(areaHeight) * 0.42)
  var width = Math.max(1, (regionWidth - gap * (columns - 1)) / columns)
  var height = Math.max(1, (regionHeight - gap * (rows - 1)) / rows)
  var column = Math.max(0, Number(index) || 0) % columns
  var row = Math.floor(Math.max(0, Number(index) || 0) / columns)

  return {
    valid: false,
    x: Math.max(0, finiteNumber(areaWidth) - regionWidth) + column * (width + gap),
    y: Math.max(0, finiteNumber(areaHeight) - regionHeight) + row * (height + gap),
    width: width,
    height: height
  }
}
