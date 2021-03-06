-- LIGHT STATES - For US CTA Colour Lights
ANIMSTATE_GREEN_RED = 0
ANIMSTATE_RED_GREEN = 11
ANIMSTATE_YELLOW_RED = 1
ANIMSTATE_RED_YELLOW = 10
ANIMSTATE_RED_RED = 3

ATC_TARGET_DECELERATION = 1.20 -- meters/second/second
ATC_REACTION_TIME = 2.5 -- seconds
MPS_TO_MPH = 2.23694 -- Meters/Second to Miles/Hour
MPH_TO_MPS = 1.0 / MPS_TO_MPH
MPH_TO_MiPS = 0.000277777778 -- Miles/Hour to Miles/Second
MI_TO_M = 1609.34 -- Miles to Meters
M_TO_MI = 1.0 / MI_TO_M -- Meters to Miles
ATC_WARN_OFF = 0.0
ATC_WARN_CONSTANT = 1.0
ATC_WARN_INTERMITTENT = 2.0
DISPLAY_SPEEDS = { 0, 15, 25, 35, 45, 55, 70 }
NUM_DISPLAY_SPEEDS = 7
EST_REACTION_TIME = 3 -- Estimated reaction time of the driver for speed drops
SIGNAL_DISTANCE_BUFFER = 3.00
ACCEL_TIME = 3 -- The amount of time it takes to go from full power to full brake ( with jerk limit )
ACCEL_PER_SECOND = 1.0 / 3.0 -- Units of acceleration per second ( jerk limit, used for extra buffers )

atcSigDirection = 0.0
gLastSigDist = 0.0
gLastSigDistTime = 0.0
gBrakeApplication = false
gBrakeTime = 0.0
gAlertAcknowledged = true
gTimeSinceSpeedIncrease = 0.0
gLastSpeedLimit = 0.0

function getBrakingDistance( vF, vI, a )
	return ( ( vF * vF ) - ( vI * vI ) ) / ( 2 * a )
end

function getStoppingSpeed( vI, a, d )
	return math.sqrt( math.max( ( vI * vI ) + ( 2 * a * d ), 0.0 ) )
end

function SetATCWarnMode( mode )
	Call( "*:SetControlValue", "ATCWarnMode", 0, mode )
end

function getSpeedLimitAbove( speed )
	for i = 1, NUM_DISPLAY_SPEEDS do
		if DISPLAY_SPEEDS[i] >= speed then
			return DISPLAY_SPEEDS[i]
		end
	end
	return DISPLAY_SPEEDS[NUM_DISPLAY_SPEEDS]
end

function getSpeedLimitBelow( speed )
	for i = NUM_DISPLAY_SPEEDS, 1, -1 do
		if DISPLAY_SPEEDS[i] <= speed then
			return DISPLAY_SPEEDS[i]
		end
	end
	return DISPLAY_SPEEDS[1]
end

