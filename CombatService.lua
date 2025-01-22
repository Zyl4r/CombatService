--THIS SCRIPT SHOULD BE INITIALIZED ON THE SERVER

--Services
local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")

--Modules
local HitboxClass = require(script.HitboxClass)
local HitboxTypes = require(script.HitboxClass.Types)
local RocksModule = require(script.RocksModule)
local StunHandler = require(script.StunHandlerV2)

--Constants
local MAX_COMBO = 4

--Variables
local animationsFolder = ReplicatedStorage.Animations
local soundsFolder = ReplicatedStorage.SFX
local debounces = {}

--If an exploiter requires the module, kick them
if RunService:IsClient() then
	Players.LocalPlayer:Kick("Unexpected behaviour")
end

--Clones the rigs from ServerStorage.Dummies to workspace.Characters
local function spawnRigs()
	for _, rig: Model in ipairs(ServerStorage.Dummies:GetChildren()) do
		local clonedRig = rig:Clone()
		clonedRig.Parent = workspace.Characters
	end
end

--Create leaderstats folder with a NumberValue named "Kills", which is incremented when the player kills another player
local function createLeaderstats(player: Player)
	local newLeaderstatsFolder = Instance.new("Folder")
	newLeaderstatsFolder.Name = "leaderstats"
	
	local killsValue = Instance.new("NumberValue")
	killsValue.Name = "Kills"
	killsValue.Value = 0
	killsValue.Parent = newLeaderstatsFolder
	
	newLeaderstatsFolder.Parent = player
end

--Adds the client LocalScript to all clients and sets up RemoteEvents, the LocalScript fires the "M1Event" when the player clicks with the LMB
local function setupClients()
	local newRemoteEvent = Instance.new("RemoteEvent")
	newRemoteEvent.Name = "M1Event"
	newRemoteEvent.Parent = ReplicatedStorage
	
	local newRemoteEvent = Instance.new("RemoteEvent")
	newRemoteEvent.Name = "BlockEvent"
	newRemoteEvent.Parent = ReplicatedStorage
	
	local newLocalScript = script.Client:Clone()
	newLocalScript.Parent = StarterPlayer.StarterPlayerScripts
	
	task.spawn(function() --The server can't access PlayerScripts, so parent the client script to PlayerGui instead.
		for _, player: Player in pairs(Players:GetPlayers()) do
			local ScreenGUI = Instance.new("ScreenGui")
			ScreenGUI.Name = "HitServiceContainer"
			ScreenGUI.ResetOnSpawn = false
			
			local newScriptClone = newLocalScript:Clone()
			newScriptClone.Parent = ScreenGUI
			newScriptClone.Enabled = true
			
			ScreenGUI.Parent = player:WaitForChild("PlayerGui")
		end
	end)
	
	newLocalScript.Enabled = true
end

--Adds a tag that shows which player was the last to attack the target, this is used to increment the "Kills" leaderstats value and prevents teaming
local function createCreatorTag(playerWhoTagged: Player, characterToTag: Model)
	if not Players:GetPlayerFromCharacter(characterToTag) then
		return
	end
	
	local oldCreatorTag: ObjectValue = characterToTag:FindFirstChild("creatorTag")
	
	if oldCreatorTag then
		oldCreatorTag:Destroy()
	end
	
	local newCreatorTag = Instance.new("ObjectValue")
	newCreatorTag.Name = "creatorTag"
	newCreatorTag.Value = playerWhoTagged
	newCreatorTag.Parent = characterToTag
	
	local attributeChanged: RBXScriptConnection
	
	attributeChanged = characterToTag:GetAttributeChangedSignal("Stunned"):Connect(function()
		if not characterToTag:GetAttribute("Stunned") then
			local creatorTag: ObjectValue = characterToTag:FindFirstChild("creatorTag")

			if creatorTag then
				creatorTag:Destroy()
			end
		end
		
		attributeChanged:Disconnect()
	end)
end

--Gets the animation based on the humanoid's floor material (if it's Air, then return Downslam animation, needs to be the last hit) and if player is pressing space (last hit only), else, return a normal punch
local function getAnimation(character: Model, isSpaceDown: boolean): AnimationTrack
	local currentCombo = character:GetAttribute("Combo")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid:FindFirstChildOfClass("Animator")
	local punchAnimations = animationsFolder.Punches:GetChildren()
	local miscAnimations = animationsFolder.Misc
	local animation
	local attackType
	
	if currentCombo == MAX_COMBO and humanoid.FloorMaterial == Enum.Material.Air then
		animation = miscAnimations.Downslam
		attackType = "Downslam"
	elseif currentCombo == MAX_COMBO and isSpaceDown then
		animation = miscAnimations.Uppercut
		attackType = "Uppercut"
	else
		--Sorting the table so every animation is in order.
		table.sort(punchAnimations, function(a, b)
			return tonumber(a.Name) < tonumber(b.Name)
		end)

		animation = punchAnimations[currentCombo]
		attackType = "Punch"
	end

	local animationTrack = animator:LoadAnimation(animation)

	return animationTrack, attackType
