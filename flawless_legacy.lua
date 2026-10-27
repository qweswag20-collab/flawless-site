-- flawless 1.4.3 | Skeet / gamesense, CS:GO Lua API.
-- Self-contained: no HTTP, FFI, downloaded modules, or remote configs.
-- Master starts disabled. Menu: LUA > B.

local VERSION, DB_KEY = "1.4.3", "flawless.legacy.v1"
local OLD_DB_KEY = "nexra.legacy.v1"
local TAB, BOX = "LUA", "B"
local floor, min, max = math.floor, math.min, math.max
local unpack = unpack or table.unpack
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local function clamp(v, lo, hi)
    return max(lo, min(hi, v))
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

local function contains(list, value)
    for i = 1, #list do
        if list[i] == value then return true end
    end
    return false
end

local function clean(value)
    return (tostring(value or "unknown"):gsub("%c", ""))
end

local function ref(tab, container, name)
    local result = {pcall(ui.reference, tab, container, name)}
    if not result[1] then return {} end
    table.remove(result, 1)
    return result
end

local function fallback_ref(first, second)
    if first[1] ~= nil then return first end
    return second
end

-- Built-in bind references are read-only here: the keybind list just shows
-- which of the cheat's own binds are currently active.
local builtin = {
    dt = fallback_ref(ref("RAGE", "Aimbot", "Double tap"), ref("RAGE", "Other", "Double tap")),
    hs = ref("AA", "Other", "On shot anti-aim"),
    slow = ref("AA", "Other", "Slow motion"),
    peek = fallback_ref(ref("RAGE", "Other", "Quick peek assist"), ref("RAGE", "Aimbot", "Quick peek assist")),
    duck = ref("RAGE", "Other", "Duck peek assist"),
    baim = fallback_ref(ref("RAGE", "Aimbot", "Force body aim"), ref("RAGE", "Other", "Force body aim")),
    safe = ref("RAGE", "Aimbot", "Force safe point")
}
-- The resolver does not touch the Player List: it reads raw entity data
-- (LBY, eye angles, simulation time, velocity) and writes the fixed angle
-- straight into entity properties instead.
local resolver_available = type(entity.get_players) == "function"
    and type(entity.get_steam64) == "function" and type(entity.is_dormant) == "function"
    and type(entity.is_enemy) == "function" and type(entity.get_prop) == "function"
    and type(entity.set_prop) == "function"

local runtime = {
    fps = 60, bind_alpha = 0, last_rows = {}, dragging = false, scope_shift = 0, kills = 0,
    previous_mouse = false, drag_dx = 0, drag_dy = 0,
    feed = {}, shots = {}, shot_order = {}, hits = 0, misses = 0
}
local batching, suspended = false, false
local update_visibility
local store = {schema = 1, profiles = {}}
local registry, registry_order = {}, {}

local function unique(label, id)
    return label .. "\nflawless/" .. id
end

