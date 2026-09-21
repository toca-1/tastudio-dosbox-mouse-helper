local MOUSE_X = "Mouse Position X"
local MOUSE_Y = "Mouse Position Y"
local MOUSE_DX = "Mouse Speed X"
local MOUSE_DY = "Mouse Speed Y"

local MOUSE_LEFT = "Mouse Left Button"
local MOUSE_MIDDLE = "Mouse Middle Button"
local MOUSE_RIGHT = "Mouse Right Button"

local CLICK_BUTTONS = {
	LMB = MOUSE_LEFT,
	MMB = MOUSE_MIDDLE,
	RMB = MOUSE_RIGHT,
}

local X_MIN, X_MAX, X_NEUTRAL = 0, 2560, 1280
local Y_MIN, Y_MAX, Y_NEUTRAL = 0, 2048, 1024

local MAX_POSITION_DELTA = 255
local MAX_EXPLICIT_SPEED = 180

local alive = true
local form

local current_x_box
local current_y_box
local target_x_box
local target_y_box

local click_type_box
local lead_box
local hold_box

local remember_box

local click_nudge_box
local click_nudge_x_box
local click_nudge_y_box


local function status(msg)
	console.log(msg)
end


local function read_integer(handle)
	local v = tonumber(forms.gettext(handle))

	if not v or v ~= math.floor(v) then
		return nil
	end

	return v
end


local function read_nonnegative_integer(handle, name, minimum)
	local v = read_integer(handle)

	if v == nil or v < minimum then
		return nil, name .. " must be an integer >= " .. minimum
	end

	return v
end


local function round_nearest(v)
	if v >= 0 then
		return math.floor(v + 0.5)
	else
		return math.ceil(v - 0.5)
	end
end


local function first_selected_frame()
	local selection = tastudio.getselection()

	if not selection then
		return nil
	end

	local first = nil

	for _, frame in pairs(selection) do
		if type(frame) == "number" and (first == nil or frame < first) then
			first = frame
		end
	end

	return first
end


local function axis_from_input(input, exact_name, neutral)
	if not input then
		return neutral
	end

	local value = input[exact_name]

	if value == nil then
		return neutral
	end

	local n = tonumber(value)

	if n == nil then
		return neutral
	end

	return math.floor(n + 0.5)
end


local function get_start_axis_position(move_frame)
	if move_frame <= 0 then
		return X_NEUTRAL, Y_NEUTRAL
	end

	local ok, input = pcall(function() return movie.getinput(move_frame - 1) end)

	if not ok or not input then
		return X_NEUTRAL, Y_NEUTRAL
	end

	return
		axis_from_input(input, MOUSE_X, X_NEUTRAL),
		axis_from_input(input, MOUSE_Y, Y_NEUTRAL)
end


local function get_video_size()
	local ok_w, w = pcall(function() return client.bufferwidth() end)
	local ok_h, h = pcall(function() return client.bufferheight() end)

	if not ok_w or not ok_h then
		return nil, nil
	end

	w = tonumber(w)
	h = tonumber(h)

	if not w or not h or w <= 0 or h <= 0 then
		return nil, nil
	end

	return math.floor(w + 0.5), math.floor(h + 0.5)
end


local function cursor_delta_to_mickeys(cur_x, cur_y, target_x, target_y, video_w, video_h)
	local dx = round_nearest(
		(target_x - cur_x) * video_w / (X_MAX - X_MIN)
	)

	local dy = round_nearest(
		(target_y - cur_y) * video_h / (Y_MAX - Y_MIN)
	)

	return dx, dy
end


local function plan_axis_frame(pos, remaining, minv, maxv)
	if remaining == 0 then
		return pos, 0, 0
	end

	local dir = remaining > 0 and 1 or -1
	local amount = math.abs(remaining)
	local room = dir > 0 and (maxv - pos) or (pos - minv)

	local position_amount = math.min(amount, MAX_POSITION_DELTA, room)
	local explicit_amount = math.min(amount, MAX_EXPLICIT_SPEED)

	if position_amount >= explicit_amount and position_amount > 0 then
		local moved = dir * position_amount
		return pos + moved, 0, moved
	end

	local moved = dir * explicit_amount
	local rearmed_pos = dir > 0 and minv or maxv

	return rearmed_pos, moved, moved
end


