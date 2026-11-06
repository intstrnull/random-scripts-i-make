--!nolint
if getgenv().fragStop then getgenv().fragStop() end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local plr = Players.LocalPlayer
local pickups = workspace:WaitForChild("Pickups")

local MAX_DIST = 1000        -- max distance from home position
local TWEEN_SPEED = 350      -- studs per second when tweening
local MIN_TWEEN_TIME = 0.08  -- shortest tween duration
local MAX_TWEEN_TIME = 0.40  -- longest tween duration
local TRY_WAIT = 0.22        -- seconds to stand steadily on fragment per try
local MAX_TRIES = 3          -- touch tries per visit (sinks deeper on each try)
local LIFT = 8               -- step-off height between tries so .Touched fires fresh
local RETRY_COOLDOWN = 0.8   -- seconds before distance-check re-targets a stubborn fragment
local DEBUG = true           -- set to false to silence F9 console prints

-- Progressive sink depths across the 3 tries so flat floor fragments never get missed
local SINK_LEVELS = { 0.5, 1.8, 3.0 }

local alive = true
local busy = false
local activeTween = nil
local picked = setmetatable({}, { __mode = "k" })
local skipUntil = setmetatable({}, { __mode = "k" })
local visits = setmetatable({}, { __mode = "k" })
local conns = {}

local function log(...)
	if DEBUG then
		print("[Fragments]", ...)
	end
end

local function fmtVec(v)
	return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
end

local function cancelTween()
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end
end

local function getRoot()
	local char = plr.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 and hum.RootPart then
		return hum.RootPart, hum
	end
	return nil, nil
end

local function standHeight(hum, hrp)
	if hum.RigType == Enum.HumanoidRigType.R15 then
		return hum.HipHeight + hrp.Size.Y / 2
	end
	local leg = hum.Parent:FindFirstChild("Left Leg")
	return hrp.Size.Y / 2 + (leg and leg.Size.Y or 2)
end

local function getPart(v)
	if v:IsA("BasePart") then return v end
	local ti = v:FindFirstChildWhichIsA("TouchTransmitter", true)
	if ti and ti.Parent:IsA("BasePart") then return ti.Parent end
	if v:IsA("Model") and v.PrimaryPart then return v.PrimaryPart end
	return v:FindFirstChildWhichIsA("BasePart", true)
end

local function isPresent(v, part)
	return v ~= nil
		and part ~= nil
		and v:IsDescendantOf(pickups)
		and part:IsDescendantOf(workspace)
end

local function checkDistance(partPos, homePos)
	local dist = (partPos - homePos).Magnitude
	return dist <= MAX_DIST, dist
end

local function pin(hrp, pos, rot)
	hrp.CFrame = CFrame.new(pos) * rot
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
end

-- Smoothly tween hrp to targetPos; aborts immediately if checkFn() returns false
local function tweenTo(hrp, targetPos, rot, checkFn)
	cancelTween()

	local dist = (targetPos - hrp.Position).Magnitude
	if dist < 1.5 then
		pin(hrp, targetPos, rot)
		return true
	end

	local duration = math.clamp(dist / TWEEN_SPEED, MIN_TWEEN_TIME, MAX_TWEEN_TIME)
	local info = TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	local tween = TweenService:Create(hrp, info, { CFrame = CFrame.new(targetPos) * rot })
	activeTween = tween
	tween:Play()

	while alive and tween.PlaybackState == Enum.PlaybackState.Playing do
		if getRoot() ~= hrp then
			cancelTween()
			return false, "respawned"
		end
		if checkFn then
			local ok, reason = checkFn()
			if not ok then
				cancelTween()
				return false, reason
			end
		end
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
		RunService.Heartbeat:Wait()
	end

	if activeTween == tween then
		activeTween = nil
	end
	return true
end

