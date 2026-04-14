--//  Server handler for enemies, will not display more than this for the enemy system - to make it impossible to replicate unless you'd rewrite your own system. Feel free to learn from this code tho.

--[[

NOTE!
This script depends on external modules (PathModule, NetworkUtilityModule - made by me, etc.) which handle path computation and network abstraction.
For the sole purpose of a submission, this script demonstrates: enemy lifecycle / management, movement system, combat and attack scheduling, phase/state transitions.
Movement is based on a precomputed path system aforementioned which converts distance traveled into **world position** using linear segments and quadratic bezier curves for smooth motion.

--]]

--//  @RealManMun 27th August 2025

local Enemy = {}
Enemy.Priority = 2
Enemy.FarthestEnemy = nil
Enemy.FinalBossName = "IceboundKrampus"
Enemy.MarkedBosses = {}

--// Types
--// Full enemy state definition - every field an enemy instance carries through its lifecycle
type EnemyData = {
	Name: string,
	UniqueId: string,
	Speed: number,
	OriginalSpeed: number,
	Health: number,
	CurrentWaypoint: Instance,
	SpawnTime: number,
	ParentSpawnTime: number | nil,

	FixedElapsed: number,       -- snapshot of elapsed time when frozen, so distance calc stays consistent
	ElapsedDelay: number,       -- accumulated total time spent frozen, subtracted from movement calc

	Distance: number, -- distance travelled along path
	ExtraDistance: number,
	Position: Vector3,
	Orientation: Vector3, -- yaw in degrees
	PathIndex: number,

	--// Summoner-specific fields, nil for non-summoners
	summonTime: number | nil,
	summonDelayTime: number | nil,
	summonAnimationLength: number | nil,
	enemyToSummon: string | { string } | nil,
	previousSummonTime: number | nil,

	fat: number,
	enemyStats: {any},
	enemyValues: {string},      -- setting names pulled from the model's Settings folder
	died: boolean,
	
	--// Attack system fields - populated from attacksData in EnemyStats
	Attacks: { [number]: { string | number | {number} } } | nil,
	activeAttacks: { { string | number | {number} } } | nil,   -- subset of Attacks valid for the current phase
	currentAttack: { string | number | {number} },              -- randomly picked from activeAttacks each cycle
	lastAttackTime: number | nil,
	Phase: number | nil,        -- nil if enemy has no phases, 1 or 2 otherwise
	CashPerHit: number,
	GodMode: boolean,           -- true during phase transitions so the enemy can't die mid-animation

	state: string?              -- "ActionState" while mid-summon or mid-attack, blocks other actions
}
type EnemyPool = { [string]: EnemyData }

--// Variables
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage") 
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Networking - Packet wraps RemoteEvents with typed payloads so we're not sending unstructured garbage
local Packet = require(ReplicatedStorage:WaitForChild("Packet"))
local PathModule = require(ReplicatedStorage:WaitForChild("PathModule"))
local NetworkUtilityModule = require(ReplicatedStorage:WaitForChild("NetworkUtility"))

--// Packet definitions - each one declares its payload layout (U8, U16, F32 etc.)
--// These get fired to clients to replicate enemy state without giving them raw server data
local ReplicateEnemyEvent = Packet("ReplicateEnemy", Packet.NumberU8, Packet.NumberU16 , Packet.NumberU16)
local SummonEnemyEvent = Packet("SummonEnemyEvent", Packet.NumberU8, Packet.NumberU16, Packet.NumberU16, Packet.NumberF32, Packet.NumberU32)