function UpdateATC( interval )
	local targetSpeed, trackSpeed, trainSpeed, enabled, throttle
	local spdType, spdLimit, spdDist, spdBuffer, accelBuff
	local sigResult, sigState, sigDist, sigAspect
	local reactionTimeDistance, stoppingDistance, trackStoppingDistance

	targetSpeed = Call( "*:GetCurrentSpeedLimit" )
	trackSpeed = targetSpeed
	trainSpeed = math.abs( Call( "*:GetSpeed" ) )
	enabled = Call( "*:GetControlValue", "ATCEnabled", 0 ) > 0
	reactionTimeDistance = trackSpeed * ( EST_REACTION_TIME + ACCEL_TIME )
	trackStoppingDistance = getBrakingDistance( 0, math.max( trackSpeed, 0.01 ), -ATC_TARGET_DECELERATION )
	totalStoppingDistance = reactionTimeDistance + trackStoppingDistance
	
	trueThrottle = GetControlValue( "TrueThrottle" )
	
	spdBuffer = math.max( trackStoppingDistance, 0 ) + 10
		
	accelBuff = ( ( trueThrottle - ( -1 ) ) / ACCEL_PER_SECOND ) -- Estimated time to reach full brakes from current throttle
	accelBuff = accelBuff * trainSpeed -- Estimated meters covered in the time taken to reach full brakes
	
	spdBuffer = spdBuffer + accelBuff -- Accomodate for jerk limit

	spdType, spdLimit, spdDist = Call( "*:GetNextSpeedLimit", 0 )
	sigResult, sigState, sigDist, sigAspect = Call( "*:GetNextRestrictiveSignal", 0 )

	if ( sigResult < 0 ) then -- no signal
		sigState = 0
	end

	local searchDist, searchCount, maxSearchDist, setAspect

	searchDist = 0
	searchCount = 0
	maxSearchDist = reactionTimeDistance + trackStoppingDistance
	setAspect = false
	repeat
		if ( sigAspect < 20 and setAspect == false ) then
			if ( sigAspect == ANIMSTATE_GREEN_RED or sigAspect == ANIMSTATE_RED_GREEN ) then -- Clear signals are actually at warning so the script system sees them ( honestly, DTG...can you not make a way to find clear signals? )
				Call( "*:SetControlValue", "ATCAspect", 0, 0 )
			else
				Call( "*:SetControlValue", "ATCAspect", 0, sigState )
			end

			Call( "*:SetControlValue", "NextSignalAspect", sigAspect )
			setAspect = true
		end

		if ( sigResult > 0 and sigState == 2 and sigDist < maxSearchDist ) then -- Treat a red signal as "end of track"
			spdType = 0
			spdDist = sigDist
		end

		if ( spdType == 0 ) then -- End of line...stop the train
			if ( spdDist <= spdBuffer ) then
				targetSpeed = math.min( targetSpeed, math.max( getStoppingSpeed( trackSpeed, -ATC_TARGET_DECELERATION, spdBuffer - ( spdDist - SIGNAL_DISTANCE_BUFFER ) ), 6.0 * MPH_TO_MPS ) )
				if ( spdDist < 15 ) then
					targetSpeed = 0
				end
			end
		elseif ( spdType > 0 ) then
			if ( spdLimit < targetSpeed ) then
				if ( spdDist <= spdBuffer ) then
				  --targetSpeed = math.min( targetSpeed, math.max( getStoppingSpeed( trackSpeed, -ATC_TARGET_DECELERATION, spdBuffer - ( spdDist - reactionTimeDistance ) ), spdLimit ) )
					targetSpeed = math.min( targetSpeed, math.max( getStoppingSpeed( trackSpeed, -ATC_TARGET_DECELERATION, spdBuffer - ( spdDist - SIGNAL_DISTANCE_BUFFER ) ), spdLimit ) )
				end
			end
		end

		tSpdType, tSpdLimit, tSpdDist = Call( "*:GetNextSpeedLimit", 0, searchDist )
		if ( tSpdType == 0 or ( tSpdType > 0 and tSpdLimit < spdLimit ) ) then
			spdType, spdLimit, spdDist = tSpdType, tSpdLimit, tSpdDist
		end

		tSigResult, tSigState, tSigDist, tSigAspect = Call( "*:GetNextRestrictiveSignal", 0, searchDist )

		if ( tSigState >= sigState and tSigAspect < 20 ) then -- More restrictive signal, or we're skipping over a station signal
			sigResult, sigState, sigDist, sigAspect = tSigResult, tSigState, tSigDist, tSigAspect
		end

		if ( tSpdType < 0 ) then
			searchDist = tSigDist + 0.1
		elseif ( tSigResult < 0 ) then
			searchDist = tSpdDist + 0.1
		else
			searchDist = math.min( tSpdDist, tSigDist ) + 0.1
		end
		searchCount = searchCount + 1
	until ( searchDist > maxSearchDist or searchCount > 25 or ( tSpdType < 0 and tSigResult < 0 ) )

	gLastSigDistTime = gLastSigDistTime + interval
	if ( sigDist > gLastSigDist and gLastSigDistTime >= 1.0 ) then
		if ( atcSigDirection < 0.5 ) then
			atcSigDirection = 1
		else
			atcSigDirection = 0
		end
	end

	if ( gLastSigDistTime >= 1.0 ) then
		gLastSigDistTime = 0.0
		gLastSigDist = sigDist
	end

	targetSpeed = math.floor( ( targetSpeed * MPS_TO_MPH * 4 ) + 0.5 ) / 4 -- Round to nearest 0.25

	local ATOEnabled = ( Call( "*:GetControlValue", "ATOEnabled", 0 ) or -1 ) > 0.0

	if ( targetSpeed > gLastSpeedLimit ) then
		if ( gTimeSinceSpeedIncrease < 1.5 ) then -- Don't increase speed if it only increases for a split second ( this avoids speed limit bugs in the engine )
			gTimeSinceSpeedIncrease = gTimeSinceSpeedIncrease + interval
			targetSpeed = gLastSpeedLimit
		else
			gLastSpeedLimit = targetSpeed
		end
	else
		gTimeSinceSpeedIncrease = 0
	end
	gLastSpeedLimit = targetSpeed

	if not enabled then
		targetSpeed = 110
	end

	Call( "*:SetControlValue", "ATCRestrictedSpeed", 0, targetSpeed )

	-- Following section logic taken from CTA 7000-series RFP spec

	throttle = CombinedLever * 2.0 - 1.0

	if ( ( TrainSpeed >= ( targetSpeed + 1 ) or gBrakeApplication ) and not ATOEnabled ) then
		gAlertAcknowledged = false
		if ( gBrakeApplication ) then
			Call( "*:SetControlValue", "ATCBrakeApplication", 0, 1.0 )
			SetATCWarnMode( ATC_WARN_CONSTANT )
			if ( trainSpeed < 0.1 and throttle <= -0.99 ) then
				gBrakeApplication = false
			end
		else
			Call( "*:SetControlValue", "ATCBrakeApplication", 0, 0.0 )
			if ( throttle <= -0.9 ) then -- 90% brake application
				SetATCWarnMode( ATC_WARN_INTERMITTENT )
			else
				gBrakeTime = gBrakeTime + interval
				SetATCWarnMode( ATC_WARN_CONSTANT )
			end
		end
	else
		Call( "*:SetControlValue", "ATCBrakeApplication", 0, 0.0 )
		gBrakeTime = 0.0
		SetATCWarnMode( ATC_WARN_OFF )
	end

	if ( TrainSpeed < ( targetSpeed + 1 ) and throttle <= -0.9 ) then
		gAlertAcknowledged = true
	end
end