local function register(id, kind, handle, default, options, lo, hi)
    local entry = {
        id = id, kind = kind, handle = handle, default = copy(default),
        options = options, lo = lo, hi = hi
    }
    registry[id] = entry
    registry_order[#registry_order + 1] = entry
    if kind == "color" or kind == "multi" then
        ui.set(handle, unpack(default))
    else
        ui.set(handle, default)
    end
    return handle
end

local function checkbox(id, label, default)
    return register(id, "bool", ui.new_checkbox(TAB, BOX, unique(label, id)), default)
end

local function slider(id, label, lo, hi, default, unit)
    local handle = ui.new_slider(TAB, BOX, unique(label, id), lo, hi, default, true, unit or "")
    return register(id, "number", handle, default, nil, lo, hi)
end

local function combo(id, label, options, default)
    return register(id, "combo", ui.new_combobox(TAB, BOX, unique(label, id), options), default, options)
end

local U = {}
U.title = ui.new_label(TAB, BOX, "flawless / " .. VERSION)
U.master = ui.new_checkbox(TAB, BOX, "flawless | Enable")
U.accent = register("accent", "color", ui.new_color_picker(TAB, BOX, "flawless accent", 161, 132, 255, 255), {161, 132, 255, 255})
U.page = ui.new_combobox(TAB, BOX, "flawless | Page", "Resolver", "Visuals", "Profiles")

U.resolver = checkbox("resolver.enabled", "Entity resolver (no Player List)", true)
U.resolver_jitter = checkbox("resolver.jitter", "Fix jitter (center alternating yaw)", true)
U.resolver_limit = slider("resolver.limit", "Brute force angle", 0, 60, 58)
U.resolver_misses = slider("resolver.misses", "Misses before brute force", 1, 4, 2)
U.resolver_moving = checkbox("resolver.moving", "Resolve moving targets", true)
U.resolver_logs = checkbox("resolver.logs", "Resolver console logs", false)
U.resolver_info = ui.new_label(TAB, BOX, "No Player List. LBY fix via entity props.")
U.resolver_status = ui.new_label(TAB, BOX, "Resolver: off")
local resolver_controls = {}
for _, handle in ipairs({U.resolver, U.resolver_jitter, U.resolver_limit,
    U.resolver_misses, U.resolver_moving}) do resolver_controls[handle] = true end

U.hud = register("hud", "multi", ui.new_multiselect(TAB, BOX, "flawless HUD", "Watermark", "Keybind list", "Shot feed"),
    {"Watermark", "Keybind list", "Shot feed"}, {"Watermark", "Keybind list", "Shot feed"})
U.opacity = slider("opacity", "Panel opacity", 35, 100, 90, "%")
U.feed_time = slider("feed_time", "Shot feed lifetime", 2, 10, 5, "s")
U.console = checkbox("console", "Console shot logs", true)
U.hit_fx = checkbox("hit_fx", "Hit particles (world 3D)", true)
U.hit_density = slider("hit_density", "Hit particle count", 4, 18, 12)
U.kill_fx = checkbox("kill_fx", "Kill burst (world 3D)", true)
U.kill_amount = slider("kill_amount", "Kill particle count", 12, 40, 28)
U.kill_ring = checkbox("kill_ring", "Kill shockwave ring", true)
U.indicator = checkbox("indicator", "Crosshair indicator + logo", true)
U.scope_off = slider("scope_off", "Scope shift amount", 0, 160, 64, "px")
U.scope_side = combo("scope.side", "Scope shift direction", {"Left", "Right"}, "Left")
U.visual_info = ui.new_label(TAB, BOX, "Particles are world-space, not screen-space.")
U.visual_info2 = ui.new_label(TAB, BOX, "Drag the keybind header with the menu open.")
U.bind_x = slider("bind_x", "Keybind position X", 0, 10000, 160)
U.bind_y = slider("bind_y", "Keybind position Y", 0, 10000, 4200)
U.slot = ui.new_combobox(TAB, BOX, "Local profile slot", "Slot 1", "Slot 2", "Slot 3", "Slot 4", "Slot 5")
U.profile_info = ui.new_label(TAB, BOX, "Profiles save settings, not hotkeys or master.")

local function notify(text, color, console)
    color = color or {161, 132, 255}
    runtime.feed[#runtime.feed + 1] = {text = clean(text), color = color, time = globals.realtime()}
    if #runtime.feed > 6 then table.remove(runtime.feed, 1) end
    if console then client.color_log(color[1], color[2], color[3], "[flawless] ", clean(text)) end
end


-- Entity-level resolver, no Player List. It samples raw entity data (LBY,
-- eye angles, simulation time, velocity), centers jitter patterns, resolves
-- moving targets from velocity, and brute-forces on misses. The fixed angle
-- is written straight into entity props and fully restored when released.
local resolver = {targets = {}, serial = 0, count = 0, status_time = 0}

local function norm_yaw(deg)
    return ((deg + 180) % 360) - 180
end

local function shortest_arc(a, b)
    return ((b - a + 180) % 360) - 180
end

local function detect_jitter(ring)
    local n = #ring
    if n < 4 then return nil end
    local first = norm_yaw(ring[1])
    local vals, acc = {first}, first
    for i = 2, n do
        acc = acc + shortest_arc(norm_yaw(ring[i - 1]), norm_yaw(ring[i]))
        vals[i] = acc
    end
    local a = vals[n]
    local b
    for i = n - 1, max(1, n - 5), -1 do
        if math.abs(vals[i] - a) >= 10 then b = vals[i]; break end
    end
    if b == nil then return nil end
    -- Both poles must repeat inside the window, otherwise it is a slow drift
    -- (freestanding / direction change), not an alternating jitter pattern.
    local repeats_a, repeats_b = 0, 0
    for i = 1, n do
        if math.abs(vals[i] - a) <= 6 then repeats_a = repeats_a + 1 end
        if math.abs(vals[i] - b) <= 6 then repeats_b = repeats_b + 1 end
    end
    if repeats_a < 2 or repeats_b < 2 then return nil end
    local span = math.abs(a - b)
    if span < 12 or span > 170 then return nil end
    return norm_yaw((a + b) / 2)
end

local function alive_local()
    local player = entity.get_local_player()
    if player == nil or not entity.is_alive(player) then return nil end
    return player
end

function resolver.identity(index)
    local ok, identity = pcall(entity.get_steam64, index)
    if not ok or identity == nil then return nil end
    identity = tostring(identity)
    if identity == "" or identity == "0" or identity == "BOT" then return nil end
    return identity
end

function resolver.id_of(index)
    return resolver.identity(index) or ("index:" .. tostring(index))
end

function resolver.restore_target(index, keep_history)
    local entry = resolver.targets[index]
    if entry == nil then return end
    if entry.original_lby ~= nil and resolver.id_of(index) == entry.identity then
        local ok, err = pcall(entity.set_prop, index, "m_flLowerBodyYawTarget", entry.original_lby)
        if not ok then client.error_log("flawless resolver restore: " .. tostring(err)) end
    end
    entry.original_lby, entry.forced, entry.angle, entry.mode = nil, false, nil, nil
    entry.epoch = entry.epoch + 1
    if not keep_history then resolver.targets[index] = nil end
end

function resolver.release_all()
    for index in pairs(resolver.targets) do resolver.restore_target(index, false) end
    resolver.count = 0
end

function resolver.allowed()
    return resolver_available and ui.get(U.master) and ui.get(U.resolver)
        and not suspended and alive_local() ~= nil
end

function resolver.state(index)
    local vx, vy = entity.get_prop(index, "m_vecVelocity")
    local speed = math.sqrt((vx or 0) ^ 2 + (vy or 0) ^ 2)
    local flags = entity.get_prop(index, "m_fFlags") or 0
    if flags % 2 == 0 then return "Air", speed end
    if speed > 80 then return "Moving", speed end
    if (entity.get_prop(index, "m_flDuckAmount") or 0) > 0.5 then return "Crouching", speed end
    return "Standing", speed
end

function resolver.sample(entry, index, now)
    local sim = entity.get_prop(index, "m_flSimulationTime")
    if type(sim) == "number" and entry.sim_time ~= nil and sim == entry.sim_time then
        -- Simulation time is frozen: the enemy is choking, do not sample.
        entry.choke = min((entry.choke or 0) + 1, 64)
        return
    end
    entry.choke, entry.sim_time = 0, sim
    local _, eye = entity.get_prop(index, "m_angEyeAngles")
    if type(eye) == "number" then
        local ring = entry.eyes
        ring[#ring + 1] = eye
        if #ring > 6 then table.remove(ring, 1) end
        entry.jitter = detect_jitter(ring)
    end
    local lby = entity.get_prop(index, "m_flLowerBodyYawTarget")
    if type(lby) == "number" then
        if entry.lby == nil or math.abs(shortest_arc(entry.lby, lby)) > 2 then
            entry.lby_time, entry.lby_updates = now, (entry.lby_updates or 0) + 1
        end
        entry.lby = lby
    end
end

function resolver.bucket(entry, state)
    local bucket = entry.buckets[state]
    if bucket == nil then
        local magnitude = ui.get(U.resolver_limit)
        bucket = {values = magnitude == 0 and {0} or {0, magnitude, -magnitude},
            candidate = 1, misses = 0, revision = 0}
        entry.buckets[state] = bucket
    end
    return bucket
end

function resolver.angle_for(entry, index, state)
    local bucket = resolver.bucket(entry, state)
    local base, mode
    if state == "Moving" and ui.get(U.resolver_moving) then
        local vx, vy = entity.get_prop(index, "m_vecVelocity")
        local speed = math.sqrt((vx or 0) ^ 2 + (vy or 0) ^ 2)
        if speed > 40 then
            base, mode = norm_yaw(math.deg(atan2(vy or 0, vx or 0))), "velocity"
        end
    end
    if base == nil then
        if state == "Air" then
            -- In the air LBY is frozen, so the jitter center is the best guess.
            if entry.jitter and ui.get(U.resolver_jitter) then base, mode = entry.jitter, "jitter"
            elseif entry.hold then base, mode = entry.hold, "hold" end
        elseif entry.lby ~= nil then
            -- On the ground LBY is authoritative; jitter centering is a fallback.
            base, mode = entry.lby, "lby"
        elseif entry.jitter and ui.get(U.resolver_jitter) then
            base, mode = entry.jitter, "jitter"
        elseif entry.hold then
            base, mode = entry.hold, "hold"
        end
    end
    if base == nil then return nil, nil, bucket end
    local offset = bucket.values[bucket.candidate]
    if offset ~= nil and offset ~= 0 then mode = "brute" end
    return norm_yaw(base + (offset or 0)), mode, bucket
end

function resolver.apply(entry, index)
    local angle, mode = resolver.angle_for(entry, index, entry.state)
    if angle == nil then
        entry.forced, entry.angle, entry.mode = false, nil, nil
        return false
    end
    if entry.original_lby == nil then
        local ok, lby = pcall(entity.get_prop, index, "m_flLowerBodyYawTarget")
        if not ok or type(lby) ~= "number" then error("Cannot read LBY") end
        entry.original_lby = lby
    end
    local current = entity.get_prop(index, "m_flLowerBodyYawTarget")
    if type(current) ~= "number" then error("Cannot write LBY") end
    local target = norm_yaw(angle)
    if math.abs(shortest_arc(current, target)) > 0.5 then
        entity.set_prop(index, "m_flLowerBodyYawTarget", target)
    end
    entry.forced, entry.angle, entry.mode = true, target, mode
    if entry.state ~= "Air" then entry.hold = target end
    return true
end

function resolver.stop(err)
    resolver.release_all()
    ui.set(U.resolver, false)
    notify("Resolver stopped: " .. tostring(err), {250, 125, 145}, true)
end

function resolver.update()
    if not resolver.allowed() then resolver.release_all(); return end
    local ok, err = pcall(function()
        local now = globals.realtime()
        local seen, active = {}, 0
        local players = entity.get_players(true) or {}
        for i = 1, #players do
            local index = players[i]
            if entity.is_enemy(index) and entity.is_alive(index) and not entity.is_dormant(index) then
                seen[index] = true
                local identity = resolver.id_of(index)
                local entry = resolver.targets[index]
                if entry and entry.identity ~= identity then
                    -- Never carry tracked state onto a reused entity slot.
                    resolver.restore_target(index, false)
                    entry = nil
                end
                local state = resolver.state(index)
                if state == "Moving" and not ui.get(U.resolver_moving) then
                    resolver.restore_target(index, true)
                else
                    if entry == nil then
                        resolver.serial = resolver.serial + 1
                        entry = {identity = identity, token = resolver.serial, epoch = 0,
                            buckets = {}, eyes = {}, forced = false}
                        resolver.targets[index] = entry
                    end
                    entry.state = state
                    resolver.sample(entry, index, now)
                    if resolver.apply(entry, index) then active = active + 1 end
                end
            end
        end
        for index in pairs(resolver.targets) do
            if not seen[index] then resolver.restore_target(index, false) end
        end
        resolver.count = active
    end)
    if not ok then resolver.stop(err) end
end

function resolver.record_shot(index)
    if not resolver.allowed() or index == nil then return nil end
    local entry = resolver.targets[index]
    if not entry or not entry.forced or resolver.id_of(index) ~= entry.identity then return nil end
    local bucket = entry.buckets[entry.state]
    if not bucket then return nil end
    return {target = index, identity = entry.identity, token = entry.token, epoch = entry.epoch,
        state = entry.state, revision = bucket.revision, candidate = bucket.candidate,
        angle = entry.angle, time = globals.realtime()}
end

function resolver.feedback(shot, event, hit)
    local record = shot and shot.resolver
    if not record or not resolver.allowed() or event.target ~= record.target then return end
    if globals.realtime() - record.time > 2 then return end
    local entry = resolver.targets[record.target]
    if not entry or not entry.forced or entry.token ~= record.token or entry.epoch ~= record.epoch
        or entry.identity ~= record.identity or resolver.id_of(record.target) ~= record.identity then return end
    if not entity.is_alive(record.target) or entity.is_dormant(record.target) then return end
    local bucket = entry.buckets[record.state]
    if not bucket or bucket.revision ~= record.revision or bucket.candidate ~= record.candidate then return end
    if hit then
        -- A hit keeps the current angle; it does not prove the guess is right.
        bucket.misses, bucket.revision = 0, bucket.revision + 1
    else
        bucket.misses = bucket.misses + 1
        if bucket.misses < ui.get(U.resolver_misses) then return end
        bucket.misses, bucket.revision = 0, bucket.revision + 1
        bucket.candidate = bucket.candidate % #bucket.values + 1
    end
    if entry.state == record.state then
        local ok, err = pcall(resolver.apply, entry, record.target)
        if not ok then resolver.stop(err); return end
        if not hit and ui.get(U.resolver_logs) and entry.angle ~= nil then
            notify(string.format("Resolver %s / %s: %.0f -> %.0f (%s)",
                clean(entity.get_player_name(record.target)), record.state,
                record.angle or 0, entry.angle, entry.mode or "brute"), nil, true)
        end
    end
end

function resolver.status()
    local now = globals.realtime()
    if now < resolver.status_time then return end
    resolver.status_time = now + 0.25
    local text
    if not resolver_available then text = "Resolver: entity API unavailable"
    elseif not ui.get(U.resolver) then text = "Resolver: off"
    elseif not ui.get(U.master) then text = "Resolver: master is off"
    elseif suspended then text = "Resolver: config operation"
    elseif alive_local() == nil then text = "Resolver: waiting for local player"
    else text = string.format("Resolver: %d active fixes", resolver.count) end
    ui.set(U.resolver_status, text)
end

U.resolver_reset = ui.new_button(TAB, BOX, "Reset resolver history", function()
    resolver.release_all()
    notify("Resolver history reset", nil, true)
end)

local function read_control(entry)
    if entry.kind == "color" then return {ui.get(entry.handle)} end
    return copy(ui.get(entry.handle))
end

local function collect_settings()
    local settings = {}
    for i = 1, #registry_order do
        local e = registry_order[i]
        settings[e.id] = read_control(e)
    end
    return {version = 1, settings = settings}
end

local function valid(entry, value)
    local kind = entry.kind
    if kind == "bool" then return type(value) == "boolean" end
    if kind == "number" then
        return type(value) == "number" and value == value and value % 1 == 0 and value >= entry.lo and value <= entry.hi
    end
    if kind == "combo" then return type(value) == "string" and contains(entry.options, value) end
    if kind == "color" then
        if type(value) ~= "table" or #value ~= 4 then return false end
        for i = 1, 4 do
            if type(value[i]) ~= "number" or value[i] ~= value[i] or value[i] % 1 ~= 0 or value[i] < 0 or value[i] > 255 then return false end
        end
        return true
    end
    if kind == "multi" then
        if type(value) ~= "table" then return false end
        -- Unknown options from older profiles are filtered out, not rejected,
        -- so saved profiles keep loading across version changes.
        local filtered, seen = {}, {}
        for i = 1, #value do
            if contains(entry.options, value[i]) and not seen[value[i]] then
                seen[value[i]] = true
                filtered[#filtered + 1] = value[i]
            end
        end
        return true, filtered
    end
    return false
end

local function set_control(entry, value)
    if entry.kind == "color" or entry.kind == "multi" then
        ui.set(entry.handle, unpack(value))
    else
        ui.set(entry.handle, value)
    end
end

local function apply_settings(config)
    if type(config) ~= "table" or config.version ~= 1 or type(config.settings) ~= "table" then
        return false, "Unsupported or damaged profile"
    end
    local values = {}
    for i = 1, #registry_order do
        local entry = registry_order[i]
        local value = config.settings[entry.id]
        if value == nil then value = entry.default end
        local ok, fixed = valid(entry, value)
        if not ok then return false, "Invalid setting: " .. entry.id end
        values[entry.id] = copy(fixed or value)
    end
    local previous = collect_settings()
    resolver.release_all()
    batching = true
    local ok, err = pcall(function()
        for i = 1, #registry_order do
            local e = registry_order[i]
            set_control(e, values[e.id])
        end
    end)
    if not ok then
        for i = 1, #registry_order do
            local e = registry_order[i]
            pcall(set_control, e, previous.settings[e.id])
        end
    end
    batching = false
    if update_visibility then update_visibility() end
    return ok, err
end

local function flush_database()
    store.last = collect_settings()
    return pcall(database.write, DB_KEY, copy(store))
end

U.save = ui.new_button(TAB, BOX, "Save local profile", function()
    local slot = ui.get(U.slot)
    local previous = store.profiles[slot]
    store.profiles[slot] = collect_settings()
    local ok, err = flush_database()
    if not ok then store.profiles[slot] = previous end
    notify(ok and (slot .. " saved") or ("Save failed: " .. tostring(err)), nil, true)
end)
U.load = ui.new_button(TAB, BOX, "Load local profile", function()
    local slot = ui.get(U.slot)
    local config = store.profiles[slot]
    if config == nil then notify(slot .. " is empty", nil, true); return end
    local ok, err = apply_settings(config)
    notify(ok and (slot .. " loaded") or ("Load failed: " .. tostring(err)), nil, true)
end)
U.defaults = ui.new_button(TAB, BOX, "Reset script settings", function()
    local defaults = {version = 1, settings = {}}
    for i = 1, #registry_order do
        local e = registry_order[i]
        defaults.settings[e.id] = copy(e.default)
    end
    local ok, err = apply_settings(defaults)
    notify(ok and "Script settings reset; profiles kept" or tostring(err), nil, true)
end)
U.reset_position = ui.new_button(TAB, BOX, "Reset keybind position", function()
    ui.set(U.bind_x, registry.bind_x.default)
    ui.set(U.bind_y, registry.bind_y.default)
    runtime.dragging = false
end)

update_visibility = function()
    local page = ui.get(U.page)
    local visuals, profiles = page == "Visuals", page == "Profiles"
    local resolving = page == "Resolver"
    ui.set_visible(U.resolver, resolving)
    ui.set_visible(U.resolver_info, resolving)
    ui.set_visible(U.resolver_status, resolving)
    ui.set_visible(U.resolver_reset, resolving)
    for _, handle in ipairs({U.resolver_jitter, U.resolver_limit, U.resolver_misses,
        U.resolver_moving, U.resolver_logs}) do
        ui.set_visible(handle, resolving and ui.get(U.resolver) and resolver_available)
    end
    for _, handle in ipairs({U.hud, U.opacity, U.console, U.visual_info, U.visual_info2,
        U.reset_position, U.hit_fx, U.kill_fx, U.indicator}) do
        ui.set_visible(handle, visuals)
    end
    ui.set_visible(U.hit_density, visuals and ui.get(U.hit_fx))
    ui.set_visible(U.kill_amount, visuals and ui.get(U.kill_fx))
    ui.set_visible(U.kill_ring, visuals and ui.get(U.kill_fx))
    ui.set_visible(U.scope_off, visuals and ui.get(U.indicator))
    ui.set_visible(U.scope_side, visuals and ui.get(U.indicator))
    ui.set_visible(U.feed_time, visuals and contains(ui.get(U.hud), "Shot feed"))
    ui.set_visible(U.bind_x, false)
    ui.set_visible(U.bind_y, false)
    for _, handle in ipairs({U.slot, U.profile_info, U.save, U.load, U.defaults}) do
        ui.set_visible(handle, profiles)
    end
end

local function on_ui_change(changed)
    if batching then return end
    if not ui.get(U.master) or not ui.get(U.resolver) or resolver_controls[changed] then resolver.release_all() end
    resolver.status_time = 0
    resolver.status()
    update_visibility()
end
for i = 1, #registry_order do ui.set_callback(registry_order[i].handle, on_ui_change) end
ui.set_callback(U.master, on_ui_change)
ui.set_callback(U.page, update_visibility)

local read_ok, saved = pcall(database.read, DB_KEY)
if read_ok and saved == nil then
    local old_ok, old_cfg = pcall(database.read, OLD_DB_KEY)
    if old_ok and type(old_cfg) == "table" and old_cfg.schema == 1 then
        saved = old_cfg
        client.color_log(161, 132, 255, "[flawless] Imported local settings from the previous version.")
    end
end
if read_ok and type(saved) == "table" and saved.schema == 1 then
    if type(saved.profiles) == "table" then
        for i = 1, 5 do
            local key = "Slot " .. i
            if type(saved.profiles[key]) == "table" then store.profiles[key] = saved.profiles[key] end
        end
    end
    if saved.last ~= nil then
        local ok, err = apply_settings(saved.last)
        if not ok then client.error_log("flawless last settings: " .. tostring(err)) end
    end
end
ui.set(U.master, false)
update_visibility()

local function bind_active(handles)
    if handles[1] == nil then return false end
    if handles[2] ~= nil then return ui.get(handles[1]) == true and ui.get(handles[2]) == true end
    return ui.get(handles[1]) == true
end


-- World-space particle effects. Particles live in 3D coordinates (velocity,
-- gravity, lifetime) and are projected to the screen every frame, so they
-- stay anchored to the world instead of being glued to the screen.
local particles, rings = {}, {}
local hitbox_by_group = {
    generic = 2, head = 0, chest = 5, stomach = 3, neck = 1,
    ["left arm"] = 17, ["right arm"] = 15,
    ["left leg"] = 8, ["right leg"] = 7, ["?"] = 2, gear = 2
}

local function spawn_sparks(x, y, z, count, color, speed)
    for _ = 1, count do
        if #particles >= 320 then break end
        local theta = math.random() * math.pi * 2
        local cos_phi = math.random() * 2 - 1
        local sin_phi = math.sqrt(1 - cos_phi * cos_phi)
        local v = speed * (0.35 + math.random() * 0.65)
        particles[#particles + 1] = {
            x = x, y = y, z = z,
            vx = math.cos(theta) * sin_phi * v,
            vy = math.sin(theta) * sin_phi * v,
            vz = cos_phi * v,
            life = 0, max_life = 0.45 + math.random() * 0.5,
            size = 2 + math.random() * 3,
            color = color, gravity = 480
        }
    end
end

local function spawn_ring(x, y, z, color, radius)
    if #rings < 8 then
        rings[#rings + 1] = {x = x, y = y, z = z, life = 0, max_life = 0.55, radius = radius, color = color}
    end
end

local function update_effects(dt)
    for i = #particles, 1, -1 do
        local p = particles[i]
        p.life = p.life + dt
        if p.life >= p.max_life then
            table.remove(particles, i)
        else
            local damp = 1 - min(1, dt * 2.2)
            p.vx, p.vy = p.vx * damp, p.vy * damp
            p.vz = p.vz - p.gravity * dt
            p.x, p.y, p.z = p.x + p.vx * dt, p.y + p.vy * dt, p.z + p.vz * dt
        end
    end
    for i = #rings, 1, -1 do
        local ring = rings[i]
        ring.life = ring.life + dt
        if ring.life >= ring.max_life then table.remove(rings, i) end
    end
end

local function draw_effects(alpha)
    local a255 = floor(255 * alpha)
    for i = 1, #rings do
        local ring = rings[i]
        local t = ring.life / ring.max_life
        local radius = ring.radius * (1 - (1 - t) ^ 2)
        local c, a = ring.color, floor(a255 * (1 - t))
        local prev_sx, prev_sy
        for seg = 0, 20 do
            local ang = seg / 20 * math.pi * 2
            local sx, sy = renderer.world_to_screen(
                ring.x + math.cos(ang) * radius, ring.y + math.sin(ang) * radius, ring.z)
            if sx ~= nil then
                if prev_sx ~= nil then
                    renderer.line(prev_sx, prev_sy, sx, sy, c[1], c[2], c[3], a)
                end
                prev_sx, prev_sy = sx, sy
            else
                prev_sx, prev_sy = nil, nil
            end
        end
    end
    for i = 1, #particles do
        local p = particles[i]
        local t = p.life / p.max_life
        local sx, sy = renderer.world_to_screen(p.x, p.y, p.z)
        if sx ~= nil then
            local c = p.color
            local size = max(1, floor(p.size * (1 - t * 0.75)))
            renderer.rectangle(sx - floor(size * 0.5), sy - floor(size * 0.5), size, size,
                c[1], c[2], c[3], floor(a255 * (1 - t * 0.85)))
        end
    end
end

local function effect_position(entity_index, lift)
    local ok, x, y, z = pcall(entity.hitbox_position, entity_index, 2)
    if not ok or x == nil then
        x, y, z = entity.get_prop(entity_index, "m_vecOrigin")
        if x == nil then return nil end
        z = (z or 0) + 40
    end
    return x, y, (z or 0) + (lift or 0)
end

local function panel(x, y, w, h, r, g, b, alpha)
    local a = floor(255 * clamp(alpha, 0, 1))
    local opacity = ui.get(U.opacity) * 0.01
    renderer.rectangle(x - 1, y - 1, w + 2, h + 2, 8, 9, 15, floor(a * 0.65))
    renderer.rectangle(x, y, w, h, 18, 20, 29, floor(a * opacity))
    renderer.gradient(x, y, w, 2, r, g, b, a, 96, 217, 235, a, true)
end

local function draw_watermark(sw, r, g, b, alpha)
    local h, m, s = client.system_time()
    s = s or 0
    local tick = floor(1 / max(globals.tickinterval(), 0.001) + 0.5)
    local name_w = renderer.measure_text("b", "flawless")
    local texts = {
        string.format("%d ms", floor(client.latency() * 1000 + 0.5)),
        string.format("%d fps", floor(runtime.fps + 0.5)),
        string.format("%d tick", tick),
        string.format("%02d:%02d:%02d", h, m, s)
    }
    local tw, info_w = {}, 0
    for i = 1, #texts do
        tw[i] = renderer.measure_text("", texts[i])
        info_w = info_w + tw[i] + 21
    end
    local w = 22 + name_w + 12 + info_w
    local bh = 27
    local x, y = sw - w - 12, 12
    local a = floor(255 * alpha)
    local bg = floor(a * (ui.get(U.opacity) * 0.01))
    renderer.rectangle(x + 1, y + bh + 1, w - 2, 1, 0, 0, 0, floor(bg * 0.35))
    renderer.rectangle(x, y, w, bh, 10, 11, 16, bg)
    renderer.gradient(x, y, w, 2, r, g, b, a, 96, 217, 235, a, true)
    local dot = ui.get(U.master) and {116, 225, 178} or {112, 116, 132}
    renderer.rectangle(x + 10, y + 12, 4, 4, dot[1], dot[2], dot[3], a)
    local cursor = x + 22
    renderer.text(cursor, y + 7, r, g, b, a, "b", 0, "flawless")
    cursor = cursor + name_w + 12
    for i = 1, #texts do
        renderer.rectangle(cursor, y + 8, 1, bh - 16, 40, 43, 55, a)
        cursor = cursor + 11
        renderer.text(cursor, y + 7, 206, 210, 222, floor(a * 0.92), "", 0, texts[i])
        cursor = cursor + tw[i] + 10
    end
end

local function bind_rows()
    local rows = {}
    if resolver.allowed() then rows[#rows + 1] = {"Resolver", resolver.count .. " active"} end
    local definitions = {
        {"Double tap", builtin.dt}, {"On shot anti-aim", builtin.hs},
        {"Fake duck", builtin.duck}, {"Slow walk", builtin.slow},
        {"Quick peek", builtin.peek}, {"Body aim", builtin.baim}, {"Safe point", builtin.safe}
    }
    for i = 1, #definitions do
        if bind_active(definitions[i][2]) then rows[#rows + 1] = {definitions[i][1], "ON"} end
    end
    return rows
end

local function draw_keybinds(sw, sh, r, g, b, alpha, dt)
    local menu = ui.is_menu_open()
    local rows = bind_rows()
    local show = #rows > 0 or menu
    runtime.bind_alpha = runtime.bind_alpha + ((show and 1 or 0) - runtime.bind_alpha) * min(1, dt * 12)
    if show then
        if #rows == 0 then rows = {{"No active binds", ""}} end
        runtime.last_rows = rows
    else
        rows = runtime.last_rows
    end
    if runtime.bind_alpha < 0.01 then runtime.dragging = false; return end
    local w = min(214, max(70, sw - 16))
    local h = 27 + #rows * 20
    local max_x, max_y = max(4, sw - w - 4), max(4, sh - h - 4)
    local x = clamp(floor(ui.get(U.bind_x) * 0.0001 * sw), 4, max_x)
    local y = clamp(floor(ui.get(U.bind_y) * 0.0001 * sh), 4, max_y)
    local mx, my = ui.mouse_position()
    local mouse_down = client.key_state(0x01) == true
    local over_header = mx >= x and mx <= x + w and my >= y and my <= y + 26
    local menu_x, menu_y = ui.menu_position()
    local menu_w, menu_h = ui.menu_size()
    local over_menu = mx >= menu_x and mx <= menu_x + menu_w and my >= menu_y and my <= menu_y + menu_h
    if menu and mouse_down and not runtime.previous_mouse and over_header and not over_menu then
        runtime.dragging, runtime.drag_dx, runtime.drag_dy = true, mx - x, my - y
    end
    if not menu or not mouse_down then runtime.dragging = false end
    if runtime.dragging then
        x = clamp(mx - runtime.drag_dx, 4, max_x)
        y = clamp(my - runtime.drag_dy, 4, max_y)
        batching = true
        ui.set(U.bind_x, floor(x / sw * 10000 + 0.5))
        ui.set(U.bind_y, floor(y / sh * 10000 + 0.5))
        batching = false
    end
    runtime.previous_mouse = mouse_down
    local a = alpha * runtime.bind_alpha
    panel(x, y, w, h, r, g, b, a)
    renderer.text(x + 11, y + 8, 239, 239, 247, floor(a * 255), "b", 0, "KEYBINDS")
    if menu then renderer.text(x + w - 10, y + 9, r, g, b, floor(a * 210), "r-", 0, "DRAG") end
    for i = 1, #rows do
        local row_y = y + 29 + (i - 1) * 20
        renderer.text(x + 11, row_y, 203, 207, 220, floor(a * 255), "", max(1, w - 60), rows[i][1])
        renderer.text(x + w - 11, row_y, r, g, b, floor(a * 255), "r", 0, rows[i][2])
    end
end

local function draw_feed(sw, sh, alpha)
    local now = globals.realtime()
    local life = ui.get(U.feed_time)
    for i = #runtime.feed, 1, -1 do
        if now - runtime.feed[i].time > life then table.remove(runtime.feed, i) end
    end
    local row = 0
    for i = #runtime.feed, max(1, #runtime.feed - 3), -1 do
        local entry = runtime.feed[i]
        local age = max(0, now - entry.time)
        local fade = clamp(age / 0.18, 0, 1) * clamp((life - age) / 0.5, 0, 1) * alpha
        if fade > 0.01 then
            local tw = renderer.measure_text("", entry.text)
            local w = min(tw + 28, min(590, max(40, sw - 24)))
            local x = floor((sw - w) * 0.5)
            local y = floor(sh * 0.73 + row * 27 + (1 - fade) * 8)
            local c, a = entry.color, floor(255 * fade)
            renderer.rectangle(x, y, w, 23, 18, 20, 29, floor(a * ui.get(U.opacity) * 0.01))
            renderer.rectangle(x, y, 2, 23, c[1], c[2], c[3], a)
            renderer.text(x + 12, y + 5, 228, 231, 242, a, "", max(1, w - 24), entry.text)
            row = row + 1
        end
    end
end

-- Text-only indicator next to the crosshair: the drawn logo plus a small
-- status line. No panels, no backgrounds, nothing screen-glued. While
-- scoped the whole group glides left with a smooth spring, off the scope's
-- vertical line.
local function draw_indicator(sw, sh, r, g, b, alpha, dt)
    local me = entity.get_local_player()
    local scoped = false
    if me ~= nil then
        local v = entity.get_prop(me, "m_bIsScoped")
        scoped = v == 1 or v == true
    end
    runtime.scope_shift = runtime.scope_shift + ((scoped and 1 or 0) - runtime.scope_shift) * min(1, dt * 9)
    local shift = floor(runtime.scope_shift * ui.get(U.scope_off) + 0.5)
        * (ui.get(U.scope_side) == "Right" and 1 or -1)

    local cx = floor(sw * 0.5) - shift
    local y = floor(sh * 0.5) + 20
    local a = floor(255 * alpha)

    -- Status line: resolver / accuracy / speed / kills.
    local r_txt
    if resolver.allowed() then r_txt = "R " .. resolver.count else r_txt = "R off" end
    local total = runtime.hits + runtime.misses
    local acc = total > 0 and (floor(runtime.hits / total * 100 + 0.5) .. "%") or "--"
    local spd = 0
    if me ~= nil then
        local vx, vy = entity.get_prop(me, "m_vecVelocity")
        spd = floor(math.sqrt((vx or 0) ^ 2 + (vy or 0) ^ 2) + 0.5)
    end
    local status = string.format("%s   %s   %d u/s   K%d", r_txt, acc, spd, runtime.kills)

    -- Logo row: small layered diamond + wordmark, centered as one group.
    local name_w = renderer.measure_text("b", "flawless")
    local es = 14
    local ex, ey = floor(cx - (es + 6 + name_w) * 0.5), y
    local emy = ey + es * 0.5
    local outer = {{ex, emy}, {ex + es * 0.5, ey}, {ex + es, emy}, {ex + es * 0.5, ey + es}}
    for i = 1, 4 do
        local p1, p2 = outer[i], outer[i % 4 + 1]
        renderer.line(p1[1], p1[2], p2[1], p2[2], r, g, b, floor(a * 0.9))
        renderer.line(p1[1] + 1, p1[2], p2[1] + 1, p2[2], r, g, b, floor(a * 0.45))
    end
    local inset = 3
    local inner = {{ex + inset, emy}, {ex + es * 0.5, ey + inset}, {ex + es - inset, emy}, {ex + es * 0.5, ey + es - inset}}
    for i = 1, 4 do
        local p1, p2 = inner[i], inner[i % 4 + 1]
        renderer.line(p1[1], p1[2], p2[1], p2[2], 96, 217, 235, floor(a * 0.28))
    end
    renderer.text(ex + es * 0.5, ey + 2, r, g, b, a, "cb", 0, "F")
    renderer.text(ex + es + 6, ey, r, g, b, a, "b", 0, "flawless")

    renderer.text(cx, ey + es + 4, 175, 180, 195, floor(a * 0.85), "c-", 0, status)
end

local function prune_shots()
    local now = globals.realtime()
    while #runtime.shot_order > 0 do
        local first = runtime.shot_order[1]
        if #runtime.shot_order <= 128 and now - first.time <= 15 then break end
        if runtime.shots[first.id] == first then runtime.shots[first.id] = nil end
        table.remove(runtime.shot_order, 1)
    end
end

local hitgroups = {[0] = "generic", "head", "chest", "stomach", "left arm", "right arm", "left leg", "right leg", "neck", "?", "gear"}
local function aim_fire(e)
    if not ui.get(U.master) or e.id == nil then return end
    local shot = {id = e.id, target = e.target, chance = e.hit_chance or 0, time = globals.realtime(), resolver = resolver.record_shot(e.target)}
    runtime.shots[e.id] = shot
    runtime.shot_order[#runtime.shot_order + 1] = shot
    prune_shots()
end

local function aim_hit(e)
    if not ui.get(U.master) then return end
    local shot = e.id ~= nil and runtime.shots[e.id] or nil
    resolver.feedback(shot, e, true)
    if e.id ~= nil then runtime.shots[e.id] = nil end
    runtime.hits = runtime.hits + 1
    local group = type(e.hitgroup) == "string" and e.hitgroup or (hitgroups[e.hitgroup or 0] or "body")
    local name = clean(entity.get_player_name(e.target))
    notify(string.format("Hit %s | %s | %d damage", name, group, floor(e.damage or 0)), {116, 225, 178}, ui.get(U.console))
    if not ui.get(U.hit_fx) or e.target == nil then return end
    local x, y, z = effect_position(e.target)
    if x == nil then return end
    local r, g, b = ui.get(U.accent)
    if group == "head" then
        -- Headshots get a warmer burst and a small ring at the head.
        spawn_sparks(x, y, z, ui.get(U.hit_density) + 6, {255, 120, 110}, 250)
        spawn_ring(x, y, z, {255, 120, 110}, 24)
    else
        spawn_sparks(x, y, z, ui.get(U.hit_density), {r, g, b}, 190)
    end
end

local function aim_miss(e)
    if not ui.get(U.master) then return end
    local shot = e.id ~= nil and runtime.shots[e.id] or nil
    local chance = e.hit_chance or (shot and shot.chance) or 0
    resolver.feedback(shot, e, false)
    if e.id ~= nil then runtime.shots[e.id] = nil end
    runtime.misses = runtime.misses + 1
    local name = clean(entity.get_player_name(e.target))
    notify(string.format("Miss %s | %s | %d%% chance", name, clean(e.reason or "unknown"), floor(chance + 0.5)), {250, 125, 145}, ui.get(U.console))
end

local function player_death(e)
    if not ui.get(U.master) or not ui.get(U.kill_fx) then return end
    local me = entity.get_local_player()
    local victim = client.userid_to_entindex(e.userid)
    local attacker = client.userid_to_entindex(e.attacker)
    if me == nil or victim == nil or victim == me or attacker ~= me then return end
    local x, y, z = effect_position(victim, 24)
    if x == nil then return end
    runtime.kills = runtime.kills + 1
    local r, g, b = ui.get(U.accent)
    spawn_sparks(x, y, z, ui.get(U.kill_amount), {255, 208, 120}, 320)
    if ui.get(U.kill_ring) then
        spawn_ring(x, y, z, {255, 208, 120}, 56)
        spawn_ring(x, y, z, {r, g, b}, 40)
    end
    notify("Kill " .. clean(entity.get_player_name(victim)), {255, 208, 120}, ui.get(U.console))
end

local function paint_ui()
    if not resolver.allowed() then resolver.release_all() end
    resolver.status()
    local frame_time = max(globals.absoluteframetime(), 0.000001)
    local dt = min(frame_time, 0.1)
    runtime.fps = runtime.fps + (1 / frame_time - runtime.fps) * min(1, dt * 3)
    prune_shots()
    update_effects(dt)
    local r, g, b, a = ui.get(U.accent)
    local alpha = a / 255
    local hud = ui.get(U.hud)
    local sw, sh = client.screen_size()
    if sw <= 0 or sh <= 0 then return end
    -- The watermark stays on even when the master is off, like a real cheat.
    if contains(hud, "Watermark") then draw_watermark(sw, r, g, b, alpha) end
    if not ui.get(U.master) then runtime.dragging = false; return end
    if #particles > 0 or #rings > 0 then draw_effects(alpha) end
    if ui.get(U.indicator) then draw_indicator(sw, sh, r, g, b, alpha, dt) end
    if contains(hud, "Keybind list") then draw_keybinds(sw, sh, r, g, b, alpha, dt)
    else runtime.dragging = false end
    if contains(hud, "Shot feed") then draw_feed(sw, sh, alpha) end
end

local function suspend_native()
    suspended = true
    resolver.release_all()
end

local function resume_native()
    suspended = false
    update_visibility()
end

client.set_event_callback("net_update_end", resolver.update)
client.set_event_callback("paint_ui", paint_ui)
client.set_event_callback("aim_fire", aim_fire)
client.set_event_callback("aim_hit", aim_hit)
client.set_event_callback("aim_miss", aim_miss)
client.set_event_callback("player_death", player_death)
client.set_event_callback("pre_config_load", suspend_native)
client.set_event_callback("post_config_load", resume_native)
client.set_event_callback("pre_config_save", suspend_native)
client.set_event_callback("post_config_save", resume_native)
client.set_event_callback("round_start", function()
    resolver.release_all()
    particles, rings = {}, {}
    runtime.shots, runtime.shot_order = {}, {}
end)
client.set_event_callback("shutdown", function()
    resolver.release_all()
    local ok, err = flush_database()
    if not ok then client.error_log("flawless database: " .. tostring(err)) end
end)

if not resolver_available then
    client.error_log("flawless: entity resolver unavailable; missing entity read/write API.")
end

client.color_log(161, 132, 255, "[flawless] " .. VERSION .. " loaded. LUA > B. Master is OFF.")