-- Pass 1: Unpicked fragments within MAX_DIST
-- Pass 2 (Distance Fallback): Any fragment still within MAX_DIST (ignores picked[v] label!)
local function getNextByDistance(hrpPos, homePos)
	local now = os.clock()
	local best, bestPart, bestDist, bestHomeDist
	local fallback, fallbackPart, fallbackDist, fallbackHomeDist

	for _, v in pickups:GetChildren() do
		if v.Name ~= "Fragment" then continue end
		if (skipUntil[v] or 0) > now then continue end

		local part = getPart(v)
		if not isPresent(v, part) then continue end

		-- Strict distance check from homePos
		local withinMax, homeDist = checkDistance(part.Position, homePos)
		if not withinMax then continue end

		local curDist = (part.Position - hrpPos).Magnitude

		if not picked[v] then
			-- Priority 1: Fresh/unmarked fragments
			if not best or curDist < bestDist then
				best, bestPart, bestDist, bestHomeDist = v, part, curDist, homeDist
			end
		else
			-- Priority 2: Distance-check fallback (ignores picked[v] if still sitting in range)
			if not fallback or curDist < fallbackDist then
				fallback, fallbackPart, fallbackDist, fallbackHomeDist = v, part, curDist, homeDist
			end
		end
	end

	if best then
		return best, bestPart, bestDist, bestHomeDist, false
	end
	return fallback, fallbackPart, fallbackDist, fallbackHomeDist, true
end