local function build_relative_path(start_axis_x, start_axis_y, dx, dy)
	local path = {}

	local axis_x = start_axis_x
	local axis_y = start_axis_y

	local rem_x = dx
	local rem_y = dy

	while rem_x ~= 0 or rem_y ~= 0 do
		local new_x, speed_x, moved_x =
			plan_axis_frame(axis_x, rem_x, X_MIN, X_MAX)

		local new_y, speed_y, moved_y =
			plan_axis_frame(axis_y, rem_y, Y_MIN, Y_MAX)

		path[#path + 1] = {
			x = new_x,
			y = new_y,

			speed_x = speed_x,
			speed_y = speed_y,

			moved_x = moved_x,
			moved_y = moved_y,
		}

		axis_x = new_x
		axis_y = new_y

		rem_x = rem_x - moved_x
		rem_y = rem_y - moved_y

		if #path > 64 then
			error("mouse path unexpectedly exceeded 64 frames")
		end
	end

	return path, axis_x, axis_y
end


local function write_mouse_frame(frame, x, y, speed_x, speed_y, click_button, pressed)
	tastudio.submitanalogchange(frame, MOUSE_X, x)
	tastudio.submitanalogchange(frame, MOUSE_Y, y)
	tastudio.submitanalogchange(frame, MOUSE_DX, speed_x)
	tastudio.submitanalogchange(frame, MOUSE_DY, speed_y)

	tastudio.submitinputchange(
		frame,
		MOUSE_LEFT,
		pressed and click_button == MOUSE_LEFT
	)

	tastudio.submitinputchange(
		frame,
		MOUSE_MIDDLE,
		pressed and click_button == MOUSE_MIDDLE
	)

	tastudio.submitinputchange(
		frame,
		MOUSE_RIGHT,
		pressed and click_button == MOUSE_RIGHT
	)
end


local function write_cleanup(frame, axis_x, axis_y)
	local sx = 0
	local sy = 0

	local stage_x = X_NEUTRAL
	local stage_y = Y_NEUTRAL

	if axis_x ~= X_NEUTRAL then
		sx = axis_x < X_NEUTRAL and 1 or -1
		stage_x = X_NEUTRAL + sx
	end

	if axis_y ~= Y_NEUTRAL then
		sy = axis_y < Y_NEUTRAL and 1 or -1
		stage_y = Y_NEUTRAL + sy
	end

	write_mouse_frame(frame, stage_x, stage_y, sx, sy, nil, false)
	write_mouse_frame(frame + 1, X_NEUTRAL, Y_NEUTRAL, 0, 0, nil, false)
end


local function validate_cursor_coord(x, y, label)
	if x == nil or y == nil then
		return false, label .. " X and Y must both be integers"
	end

	if x < X_MIN or x > X_MAX then
		return false, string.format(
			"%s X must be %d..%d",
			label,
			X_MIN,
			X_MAX
		)
	end

	if y < Y_MIN or y > Y_MAX then
		return false, string.format(
			"%s Y must be %d..%d",
			label,
			Y_MIN,
			Y_MAX
		)
	end

	return true
end


local function fit_click_nudge(pos, requested, minv, maxv, press_speed, press_moved)
	if requested == 0 then
		return 0
	end

	local function fits(n)
		if pos + n < minv or pos + n > maxv then
			return false
		end

		if press_speed ~= 0 then
			if math.abs(press_speed + n) > MAX_EXPLICIT_SPEED then
				return false
			end
		else
			if math.abs(press_moved + n) > MAX_POSITION_DELTA then
				return false
			end
		end

		return true
	end

	if fits(requested) then
		return requested
	end

	if fits(-requested) then
		return -requested
	end

	return nil
end


