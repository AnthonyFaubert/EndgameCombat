require "functions"

local STREAMS = {
"acid-stream-worm-small", "acid-stream-worm-medium", "acid-stream-worm-big", "acid-stream-worm-behemoth",
"acid-stream-spitter-small", "acid-stream-spitter-medium", "acid-stream-spitter-big", "acid-stream-spitter-behemoth"
}

local function createAndAddEdgeForAttack(egcombat, entry, r, tick, attacker)
	if not attacker.unit_number or not entry.edges[attacker.unit_number] or not entry.edges[attacker.unit_number].entity.valid or (entry.edges[attacker.unit_number].entity.health and entry.edges[attacker.unit_number].entity.health <= 0) then
		local ang = math.atan2(attacker.position.y-entry.dome.position.y, attacker.position.x-entry.dome.position.x) --y,x, not x,y
		local pos = {x=entry.dome.position.x+r*0.9*math.cos(ang), y=entry.dome.position.y+r*0.9*math.sin(ang)}
		local edge = entry.dome.surface.create_entity({name="shield-dome-edge-" .. entry.index, position = pos, force=game.forces.neutral}) --neutral force so robots do not try to repair it, and does not trigger "structure damage warning"
		local fx = entry.dome.surface.create_trivial_smoke({name="shield-dome-edge-effect-" .. entry.index, position = pos, force=game.forces.neutral})
		local light = entry.dome.surface.create_entity({name="shield-dome-edge-effect-light-" .. entry.index, position = pos, force=game.forces.neutral})
		--game.print("Spawning edge entity for " .. attacker.name)
		local entry2 = {entity=edge, effect=fx, light=light, life=tick+150, force=entry.dome.force.name, entry_key = entry.dome.unit_number}
		if attacker.type == "unit" then --only add to memory if a unit; projectiles have special handling
			entry.edges[attacker.unit_number] = entry2
			egcombat.shield_dome_edges[attacker.unit_number] = entry2
			attacker.set_command({type=defines.command.attack, target=edge, distraction=defines.distraction.none})
		elseif attacker.type == "projectile" or attacker.type == "stream" then
			--this is not the main way of handling spitters; they preferentially target the edges; this is just for ones that make it through
			--entry.dome.surface.create_entity({name="acid-splash-purple", position = attacker.position, force=game.forces.neutral})
			--game.print("Dome intercepting projectile " .. stream.name .. " @ " .. attacker.position.x .. ", " .. attacker.position.y)
			attackShieldDome(entry, 25) --cannot get actual damage, so go for 25 (normally 10/20/30/50 for S/M/Bg/Bhm)
			attacker.destroy()
		end
	end
end

function getDomeRebootThresholdByLevel(level)
	return SHIELD_REACTIVATE_FRACTION[level+1]
end

function getLevel100DomeStrengthBoost()
	local inc = getCurrentDomeStrengthFactorByLevel(99)
	local prev = getTotalDomeStrengthFactorByLevel(99)
	local i = 0
	local base = 0
	while (base < inc*1.25) do
		i = i+1
		base = (math.ceil(prev/10+i)*10-prev)
	end
	return base
end

function getCurrentDomeStrengthFactorByLevel(lvl)
	return lvl == 100 and getLevel100DomeStrengthBoost() or 1+0.04*lvl+math.floor(0.004*lvl*lvl * 100 + 0.5) / 100 --round quadratic part to nearest 0.01
end

function getTotalDomeStrengthFactorByLevel(lvl)
	local sum = 1
	for i = 0,lvl do
		sum = sum+getCurrentDomeStrengthFactorByLevel(i)-1 --  -1 to subtract 100%
	end
	return sum
end

function getTotalDomeCostFactorByLevel(lvl)
	local sum = 1
	for i = 0,lvl do
		sum = sum*getCurrentDomeCostFactorByLevel(i)
	end
	return math.floor(sum*10000+0.5) / 10000 --round nearest 0.0001 (0.01%)
end