local SummonerEnemyEvent = Packet("SummonerEnemyEvent", Packet.NumberU8, Packet.NumberU16, Packet.NumberU16)
local RemoveEnemyEvent = Packet("RemoveEnemy", Packet.NumberU16)
local UpdateEnemyHealthEvent = Packet("UpdateEnemyHealth", Packet.NumberU16, Packet.NumberU32)
local FreezeEnemyEvent = Packet("FreezeEnemyEvent", Packet.NumberU16, Packet.NumberU16)
local UnfreezeEnemyEvent = Packet("UnfreezeEnemyEvent", Packet.NumberU16, Packet.NumberU16)
local UpdateBaseHPEvent = Packet("UpdateBaseHP", Packet.NumberU8)
local EnemyAttackEvent = Packet("EnemyAttack", Packet.NumberU16, Packet.NumberU8)
local TrackEnemyHealthbarEvent = Packet("TrackEnemyHealthbar", Packet.NumberU16)
local NewPhaseEvent = Packet("NewPhase", Packet.NumberU16, Packet.NumberU8)
local SyncToServerTimeEvent = Packet("SyncToServerTimeEvent", Packet.NumberU16)
local GameEndPacket = Packet("GameEnd", Packet.NumberU8)
local PlayMusicPacket = Packet("PlayMusic", Packet.NumberU8)
local StopMusicPacket = Packet("StopMusic", Packet.NumberU8)
local PlaySoundPacket = Packet("PlaySound", Packet.NumberU8)
local KrampusMessagePacket = Packet("KrampusMessage", Packet.NumberU8)

local Assets = ReplicatedStorage:WaitForChild("Assets")
local EnemyModels = Assets:WaitForChild("EnemyModels")
local waypointsFolder = workspace:WaitForChild("Waypoints")

local BaseModule: ModuleScript = nil

local Data = ReplicatedStorage:WaitForChild("Data")
local PlaceIds = require(Data:WaitForChild("PlaceIds"))
local EnemyStatsData = require(Data:WaitForChild("EnemyStats"))

local GAMESTARTED = ServerStorage:WaitForChild("GAMESTARTED")
local GAME = ServerStorage:WaitForChild("GAME")

local BaseHP = ServerStorage:WaitForChild("BaseHP")

local mapWaypoints: { [number]: Instance } = {}
local freezeTimes: { [string]: number } = {}     -- tracks when each enemy was frozen, keyed by UniqueId
local enemyPool: EnemyPool = {}                   -- master pool of all living enemies
local uniqueIdCounter = 0                         -- monotonically increasing, never reused
local enemyPoolCount = 0

--// Enemies that get a dedicated healthbar on the client UI
--// false = not yet spawned, flips to true on first spawn so we only send the track event once
local healthbarEnemies = {
	["FrostShade"] = false,
	["FrostReaver"] = false,
	["FrostSpirit"] = false,
	["RoboSanta"] = false,
	["IceboundKrampus"] = false,
}

--// Multiplayer health scaling - each extra player adds 35% base HP to certain enemies
local HEALTH_SCALE = 0.35
local HEALTH_SCALE_TARGETS = {"RoboSanta", "FrostVanguard", "IceboundKrampus", "FrostSpirit", "FrostNecromancer", "FrostbiteRevenant", "CryingSpirit"}

local wTowers = workspace:WaitForChild("Towers")

--// Build the waypoint lookup table from workspace and feed it into PathModule
--// PathModule.precomputePath turns these into cached line segments + bezier curves
for _, child in waypointsFolder:GetChildren() do
	local i = tonumber(child.Name)
	if i then mapWaypoints[i] = child end
end
PathModule.precomputePath(1, mapWaypoints) -- 1 path for now


--// Utilities

--// Broadcast a packet to every connected player
local function fireAllClients(packet: Packet.Packet, ...)
	for _, player in Players:GetPlayers() do
		packet:FireClient(player, ...)
	end
end

--// Generic dictionary length since # only works on arrays
local function _len(dictionary: { [any]: any }): number
	local c = 0
	for _, __ in dictionary do
		c += 1
	end
	return c
end

--// Finds all placed towers within a flat (XZ) radius of a position
--// Used by the attack system to determine which towers get stunned
local function getTowersInRange(position: Vector3, range: number): { Model }
	local towersInRange = {}
	
	for _, tower: Model in wTowers:GetChildren() do
		local offset = tower.Position - position
		local dist = Vector3.new(offset.X, 0, offset.Z).Magnitude
		if dist <= range then
			table.insert(towersInRange, tower)
		end
	end
	
	return towersInRange
end