local function apply_mouse_input()
	if not tastudio or not tastudio.engaged or not tastudio.engaged() then
		status("TAStudio is not active.")
		return
	end

	local move_frame = first_selected_frame()

	if move_frame == nil then
		status("Select a frame in TAStudio first.")
		return
	end

	local cur_x = read_integer(current_x_box)
	local cur_y = read_integer(current_y_box)

	local target_x = read_integer(target_x_box)
	local target_y = read_integer(target_y_box)

	local valid, why = validate_cursor_coord(cur_x, cur_y, "Current cursor")

	if not valid then
		status(why)
		return
	end

	valid, why = validate_cursor_coord(target_x, target_y, "Target cursor")

	if not valid then
		status(why)
		return
	end

	local click_type = forms.gettext(click_type_box)
	local click_button = CLICK_BUTTONS[click_type]
	local do_click = click_type ~= "None"

	if do_click and click_button == nil then
		status("Invalid click type.")
		return
	end

	local lead = 0
	local hold = 1
	local err

	if do_click then
		lead, err = read_nonnegative_integer(lead_box, "Click delay", 0)

		if lead == nil then
			status(err)
			return
		end

		hold, err = read_nonnegative_integer(hold_box, "Hold", 1)

		if hold == nil then
			status(err)
			return
		end
	end

	local use_click_nudge = do_click and forms.ischecked(click_nudge_box)

	local requested_nudge_x = 0
	local requested_nudge_y = 0

	if use_click_nudge then
		requested_nudge_x = read_integer(click_nudge_x_box)
		requested_nudge_y = read_integer(click_nudge_y_box)

		if requested_nudge_x == nil or requested_nudge_y == nil then
			status("Click nudge X and Y must be signed integers.")
			return
		end

		if requested_nudge_x == 0 and requested_nudge_y == 0 then
			status(
				"Click nudge cannot be 0,0 while " ..
				"'Nudge mouse on click frame' is enabled."
			)
			return
		end

		if math.abs(requested_nudge_x) > MAX_POSITION_DELTA
			or math.abs(requested_nudge_y) > MAX_POSITION_DELTA
		then
			status(string.format(
				"Click nudge must stay within +/-%d per axis.",
				MAX_POSITION_DELTA
			))
			return
		end
	end

	local video_w, video_h = get_video_size()

	if not video_w or not video_h then
		status(
			"Could not determine the core video resolution " ..
			"(client.bufferwidth/height)."
		)
		return
	end

	local dx, dy = cursor_delta_to_mickeys(
		cur_x,
		cur_y,
		target_x,
		target_y,
		video_w,
		video_h
	)

	local recording_was_on = false

	if tastudio.getrecording and tastudio.setrecording then
		local ok_recording, is_recording =
			pcall(function() return tastudio.getrecording() end)

		if ok_recording and is_recording then
			local ok_disable, disable_error =
				pcall(function() tastudio.setrecording(false) end)

			if not ok_disable then
				status(
					"Could not turn off TAStudio Recording Mode: " ..
					tostring(disable_error)
				)
				return
			end

			recording_was_on = true
		end
	end

	local start_axis_x, start_axis_y = get_start_axis_position(move_frame)

	local path, final_axis_x, final_axis_y =
		build_relative_path(start_axis_x, start_axis_y, dx, dy)

	local arrival_frame = move_frame

	if #path > 0 then
		arrival_frame = move_frame + #path - 1
	end

	local press_frame = nil
	local release_frame = nil

	if do_click then
		press_frame = arrival_frame + lead
		release_frame = press_frame + hold
	end

	local applied_nudge_x = 0
	local applied_nudge_y = 0

	local ok

	ok, why = pcall(function()
		tastudio.clearinputchanges()

		local nudge_x = 0
		local nudge_y = 0

		if use_click_nudge then
			local press_speed_x = 0
			local press_speed_y = 0

			local press_moved_x = 0
			local press_moved_y = 0

			if #path > 0 and press_frame == arrival_frame then
				press_speed_x = path[#path].speed_x
				press_speed_y = path[#path].speed_y

				press_moved_x = path[#path].moved_x
				press_moved_y = path[#path].moved_y
			end

			nudge_x = fit_click_nudge(
				final_axis_x,
				requested_nudge_x,
				X_MIN,
				X_MAX,
				press_speed_x,
				press_moved_x
			)

			nudge_y = fit_click_nudge(
				final_axis_y,
				requested_nudge_y,
				Y_MIN,
				Y_MAX,
				press_speed_y,
				press_moved_y
			)

			if nudge_x == nil
				or nudge_y == nil
				or (nudge_x == 0 and nudge_y == 0)
			then
				error(
					"Could not fit the requested click nudge " ..
					"on the press frame"
				)
			end

			applied_nudge_x = nudge_x
			applied_nudge_y = nudge_y
		end

		for i, point in ipairs(path) do
			local frame = move_frame + i - 1
			local pressed =
				do_click
				and frame >= press_frame
				and frame < release_frame

			local x = point.x
			local y = point.y

			local speed_x = point.speed_x
			local speed_y = point.speed_y

			if use_click_nudge and pressed then
				x = x + nudge_x
				y = y + nudge_y

				if speed_x ~= 0 then
					speed_x = speed_x + nudge_x
				end

				if speed_y ~= 0 then
					speed_y = speed_y + nudge_y
				end
			end

			write_mouse_frame(
				frame,
				x,
				y,
				speed_x,
				speed_y,
				click_button,
				pressed
			)
		end

		if do_click then
			local first_stationary =
				(#path == 0) and move_frame or (arrival_frame + 1)

			for frame = first_stationary, release_frame do
				local pressed =
					frame >= press_frame
					and frame < release_frame

				local x = final_axis_x
				local y = final_axis_y

				if use_click_nudge and pressed then
					x = final_axis_x + nudge_x
					y = final_axis_y + nudge_y
				end

				write_mouse_frame(
					frame,
					x,
					y,
					0,
					0,
					click_button,
					pressed
				)
			end
		end

		if final_axis_x ~= X_NEUTRAL or final_axis_y ~= Y_NEUTRAL then
			local cleanup_frame

			if do_click then
				cleanup_frame = release_frame + 1
			else
				cleanup_frame = arrival_frame + 1
			end

			write_cleanup(cleanup_frame, final_axis_x, final_axis_y)
		end

		tastudio.applyinputchanges()
	end)

	if not ok then
		pcall(function() tastudio.clearinputchanges() end)

		status("TAStudio edit failed: " .. tostring(why))
		return
	end

	if forms.ischecked(remember_box) then
		forms.settext(current_x_box, tostring(target_x))
		forms.settext(current_y_box, tostring(target_y))
	end

	local recording_text =
		recording_was_on
		and "; Recording Mode OFF"
		or ""

	local nudge_text = ""

	if applied_nudge_x ~= 0 or applied_nudge_y ~= 0 then
		nudge_text = string.format(
			"; click nudge %+d,%+d",
			applied_nudge_x,
			applied_nudge_y
		)
	end

	if do_click then
		status(string.format(
			"Cursor (%d,%d) -> (%d,%d), " ..
			"video %dx%d: move %d,%d mickeys " ..
			"in %d frame(s); %s click %d, " ..
			"release %d%s%s",
			cur_x,
			cur_y,
			target_x,
			target_y,
			video_w,
			video_h,
			dx,
			dy,
			#path,
			click_type,
			press_frame,
			release_frame,
			recording_text,
			nudge_text
		))
	else
		status(string.format(
			"Cursor (%d,%d) -> (%d,%d), " ..
			"video %dx%d: move %d,%d mickeys " ..
			"in %d frame(s); no click%s",
			cur_x,
			cur_y,
			target_x,
			target_y,
			video_w,
			video_h,
			dx,
			dy,
			#path,
			recording_text
		))
	end
end


form = forms.newform(
	430,
	275,
	"TAStudio DOS mouse helper",
	function() alive = false end
)

forms.label(form, "Assumes DOSBox-X Mouse Relative Sensitivity = 1.0.", 10, 12, 400, 20)
forms.label(form, "(Use coordinates from View > Display Input, Recording mode has to be on for that)", 10, 40, 400, 20)

forms.label(form, "Current cursor:", 10, 72, 100, 20)
forms.label(form, "X:", 110, 72, 20, 20)
current_x_box = forms.textbox(form, "", 70, 22, nil, 130, 69)

forms.label(form, "Y:", 210, 72, 20, 20)
current_y_box = forms.textbox(form, "", 70, 22, nil, 230, 69)

forms.label(form, "Target cursor:", 10, 105, 100, 20)
forms.label(form, "X:", 110, 105, 20, 20)
target_x_box = forms.textbox(form, "", 70, 22, nil, 130, 102)

forms.label(form, "Y:", 210, 105, 20, 20)
target_y_box = forms.textbox(form, "", 70, 22, nil, 230, 102)

forms.label(form, "Button:", 10, 139, 50, 20)

local click_types = { "None", "LMB", "MMB", "RMB" }

click_type_box = forms.dropdown(form, click_types, 65, 136, 70, 22)
forms.setdropdownitems(click_type_box, click_types, false)

forms.label(form, "Click delay:", 155, 139, 75, 20)
lead_box = forms.textbox(form, "0", 45, 22, "UNSIGNED", 230, 136)

forms.label(form, "Hold:", 290, 139, 40, 20)
hold_box = forms.textbox(form, "1", 45, 22, "UNSIGNED", 330, 136)

remember_box = forms.checkbox(
	form,
	"Use target as current for next operation",
	10,
	165
)

forms.setproperty(remember_box, "Checked", false)
forms.setproperty(remember_box, "Width", 280)

click_nudge_box = forms.checkbox(form, "Nudge mouse on click frame", 10, 190)

forms.setproperty(click_nudge_box, "Checked", true)
forms.setproperty(click_nudge_box, "Width", 180)

forms.label(form, "Nudge", 205, 190, 45, 20)
forms.label(form, "X:", 250, 190, 20, 20)

click_nudge_x_box = forms.textbox(form, "0", 55, 22, nil, 270, 186)

forms.label(form, "Y:", 335, 190, 20, 20)

click_nudge_y_box = forms.textbox(form, "1", 55, 22, nil, 355, 186)

forms.button(form, "Apply mouse input", apply_mouse_input, 10, 220, 155, 30)


event.onexit(
	function()
		if form then
			pcall(function() forms.destroy(form) end)
		end
	end,
	"TAStudio DOS mouse helper cleanup"
)


while alive do
	emu.yield()
end