function getCurrentDomeCostFactorByLevel(lvl)
	return 1/math.min(500, math.floor((1+lvl*0.01+((1.25^lvl)-1)*0.075)*10000+0.5) / 10000) --round to nearest 0.0001 (0.01%)
end

function getCurrentDomeStrengthFactor(force)
	local lvl = 1
	while force.technologies["shield-dome-strength-" .. lvl].researched and lvl < MAX_DOME_STRENGTH_TECH_LEVEL do
		lvl = lvl+1
	end
	lvl = lvl-1
	return getCurrentDomeStrengthFactorByLevel(lvl)
end

function getCurrentDomeCostFactor(force)
	local lvl = 1
	while force.technologies["shield-dome-recharge-" .. lvl].researched and lvl < MAX_DOME_RECHARGE_TECH_LEVEL do
		lvl = lvl+1
	end
	lvl = lvl-1
	return getCurrentDomeCostFactorByLevel(lvl)
end

function getCurrentDomeRebootThreshold(force)
	local lvl = 1
	while force.technologies["shield-dome-reboot-" .. lvl].researched and lvl < MAX_DOME_REBOOT_TECH_LEVEL do
		lvl = lvl+1
	end
	lvl = lvl-1
	return getDomeRebootThresholdByLevel(lvl)
end

function getShieldDomeStrength(entry)
	if not entry.strength_factor then
		entry.strength_factor = getCurrentDomeStrengthFactor(entry.dome.force)
	end
	return math.floor(SHIELD_DOMES[entry.index].strength*entry.strength_factor)
end

function getShieldDomeRechargeCost(entry)
	if not entry.cost_factor then
		entry.cost_factor = getCurrentDomeCostFactor(entry.dome.force)
	end
	return math.max(1, math.ceil(SHIELD_DOMES[entry.index].energy_per_point*entry.cost_factor))*1000
end

function getShieldDomeRebootThreshold(entry)
	if not entry.reboot_threshold then
		entry.reboot_threshold = getCurrentDomeRebootThreshold(entry.dome.force)
		--game.print(entry.reboot_threshold)
	end
	return entry.reboot_threshold
end

local function setDomeCircuitStatus(entry)
	if entry.circuit then
		params = {
			{
				index = 1,
				signal = {type = "virtual", name = "shield-level"},
				count = entry.current_shield
			},
			{
				index = 2,
				signal = {type = "virtual", name = "shield-capacity"},
				count = getShieldDomeStrength(entry)
			}
		}
		entry.circuit.get_control_behavior().parameters = params
	end
end