--// Returns scaled health based on player count
--// Solo player gets base health, each additional player adds HEALTH_SCALE % on top
local function getScaledHealth(baseHealth: number): number
	local playerCount = #Players:GetPlayers()
	if playerCount <= 1 then
		return baseHealth
	end
	return math.floor(
		baseHealth * (1 + HEALTH_SCALE * (playerCount - 1))
	)
end

--// Core spawn function - creates the server-side enemy data, calculates scaled health,
--// wires up attacks/phases/summon behavior, then replicates to all clients
local function spawnEnemy(name: string, isSummoned: boolean, params: { Vector3 | Instance | number })
	local id = uniqueIdCounter
	local uniqueId = name .. "_" .. id
	uniqueIdCounter += 1

	local stats = EnemyStatsData[name]
	params = params or {}
	
	--// Play spawn voice line if the enemy has one configured
	if stats and stats.SoundData and stats.SoundData.SpawnLineID then
		fireAllClients(PlaySoundPacket, stats.SoundData.SpawnLineID)
	end

	local summonData = stats.summonData or {}
	local fakeModel = EnemyModels[name]
	local settingsFolder = fakeModel.Settings

	--// Build the full EnemyData table
	--// params come from summonEnemy when this is a summoned child: [1]=pos, [2]=orientation, [3]=waypoint, [4]=extraDistance
	local now = workspace:GetServerTimeNow()
	local enemy: EnemyData = {
		Name = name,
		UniqueId = uniqueId,
		NumId = id,
		Speed = stats.WalkSpeed,
		OriginalSpeed = stats.WalkSpeed,
		Health = stats.Health,
		CurrentWaypoint = params[3] or nil,
		SpawnTime = now,

		FixedElapsed = nil,
		ElapsedDelay = 0,

		Distance = 0,
		ExtraDistance = params[4] or 0,       -- summoned enemies inherit parent's distance so they don't start from 0
		Position =  params[1] or Vector3.zero,
		Orientation = params[2] or Vector3.zero,
		PathIndex = 1,

		summonTime = summonData[1] or nil,
		summonDelayTime = summonData[2] or nil,
		summonAnimationLength = summonData[3] or nil,
		enemyToSummon = summonData[4] or nil,
		isSummonRandom = summonData[5] or nil,
		previousSummonTime = now,

		fat = 0,
		enemyStats = stats,
		enemyValues = {},
		died = false,
		state = nil,
		Attacks = {},
		activeAttacks = nil,
		lastAttackTime = nil,
		Phase = nil,
		CashPerHit = stats.CashPerHit,
		GodMode = false,
		
		--// Debug part for visualizing enemy position in studio, left commented out intentionally
		--[[
		PART = (function()
			local part = Instance.new("Part")
			part.Name = uniqueId
			part.Anchored = true
			part.CanCollide = false
			part.CastShadow = false
			part.Transparency = .5
			part.Color = Color3.fromRGB(255, 0, 0)
			part.Size = Vector3.new(2,2,2)
			part.Parent = workspace
			return part
		end)()
		--]]
	}
	
	--// Apply multiplayer health scaling
	enemy.Health = getScaledHealth(enemy.Health)

	--// Pull setting names from the model's Settings folder into enemyValues
	--// These act as tags/flags checked elsewhere (e.g. "Shielded", "Flying", etc.)
	for _, settingValue in settingsFolder:GetChildren() do
		table.insert(enemy.enemyValues, settingValue.Name)
	end
	settingsFolder = nil
	
	--// Wire up attack system if this enemy type has attacks defined
	--// Each attack gets its own table with timing/range info, phase-gated attacks start inactive
	if stats.attacksData then
		enemy.activeAttacks = {}
		enemy.lastAttackTime = now
		for attackId: number, data: {any} in stats.attacksData do
			local currentAttackTable = { 
				lastAttackTime = now, 
				range = data.attackRange, 
				duration = data.attackDuration, 
				animationEventLength = data.animationEventLength, 
				attackFrequency = data.attackFrequency, 
				freezeEnemyForSeconds = data.freezeEnemyForSeconds, 
				actualFrequency = nil,       -- randomized each cycle from attackFrequency range
				phase = data.phase,
				attackId = attackId,
			}
			
			enemy.Attacks[attackId] = currentAttackTable
			--// Only add to activeAttacks if the attack isn't phase-locked
			if not data.phase then
				table.insert(enemy.activeAttacks, currentAttackTable)
			end
		end
		
		--// Pick a random starting attack from the active pool
		enemy.currentAttack = enemy.activeAttacks[math.random(1, #enemy.activeAttacks)]
	end
	
	--// If this enemy supports phase transitions, start at phase 1
	if stats.PhaseTwoData then
		enemy.Phase = 1
	end
	
	if _len(enemy.Attacks) == 0 then enemy.Attacks = nil end

	enemyPool[uniqueId] = enemy
	enemyPoolCount += 1

	--// Encrypt the spawn time before sending to clients - prevents trivial speed/position manipulation
	local encrypted = NetworkUtilityModule:EncryptNetworkServerTime(enemy.SpawnTime)

	--// Summoned enemies use a different packet that includes their starting distance and health
	--// so the client can place them at the correct path position immediately
	if isSummoned then

		local elapsed = now - enemy.SpawnTime
		local distanceTravelled = enemy.Speed * ( enemy.FixedElapsed or (elapsed - enemy.ElapsedDelay)) + enemy.ExtraDistance

		fireAllClients(SummonEnemyEvent, stats.EnemyIndex, id, encrypted, distanceTravelled, enemy.Health)
	else
		fireAllClients(ReplicateEnemyEvent, stats.EnemyIndex, encrypted, id)
	end
	
	--// First-time healthbar tracking for boss/miniboss enemies
	--// Also starts their theme music and triggers Krampus intro dialogue if applicable
	if healthbarEnemies[name] == false then
		healthbarEnemies[name] = true
		if stats.SoundData then
			fireAllClients(PlayMusicPacket, stats.SoundData.ThemeSongID)
		end
		
		--// Krampus-specific intro sequence - staggered voice lines
		if name == Enemy.FinalBossName then
			print("Krampus spawn detected, playing voice lines!")
			task.spawn(function()
				fireAllClients(KrampusMessagePacket, 1)
				task.wait(13)
				fireAllClients(KrampusMessagePacket, 2)
				task.wait(10)
				fireAllClients(KrampusMessagePacket, 3)
			end)
		end
		
		fireAllClients(TrackEnemyHealthbarEvent, id)
		enemy.SOUND_MARKED = true
	end
	
	Enemy.UpdateHP(uniqueId, enemy.Health)
end

--// Spawns multiple summoned enemies with a 0.3s stagger between each
--// The extra distance offset per enemy prevents them from stacking on the exact same spot
local function summonEnemy(name: string, amount: number, ...): ()
	for i = 1, amount do
		local args = {...}
		args[5] += (0.3*(i - 1))
		spawnEnemy(name, true, args)
		task.wait(.3)
	end
end

--// Public API - spawns a wave of non-summoned enemies with a configurable delay between each
function Enemy.new(name: string, amount: number, delayTime: number): EnemyData
	for i = 1, amount do
		spawnEnemy(name)
		task.wait(delayTime)
	end
end

function Enemy.GetActiveEnemies(): EnemyPool
	return enemyPool
end

--// Freeze helpers - freezing an enemy snapshots its elapsed movement time so it stops advancing
--// Unfreezing adds the frozen duration to ElapsedDelay so the movement formula picks up where it left off

local function beginFreeze(enemy, now, elapsed): number
	enemy.FixedElapsed = elapsed - enemy.ElapsedDelay
	return NetworkUtilityModule:EncryptNetworkServerTime(now)
end

local function endFreeze(enemy, now): ()
	enemy.ElapsedDelay += workspace:GetServerTimeNow() - now
	enemy.FixedElapsed = nil
end

local function unfreezeEnemy(enemy: EnemyData, now: number): ()
	if (enemy.FixedElapsed and freezeTimes[enemy.UniqueId]) then
		local encrypted = NetworkUtilityModule:EncryptNetworkServerTime(now)
		fireAllClients(UnfreezeEnemyEvent, enemy.NumId, encrypted)
		enemy.ElapsedDelay += workspace:GetServerTimeNow() - freezeTimes[enemy.UniqueId]
		enemy.FixedElapsed = nil
		freezeTimes[enemy.UniqueId] = nil
	end
end

--// Externally triggered freeze - used by towers or abilities that stun enemies for a set duration
function Enemy.Stop(now: number, elapsed: number, id: string, givenDuration: number)
	local enemy = enemyPool[id]
	beginFreeze(enemy, now, elapsed)

	task.wait(givenDuration)

	endFreeze(enemy, now)
end

--// Summoner-type enemy action - freezes the enemy, plays the summon animation,
--// spawns the child enemy(ies) at the summoner's current position, then unfreezes
function Enemy.SummonerStop(now: number, elapsed: number, id: string)
	local enemy = enemyPool[id]
	local encrypted = beginFreeze(enemy, now, elapsed)

	fireAllClients(SummonerEnemyEvent, enemy.enemyStats.EnemyIndex, encrypted, tonumber(id:split("_")[2]))

	--// Wait for the pre-summon windup
	task.wait(enemy.summonDelayTime)

	--// Resolve what to summon - can be a single name, a list, or a random pick from a list
	local enemyToSummon = enemy.enemyToSummon
	if typeof(enemyToSummon) == "string" then
		task.spawn(summonEnemy, enemyToSummon, 1, enemy.Position, enemy.Orientation, enemy.CurrentWaypoint, enemy.Distance, enemy.SpawnTime, enemy.Speed)
	elseif typeof(enemyToSummon) == "table" then
		if enemy.isSummonRandom then
			local chosen = enemyToSummon[math.random(1, #enemyToSummon)]
			task.spawn(summonEnemy, chosen, 1, enemy.Position, enemy.Orientation, enemy.CurrentWaypoint, enemy.Distance, enemy.SpawnTime, enemy.Speed)
		else
			--// Summon all entries in the table
			for _, enemyName in enemyToSummon do
				task.spawn(summonEnemy, enemyName, 1, enemy.Position, enemy.Orientation, enemy.CurrentWaypoint, enemy.Distance, enemy.SpawnTime, enemy.Speed)
			end
		end
	end

	--// Wait out the rest of the summon animation after the actual spawn happened
	task.wait(enemy.summonAnimationLength - enemy.summonDelayTime)

	endFreeze(enemy, now)
	enemy.state = nil
end

function Enemy.GetFarthestEnemy(): EnemyData
	return Enemy.FarthestEnemy
end

--// Central HP update function - handles damage, death, phase transitions, on-death summons, and win condition
function Enemy.UpdateHP(uniqueId: string, newhp: number, arg: string | nil) -- HP TO CHECK
	local enemy = enemyPool[uniqueId]
	if not enemy then return end
	local phaseTwoData = enemy.enemyStats.PhaseTwoData

	newhp = math.floor(newhp)
	if newhp < 0 then newhp = 0 end
	local numId = tonumber(uniqueId:split("_")[2])

	if newhp <= 0 then
		--// Prevent double-death if multiple damage sources hit simultaneously
		if enemy.died then return end
		
		--// Phase transition check - if enemy is in phase 1 and has phase 2 data,
		--// don't kill it, instead freeze it, restore HP, swap active attacks, and transition
		if enemy.Phase and enemy.Phase == 1 then
			local now = workspace:GetServerTimeNow()
			local elapsed = now - enemy.SpawnTime
			local encrypted = NetworkUtilityModule:EncryptNetworkServerTime(now)
			enemy.FixedElapsed = elapsed - enemy.ElapsedDelay

			--// Lock the enemy in place during the transition animation
			enemy.state = "ActionState"
			freezeTimes[enemy.UniqueId] = now
			fireAllClients(NewPhaseEvent, numId, 2) -- automatically choose second phase (default)
			fireAllClients(FreezeEnemyEvent, numId, encrypted)
			
			--// Set phase 2 health, scaled for player count
			local phaseTwoHealth = phaseTwoData.PhaseTwoHealth
			phaseTwoHealth = getScaledHealth(phaseTwoHealth)
			enemy.Health = phaseTwoHealth

			--// GodMode prevents any damage during the transition window
			enemy.GodMode = true
			
			local stats = enemy.enemyStats
			if stats.SoundData and stats.SoundData.PhaseTransitionID then
				fireAllClients(PlaySoundPacket, stats.SoundData.PhaseTransitionID)
			end
			
			fireAllClients(UpdateEnemyHealthEvent, numId, phaseTwoHealth)
			
			--// Rebuild activeAttacks for phase 2 - swap out phase 1 attacks for phase 2 ones
			enemy.Phase += 1
			enemy.lastAttackTime = now
			enemy.activeAttacks = {}
			for actualIndex, attack in enemy.Attacks do
				if attack.phase == enemy.Phase then
					table.insert(enemy.activeAttacks, enemy.Attacks[actualIndex])
				end
			end
			enemy.currentAttack = enemy.activeAttacks[math.random(1, #enemy.activeAttacks)]

			--// After the transition duration, unfreeze and apply any phase-specific enemy values
			task.delay(phaseTwoData.PhaseTwoTransitionDuration, function()
				if enemy then
					unfreezeEnemy(enemy, workspace:GetServerTimeNow())
					enemy.state = nil
					
					--// Phase 2 might grant new properties (e.g. "Shielded", "Enraged")
					local extraValues = phaseTwoData.PhaseEnemyValues
					for _, value: string? in extraValues do
						if typeof(value) == "string" then
							table.insert(enemy.enemyValues, value)
						end
					end
					enemy.GodMode = false
				end
			end)

			enemy.Phase = 2
			return
		end

		--// Actual death path - cache position data before cleanup for on-death summons
		local deathPosition, deathOrientation, deathCurrentWaypoint, deathDistanceReached = enemy.Position, enemy.Orientation, enemy.CurrentWaypoint, enemy.Distance

		enemy.Health = 0
		--// Stop boss theme music if this was a tracked healthbar enemy
		if enemy.SOUND_MARKED and enemy.enemyStats and enemy.enemyStats.SoundData and enemy.enemyStats.SoundData.ThemeSongID then
			fireAllClients(StopMusicPacket, enemy.enemyStats.SoundData.ThemeSongID)
		end
		enemy.died = true
		--// Only play death sound for real kills, not autoclears (wave skip / cleanup)
		if arg ~= "autoclear" then
			if enemy.enemyStats.SoundData and enemy.enemyStats.SoundData.DeathSoundID then
				fireAllClients(PlaySoundPacket, enemy.enemyStats.SoundData.DeathSoundID)
			end
		end
		fireAllClients(UpdateEnemyHealthEvent, tonumber(uniqueId:split("_")[2]), newhp)

		--// On-death summoning - some enemies spawn children when they die (e.g. splitting enemies)
		local stats = enemy.enemyStats
		if stats.summonType == "OnDeath" then
			local summonData = stats.summonData
			local summonedEntityName = summonData.summonedEntityName
			local summonedEntityAmount = summonData.summonedEntityAmount

			--// Resolve name - can be a table for random picks
			local toSummonEnemyName
			if type(summonedEntityName) == "table" then
				local chosen = math.random(1, #summonedEntityName)
				toSummonEnemyName = summonedEntityName[chosen]
			else
				toSummonEnemyName = summonedEntityName
			end

			local now = workspace:GetServerTimeNow()
			task.spawn(summonEnemy, toSummonEnemyName, summonedEntityAmount, deathPosition, deathOrientation, deathCurrentWaypoint, deathDistanceReached, enemy.SpawnTime, enemy.Speed)
		end
		--// Remove from pool and tell clients to clean up
		fireAllClients(RemoveEnemyEvent, numId)
		enemyPool[uniqueId] = nil
		enemyPoolCount -= 1
	else
		--// Not dead - just update HP and replicate
		enemy.Health = newhp
		fireAllClients(UpdateEnemyHealthEvent, tonumber(uniqueId:split("_")[2]), newhp)
	end
	
	--// Win condition check - if the final boss just died (and it wasn't an autoclear),
	--// trigger the victory sequence: voice lines, award wins, then teleport everyone to lobby
	if arg == "autoclear" then
		print("Autocleared.")
		--
	else
		if enemy.Health == 0 and enemy.Name == Enemy.FinalBossName then
			print("Game cleared succesfully!")
			fireAllClients(PlaySoundPacket, 2)
			task.wait(1)
			--// Staggered Krampus defeat dialogue
			fireAllClients(KrampusMessagePacket, 4)
			task.wait(8)
			fireAllClients(KrampusMessagePacket, 5)
			task.wait(8)
			fireAllClients(KrampusMessagePacket, 6)
			task.wait(8)
			GAME.Value = false
			--// Award wins to all connected players, deduped
			local awarded = {}
			for _, player: Player in Players:GetPlayers() do
				if not table.find(awarded, player) then
					table.insert(awarded, player)
					player:WaitForChild("Stats"):WaitForChild("Wins").Value += 1
				end
			end
			
			fireAllClients(GameEndPacket, 1)
			fireAllClients(PlayMusicPacket, 102)
			--// Give players 60 seconds on the victory screen before booting them
			task.delay(60, function()
				print("Teleporting remaining players..")
				for _, player: Player in Players:GetPlayers() do
					TeleportService:Teleport(PlaceIds.Lobby, player)
				end
			end)
		end
	end
end

function Enemy.GetActiveEnemyCount(): number
	return enemyPoolCount
end

--// Nuke the entire pool - used for wave resets or game end cleanup
function Enemy.ClearAllEnemies(): ()
	for id, enemy in enemyPool do
		Enemy.UpdateHP(id, 0, "autoclear")
		enemyPool[id] = nil
	end
	enemyPoolCount = 0
end

--// Main loop - runs on Heartbeat, handles all per-frame enemy logic:
--// movement, path completion (base damage), summoner scheduling, attack scheduling, farthest enemy tracking
function Enemy.Init(serverModules)
	print("SERVER Enemy system initialized")

	BaseModule = serverModules["Base"]
	task.wait(5)
	
	--// Accumulator for server time sync broadcasts - sends encrypted time to clients at 20hz
	--// Clients use this to stay in sync for position interpolation
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		local now = workspace:GetServerTimeNow()
		
		accumulator += dt
		if accumulator >= 1/20 then
			accumulator = 0
			fireAllClients(SyncToServerTimeEvent,  NetworkUtilityModule:EncryptNetworkServerTime(now))		
		end
		
		--// Track farthest enemy each frame for tower targeting priority
		local farthestDistance = 0
		local farthestEnemy = nil

		if enemyPoolCount == 0 then
			if Enemy.FarthestEnemy ~= nil then
				Enemy.FarthestEnemy = nil
			end
		end

		for id, enemy in enemyPool do
			if enemy.Health <= 0 then continue end

			--// Core movement formula: distance = speed * effectiveTime + extraDistance
			--// FixedElapsed is used when frozen (snapshot), otherwise we compute live elapsed minus total freeze time
			local elapsed = now - enemy.SpawnTime
			local distanceTravelled = enemy.Speed * ( enemy.FixedElapsed or (elapsed - enemy.ElapsedDelay)) + enemy.ExtraDistance

			enemy.Distance = distanceTravelled
			if distanceTravelled > farthestDistance then farthestDistance = distanceTravelled farthestEnemy = enemy end
			
			--// Check if the enemy has reached the end of the path
			--// If so, deal damage to the base equal to its remaining HP, then remove it
			local path = PathModule.getPathByIndex(enemy.PathIndex)
			if path then
				if enemy.Distance >= path.totalLength then

					BaseModule.ServerUpdateHP(enemy.Health)
					Enemy.UpdateHP(enemy.UniqueId, 0, "autoclear")
					
					enemyPool[id] = nil

					--[[
					if enemy.PART then
						enemy.PART:Destroy()
					end
					--]]
					
					continue
				end
			end

			--// Resolve world position + facing direction from distance along the precomputed path
			local pos, forward, waypoint = PathModule.getPathPositionFromDistance(enemy.PathIndex, enemy.Distance)
			if pos then
				enemy.Position = pos
				local yaw = math.deg(math.atan2(forward.X, forward.Z))
				enemy.Orientation = Vector3.new(0, yaw, 0)

				if enemy.CurrentWaypoint ~= waypoint then
					enemy.CurrentWaypoint = waypoint
				end

				--[[
				if enemy.PART then
					enemy.PART.Position = pos
					enemy.PART.Orientation = enemy.Orientation
				end
				--]]
				
				--// Summoner check - if enough time has passed since last summon, trigger the summon action
				--// Sets state to ActionState which blocks movement and other actions during the animation
				if enemy.summonTime and not (enemy.state == "ActionState") then
					local timeSinceSpawn = now - enemy.previousSummonTime
					if timeSinceSpawn >= enemy.summonTime then
						enemy.state = "ActionState"
						enemy.previousSummonTime = now
						if enemy.enemyStats.SoundData and enemy.enemyStats.SoundData.SummonLinesID then
							fireAllClients(PlaySoundPacket, enemy.enemyStats.SoundData.SummonLinesID)
						end
						task.spawn(Enemy.SummonerStop, now, elapsed, id)
					end
				end
			end

			if farthestEnemy then
				Enemy.FarthestEnemy = farthestEnemy
			end
			
			--// Attack scheduling - if this enemy has attacks and isn't already mid-action
			--// Randomizes frequency each cycle from the configured range for less predictable patterns
			local attacksData = enemy.Attacks
			if attacksData and enemy.currentAttack then
				if enemy.state == "ActionState" then continue end
				
				local data = enemy.currentAttack
				--// Roll a random frequency if we haven't yet this cycle
				if not data.actualFrequency then
					data.actualFrequency = math.random(data.attackFrequency[1], data.attackFrequency[2])
				end
				
				--// Time to attack - freeze the enemy, find towers in range, play the attack animation,
				--// stun those towers, then unfreeze and pick the next attack
				if now - enemy.lastAttackTime >= data.actualFrequency then
					enemy.state = "ActionState"
					enemy.lastAttackTime = now
					local encrypted = NetworkUtilityModule:EncryptNetworkServerTime(now)
					enemy.FixedElapsed = elapsed - enemy.ElapsedDelay
					freezeTimes[enemy.UniqueId] = now
					fireAllClients(FreezeEnemyEvent, enemy.NumId, encrypted)

					--// Grab towers in range at the moment the attack starts
					local towersInRange = getTowersInRange(enemy.Position, data.range)
					if enemy and enemy.enemyStats and enemy.enemyStats.SoundData and enemy.enemyStats.SoundData.AttackLinesID then
						fireAllClients(PlaySoundPacket, enemy.enemyStats.SoundData.AttackLinesID)
					end
					fireAllClients(EnemyAttackEvent, enemy.NumId, enemy.currentAttack.attackId)
					task.spawn(function()

						--// Wait for the animation to reach the "hit" event point, then apply stun
						task.wait(data.animationEventLength)
						for _, tower: Model in towersInRange do
							tower:SetAttribute("Stunned", true)
						end
						--// Wait for the rest of the attack duration after the hit landed
						local diff1 = data.duration - data.animationEventLength
						task.wait(diff1)

						--// Unfreeze enemy and clear action state so it can move again
						unfreezeEnemy(enemy, workspace:GetServerTimeNow())
						enemy.state = nil
						data.actualFrequency = nil     -- will re-roll next cycle

						--// Towers stay stunned for a bit longer after the enemy resumes moving
						task.wait(data.freezeEnemyForSeconds - diff1)
						for _, tower: Model in towersInRange do
							if not tower then continue end
							tower:SetAttribute("Stunned", nil)
						end
						
						--// Pick next attack randomly from the active pool
						enemy.currentAttack = enemy.activeAttacks[math.random(1, #enemy.activeAttacks)]
					end)
				end
			end
		end
	end)
end

return Enemy