-- Stand steadily on the fragment across MAX_TRIES, sinking deeper each try and hopping between tries
local function holdOnFragment(hrp, baseStandY, rot, v, part, homePos, hopFirst)
	for try = 1, MAX_TRIES do
		local sink = SINK_LEVELS[try] or SINK_LEVELS[#SINK_LEVELS]
		local yOffset = math.max(0, baseStandY - sink)

		-- Step off into the air for 3 frames between tries so TouchTransmitter fires fresh
		if try > 1 or hopFirst then
			for _ = 1, 3 do
				if not alive or getRoot() ~= hrp then return "respawned" end
				if not isPresent(v, part) then return "picked" end
				if not checkDistance(part.Position, homePos) then return "out_of_range" end
				pin(hrp, part.Position + Vector3.new(0, baseStandY + LIFT, 0), rot)
				RunService.Heartbeat:Wait()
			end
		end

		-- Hold steadily on the fragment for TRY_WAIT seconds
		local t = 0
		while alive and t < TRY_WAIT do
			if getRoot() ~= hrp then return "respawned" end
			if not isPresent(v, part) then return "picked" end

			local curPos = part.Position
			local withinMax, dHome = checkDistance(curPos, homePos)
			if not withinMax then
				log(string.format("   [DIST STOP] Fragment moved to %.1f studs (> MAX_DIST %d)", dHome, MAX_DIST))
				return "out_of_range"
			end

			pin(hrp, curPos + Vector3.new(0, yOffset, 0), rot)

			if firetouchinterest then
				pcall(firetouchinterest, hrp, part, 0)
				pcall(firetouchinterest, hrp, part, 1)
			end

			t += RunService.Heartbeat:Wait()
		end
	end

	return isPresent(v, part) and "still_present" or "picked"
end

local function collect()
	local hrp, hum = getRoot()
	if not hrp or not hum then return end

	local startCF = hrp.CFrame
	local homePos = startCF.Position
	local rot = startCF.Rotation

	local v, part, curDist, homeDist, isFallback = getNextByDistance(homePos, homePos)
	if not v then return end

	local baseStandY = standHeight(hum, hrp)
	log(string.format("Starting batch | Home locked at %s | StandHeight: %.1f", fmtVec(homePos), baseStandY))
	local pickedCount = 0

	while alive and v and part do
		visits[v] = (visits[v] or 0) + 1
		log(string.format(
			"-> [%s] %s | Dist: %.1f | HomeDist: %.1f/%d | Visit #%d",
			isFallback and "DIST-FALLBACK" or "FRESH",
			v:GetFullName(), curDist, homeDist, MAX_DIST, visits[v]
		))

		-- 1. Smoothly tween to the fragment
		local initialY = math.max(0, baseStandY - SINK_LEVELS[1])
		local reached, abortReason = tweenTo(hrp, part.Position + Vector3.new(0, initialY, 0), rot, function()
			if not isPresent(v, part) then return false, "picked" end
			if not checkDistance(part.Position, homePos) then return false, "out_of_range" end
			return true
		end)

		local status
		if not reached then
			if abortReason == "respawned" then
				log("Batch aborted: character respawned")
				return
			end
			status = abortReason
		else
			-- 2. Hold steadily on the fragment (with step-off hops and deeper sink per try)
			status = holdOnFragment(hrp, baseStandY, rot, v, part, homePos, visits[v] > 1)
			if status == "respawned" then
				log("Batch aborted: character respawned")
				return
			end
		end

		if status == "picked" or not isPresent(v, part) then
			picked[v] = true
			pickedCount += 1
			log("   [PICKED] Fragment collected and removed!")
		elseif status == "out_of_range" then
			picked[v] = true
			skipUntil[v] = os.clock() + RETRY_COOLDOWN
			log("   [OUT OF RANGE] Stopped following fragment past MAX_DIST")
		else
			-- Fragment is still in workspace.Pickups after our visit:
			-- Mark picked[v] = true so fresh fragments go first, and set a short cooldown.
			-- If it is STILL in range after RETRY_COOLDOWN, getNextByDistance's fallback pass will grab it anyway!
			picked[v] = true
			skipUntil[v] = os.clock() + RETRY_COOLDOWN
			log(string.format("   [STILL IN RANGE] Marked visited -> distance check will re-verify in %.1fs", RETRY_COOLDOWN))
		end

		v, part, curDist, homeDist, isFallback = getNextByDistance(hrp.Position, homePos)
	end

	-- Smoothly tween back to home position
	if getRoot() == hrp then
		log("Tweening back to home:", fmtVec(homePos))
		tweenTo(hrp, homePos, rot)
		pin(hrp, homePos, rot)
		log(string.format("Batch finished | Returned to %s | Confirmed picked: %d", fmtVec(homePos), pickedCount))
	end
end

local function tryCollect()
	if busy or not alive then return end
	busy = true
	local ok, err = pcall(collect)
	cancelTween()
	if not ok then
		warn("[Fragments Error]", err)
	end
	busy = false
end

-- Instant trigger as soon as a fragment drops within MAX_DIST
table.insert(conns, pickups.ChildAdded:Connect(function(child)
	if not alive or child.Name ~= "Fragment" then return end
	task.spawn(function()
		local t = 0
		while alive and child.Parent == pickups and not getPart(child) and t < 1 do
			t += task.wait()
		end
		local part = getPart(child)
		local hrp = getRoot()
		if alive and part and hrp then
			local withinMax, dist = checkDistance(part.Position, hrp.Position)
			if withinMax then
				log(string.format("Drop detected in range (%.1f studs): %s", dist, child:GetFullName()))
				tryCollect()
			else
				log(string.format("Drop ignored (%.1f studs > MAX_DIST %d): %s", dist, MAX_DIST, child:GetFullName()))
			end
		end
	end)
end))

table.insert(conns, pickups.ChildRemoved:Connect(function(child)
	picked[child] = nil
	skipUntil[child] = nil
	visits[child] = nil
end))

getgenv().fragStop = function()
	alive = false
	cancelTween()
	for _, c in conns do
		c:Disconnect()
	end
	log("Stopped fragment collector.")
end

log("Fragment collector started (Tween + Distance Fallback) | MAX_DIST =", MAX_DIST)

-- Continuous distance scanner (catches any fragments within MAX_DIST regardless of picked label)
task.spawn(function()
	while alive do
		tryCollect()
		task.wait(0.1)
	end
end)