function tickShieldDome(egcombat, entry, tick)
	if not entry.delay then entry.delay = 60 end
	if entry.current_shield > 0 then
		if tick%entry.delay == 0 and not entry.rebooting then
			local scan = entry.delay >= 30
			--game.print("Ticking dome @ " .. entry.dome.position.x .. "," .. entry.dome.position.y)
			local r = SHIELD_DOMES[entry.index].radius+1.5
			if scan then
				r = r+10
			end
			local enemies = entry.dome.surface.find_enemy_units(entry.dome.position, r, entry.dome.force)
			if #enemies > 0 then
				--game.print(#enemies .. " @ " .. entry.delay))
				if not scan then
					for _,biter in pairs(enemies) do
						if biter.valid and biter.health > 0 then
							local d = getDistance(biter, entry.dome)
							if d < r+1.5 then --only ones with targets inside? does not make so much sense, and hard to code
								createAndAddEdgeForAttack(egcombat, entry, r, tick, biter)
							end
						end
					end
					
					--this is required for spitters to be able to damage the shield
					local projs = entry.dome.surface.find_entities_filtered({area = {{entry.dome.position.x-r, entry.dome.position.y-r}, {entry.dome.position.x+r, entry.dome.position.y+r}}, type="projectile", name = STREAMS})
					for _,proj in pairs(projs) do
						local d = getDistance(proj, entry.dome)
						if d < r*0.9 then
							--entry.dome.surface.create_entity({name="acid-splash-purple", position = proj.position, force=game.forces.neutral})
							--proj.destroy()
							createAndAddEdgeForAttack(egcombat, entry, r, tick, proj)
						end
					end
				end
				entry.delay = 5
			else
				entry.delay = math.min(60, entry.delay+10)
			end
		end
		local n = entry.rebooting and 140 or 30
		if tick%n == 0 then
			if entry.rebooting then
				entry.dome.surface.create_trivial_smoke({name="shield-dome-rebooting-effect-" .. entry.index, position = entry.dome.position, force=entry.dome.force.name})
			elseif entry.current_shield < getShieldDomeStrength(entry) then
				entry.dome.surface.create_trivial_smoke({name="shield-dome-charging-effect-" .. entry.index, position = entry.dome.position, force=entry.dome.force.name})
			else
				if tick%120 == 0 then
					entry.dome.surface.create_trivial_smoke({name="shield-dome-effect-" .. entry.index, position = entry.dome.position, force=entry.dome.force.name})
				end
			end
			if not entry.rebooting then
				entry.dome.surface.create_entity({name="shield-dome-effect-light-" .. entry.index, position = entry.dome.position, force=entry.dome.force.name})
			end
		end
		local step = 5*math.min(3, math.max(1, 4-entry.dome.last_user.mod_settings["render-quality"].value))
		if tick%step == 0 and not entry.rebooting then --spawn some edges to show radius, and to look cool
			local num = entry.index == "small" and 1 or (entry.index == "medium" and 2 or 3)
			for i = 1,num do
				local ang = math.random()*360
				local pos = {x=entry.dome.position.x+SHIELD_DOMES[entry.index].radius*math.cos(ang), y=entry.dome.position.y+SHIELD_DOMES[entry.index].radius*math.sin(ang)}
				local edge = entry.dome.surface.create_entity({name="shield-dome-edge-" .. entry.index, position = pos, force=game.forces.neutral}) --neutral force so robots do not try to repair it, and does not trigger "structure damage warning"
				local fx = entry.dome.surface.create_trivial_smoke({name="shield-dome-edge-effect-" .. entry.index, position = pos, force=game.forces.neutral})
				local light = entry.dome.surface.create_entity({name="shield-dome-edge-effect-light-" .. entry.index, position = pos, force=game.forces.neutral})
				table.insert(entry.edges, {entity=edge, effect=fx, light=light, life=tick+math.random(30, 90), force=entry.dome.force, entry_key=entry.dome.unit_number})
			end
		end
	end
	local maxe = getShieldDomeStrength(entry) --this runs every tick!!
	if entry.current_shield < maxe then
		local cost = getShieldDomeRechargeCost(entry)
		local cycles = math.min(maxe-entry.current_shield, math.floor(math.min(entry.dome.energy/cost, SHIELD_DOMES[entry.index].max_recharge*1000000/(60*cost/1000))))
		--game.print("Recharge ticking " .. entry.index .. " dome @ " .. entry.dome.position.x .. "," .. entry.dome.position.y .. " @ " .. game.tick .. ": " .. entry.dome.energy .. " & " .. SHIELD_DOMES[entry.index].max_recharge*1000000/60 .. " of " .. cost .. " > " .. cycles)
		if cycles >= 1 then
			entry.dome.energy = math.max(1, entry.dome.energy-cost*cycles)
			entry.current_shield = entry.current_shield+cycles
			if entry.rebooting and entry.current_shield >= getShieldDomeRebootThreshold(entry)*getShieldDomeStrength(entry) then
				entry.rebooting = false
				--game.print("Shields back online @ " .. entry.current_shield)
			end
		else
			--game.print("Dome " .. entry.index .. " @ " .. entry.dome.position.x .. "," .. entry.dome.position.y .. " @ " .. game.tick .. " insufficient energy to charge: " .. entry.dome.energy .. " & " .. SHIELD_DOMES[entry.index].max_recharge*1000000/0.06 .. " of " .. cost)
		end
	end
	if entry.dome.energy == 0 then
		entry.current_shield = math.max(0, math.floor(entry.current_shield*0.95)) --lose energy if empty buffer
		--game.print("Blackout! Shield depleting!")
	end
	setDomeCircuitStatus(entry)
	if #entry.edges > 0 then
		for biter,edge in pairs(entry.edges) do
			if tick >= edge.life or entry.current_shield == 0 or entry.rebooting then
				if edge.entity.valid then
					edge.entity.destroy()
				end
				if edge.effect and edge.effect.valid then
					edge.effect.destroy()
				end
				if edge.light and edge.light.valid then
					edge.light.destroy()
				end
				entry.edges[biter] = nil
			end
		end
	end
end

function getShieldDomeFromEdge(egcombat, entity, destroy, killer, damage)
	if killer == nil then return end
	if entity == nil or (not entity.valid) then return end
	local edge = egcombat.shield_dome_edges[killer.unit_number]
	if edge then
		if egcombat.shield_domes[edge.force] and egcombat.shield_domes[edge.force][edge.entry_key] then
			local entry = egcombat.shield_domes[edge.force][edge.entry_key]
			if edge.entity.valid then
				local maxh = game.entity_prototypes[entity.name].max_health
				if destroy or (damage and damage >= maxh) then
					entry.edges[killer.unit_number] = nil
					attackShieldDome(entry, maxh)
					edge.entity.destroy()
					if edge.effect and edge.effect.valid then
						edge.effect.destroy()
					end
					if edge.light and edge.light.valid then
						edge.light.destroy()
					end
				else
					attackShieldDome(entry, damage)
					if entity.valid then
						entity.health = game.entity_prototypes[entity.name].max_health
					end
				end
			else
				entry.edges[killer.unit_number] = nil --just remove, no effect
				if edge.effect and edge.effect.valid then
					edge.effect.destroy()
				end
				if edge.light and edge.light.valid then
					edge.light.destroy()
				end
			end
			return entry
		else
			game.print("A shield dome edge in table (killer=" .. killer.unit_number .. ") (force=" .. edge.force .. ", key=" .. edge.entry_key .. " without an entry!?")
			return nil
		end
	end
	--error("A shield dome edge (killer=" .. killer.unit_number .. ") not in table!?") happens if killed by something else, like player flamethrower
end

function getShieldDomeFromEntity(egcombat, entity)
	for _,entry in pairs(egcombat.shield_domes[entity.force.name]) do
		if entry.dome.position.x == entity.position.x and entry.dome.position.y == entity.position.y then
			return entry
		end
	end
	error("A shield dome without an entry!?")
end

local function onDomeFailure(entry)
	entry.rebooting = true
	entry.dome.surface.create_entity({name="shield-dome-fail-effect-" .. entry.index, position = entry.dome.position, force=game.forces.neutral})
	entry.dome.surface.create_entity({name="shield-dome-fail-effect-light-" .. entry.index, position = entry.dome.position, force=entry.dome.force.name})
	--game.print(serpent.block(entry.edges))
	for k,v in pairs(entry.edges) do
		if v and v.valid then
			v.destroy()
		end
		entry.edges[k] = nil
	end
	
	--bandaid fix
	local r = SHIELD_DOMES[entry.index].radius*1.25
	for _,e in pairs(entry.dome.surface.find_entities_filtered({name="shield-dome-edge-" .. entry.index, area = {{entry.dome.position.x-r, entry.dome.position.y-r}, {entry.dome.position.x+r, entry.dome.position.y+r}}})) do
		e.destroy()
	end
	--game.print("Shield offline. Rebooting.")
end

function attackShieldDome(entry, damage)
	--game.print("Damaging dome by " .. damage)
	if entry.current_shield > 0 and not entry.rebooting then
		entry.current_shield = math.max(0, entry.current_shield-damage)
		--game.print("Subtracting " .. damage .. " health from shield. Shield health is now: " .. entry.current_shield)
		if entry.current_shield == 0 then
			onDomeFailure(entry)
		end
	end
end