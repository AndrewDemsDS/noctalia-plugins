--!nonstrict
-- Printers panel: the CUPS destinations with a "set default" action, the
-- active job queue with per-job and cancel-all actions, and the quick actions
-- (open CUPS, printer settings, print clipboard).

local printers = {}
local jobs = {}
local status = { defaultPrinter = "", printerCount = 0, jobCount = 0, hasFault = false }

local pendingCancelAll = false

local function send(cmd)
  noctalia.state.set("printer.cmd", cmd)
end

local function sectionLabel(text)
  return ui.label({ text = text, fontSize = 11, fontWeight = "medium", color = "on_surface_variant" })
end

local function emptyLabel(text)
  return ui.label({ text = text, fontSize = 12, color = "on_surface_variant" })
end

local function printerRow(row)
  local isDefault = row.name == status.defaultPrinter
  local ok = row.enabled
  local stateText = row.discovered and noctalia.tr("panel.discovered") or row.state

  local children = {
    ui.glyph({
      name = ok and "printer" or "printer-off",
      size = 16,
      color = if not ok then "error" elseif row.discovered then "on_surface_variant" else "on_surface",
    }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({
        text = row.name,
        fontSize = 13,
        fontWeight = isDefault and "bold" or "normal",
        maxLines = 1,
      }),
      ui.label({
        text = isDefault and noctalia.tr("panel.state_default", { state = stateText }) or stateText,
        fontSize = 11,
        color = ok and "on_surface_variant" or "error",
        maxLines = 1,
      }),
    }),
  }

  if not isDefault then
    table.insert(
      children,
      ui.button({
        key = "default-" .. row.name,
        text = noctalia.tr("panel.set_default"),
        variant = "outline",
        controlSize = "sm",
        onClick = function()
          send({ op = "set_default", name = row.name })
        end,
      })
    )
  end

  return ui.row({ key = "printer-" .. row.name, gap = 8, align = "center" }, children)
end

local function printersSection()
  local rows = { sectionLabel(noctalia.tr("panel.printers")) }

  if #printers == 0 then
    table.insert(rows, emptyLabel(noctalia.tr("panel.no_printers")))
  else
    for _, row in ipairs(printers) do
      table.insert(rows, printerRow(row))
    end
  end

  return ui.column({ gap = 6 }, rows)
end

local function jobRow(row)
  return ui.row({ key = "job-" .. row.id, gap = 8, align = "center" }, {
    ui.glyph({ name = "file-description", size = 16, color = "on_surface" }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = row.id, fontSize = 13, maxLines = 1 }),
      ui.label({
        text = row.when ~= "" and `{row.user} · {row.when}` or row.user,
        fontSize = 11,
        color = "on_surface_variant",
        maxLines = 1,
      }),
    }),
    ui.button({
      key = "cancel-" .. row.id,
      glyph = "x",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.cancel"),
      onClick = function()
        send({ op = "cancel", id = row.id })
      end,
    }),
  })
end

local function queueHeader()
  local children = {
    sectionLabel(noctalia.trp("panel.queue", #jobs, { count = #jobs })),
    ui.spacer({ flexGrow = 1 }),
  }

  if #jobs > 0 then
    if pendingCancelAll then
      table.insert(
        children,
        ui.button({
          glyph = "check",
          variant = "destructive",
          controlSize = "sm",
          tooltip = noctalia.tr("panel.cancel_all_confirm"),
          onClick = function()
            pendingCancelAll = false
            send({ op = "cancel_all" })
          end,
        })
      )
      table.insert(
        children,
        ui.button({
          glyph = "x",
          variant = "ghost",
          controlSize = "sm",
          onClick = function()
            pendingCancelAll = false
            render()
          end,
        })
      )
    else
      table.insert(
        children,
        ui.button({
          text = noctalia.tr("panel.cancel_all"),
          variant = "outline",
          controlSize = "sm",
          onClick = function()
            pendingCancelAll = true
            render()
          end,
        })
      )
    end
  end

  return ui.row({ gap = 6, align = "center" }, children)
end

local function queueSection()
  local rows = { queueHeader() }

  if #jobs == 0 then
    table.insert(rows, emptyLabel(noctalia.tr("panel.no_jobs")))
  else
    for _, row in ipairs(jobs) do
      table.insert(rows, jobRow(row))
    end
  end

  return ui.column({ gap = 6 }, rows)
end

local function actionsSection()
  return ui.column({ gap = 6 }, {
    ui.row({ gap = 6 }, {
      ui.button({
        text = noctalia.tr("panel.open_cups"),
        glyph = "external-link",
        variant = "outline",
        controlSize = "sm",
        flexGrow = 1,
        onClick = function()
          send({ op = "open_queue" })
        end,
      }),
      ui.button({
        text = noctalia.tr("panel.printer_settings"),
        glyph = "settings",
        variant = "outline",
        controlSize = "sm",
        flexGrow = 1,
        onClick = function()
          send({ op = "open_settings" })
        end,
      }),
    }),
    ui.button({
      text = noctalia.tr("panel.print_clipboard"),
      glyph = "clipboard",
      variant = "outline",
      controlSize = "sm",
      enabled = status.defaultPrinter ~= "",
      onClick = function()
        send({ op = "print_clipboard" })
      end,
    }),
  })
end

function render()
  panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 10 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.refresh"),
        onClick = function()
          send({ op = "refresh" })
        end,
      }),
      ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.plugin_settings"),
        onClick = function()
          noctalia.openSettings()
        end,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          panel.close()
        end,
      }),
    }),
    ui.scroll({ flexGrow = 1, gap = 12 }, {
      printersSection(),
      ui.separator({}),
      queueSection(),
    }),
    actionsSection(),
  }))
end

function onOpen(_context)
  pendingCancelAll = false
  printers = noctalia.state.get("printer.printers") or {}
  jobs = noctalia.state.get("printer.jobs") or {}
  status = noctalia.state.get("printer.status") or status
  send({ op = "refresh" })
  render()
end

noctalia.state.watch("printer.printers", function(value)
  printers = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("printer.jobs", function(value)
  jobs = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("printer.status", function(value)
  if type(value) == "table" then
    status = value
  end
  render()
end)