end

--Stops every other animation, prevents weird behaviour when playing other animations or ragdolling characters
local function stopPlayingAnimations(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid:FindFirstChildOfClass("Animator")

	for _, animationTrack: AnimationTrack in pairs(animator:GetPlayingAnimationTracks()) do
		animationTrack:Stop()
	end
end

--Plays a punch sound effect based on the player combo
local function playPunchSFX(player: Player, hittedCharacter: Model)
	local currentPlayerCombo = player.Character:GetAttribute("Combo")
	local punchesSFX = soundsFolder.Punches
	local soundClone: Sound = punchesSFX[tostring(currentPlayerCombo)]:Clone()
	soundClone.Parent = hittedCharacter.HumanoidRootPart
	soundClone:Play()

	task.spawn(function()
		soundClone.Ended:Wait()
		soundClone:Destroy()
	end)
end

--Plays a random block sound effect
local function playBlockedSFX(hittedCharacter: Model, blockOrParry: string)
	local blockSounds = soundsFolder.Blocking:GetChildren()
	local soundClone: Sound
	
	if blockOrParry == "Block" then
		soundClone = blockSounds[math.random(1, #blockSounds)]:Clone()
	else
		soundClone = soundsFolder.Parrying.Parry:Clone()
	end
	
	soundClone.Parent = hittedCharacter.HumanoidRootPart
	soundClone:Play()

	task.spawn(function()
		soundClone.Ended:Wait()
		soundClone:Destroy()
	end)
end

--Knocks back the hitted character, it uses the attacker's HumanoidRootPart as a direction to where the character should be knocked back
local function knockbackCharacter(player: Player, hittedCharacter: Model, attackType: string)
	local enemyHumanoidRootPart: BasePart = hittedCharacter.HumanoidRootPart
	local playerHumanoidRootPart: BasePart = player.Character.HumanoidRootPart
	local playerHumanoid = player.Character:FindFirstChildOfClass("Humanoid")
	local knockbackDirection = playerHumanoidRootPart.CFrame.LookVector
	local currentPlayerCombo = player.Character:GetAttribute("Combo")
	local velocity = 10

	if currentPlayerCombo == 4 and attackType == "Downslam" then
		enemyHumanoidRootPart.CFrame = enemyHumanoidRootPart.CFrame * CFrame.new(0,-2,0) * CFrame.Angles(math.rad(90),0,0)
		RocksModule.Ground(enemyHumanoidRootPart.Position, 15, Vector3.new(4, 4, 4), {workspace.Characters, workspace.RaycastFiltered}, 15, false, 5)
		return
	end
	
	--Knocking back hittedCharacter
	local bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.MaxForce = Vector3.new(math.huge, 0, math.huge)
	bodyVelocity.P = 50000
	bodyVelocity.Velocity = knockbackDirection.Unit * velocity
	
	if currentPlayerCombo == 4 and attackType == "Uppercut" then
		bodyVelocity.MaxForce = Vector3.new(0, math.huge, 0)
		bodyVelocity.Velocity = Vector3.new(0, 40, 0)
	end
	
	if currentPlayerCombo == 4 and attackType == "Punch" then
		velocity = 35
		bodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
		bodyVelocity.Velocity = Vector3.new(knockbackDirection.X, 1, knockbackDirection.Z).Unit * velocity 
	end
	

	
	--Making the player go towards hittedCharacter if they aren't on their last hit
	local playerBodyVelocity = Instance.new("BodyVelocity")
	playerBodyVelocity.MaxForce = Vector3.new(math.huge, 0, math.huge)
	playerBodyVelocity.P = 50000
	playerBodyVelocity.Velocity = (currentPlayerCombo == 4) and Vector3.zero or knockbackDirection.Unit * velocity

	bodyVelocity.Parent = enemyHumanoidRootPart
	playerBodyVelocity.Parent = playerHumanoidRootPart

	Debris:AddItem(bodyVelocity, .2)
	Debris:AddItem(playerBodyVelocity, .2)
end

--Checks if player has hit the back of the opponent, is used to guardbreak
local function checkAttackDirection(player: Player, hittedCharacter: Model)
	local character = player.Character
	local humanoidRootPart: BasePart = character.HumanoidRootPart
	local hittedHumanoidRootPart: BasePart = hittedCharacter.HumanoidRootPart
	local attackDirection = (hittedHumanoidRootPart.Position - humanoidRootPart.Position).Unit
	local hittedCharacterLookVector = hittedHumanoidRootPart.CFrame.LookVector
	local isFacingHittedCharacter = math.acos(attackDirection:Dot(hittedCharacterLookVector)) < math.rad(90)
	
	return isFacingHittedCharacter --false: hitted the back | true: hitted the front
end

--Damages every character's humanoid that has been passed to the hittedCharacters table, tags the characters, and if it's the last hit, or they die, ragdolls them
local function damageHittedCharacter(player: Player, hittedCharacters: {Model}, attackType: string)
	for _, character: Model in ipairs(hittedCharacters) do
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local animator = humanoid:FindFirstChildOfClass("Animator")
		local ragdoll = character:GetAttribute("Ragdoll")
		local currentPlayerCombo = player.Character:GetAttribute("Combo")
		local hitsFolder = animationsFolder.Hits
		
		if character:GetAttribute("Parry") and os.clock() - character:GetAttribute("Parry") <= 0.5 and not checkAttackDirection(player, character) then
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
			print("reached")
			humanoid.WalkSpeed = 16
			humanoid.JumpHeight = 7.2
			
			character:SetAttribute("Parry", nil)
			StunHandler.Stun(humanoid, 3)
			
			playBlockedSFX(character, "Parry")
			continue
		end
		
		--Checks if the character that hitbox has hit is blocking, and the hitbox has hit the front of the character
		if character:GetAttribute("Blocking") and not checkAttackDirection(player, character) and attackType ~= "Downslam" then
			playBlockedSFX(character, "Block")
			continue
		end
		
		--Prevents teaming by checking if the last player who attacked this character is the same as the one who attacked this character now, and checks if character is ragdolled
		if character:FindFirstChild("creatorTag") and character:FindFirstChild("creatorTag").Value ~= player or ragdoll then
			continue
		end
		
		createCreatorTag(player, character)
		
		stopPlayingAnimations(character)
		
		if currentPlayerCombo == 4 then
			humanoid:TakeDamage(5)
			StunHandler.Stun(humanoid, 1.5)
			character:FindFirstChild("RagdollTrigger").Value = true
		else
			humanoid:TakeDamage(2)
			animator:LoadAnimation(hitsFolder.Hit1):Play()
			StunHandler.Stun(humanoid, 1.25)
		end
		
		--If the hitted character died, ragdoll them
		if humanoid.Health <= 0 then
			character:FindFirstChild("RagdollTrigger").Value = true
		end
		
		character:SetAttribute("Blocking", false)
		character:SetAttribute("Attacking", false)
		character:SetAttribute("Parry", nil)
		playPunchSFX(player, character)
		knockbackCharacter(player, character, attackType)
	end
end

--Changes the player's combo, resets back to 1 if more than 2 seconds has passed since the last click
local function changeCombo(player: Player)
	local character = player.Character
	local currentPlayerCombo = character:GetAttribute("Combo")

	if debounces[player] then
		local timeElapsedSinceLastPunch = os.clock() - debounces[player]

		if timeElapsedSinceLastPunch <= 2 then
			if currentPlayerCombo >= MAX_COMBO then
				character:SetAttribute("Combo", 1)
			else
				character:SetAttribute("Combo", currentPlayerCombo + 1)
			end
		else
			character:SetAttribute("Combo", 1)
		end
	else
		if currentPlayerCombo >= MAX_COMBO then
			character:SetAttribute("Combo", 1)
		else
			character:SetAttribute("Combo", currentPlayerCombo + 1)
		end
	end

	debounces[player] = os.clock()
end

--Sets "Blocking" attribute to true or false, and blocks every direct attack
local function onBlockEvent(player: Player, isBlocking: boolean)
	local character = player.Character
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid:FindFirstChildOfClass("Animator")
	local stunned = character:GetAttribute("Stunned")
	local attacking = character:GetAttribute("Attacking")
	local attributeChangedSignal: RBXScriptConnection

	if not character or stunned or attacking then
		return
	end

	local blockAnimationTrack = animator:LoadAnimation(animationsFolder.Misc.Block)

	attributeChangedSignal = character:GetAttributeChangedSignal("Blocking"):Connect(function()
		if not character:GetAttribute("Blocking") then
			stopPlayingAnimations(character)
			humanoid.WalkSpeed = 16
			humanoid.JumpHeight = 7.2
		else
			blockAnimationTrack:Play()
			humanoid.WalkSpeed = 6
			humanoid.JumpHeight = 0
		end

		attributeChangedSignal:Disconnect()
	end)
	
	if isBlocking and character:GetAttribute("CanParry") then
		character:SetAttribute("Parry", os.clock())
		character:SetAttribute("CanParry", false)
		
		task.delay(3, function()
			character:SetAttribute("CanParry", true)
		end)
	end
	
	character:SetAttribute("Blocking", isBlocking)
end

--Main function, creates hitbox, hits the characters and plays animations
local function onM1Event(player: Player, isSpaceDown: boolean)
	local character = player.Character
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local attacking = character:GetAttribute("Attacking")
	local stunned = character:GetAttribute("Stunned")
	local blocking = character:GetAttribute("Blocking")
	local ragdoll = character:GetAttribute("Ragdoll")

	if not character or attacking or stunned or blocking or ragdoll then
		return
	end

	character:SetAttribute("Attacking", true)

	changeCombo(player)
	
	humanoid.JumpHeight = 0
	humanoid.WalkSpeed = 10
	
	local currentAnimationTrack, attackType = getAnimation(character, isSpaceDown)

	task.spawn(stopPlayingAnimations, character)
	
	local markerReachedSignal: RBXScriptConnection
	local attributeChangedSignal = character:GetAttributeChangedSignal("Stunned"):Connect(function()
		currentAnimationTrack:Stop()
		markerReachedSignal:Disconnect()
	end)
	
	markerReachedSignal = currentAnimationTrack:GetMarkerReachedSignal("Hit"):Connect(function()
		attributeChangedSignal:Disconnect()
		markerReachedSignal:Disconnect()
		local hitted = false

		local hitboxParams = {
			SizeOrPart = Vector3.new(6, 6, 6),
			DebounceTime = 0,
			Debug = true,
			Blacklist = {character},
			SpatialOption = "InPart",
			LookingFor = "Humanoid"
		} :: HitboxTypes.HitboxParams

		local newHitbox, connected = HitboxClass.new(hitboxParams)
		newHitbox:WeldTo(character.HumanoidRootPart, CFrame.new(0, 0, -2.5))
		
		local connection = newHitbox.HitSomeone:Connect(function(hittedCharacters: {Model})
			hitted = true
			task.spawn(damageHittedCharacter, player, hittedCharacters, attackType)
			newHitbox:Destroy()
		end)

		newHitbox:Start()

		if not hitted then
			task.delay(0.1, function()
				newHitbox:Destroy()
			end)
		end
		
		if character:GetAttribute("Combo") == MAX_COMBO then
			task.wait(1)
		end
		
		character:SetAttribute("Attacking", false)
	end)
	
	task.spawn(function()
		currentAnimationTrack.Ended:Wait()

		humanoid.JumpHeight = 7.2
		humanoid.WalkSpeed = 16
	end)
	
	currentAnimationTrack:Play()
end

local HitService = {}

--Setup clients, adds leaderstats folders to every player (loops first because someone might join before the server intialize), connects events and preload animations and scripts
function HitService.Init()
	setupClients()
	
	for _, player in ipairs(Players:GetPlayers()) do
		createLeaderstats(player)
		
		local character = player.Character or player.CharacterAdded:Wait()
		character:SetAttribute("Combo", 0)
		player:SetAttribute("CanParry", true)
	end
	
	Players.PlayerAdded:Connect(function(player: Player)
		createLeaderstats(player)
		
		player.CharacterAdded:Connect(function(character: Model)
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local humanoidDiedEvent: RBXScriptConnection
			
			humanoidDiedEvent = humanoid.Died:Connect(function()
				local creatorTag = character:FindFirstChild("creatorTag")
				if creatorTag then
					local killer: Player = creatorTag.Value
					
					if killer then
						killer.leaderstats.Kills.Value += 1
					end
				end
				
				humanoidDiedEvent:Disconnect()
			end)
			
			character.Parent = workspace.Characters
			character:SetAttribute("Combo", 0)
			character:SetAttribute("CanParry", true)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		if debounces[player] then
			debounces[player] = nil
		end
	end)
	
	spawnRigs()
	
	ReplicatedStorage:FindFirstChild("M1Event").OnServerEvent:Connect(onM1Event)
	ReplicatedStorage:FindFirstChild("BlockEvent").OnServerEvent:Connect(onBlockEvent)
	
	ContentProvider:PreloadAsync(ReplicatedStorage.Animations:GetDescendants())
	ContentProvider:PreloadAsync({workspace.Characters.Dummy.R6NPCRagdoll, workspace.Characters.BlockingDummy.R6NPCRagdoll})
end

return HitService
