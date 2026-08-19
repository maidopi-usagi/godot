extends Node3D

## Phase 0 manual QA harness for HDDAGI screen probes.
##
## Measurements are computed over a cropped full-frame ROI and multiple rendered
## frames. They are stability/regression signals, not radiometric ground truth.

const SCHEMA_VERSION := "1.0.0"
const PHASE0_SUITE_NAME := "hddagi_screen_probe_phase0"
const PHASE1_SUITE_NAME := "hddagi_screen_probe_phase1_fresh_reference"
const PHASE2_SUITE_NAME := "hddagi_screen_probe_phase2_temporal_restir"
const DEFAULT_OUTPUT := "user://hddagi_screen_probe_qa.json"
const CAMERA_TARGET := Vector3(0.0, 1.0, -1.2)
const CAMERA_HOME := Vector3(0.0, 2.25, 6.4)

const SETTING_TEMPORAL := "rendering/global_illumination/hddagi/screen_probe_restir_temporal_guiding"
const SETTING_SPATIAL := "rendering/global_illumination/hddagi/screen_probe_restir_spatial_guiding"
const SETTING_CANDIDATES := "rendering/global_illumination/hddagi/screen_probe_restir_base_candidate_count"
const SETTING_REFERENCE_MODE := "rendering/global_illumination/hddagi/screen_probe_reference_mode"
const SETTING_DEBUG_COUNTERS := "rendering/global_illumination/hddagi/screen_probe_debug_counters"
const SETTING_DEBUG_COUNTER_TAG := "rendering/global_illumination/hddagi/screen_probe_debug_counter_tag"
const SETTING_TEMPORAL_ROBUST := "rendering/global_illumination/hddagi/screen_probe_restir_temporal_robust_mode"
const SETTING_TEMPORAL_M_CAP_MULTIPLIER := "rendering/global_illumination/hddagi/screen_probe_restir_temporal_m_cap_multiplier"
const SETTING_TEMPORAL_MAXIMUM_AGE := "rendering/global_illumination/hddagi/screen_probe_restir_temporal_maximum_age"
const SETTING_TEMPORAL_JACOBIAN_MAX := "rendering/global_illumination/hddagi/screen_probe_restir_temporal_jacobian_max"
const PHASE2_M_CAP_MULTIPLIER := 20
const PHASE2_MAXIMUM_AGE := 255
const PHASE2_JACOBIAN_MAX := 20.0
const PHASE2_ROBUST_TEST_JACOBIAN_MAX := 1.0
const PHASE2_AGE_REJECTION_TEST_MAXIMUM := 2
const PHASE2_DYNAMIC_TRANSITION_FRAMES := 128
const PHASE2_STABLE_NOISE_FRAMES := 32
const DEBUG_COUNTER_MARKER := "HDDAGI_SCREEN_PROBE_COUNTERS "
const DEBUG_COUNTER_REQUIRED_FIELDS := [
	"frame",
	"debug_counter_tag",
	"view_count",
	"width",
	"height",
	"feature_flags",
	"algorithm_mode",
	"algorithm",
	"fresh_candidates",
	"temporal_guided_candidates",
	"spatial_guided_candidates",
	"hdda_rays",
	"hdda_steps",
	"hdda_hits",
	"hdda_misses",
	"sharc_query_attempts",
	"sharc_query_hits",
	"sharc_query_ineligible",
	"sharc_query_misses",
	"sharc_update_rays",
	"sharc_update_misses",
	"sharc_update_rejects",
	"raw_hdr_sample_count",
	"raw_hdr_fixed_sum_r",
	"raw_hdr_fixed_sum_g",
	"raw_hdr_fixed_sum_b",
	"raw_hdr_nonfinite_or_overflow",
	"raw_hdr_accumulated_frame_count",
	"raw_hdr_fixed_scale",
	"raw_hdr_lattice_stride",
	"raw_hdr_lattice_period",
	"raw_hdr_lattice_phase_mask_words",
	"raw_hdr_lattice_phase_coverage_count",
]
const PHASE2_COUNTER_REQUIRED_FIELDS := [
	"history_valid",
	"history_reset",
	"camera_cut",
	"taa_jitter_nonzero",
	"history_generation",
	"history_sequence",
	"reservoir_valid_surfaces",
	"reservoir_fresh_valid",
	"reservoir_fresh_invalid",
	"reservoir_temporal_attempts",
	"reservoir_temporal_accepted",
	"reservoir_reject_no_history",
	"reservoir_reject_reprojection_or_owner",
	"reservoir_reject_generation_or_algorithm",
	"reservoir_reject_endpoint_identity_or_version",
	"reservoir_reject_visibility",
	"reservoir_reject_jacobian",
	"reservoir_reject_age",
	"reservoir_visibility_rays",
	"reservoir_visibility_visible",
	"reservoir_visibility_occluded",
	"reservoir_m_cap_applied",
	"reservoir_selected_fresh",
	"reservoir_selected_history",
	"reservoir_final_valid",
	"reservoir_final_invalid",
	"reservoir_nonfinite",
	"reservoir_robust_jacobian_clamp",
	"reservoir_max_m",
	"reservoir_max_age",
	"reservoir_sum_m",
	"reservoir_packing_invalid",
	"reservoir_hit_reuse",
	"reservoir_sky_reuse",
	"reservoir_robust_flag_final_fresh",
	"reservoir_robust_flag_final_history",
	"reservoir_zero_target_mass_only",
	"reservoir_gpu_zero_target_branch_golden",
]

var _environment: Environment
var _world_environment: WorldEnvironment
var _camera: Camera3D
var _phase1_plane: MeshInstance3D
var _saved_settings: Dictionary = {}
var _options := {
	"scenario": "all",
	"output": DEFAULT_OUTPUT,
	"warmup_frames": 32,
	"sample_frames": 12,
	"settle_frames": 24,
	"sample_stride": 2,
	"roi_border_fraction": 0.08,
	"counter_log": "",
	"gpu_profile_enabled": false,
	"phase1_long_frames": 1000,
	"phase2_long_frames": 1000,
}
var _result: Dictionary = {}
var _errors: Array[String] = []
var _warnings: Array[String] = []
var _memory_snapshots: Array[Dictionary] = []
var _debug_counter_tag := 0


func _ready() -> void:
	_parse_options()
	_build_scene()
	_save_feature_settings()
	call_deferred("_run_suite")


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_restore_feature_settings()


func _parse_options() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--scenario="):
			_options.scenario = argument.trim_prefix("--scenario=")
		elif argument.begins_with("--output="):
			_options.output = argument.trim_prefix("--output=")
		elif argument.begins_with("--warmup="):
			_options.warmup_frames = maxi(1, argument.trim_prefix("--warmup=").to_int())
		elif argument.begins_with("--frames="):
			_options.sample_frames = maxi(2, argument.trim_prefix("--frames=").to_int())
		elif argument.begins_with("--settle="):
			_options.settle_frames = maxi(2, argument.trim_prefix("--settle=").to_int())
		elif argument.begins_with("--sample-stride="):
			_options.sample_stride = clampi(argument.trim_prefix("--sample-stride=").to_int(), 1, 8)
		elif argument.begins_with("--roi-border="):
			_options.roi_border_fraction = clampf(
					argument.trim_prefix("--roi-border=").to_float(), 0.0, 0.4
			)
		elif argument.begins_with("--counter-log="):
			_options.counter_log = argument.trim_prefix("--counter-log=")
		elif argument == "--gpu-profile-enabled":
			_options.gpu_profile_enabled = true
		elif argument.begins_with("--phase1-long-frames="):
			_options.phase1_long_frames = maxi(32, argument.trim_prefix("--phase1-long-frames=").to_int())
		elif argument.begins_with("--phase2-long-frames="):
			_options.phase2_long_frames = maxi(32, argument.trim_prefix("--phase2-long-frames=").to_int())


func _build_scene() -> void:
	_environment = Environment.new()
	_environment.background_mode = Environment.BG_COLOR
	_environment.background_color = Color(0.018, 0.022, 0.032)
	_environment.background_energy_multiplier = 1.0
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_environment.ambient_light_color = Color(0.055, 0.065, 0.085)
	_environment.ambient_light_energy = 0.35
	_environment.ambient_light_sky_contribution = 0.0
	_environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_environment.tonemap_exposure = 1.0
	_environment.dynamic_gi_enabled = true
	_environment.dynamic_gi_cascades = 3
	_environment.dynamic_gi_min_cell_size = 0.25
	_environment.dynamic_gi_max_distance = 64.0
	_environment.dynamic_gi_read_sky_light = false
	_environment.dynamic_gi_energy = 1.0
	_environment.dynamic_gi_screen_probes_enabled = true
	_environment.dynamic_gi_screen_probe_size = 8

	_world_environment = WorldEnvironment.new()
	_world_environment.environment = _environment
	add_child(_world_environment)

	_add_box("Floor", Vector3(14.0, 0.2, 14.0), Vector3(0.0, -0.1, -0.5), Color(0.64, 0.64, 0.62))
	_add_box("BackWall", Vector3(14.0, 6.0, 0.2), Vector3(0.0, 3.0, -5.5), Color(0.62, 0.63, 0.66))
	_add_box("LeftWall", Vector3(0.2, 6.0, 14.0), Vector3(-6.0, 3.0, -0.5), Color(0.52, 0.13, 0.10))
	_add_box("RightWall", Vector3(0.2, 6.0, 14.0), Vector3(6.0, 3.0, -0.5), Color(0.10, 0.22, 0.50))
	_add_box("CenterBlock", Vector3(1.8, 1.8, 1.8), Vector3(-1.35, 0.9, -1.4), Color(0.58, 0.56, 0.48))
	_add_box("TallBlock", Vector3(1.4, 2.8, 1.4), Vector3(1.45, 1.4, -2.35), Color(0.22, 0.52, 0.28))
	_add_box("Occluder", Vector3(0.45, 2.2, 3.0), Vector3(0.15, 1.1, 0.0), Color(0.38, 0.38, 0.42))
	_add_emissive_panel()

	var key_light := DirectionalLight3D.new()
	key_light.name = "KeyLight"
	key_light.rotation_degrees = Vector3(-52.0, -32.0, 0.0)
	key_light.light_energy = 0.7
	key_light.light_indirect_energy = 1.0
	key_light.shadow_enabled = true
	add_child(key_light)

	var fill_light := OmniLight3D.new()
	fill_light.name = "IndirectFill"
	fill_light.position = Vector3(-3.4, 3.6, -2.8)
	fill_light.omni_range = 5.5
	fill_light.light_color = Color(1.0, 0.56, 0.28)
	fill_light.light_energy = 5.0
	fill_light.light_indirect_energy = 2.0
	fill_light.shadow_enabled = true
	add_child(fill_light)

	_camera = Camera3D.new()
	_camera.name = "QACamera"
	_camera.position = CAMERA_HOME
	_camera.fov = 64.0
	_camera.near = 0.1
	_camera.far = 80.0
	_camera.current = true
	add_child(_camera)
	_aim_camera()


func _add_box(node_name: String, size: Vector3, position: Vector3, color: Color) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.88
	material.metallic = 0.0
	mesh.material = material

	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.position = position
	instance.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	add_child(instance)


func _add_emissive_panel() -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(2.4, 1.0, 0.12)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.9, 0.32, 0.08)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.18, 0.035)
	material.emission_energy_multiplier = 4.0
	material.roughness = 0.8
	mesh.material = material

	var panel := MeshInstance3D.new()
	panel.name = "EmissivePanel"
	panel.mesh = mesh
	panel.position = Vector3(-2.6, 2.5, -5.32)
	panel.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	add_child(panel)


func _save_feature_settings() -> void:
	for setting_name in [
		SETTING_TEMPORAL,
		SETTING_SPATIAL,
		SETTING_CANDIDATES,
		SETTING_REFERENCE_MODE,
		SETTING_DEBUG_COUNTERS,
		SETTING_DEBUG_COUNTER_TAG,
		SETTING_TEMPORAL_ROBUST,
		SETTING_TEMPORAL_M_CAP_MULTIPLIER,
		SETTING_TEMPORAL_MAXIMUM_AGE,
		SETTING_TEMPORAL_JACOBIAN_MAX,
	]:
		_saved_settings[setting_name] = ProjectSettings.get_setting(setting_name)


func _restore_feature_settings() -> void:
	for setting_name in _saved_settings:
		ProjectSettings.set_setting(setting_name, _saved_settings[setting_name])


func _set_experimental_features(enabled: bool) -> void:
	ProjectSettings.set_setting(SETTING_REFERENCE_MODE, false)
	ProjectSettings.set_setting(SETTING_TEMPORAL, enabled)
	ProjectSettings.set_setting(SETTING_SPATIAL, enabled)
	ProjectSettings.set_setting(SETTING_CANDIDATES, 2 if enabled else 1)


func _current_feature_state() -> Dictionary:
	return {
		"screen_probes": _environment.dynamic_gi_screen_probes_enabled,
		"temporal_guiding": bool(ProjectSettings.get_setting(SETTING_TEMPORAL, false)),
		"spatial_guiding": bool(ProjectSettings.get_setting(SETTING_SPATIAL, false)),
		"candidate_count": int(ProjectSettings.get_setting(SETTING_CANDIDATES, 1)),
		"reference_mode": bool(ProjectSettings.get_setting(SETTING_REFERENCE_MODE, false)),
		"temporal_robust_mode": bool(ProjectSettings.get_setting(SETTING_TEMPORAL_ROBUST, false)),
		"temporal_m_cap_multiplier": int(ProjectSettings.get_setting(SETTING_TEMPORAL_M_CAP_MULTIPLIER, 0)),
		"temporal_maximum_age": int(ProjectSettings.get_setting(SETTING_TEMPORAL_MAXIMUM_AGE, 0)),
		"temporal_jacobian_max": float(ProjectSettings.get_setting(SETTING_TEMPORAL_JACOBIAN_MAX, 0.0)),
	}


func _feature_state_matches(state: Dictionary, probes: bool, experimental: bool) -> bool:
	return (
			state.screen_probes == probes
			and state.temporal_guiding == experimental
			and state.spatial_guiding == experimental
			and state.candidate_count == (2 if experimental else 1)
			and state.reference_mode == false
	)


func _phase1_settings_exist() -> bool:
	var required_settings := [
		SETTING_TEMPORAL,
		SETTING_SPATIAL,
		SETTING_CANDIDATES,
		SETTING_REFERENCE_MODE,
	]
	var all_exist := true
	for setting_name in required_settings:
		if not ProjectSettings.has_setting(setting_name):
			var message := "Phase 1 required ProjectSetting is missing: %s" % setting_name
			if not _errors.has(message):
				_errors.append(message)
			all_exist = false
	return all_exist


func _set_phase1_fresh_only(candidate_count: int) -> bool:
	if not _phase1_settings_exist():
		return false
	ProjectSettings.set_setting(SETTING_REFERENCE_MODE, true)
	ProjectSettings.set_setting(SETTING_TEMPORAL, false)
	ProjectSettings.set_setting(SETTING_SPATIAL, false)
	ProjectSettings.set_setting(SETTING_CANDIDATES, candidate_count)
	var state := _current_feature_state()
	return (
			state.reference_mode == true
			and state.temporal_guiding == false
			and state.spatial_guiding == false
			and state.candidate_count == candidate_count
	)


func _phase2_settings_exist() -> bool:
	var required_settings := [
		SETTING_TEMPORAL,
		SETTING_SPATIAL,
		SETTING_CANDIDATES,
		SETTING_REFERENCE_MODE,
		SETTING_TEMPORAL_ROBUST,
		SETTING_TEMPORAL_M_CAP_MULTIPLIER,
		SETTING_TEMPORAL_MAXIMUM_AGE,
		SETTING_TEMPORAL_JACOBIAN_MAX,
	]
	var all_exist := true
	for setting_name in required_settings:
		if not ProjectSettings.has_setting(setting_name):
			var message := "Phase 2 required ProjectSetting is missing: %s" % setting_name
			if not _errors.has(message):
				_errors.append(message)
			all_exist = false
	return all_exist


func _set_phase2_transport(
		temporal_enabled: bool,
		robust_enabled: bool = false,
		jacobian_max: float = PHASE2_JACOBIAN_MAX,
		maximum_age: int = PHASE2_MAXIMUM_AGE
) -> bool:
	if not _phase2_settings_exist():
		return false
	var candidate_count := 1 if temporal_enabled else 2
	ProjectSettings.set_setting(SETTING_REFERENCE_MODE, false)
	ProjectSettings.set_setting(SETTING_TEMPORAL, temporal_enabled)
	ProjectSettings.set_setting(SETTING_SPATIAL, false)
	ProjectSettings.set_setting(SETTING_CANDIDATES, candidate_count)
	ProjectSettings.set_setting(SETTING_TEMPORAL_ROBUST, robust_enabled)
	ProjectSettings.set_setting(SETTING_TEMPORAL_M_CAP_MULTIPLIER, PHASE2_M_CAP_MULTIPLIER)
	ProjectSettings.set_setting(SETTING_TEMPORAL_MAXIMUM_AGE, maximum_age)
	ProjectSettings.set_setting(SETTING_TEMPORAL_JACOBIAN_MAX, jacobian_max)
	var state := _current_feature_state()
	return (
			state.reference_mode == false
			and state.temporal_guiding == temporal_enabled
			and state.spatial_guiding == false
			and state.candidate_count == candidate_count
			and bool(ProjectSettings.get_setting(SETTING_TEMPORAL_ROBUST, not robust_enabled)) == robust_enabled
			and int(ProjectSettings.get_setting(SETTING_TEMPORAL_M_CAP_MULTIPLIER, -1)) == PHASE2_M_CAP_MULTIPLIER
			and int(ProjectSettings.get_setting(SETTING_TEMPORAL_MAXIMUM_AGE, -1)) == maximum_age
			and is_equal_approx(
					float(ProjectSettings.get_setting(SETTING_TEMPORAL_JACOBIAN_MAX, -1.0)),
					jacobian_max
			)
	)


func _phase2_configuration() -> Dictionary:
	return {
		"temporal_candidate_count": 1,
		"fresh_baseline_candidate_count": 2,
		"fixed_ray_budget_contract": "Phase 1 N=2 fresh rays versus Phase 2 N=1 fresh plus one accepted-history visibility ray",
		"robust_mode": false,
		"robust_coverage": true,
		"robust_test_jacobian_max": PHASE2_ROBUST_TEST_JACOBIAN_MAX,
		"age_rejection_coverage": true,
		"age_rejection_test_maximum": PHASE2_AGE_REJECTION_TEST_MAXIMUM,
		"m_cap_multiplier": PHASE2_M_CAP_MULTIPLIER,
		"effective_history_m_cap": PHASE2_M_CAP_MULTIPLIER,
		"maximum_output_m": PHASE2_M_CAP_MULTIPLIER + 1,
		"maximum_age": PHASE2_MAXIMUM_AGE,
		"jacobian_max_setting": PHASE2_JACOBIAN_MAX,
		"algorithm_mode": 3,
		"algorithm": "phase2_temporal_restir",
	}


func _run_suite() -> void:
	_result = _make_result_header()
	ProjectSettings.set_setting(SETTING_DEBUG_COUNTERS, true)
	_mark_segment("suite_boot")
	var scenario_names := _selected_scenarios()
	if scenario_names.is_empty():
		_errors.append("Unknown scenario '%s'. Expected all, baseline, motion, feature_off_toggle, phase1_fresh, or phase2_temporal." % _options.scenario)
	else:
		# Phase 1 must check that the renderer registered its stable reference-mode
		# setting before any test code could create an ad-hoc ProjectSetting.
		if _options.scenario == "phase2_temporal":
			_set_phase2_transport(false)
		elif _options.scenario != "phase1_fresh":
			_set_experimental_features(false)
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
		await _render_frames(4)
		_sample_memory("suite/after_boot")
		for scenario_name in scenario_names:
			print("HDDAGI QA: running %s" % scenario_name)
			match scenario_name:
				"baseline":
					_result.scenarios[scenario_name] = await _run_baseline()
				"motion":
					_result.scenarios[scenario_name] = await _run_motion()
				"feature_off_toggle":
					_result.scenarios[scenario_name] = await _run_feature_off_toggle()
				"phase1_fresh":
					_result.scenarios[scenario_name] = await _run_phase1_fresh()
				"phase2_temporal":
					_result.scenarios[scenario_name] = await _run_phase2_temporal()

	_restore_feature_settings()
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
	_result.debug_counters = _collect_debug_counters()
	_result.runtime_log = _collect_runtime_log_summary()
	if _result.runtime_log.error_count > 0:
		_errors.append(
				"Runtime log contains %d ERROR line(s); first observed in segment '%s'."
				% [_result.runtime_log.error_count, _result.runtime_log.first_error_segment]
		)
	_result.gpu_profile = _collect_gpu_profile()
	_result.memory = _make_memory_result()
	_validate_scenario_checks()
	_result.errors = _errors
	_result.warnings = _warnings
	_result.status = "failed" if not _errors.is_empty() else "completed"
	_result.completed_utc = Time.get_datetime_string_from_system(true, true)
	var wrote_result := _write_result()
	if not wrote_result:
		_result.status = "failed"
	get_tree().quit(1 if not _errors.is_empty() or not wrote_result else 0)


func _selected_scenarios() -> Array[String]:
	if _options.scenario == "all":
		return ["baseline", "motion", "feature_off_toggle"]
	if _options.scenario in ["baseline", "motion", "feature_off_toggle", "phase1_fresh", "phase2_temporal"]:
		return [_options.scenario]
	return []


func _validate_scenario_checks() -> void:
	for scenario_name in _result.scenarios:
		var scenario: Dictionary = _result.scenarios[scenario_name]
		if not scenario.has("checks"):
			_errors.append("Scenario '%s' did not report checks." % scenario_name)
			continue
		for check_name in scenario.checks:
			if scenario.checks[check_name] != true:
				_errors.append("Scenario check failed: %s.%s" % [scenario_name, check_name])


func _make_result_header() -> Dictionary:
	var viewport_size := get_viewport().get_visible_rect().size
	var engine_version := Engine.get_version_info()
	return {
		"schema_version": SCHEMA_VERSION,
		"suite": (
				PHASE1_SUITE_NAME
				if _options.scenario == "phase1_fresh"
				else PHASE2_SUITE_NAME if _options.scenario == "phase2_temporal" else PHASE0_SUITE_NAME
		),
		"status": "running",
		"started_utc": Time.get_datetime_string_from_system(true, true),
		"engine": {
			"version": engine_version.get("string", "unknown"),
			"hash": engine_version.get("hash", ""),
			"build": engine_version.get("build", ""),
		},
		"renderer": {
			"rendering_method": RenderingServer.get_current_rendering_method(),
			"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
			"adapter_name": RenderingServer.get_video_adapter_name(),
			"adapter_vendor": RenderingServer.get_video_adapter_vendor(),
			"api_version": RenderingServer.get_video_adapter_api_version(),
			"driver_info": OS.get_video_adapter_driver_info(),
		},
		"resolution": {
			"width": int(viewport_size.x),
			"height": int(viewport_size.y),
			"roi_border_fraction": _options.roi_border_fraction,
			"sample_stride": _options.sample_stride,
			"view_count": 1,
		},
		"frames": {
			"warmup": _options.warmup_frames,
			"sample": _options.sample_frames,
			"settle": _options.settle_frames,
			"phase1_long": _options.phase1_long_frames,
			"phase2_long": _options.phase2_long_frames,
		},
		"phase2_configuration": _phase2_configuration() if _options.scenario == "phase2_temporal" else {},
		"feature_defaults_at_start": _saved_settings.duplicate(true),
		"debug_counter_capture": {
			"enabled": true,
			"marker": DEBUG_COUNTER_MARKER.strip_edges(),
			"source_log": _options.counter_log,
		},
		"gpu_profile_capture": {
			"enabled": _options.gpu_profile_enabled,
			"source_log": _options.counter_log,
			"units": "milliseconds per profiled frame, as reported by --gpu-profile",
		},
		"metric_contract": {
			"signal": "post-tonemap display-referred RGB captured from the viewport",
			"spatial_scope": "cropped full-frame ROI sampled on a regular grid",
			"luminance": "Rec.709 coefficients applied to captured RGB",
			"ghost_metric": "proxy: excess full-ROI frame difference against a later stable frame, normalized by reference mean luminance",
			"ground_truth": false,
			"correctness_claim": "none; use for crash detection, state-isolation checks, and same-machine regression trends",
		},
		"scenarios": {},
		"errors": [],
		"warnings": [],
	}


func _set_phase1_reference_sky(shader_body: String) -> void:
	var sky_shader := Shader.new()
	sky_shader.code = "shader_type sky;\nvoid sky() { %s }\n" % shader_body
	var sky_material := ShaderMaterial.new()
	sky_material.shader = sky_shader
	var reference_sky := Sky.new()
	reference_sky.sky_material = sky_material
	_environment.sky = reference_sky


func _create_phase2_mutable_sky(initial_color: Vector3) -> ShaderMaterial:
	var sky_shader := Shader.new()
	sky_shader.code = (
			"shader_type sky;\n"
			+ "uniform vec3 qa_color = vec3(0.0);\n"
			+ "void sky() { COLOR = qa_color; }\n"
	)
	var sky_material := ShaderMaterial.new()
	sky_material.shader = sky_shader
	sky_material.set_shader_parameter("qa_color", initial_color)
	var mutable_sky := Sky.new()
	mutable_sky.sky_material = sky_material
	_environment.sky = mutable_sky
	return sky_material


func _configure_phase1_white_furnace() -> void:
	for child in get_children():
		if child is GeometryInstance3D or child is Light3D:
			child.visible = false

	_environment.background_mode = Environment.BG_SKY
	_set_phase1_reference_sky("COLOR = vec3(0.18);")
	_environment.background_energy_multiplier = 1.0
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_environment.ambient_light_color = Color.WHITE
	_environment.ambient_light_energy = 1.0
	_environment.ambient_light_sky_contribution = 1.0
	_environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_environment.tonemap_exposure = 1.0
	_environment.dynamic_gi_read_sky_light = true
	_environment.dynamic_gi_energy = 1.0

	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(80.0, 80.0)
	var plane_material := StandardMaterial3D.new()
	plane_material.albedo_color = Color.WHITE
	plane_material.roughness = 1.0
	plane_material.metallic = 0.0
	plane_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	plane_mesh.material = plane_material
	_phase1_plane = MeshInstance3D.new()
	_phase1_plane.name = "Phase1WhiteFurnacePlane"
	_phase1_plane.mesh = plane_mesh
	_phase1_plane.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	add_child(_phase1_plane)

	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 8.0
	_camera.position = Vector3(0.0, 5.0, 0.0)
	_camera.look_at(Vector3.ZERO, Vector3.FORWARD)


func _set_phase1_plane_transfer_reference(linear_color: Vector3) -> void:
	# With screen probes disabled the diffuse white plane has no indirect light and
	# is correctly black, so it cannot be used as an output-transfer reference.
	# Render the analytic linear result through an unshaded material instead. This
	# keeps the same viewport, exposure, tonemap, and display transfer while
	# remaining independent of the screen-probe apply path.
	var reference_shader := Shader.new()
	reference_shader.code = (
			"shader_type spatial;\n"
			+ "render_mode unshaded, cull_disabled;\n"
			+ "uniform vec3 reference_linear;\n"
			+ "void fragment() { ALBEDO = reference_linear; }\n"
	)
	var reference_material := ShaderMaterial.new()
	reference_material.shader = reference_shader
	reference_material.set_shader_parameter("reference_linear", linear_color)
	_phase1_plane.material_override = reference_material


func _restore_phase1_plane_target_material() -> void:
	_phase1_plane.material_override = null


func _phase1_maximum_rgb_relative_error(actual: Array, expected: Array) -> float:
	var maximum_error := 0.0
	for channel in range(3):
		maximum_error = maxf(
				maximum_error,
				absf(float(actual[channel]) - float(expected[channel]))
						/ maxf(absf(float(expected[channel])), 0.000001)
		)
	return maximum_error


func _capture_phase1_energy_case(
		energy: float, segment_suffix: String, warmup_frames: int, sample_frames: int
) -> Dictionary:
	var analytic_linear := Vector3(0.18, 0.18, 0.18) * energy
	_environment.dynamic_gi_energy = energy
	_set_phase1_plane_transfer_reference(analytic_linear)
	_environment.dynamic_gi_screen_probes_enabled = false
	_mark_segment("phase1_fresh/energy_%s_output_transfer_reference" % segment_suffix)
	await _render_frames(8)
	var output_transfer_reference := await _capture_stream_metrics(sample_frames, sample_frames)

	_restore_phase1_plane_target_material()
	_set_phase1_fresh_only(1)
	_environment.dynamic_gi_screen_probes_enabled = true
	_mark_segment("phase1_fresh/energy_%s_target" % segment_suffix)
	await _render_frames(warmup_frames)
	var target := await _capture_stream_metrics(sample_frames, sample_frames)
	_sample_memory("phase1_fresh/energy_%s_target" % segment_suffix)

	var reference_rgb: Array = output_transfer_reference.frame_mean_rgb
	var target_rgb: Array = target.frame_mean_rgb
	var maximum_rgb_relative_error := (
			_phase1_maximum_rgb_relative_error(target_rgb, reference_rgb) if energy > 0.0 else 0.0
	)
	return {
		"energy": energy,
		"segment_suffix": segment_suffix,
		"analytic_raw_D": [analytic_linear.x, analytic_linear.y, analytic_linear.z],
		"output_transfer_reference": output_transfer_reference,
		"target": target,
		"maximum_output_transfer_rgb_relative_error": maximum_rgb_relative_error,
		"zero_energy_target_maximum_rgb": maxf(target_rgb[0], maxf(target_rgb[1], target_rgb[2])),
	}


func _capture_phase1_exposure_case(
		exposure_multiplier: float, warmup_frames: int, sample_frames: int
) -> Dictionary:
	# Godot pre-exposes environment lighting before it reaches the material
	# pipeline. Render the corresponding analytic D through the unshaded transfer
	# reference, then require the screen-probe miss path to land in that same
	# CameraAttributes domain.
	var camera_attributes := CameraAttributesPractical.new()
	camera_attributes.exposure_multiplier = exposure_multiplier
	_world_environment.camera_attributes = camera_attributes
	var analytic_linear := Vector3(0.18, 0.18, 0.18) * exposure_multiplier

	_set_phase1_plane_transfer_reference(analytic_linear)
	_environment.dynamic_gi_screen_probes_enabled = false
	_mark_segment("phase1_fresh/exposure_2_output_transfer_reference")
	await _render_frames(16)
	var output_transfer_reference := await _capture_stream_metrics(sample_frames, sample_frames)

	_restore_phase1_plane_target_material()
	_set_phase1_fresh_only(1)
	_environment.dynamic_gi_screen_probes_enabled = true
	_mark_segment("phase1_fresh/exposure_2_target")
	await _render_frames(warmup_frames)
	var target := await _capture_stream_metrics(sample_frames, sample_frames)
	_sample_memory("phase1_fresh/exposure_2_target")

	var reference_rgb: Array = output_transfer_reference.frame_mean_rgb
	var target_rgb: Array = target.frame_mean_rgb
	var maximum_rgb_relative_error := _phase1_maximum_rgb_relative_error(target_rgb, reference_rgb)
	_world_environment.camera_attributes = null
	return {
		"exposure_multiplier": exposure_multiplier,
		"analytic_raw_D": [analytic_linear.x, analytic_linear.y, analytic_linear.z],
		"output_transfer_reference": output_transfer_reference,
		"target": target,
		"maximum_output_transfer_rgb_relative_error": maximum_rgb_relative_error,
	}


func _phase1_image_summary(image: Image) -> Dictionary:
	if image.is_empty():
		return {
			"width": 0,
			"height": 0,
			"mean_luma": 0.0,
			"mean_rgb": [0.0, 0.0, 0.0],
			"non_black": false,
			"finite": false,
		}
	var statistics := _measure_image(image)
	var finite := not is_nan(statistics.mean_luma) and not is_inf(statistics.mean_luma)
	for channel in statistics.mean_rgb:
		finite = finite and not is_nan(channel) and not is_inf(channel)
	return {
		"width": image.get_width(),
		"height": image.get_height(),
		"mean_luma": statistics.mean_luma,
		"mean_rgb": statistics.mean_rgb,
		"non_black": statistics.mean_luma > 0.001,
		"finite": finite,
	}


func _run_phase1_lifecycle_checks() -> Dictionary:
	_mark_segment("phase1_fresh/lifecycle_camera_cut")
	_camera.position = Vector3(3.5, 4.5, 3.5)
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	var cut_image := await _capture_frame()
	var cut_summary := _phase1_image_summary(cut_image)
	_camera.position = Vector3(0.0, 5.0, 0.0)
	_camera.look_at(Vector3.ZERO, Vector3.FORWARD)

	# RenderSceneBuffersRD::configure() clears named textures even when the
	# dimensions stay unchanged. Establish temporal state, force such a
	# reconfiguration through FXAA, then verify that the first production frame is
	# still a valid NRD/raw output.
	ProjectSettings.set_setting(SETTING_REFERENCE_MODE, false)
	_set_experimental_features(false)
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
	_mark_segment("phase1_fresh/lifecycle_same_size_reconfigure_history_setup")
	await _render_frames(4)
	var original_screen_space_aa: Viewport.ScreenSpaceAA = get_viewport().screen_space_aa
	var reconfigured_screen_space_aa := (
			Viewport.SCREEN_SPACE_AA_FXAA
			if original_screen_space_aa == Viewport.SCREEN_SPACE_AA_DISABLED
			else Viewport.SCREEN_SPACE_AA_DISABLED
	)
	get_viewport().screen_space_aa = reconfigured_screen_space_aa
	_mark_segment("phase1_fresh/lifecycle_same_size_reconfigure_first_frame")
	var same_size_reconfigure_image := await _capture_frame()
	var same_size_reconfigure_summary := _phase1_image_summary(same_size_reconfigure_image)
	var same_size_reconfigure_valid: bool = (
			same_size_reconfigure_summary.finite and same_size_reconfigure_summary.non_black
	)
	get_viewport().screen_space_aa = original_screen_space_aa

	# Exposure is part of the transport domain, so changing CameraAttributes must
	# keep the first frame in a finite, non-empty output domain.
	_mark_segment("phase1_fresh/lifecycle_exposure_history_setup")
	await _render_frames(4)
	var lifecycle_camera_attributes := CameraAttributesPractical.new()
	lifecycle_camera_attributes.exposure_multiplier = 1.75
	_world_environment.camera_attributes = lifecycle_camera_attributes
	_mark_segment("phase1_fresh/lifecycle_exposure_first_frame")
	var exposure_first_frame_image := await _capture_frame()
	var exposure_first_frame_summary := _phase1_image_summary(exposure_first_frame_image)
	var exposure_change_valid: bool = (
			exposure_first_frame_summary.finite and exposure_first_frame_summary.non_black
	)
	_world_environment.camera_attributes = null
	ProjectSettings.set_setting(SETTING_REFERENCE_MODE, true)
	await _render_frames(2)

	var subviewport := SubViewport.new()
	subviewport.name = "Phase1IntermittentSubViewport"
	subviewport.size = Vector2i(320, 180)
	subviewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	subviewport.world_3d = get_viewport().world_3d
	add_child(subviewport)
	var subviewport_camera := Camera3D.new()
	subviewport_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	subviewport_camera.size = 8.0
	subviewport_camera.position = Vector3(0.0, 5.0, 0.0)
	subviewport.add_child(subviewport_camera)
	subviewport_camera.look_at(Vector3.ZERO, Vector3.FORWARD)
	subviewport_camera.current = true

	_mark_segment("phase1_fresh/lifecycle_subviewport_first_update_once")
	await _render_frames(4)
	var first_subviewport_image := subviewport.get_texture().get_image()
	var first_subviewport_summary := _phase1_image_summary(first_subviewport_image)
	await _render_frames(7)
	subviewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_mark_segment("phase1_fresh/lifecycle_subviewport_second_update_once")
	await _render_frames(4)
	var second_subviewport_image := subviewport.get_texture().get_image()
	var second_subviewport_summary := _phase1_image_summary(second_subviewport_image)

	subviewport.size = Vector2i(384, 216)
	subviewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_mark_segment("phase1_fresh/lifecycle_subviewport_resize")
	await _render_frames(4)
	var resized_subviewport_image := subviewport.get_texture().get_image()
	var resized_subviewport_summary := _phase1_image_summary(resized_subviewport_image)
	subviewport.queue_free()
	await get_tree().process_frame

	var intermittent_valid: bool = (
			first_subviewport_summary.non_black
			and first_subviewport_summary.finite
			and second_subviewport_summary.non_black
			and second_subviewport_summary.finite
			and first_subviewport_summary.width == 320
			and first_subviewport_summary.height == 180
			and second_subviewport_summary.width == 320
			and second_subviewport_summary.height == 180
	)
	var resize_valid: bool = (
			resized_subviewport_summary.non_black
			and resized_subviewport_summary.finite
			and resized_subviewport_summary.width == 384
			and resized_subviewport_summary.height == 216
	)
	return {
		"camera_cut": cut_summary,
		"same_size_render_buffer_reconfigure": same_size_reconfigure_summary,
		"exposure_change_first_frame": exposure_first_frame_summary,
		"intermittent_subviewport": {
			"idle_main_frames_between_updates": 7,
			"first": first_subviewport_summary,
			"second": second_subviewport_summary,
		},
		"resized_subviewport": resized_subviewport_summary,
		"checks": {
			"camera_cut_first_frame_non_black_and_finite": cut_summary.non_black and cut_summary.finite,
			"same_size_render_buffer_reconfigure_produces_valid_output": same_size_reconfigure_valid,
			"camera_attributes_exposure_change_produces_valid_output": exposure_change_valid,
			"update_once_subviewport_survives_idle_gap": intermittent_valid,
			"subviewport_resize_recreates_valid_output": resize_valid,
		},
	}


func _run_phase1_outer_disable_lifecycle() -> Dictionary:
	# Exercise the render-buffer owner transition without relying on any removed
	# removed cache-specific allocation or diagnostic view.
	_set_phase1_fresh_only(1)
	_environment.dynamic_gi_screen_probes_enabled = true
	await _render_frames(4)
	var enabled := _sample_memory("phase1_fresh/outer_disable/enabled")

	_environment.dynamic_gi_screen_probes_enabled = false
	_mark_segment("phase1_fresh/outer_disable/disabled")
	await _render_frames(8)
	var disabled := _sample_memory("phase1_fresh/outer_disable/disabled")
	var disabled_frame_summary := _phase1_image_summary(await _capture_frame())

	_environment.dynamic_gi_screen_probes_enabled = true
	_mark_segment("phase1_fresh/outer_disable/reenabled_first_frame")
	var first_frame := await _capture_frame()
	var first_frame_summary := _phase1_image_summary(first_frame)

	_set_phase1_fresh_only(1)
	return {
		"enabled": enabled,
		"disabled": disabled,
		"disabled_frame": disabled_frame_summary,
		"reenabled_first_frame": first_frame_summary,
		"checks": {
			"outer_disable_produces_valid_output": (
					disabled_frame_summary.finite and disabled_frame_summary.non_black
			),
			"outer_reenable_first_frame_non_black_and_finite": (
					first_frame_summary.finite and first_frame_summary.non_black
			),
		},
	}


func _packed_tail(values: PackedFloat64Array, count: int) -> PackedFloat64Array:
	var result := PackedFloat64Array()
	var first_index := maxi(values.size() - maxi(count, 0), 0)
	for index in range(first_index, values.size()):
		result.append(values[index])
	return result


func _packed_range(values: PackedFloat64Array, first_index: int, end_index: int) -> PackedFloat64Array:
	var result := PackedFloat64Array()
	for index in range(clampi(first_index, 0, values.size()), clampi(end_index, 0, values.size())):
		result.append(values[index])
	return result


func _linear_slope(values: PackedFloat64Array) -> float:
	if values.size() < 2:
		return 0.0
	var count := float(values.size())
	var mean_x := (count - 1.0) * 0.5
	var mean_y := 0.0
	for value in values:
		mean_y += value
	mean_y /= count
	var covariance := 0.0
	var variance_x := 0.0
	for index in range(values.size()):
		var centered_x := float(index) - mean_x
		covariance += centered_x * (values[index] - mean_y)
		variance_x += centered_x * centered_x
	return covariance / maxf(variance_x, 0.000001)


func _capture_stream_metrics(frame_count: int, tail_count: int = 0) -> Dictionary:
	var luma_values := PackedFloat64Array()
	var red_values := PackedFloat64Array()
	var green_values := PackedFloat64Array()
	var blue_values := PackedFloat64Array()
	var spatial_variance_values := PackedFloat64Array()
	var sampled_pixels := 0
	for _frame_index in range(frame_count):
		var image := await _capture_frame()
		var statistics := _measure_image(image)
		luma_values.append(statistics.mean_luma)
		red_values.append(statistics.mean_rgb[0])
		green_values.append(statistics.mean_rgb[1])
		blue_values.append(statistics.mean_rgb[2])
		spatial_variance_values.append(statistics.variance_luma)
		sampled_pixels = statistics.sampled_pixels

	var tail_size := mini(maxi(tail_count, 0), luma_values.size())
	var tail_luma := _packed_tail(luma_values, tail_size)
	var half_index := int(luma_values.size() / 2)
	var first_half := _summarize_values(_packed_range(luma_values, 0, half_index))
	var second_half := _summarize_values(_packed_range(luma_values, half_index, luma_values.size()))
	var full_summary := _summarize_values(luma_values)
	var slope := _linear_slope(luma_values)
	var mean_rgb := [
		_summarize_values(red_values).mean,
		_summarize_values(green_values).mean,
		_summarize_values(blue_values).mean,
	]
	var minimum_channel: float = minf(mean_rgb[0], minf(mean_rgb[1], mean_rgb[2]))
	var maximum_channel: float = maxf(mean_rgb[0], maxf(mean_rgb[1], mean_rgb[2]))
	return {
		"frames": luma_values.size(),
		"sampled_pixels_per_frame": sampled_pixels,
		"frame_mean_luma": full_summary,
		"tail_frame_mean_luma": _summarize_values(tail_luma),
		"spatial_variance_luma": _summarize_values(spatial_variance_values),
		"frame_mean_rgb": mean_rgb,
		"neutral_chroma_spread_normalized": (
				(maximum_channel - minimum_channel) / maxf(full_summary.mean, 0.000001)
		),
		"linear_slope_luma_per_frame": slope,
		"absolute_relative_slope_per_100_frames": absf(slope) * 100.0 / maxf(full_summary.mean, 0.000001),
		"first_half": first_half,
		"second_half": second_half,
		"absolute_half_drift_normalized": (
				absf(second_half.mean - first_half.mean) / maxf(full_summary.mean, 0.000001)
		),
	}


func _run_phase1_fresh() -> Dictionary:
	_mark_segment("phase1_fresh/setup")
	var settings_exist := _phase1_settings_exist()
	_configure_phase1_white_furnace()
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
	var fresh_state_ok := _set_phase1_fresh_only(1)
	var warmup_frames := maxi(_options.warmup_frames, 64)
	var reference_frames := clampi(_options.sample_frames, 8, 32)
	var frames_rendered := 0

	# First establish the constant-environment output-transfer reference. Raw HDR
	# correctness is validated independently from the post-exit counter reduction.
	_set_phase1_plane_transfer_reference(Vector3(0.18, 0.18, 0.18))
	_environment.dynamic_gi_screen_probes_enabled = false
	_mark_segment("phase1_fresh/white_furnace_engine_reference")
	await _render_frames(warmup_frames)
	var white_furnace_engine_reference := await _capture_stream_metrics(reference_frames, reference_frames)
	_sample_memory("phase1_fresh/white_furnace_engine_reference")
	var white_furnace_reference_luma: float = white_furnace_engine_reference.frame_mean_luma.mean
	frames_rendered += warmup_frames + reference_frames

	_restore_phase1_plane_target_material()
	_environment.dynamic_gi_screen_probes_enabled = true
	_mark_segment("phase1_fresh/white_furnace_long_run")
	await _render_frames(warmup_frames)
	var long_run_metrics := await _capture_stream_metrics(
			_options.phase1_long_frames, _options.sample_frames
	)
	_sample_memory("phase1_fresh/white_furnace_long_run")
	frames_rendered += warmup_frames + _options.phase1_long_frames
	var white_furnace_output_luma: float = long_run_metrics.tail_frame_mean_luma.mean
	var white_furnace_end_to_end_error := (
			absf(white_furnace_output_luma - white_furnace_reference_luma)
			/ maxf(white_furnace_reference_luma, 0.000001)
	)

	# Verify Environment.dynamic_gi_energy at zero, half, and double energy. Each
	# target gets a fresh history generation because the analytic transfer
	# reference temporarily disables the outer screen-probe feature.
	var energy_sample_frames := clampi(_options.sample_frames, 8, 16)
	var energy_results: Array[Dictionary] = []
	var maximum_nonzero_energy_output_transfer_error := 0.0
	var zero_energy_target_maximum_rgb := INF
	for energy_spec in [
		{"energy": 0.0, "suffix": "0"},
		{"energy": 0.5, "suffix": "0_5"},
		{"energy": 2.0, "suffix": "2"},
	]:
		var energy_result := await _capture_phase1_energy_case(
				float(energy_spec.energy), energy_spec.suffix, warmup_frames, energy_sample_frames
		)
		energy_results.append(energy_result)
		if float(energy_spec.energy) > 0.0:
			maximum_nonzero_energy_output_transfer_error = maxf(
					maximum_nonzero_energy_output_transfer_error,
					energy_result.maximum_output_transfer_rgb_relative_error
			)
		else:
			zero_energy_target_maximum_rgb = energy_result.zero_energy_target_maximum_rgb
		frames_rendered += 8 + energy_sample_frames + warmup_frames + energy_sample_frames
	_environment.dynamic_gi_energy = 1.0

	# A non-unit CameraAttributes exposure catches both stale sky-octmap
	# normalization and missing history invalidation. The raw validator also
	# checks this target against analytic D=(0.36, 0.36, 0.36).
	var exposure_result := await _capture_phase1_exposure_case(
			2.0, warmup_frames, energy_sample_frames
	)
	frames_rendered += 16 + energy_sample_frames + warmup_frames + energy_sample_frames

	# Use a colored, direction-dependent sky for the candidate-count sweep. A
	# constant furnace alone cannot detect accidental sample selection/weighting.
	_set_phase1_reference_sky(
			"float z = clamp(abs(EYEDIR.y), 0.0, 1.0); COLOR = vec3(0.04 + 0.28 * z, 0.06 + 0.14 * z * z, 0.02 + 0.24 * z * z * z);"
	)
	_set_phase1_plane_transfer_reference(Vector3(0.2266666667, 0.13, 0.116))
	_environment.dynamic_gi_screen_probes_enabled = false
	_mark_segment("phase1_fresh/colored_lobe_engine_reference")
	await _render_frames(warmup_frames)
	var colored_lobe_engine_reference := await _capture_stream_metrics(reference_frames, reference_frames)
	_sample_memory("phase1_fresh/colored_lobe_engine_reference")
	frames_rendered += warmup_frames + reference_frames
	var colored_reference_rgb: Array = colored_lobe_engine_reference.frame_mean_rgb
	var colored_reference_spread: float = (
			maxf(colored_reference_rgb[0], maxf(colored_reference_rgb[1], colored_reference_rgb[2]))
			- minf(colored_reference_rgb[0], minf(colored_reference_rgb[1], colored_reference_rgb[2]))
	)

	_restore_phase1_plane_target_material()
	_environment.dynamic_gi_screen_probes_enabled = true
	var candidate_results: Array[Dictionary] = []
	var candidate_tail_means := PackedFloat64Array()
	var candidate_tail_rgb_means: Array = []
	var all_states_fresh_only := fresh_state_ok
	var all_outputs_non_black := true
	var maximum_colored_lobe_reference_error := 0.0
	for candidate_count in [1, 2, 4, 8]:
		var state_ok := _set_phase1_fresh_only(candidate_count)
		all_states_fresh_only = all_states_fresh_only and state_ok
		_mark_segment("phase1_fresh/candidates_%d_warmup" % candidate_count)
		await _render_frames(warmup_frames)
		_mark_segment("phase1_fresh/candidates_%d_sample" % candidate_count)
		var metrics := await _capture_stream_metrics(_options.sample_frames, _options.sample_frames)
		_sample_memory("phase1_fresh/candidates_%d" % candidate_count)
		var comparison_mean: float = metrics.tail_frame_mean_luma.mean
		var comparison_rgb: Array = metrics.frame_mean_rgb
		var reference_error := _phase1_maximum_rgb_relative_error(comparison_rgb, colored_reference_rgb)
		maximum_colored_lobe_reference_error = maxf(maximum_colored_lobe_reference_error, reference_error)
		all_outputs_non_black = all_outputs_non_black and comparison_mean > 0.001
		candidate_tail_means.append(comparison_mean)
		candidate_tail_rgb_means.append(comparison_rgb.duplicate())
		candidate_results.append(
				{
					"candidate_count": candidate_count,
					"fresh_only_state": _current_feature_state(),
					"fresh_only_state_valid": state_ok,
					"warmup_frames": warmup_frames,
					"metrics": metrics,
					"output_mean_rgb": comparison_rgb,
					"colored_lobe_reference_relative_error": reference_error,
				}
		)
		frames_rendered += warmup_frames + _options.sample_frames

	var maximum_candidate_mean_difference := 0.0
	var maximum_candidate_luma_mean_difference := 0.0
	for first_index in range(candidate_tail_means.size()):
		for second_index in range(first_index + 1, candidate_tail_means.size()):
			var pair_mean := (candidate_tail_means[first_index] + candidate_tail_means[second_index]) * 0.5
			maximum_candidate_luma_mean_difference = maxf(
					maximum_candidate_luma_mean_difference,
					absf(candidate_tail_means[first_index] - candidate_tail_means[second_index])
							/ maxf(pair_mean, 0.000001)
			)
			var first_rgb: Array = candidate_tail_rgb_means[first_index]
			var second_rgb: Array = candidate_tail_rgb_means[second_index]
			for channel in range(3):
				var channel_mean: float = (float(first_rgb[channel]) + float(second_rgb[channel])) * 0.5
				maximum_candidate_mean_difference = maxf(
						maximum_candidate_mean_difference,
						absf(float(first_rgb[channel]) - float(second_rgb[channel]))
								/ maxf(channel_mean, 0.000001)
				)

	var long_run_slope: float = long_run_metrics.get("absolute_relative_slope_per_100_frames", INF)
	var long_run_half_drift: float = long_run_metrics.get("absolute_half_drift_normalized", INF)
	var lifecycle := await _run_phase1_lifecycle_checks()
	var outer_disable_lifecycle := await _run_phase1_outer_disable_lifecycle()
	frames_rendered += 55
	return {
		"description": "Phase 1 reference-mode raw white furnace, colored directional sky candidate-count sweep, and local lifecycle checks.",
		"frames_rendered": frames_rendered,
		"reference_mode": true,
		"candidate_counts": [1, 2, 4, 8],
		"analytic_raw_white_furnace_D": [0.18, 0.18, 0.18],
		"engine_white_furnace_reference": white_furnace_engine_reference,
		"engine_white_furnace_reference_kind": "analytic linear D rendered through an unshaded plane with screen probes disabled; same exposure/tonemap/output transfer, not an offline path trace",
		"white_furnace_long_run": long_run_metrics,
		"energy_scaling": energy_results,
		"camera_attributes_exposure": exposure_result,
		"colored_lobe_engine_reference": colored_lobe_engine_reference,
		"colored_lobe_reference_kind": "analytic colored-lobe D rendered through an unshaded plane with screen probes disabled; same exposure/tonemap/output transfer",
		"candidate_results": candidate_results,
		"lifecycle": lifecycle,
		"outer_disable_lifecycle": outer_disable_lifecycle,
		"metrics": {
			"maximum_candidate_count_mean_relative_difference": maximum_candidate_mean_difference,
			"maximum_candidate_count_luma_mean_relative_difference": maximum_candidate_luma_mean_difference,
			"white_furnace_end_to_end_relative_error": white_furnace_end_to_end_error,
			"white_furnace_neutral_chroma_spread_normalized": long_run_metrics.neutral_chroma_spread_normalized,
			"maximum_nonzero_energy_output_transfer_relative_error": maximum_nonzero_energy_output_transfer_error,
			"camera_attributes_exposure_output_transfer_relative_error": exposure_result.maximum_output_transfer_rgb_relative_error,
			"zero_energy_target_maximum_rgb": zero_energy_target_maximum_rgb,
			"maximum_colored_lobe_reference_relative_error": maximum_colored_lobe_reference_error,
			"colored_lobe_reference_channel_spread": colored_reference_spread,
			"long_run_absolute_relative_slope_per_100_frames": long_run_slope,
			"long_run_absolute_half_drift_normalized": long_run_half_drift,
		},
		"checks": {
			"all_required_project_settings_exist": settings_exist,
			"all_candidate_counts_executed": candidate_results.size() == 4,
			"all_candidate_states_are_fresh_only_reference": all_states_fresh_only,
			"all_candidate_outputs_non_black": all_outputs_non_black,
			"white_furnace_output_transfer_reference_non_black": white_furnace_reference_luma > 0.001,
			"white_furnace_end_to_end_output_non_black": white_furnace_output_luma > 0.001,
			"white_furnace_matches_output_transfer_reference_within_three_percent": white_furnace_end_to_end_error < 0.03,
			"energy_sweep_all_levels_executed": energy_results.size() == 3,
			"zero_dynamic_gi_energy_produces_black_indirect_output": zero_energy_target_maximum_rgb < 0.001,
			"nonzero_dynamic_gi_energy_matches_output_transfer_reference_within_three_percent": maximum_nonzero_energy_output_transfer_error < 0.03,
			"camera_attributes_exposure_matches_output_transfer_reference_within_three_percent": exposure_result.maximum_output_transfer_rgb_relative_error < 0.03,
			"candidate_count_long_time_means_within_two_percent": maximum_candidate_mean_difference < 0.02,
			"colored_lobe_means_match_output_transfer_reference_within_three_percent": maximum_colored_lobe_reference_error < 0.03,
			"colored_lobe_reference_is_directional_and_chromatic": colored_reference_spread > 0.005,
			"neutral_environment_has_no_systematic_chroma": long_run_metrics.neutral_chroma_spread_normalized < 0.01,
			"long_run_has_at_least_1000_frames": int(long_run_metrics.get("frames", 0)) >= 1000,
			"long_run_energy_slope_below_point_one_percent_per_100_frames": long_run_slope < 0.001,
			"long_run_half_drift_below_one_percent": long_run_half_drift < 0.01,
			"camera_cut_first_frame_non_black_and_finite": lifecycle.checks.camera_cut_first_frame_non_black_and_finite,
			"same_size_render_buffer_reconfigure_produces_valid_output": lifecycle.checks.same_size_render_buffer_reconfigure_produces_valid_output,
			"camera_attributes_exposure_change_produces_valid_output": lifecycle.checks.camera_attributes_exposure_change_produces_valid_output,
			"update_once_subviewport_survives_idle_gap": lifecycle.checks.update_once_subviewport_survives_idle_gap,
			"subviewport_resize_recreates_valid_output": lifecycle.checks.subviewport_resize_recreates_valid_output,
			"outer_disable_produces_valid_output": outer_disable_lifecycle.checks.outer_disable_produces_valid_output,
			"outer_reenable_first_frame_non_black_and_finite": outer_disable_lifecycle.checks.outer_reenable_first_frame_non_black_and_finite,
		},
	}


func _phase2_number_is_finite(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)


func _phase2_metrics_are_finite(value: Variant) -> bool:
	if value is float:
		return _phase2_number_is_finite(value)
	if value is Array:
		for child in value:
			if not _phase2_metrics_are_finite(child):
				return false
	elif value is Dictionary:
		for child in value.values():
			if not _phase2_metrics_are_finite(child):
				return false
	return true


func _phase2_relative_difference(first: float, second: float) -> float:
	return absf(first - second) / maxf((absf(first) + absf(second)) * 0.5, 0.000001)


func _configure_phase2_regression_scene() -> void:
	for child in get_children():
		if child is GeometryInstance3D or child is Light3D:
			child.visible = true
	if _phase1_plane != null:
		_phase1_plane.visible = false

	_environment.background_mode = Environment.BG_COLOR
	_environment.background_color = Color(0.018, 0.022, 0.032)
	_environment.background_energy_multiplier = 1.0
	_environment.sky = null
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_environment.ambient_light_color = Color(0.055, 0.065, 0.085)
	_environment.ambient_light_energy = 0.35
	_environment.ambient_light_sky_contribution = 0.0
	_environment.reflected_light_source = Environment.REFLECTION_SOURCE_BG
	_environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_environment.tonemap_exposure = 1.0
	_environment.dynamic_gi_read_sky_light = false
	_environment.dynamic_gi_energy = 1.0
	_environment.dynamic_gi_screen_probes_enabled = true
	_world_environment.camera_attributes = null

	var blocker := get_node_or_null("Occluder") as MeshInstance3D
	if blocker != null:
		blocker.position = Vector3(0.15, 1.1, 0.0)
		blocker.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	var fill_light := get_node_or_null("IndirectFill") as OmniLight3D
	if fill_light != null:
		fill_light.light_energy = 5.0
		fill_light.light_color = Color(1.0, 0.56, 0.28)
		fill_light.visible = true

	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.fov = 64.0
	_camera.position = CAMERA_HOME
	_aim_camera()


func _capture_phase2_steady(
		label: String, temporal_enabled: bool, warmup_frames: int, sample_frames: int
) -> Dictionary:
	var state_valid := _set_phase2_transport(temporal_enabled)
	_mark_segment("phase2_temporal/%s_warmup" % label)
	await _render_frames(warmup_frames)
	_mark_segment("phase2_temporal/%s_sample" % label)
	var metrics := await _capture_stream_metrics(sample_frames, sample_frames)
	_sample_memory("phase2_temporal/%s" % label)
	return {
		"transport": "phase2_n1_visibility" if temporal_enabled else "phase1_n2_fresh",
		"state": _current_feature_state(),
		"state_valid": state_valid,
		"warmup_frames": warmup_frames,
		"sample_frames": sample_frames,
		"metrics": metrics,
	}


func _phase2_transition_metrics(
		before: Image, first_after: Image, stable_after: Image, stable_after_next: Image
) -> Dictionary:
	var step_signal := _measure_difference(before, stable_after)
	var first_to_stable := _measure_difference(first_after, stable_after)
	var stable_noise := _measure_difference(stable_after, stable_after_next)
	var stable_statistics := _measure_image(stable_after)
	var excess := maxf(first_to_stable.mean_abs_luma - stable_noise.mean_abs_luma, 0.0)
	return {
		"step_signal": step_signal,
		"first_after_to_stable": first_to_stable,
		"stable_noise_floor": stable_noise,
		"stable_mean_luma": stable_statistics.mean_luma,
		"ghost_proxy_excess_mean_abs_luma": excess,
		"ghost_proxy_normalized": excess / maxf(stable_statistics.mean_luma, 0.000001),
		"reference_kind": "later same-state frame; regression proxy, not ground truth",
		"finite": _phase2_metrics_are_finite(
				[step_signal, first_to_stable, stable_noise, stable_statistics]
		),
	}


func _phase2_transition_series_metrics(
		before: Image,
		transition_images: Array[Image],
		stable_images: Array[Image]
) -> Dictionary:
	if transition_images.is_empty() or stable_images.size() < 2:
		return {
			"finite": false,
			"half_life_reached": false,
			"half_life_frames": -1,
			"step_signal_normalized": 0.0,
			"residual_curve_normalized": [],
		}
	var stable_after: Image = stable_images.back()
	var stable_after_next: Image = stable_images[stable_images.size() - 2]
	var metrics := _phase2_transition_metrics(
			before, transition_images.front(), stable_after, stable_after_next
	)
	var stable_mean: float = maxf(float(metrics.stable_mean_luma), 0.000001)
	# Compare a later steady-state population to the same final reference used by
	# the transition curve. One adjacent-frame difference underestimates the
	# floor for temporally correlated stochastic reservoirs and can make a true
	# half-life mathematically unreachable.
	var stable_noise_samples: Array[float] = []
	for index in range(stable_images.size() - 1):
		stable_noise_samples.append(
				float(_measure_difference(stable_images[index], stable_after).mean_abs_luma)
		)
	stable_noise_samples.sort()
	var stable_noise := 0.0
	var noise_middle := stable_noise_samples.size() >> 1
	if stable_noise_samples.size() % 2 == 0:
		stable_noise = (stable_noise_samples[noise_middle - 1] + stable_noise_samples[noise_middle]) * 0.5
	else:
		stable_noise = stable_noise_samples[noise_middle]
	var transition_samples: Array[float] = []
	var residuals: Array[float] = []
	for image in transition_images:
		var difference := _measure_difference(image, stable_after)
		var transition_mae := float(difference.mean_abs_luma)
		transition_samples.append(transition_mae)
		residuals.append(maxf(transition_mae - stable_noise, 0.0) / stable_mean)

	# Use the largest of the first four post-step residuals as the reference so
	# one unusually lucky stochastic frame cannot manufacture an immediate pass.
	var initial_residual := 0.0
	var initial_peak_index := 0
	for index in range(mini(4, residuals.size())):
		if residuals[index] > initial_residual:
			initial_residual = residuals[index]
			initial_peak_index = index
	var noise_normalized := stable_noise / stable_mean
	# If the remaining post-subtraction peak is no larger than a typical stable
	# frame-to-reference variation, the ghost is already below the measurement
	# noise floor. Report frame 0 instead of fitting a half-life to noise.
	var half_life_reached := initial_residual <= maxf(noise_normalized, 0.000000001)
	var half_life_frames := 0 if half_life_reached else -1
	var half_threshold := initial_residual * 0.5
	if not half_life_reached:
		# Require three consecutive frames below half amplitude. This makes the
		# metric a convergence gate rather than a single-frame noise crossing.
		# Do not search before the first-four-frame reference peak: otherwise three
		# lucky low frames followed by the peak would be reported as convergence.
		for index in range(initial_peak_index, residuals.size()):
			if residuals[index] > half_threshold:
				continue
			var sustained := true
			for lookahead in range(index, mini(index + 3, residuals.size())):
				if residuals[lookahead] > half_threshold:
					sustained = false
					break
			if sustained and residuals.size() - index >= 3:
				half_life_reached = true
				half_life_frames = index + 1
				break

	metrics.merge(
			{
				"transition_frame_count": transition_images.size(),
				"transition_samples_mean_abs_luma": transition_samples,
				"step_signal_normalized": float(metrics.step_signal.mean_abs_luma) / stable_mean,
				"stable_reference_noise_floor": {
					"sample_count": stable_noise_samples.size(),
					"samples_mean_abs_luma": stable_noise_samples,
					"median_mean_abs_luma": stable_noise,
					"normalized": noise_normalized,
				},
				"initial_residual_normalized": initial_residual,
				"initial_peak_frame": initial_peak_index + 1,
				"half_amplitude_threshold_normalized": half_threshold,
				"half_life_reached": half_life_reached,
				"half_life_frames": half_life_frames,
				"residual_frame_2_normalized": residuals[1] if residuals.size() >= 2 else -1.0,
				"residual_frame_4_normalized": residuals[3] if residuals.size() >= 4 else -1.0,
				"residual_frame_8_normalized": residuals[7] if residuals.size() >= 8 else -1.0,
				"final_residual_normalized": residuals.back() if not residuals.is_empty() else 0.0,
				"residual_curve_normalized": residuals,
				"half_life_definition": "frame 0 when the post-subtraction frame-1..4 peak is no larger than the normalized stable noise floor; otherwise first of at least three consecutive samples at or below half that peak",
			},
			true
	)
	var first_to_stable_mae: float = float(metrics.first_after_to_stable.mean_abs_luma)
	var first_excess := maxf(first_to_stable_mae - stable_noise, 0.0)
	metrics.ghost_proxy_excess_mean_abs_luma = first_excess
	metrics.ghost_proxy_normalized = first_excess / stable_mean
	metrics.finite = (
			bool(metrics.finite)
			and _phase2_metrics_are_finite(residuals)
			and _phase2_metrics_are_finite(transition_samples)
			and _phase2_metrics_are_finite(stable_noise_samples)
	)
	return metrics


func _run_phase2_motion_and_cut() -> Dictionary:
	_configure_phase2_regression_scene()
	var state_valid := _set_phase2_transport(true)
	var motion_frames := clampi(_options.sample_frames, 8, 64)
	var start := Vector3(-0.9, 2.2, 6.2)
	var finish := Vector3(0.9, 2.2, 6.2)
	_camera.position = start
	_aim_camera()
	_mark_segment("phase2_temporal/camera_motion_warmup")
	await _render_frames(maxi(_options.warmup_frames, 32))
	var motion_images: Array[Image] = []
	_mark_segment("phase2_temporal/camera_motion")
	for frame_index in range(motion_frames):
		var t := float(frame_index + 1) / float(motion_frames)
		_camera.position = start.lerp(finish, t)
		_aim_camera()
		motion_images.append(await _capture_frame())
	var first_stopped := await _capture_frame()
	_mark_segment("phase2_temporal/camera_motion_settle")
	await _render_frames(_options.settle_frames)
	var stable_motion := await _capture_frame()
	var stable_motion_next := await _capture_frame()
	var motion_transition := _phase2_transition_metrics(
			motion_images.front(), first_stopped, stable_motion, stable_motion_next
	)

	var before_cut := stable_motion_next
	_camera.position = Vector3(3.8, 3.2, 3.0)
	_camera.look_at(Vector3(0.0, 1.0, -1.5), Vector3.UP)
	_mark_segment("phase2_temporal/camera_cut_first_frame")
	var cut_first := await _capture_frame()
	await _render_frames(_options.settle_frames)
	var cut_stable := await _capture_frame()
	var cut_stable_next := await _capture_frame()
	var cut_transition := _phase2_transition_metrics(
			before_cut, cut_first, cut_stable, cut_stable_next
	)
	var cut_summary := _phase1_image_summary(cut_first)

	_camera.position = CAMERA_HOME
	_aim_camera()
	return {
		"state_valid": state_valid,
		"motion_frames": motion_frames,
		"motion_series": _measure_series(motion_images),
		"motion_stop": motion_transition,
		"camera_cut": cut_transition,
		"camera_cut_first_frame": cut_summary,
		"checks": {
			"motion_sequence_captured": motion_images.size() == motion_frames,
			"motion_metrics_finite": _phase2_metrics_are_finite(motion_transition),
			"camera_cut_metrics_finite": _phase2_metrics_are_finite(cut_transition),
			"camera_cut_first_frame_non_black_and_finite": cut_summary.non_black and cut_summary.finite,
		},
	}


func _run_phase2_cascade_scroll() -> Dictionary:
	_configure_phase2_regression_scene()
	var state_valid := _set_phase2_transport(true)
	await _render_frames(maxi(_options.warmup_frames, 32))
	var before := await _capture_frame()
	var world_shift := Vector3(4.5, 0.0, 0.0)
	_camera.position += world_shift
	_camera.look_at(CAMERA_TARGET + world_shift, Vector3.UP)
	_mark_segment("phase2_temporal/cascade_scroll_first_frame")
	var first_after := await _capture_frame()
	await _render_frames(_options.settle_frames)
	var stable_after := await _capture_frame()
	var stable_after_next := await _capture_frame()
	var transition := _phase2_transition_metrics(before, first_after, stable_after, stable_after_next)
	var first_summary := _phase1_image_summary(first_after)
	_camera.position = CAMERA_HOME
	_aim_camera()
	return {
		"state_valid": state_valid,
		"camera_world_shift": [world_shift.x, world_shift.y, world_shift.z],
		"finest_cascade_cell_shift": world_shift.x / _environment.dynamic_gi_min_cell_size,
		"transition": transition,
		"first_frame": first_summary,
		"checks": {
			"translation_crosses_multiple_finest_cells": absf(world_shift.x) / _environment.dynamic_gi_min_cell_size >= 8.0,
			"first_frame_non_black_and_finite": first_summary.non_black and first_summary.finite,
			"cascade_scroll_metrics_finite": _phase2_metrics_are_finite(transition),
		},
	}


func _run_phase2_dynamic_steps() -> Dictionary:
	_configure_phase2_regression_scene()
	var state_valid := _set_phase2_transport(true)
	var settle_frames := maxi(_options.settle_frames, 24)
	var blocker := get_node_or_null("Occluder") as MeshInstance3D
	var fill_light := get_node_or_null("IndirectFill") as OmniLight3D
	var blocker_result: Dictionary = {}
	var light_result: Dictionary = {}
	var sky_result: Dictionary = {}

	if blocker != null:
		_mark_segment("phase2_temporal/dynamic_blocker_setup")
		blocker.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
		blocker.position = Vector3(-2.8, 1.1, -0.2)
		await _render_frames(settle_frames)
		_mark_segment("phase2_temporal/dynamic_blocker_baseline")
		var blocker_baseline := await _capture_series(4)
		var blocker_before: Image = blocker_baseline.back()
		blocker.position = Vector3(0.15, 1.1, 0.0)
		_mark_segment("phase2_temporal/dynamic_blocker_step")
		var blocker_transition := await _capture_series(PHASE2_DYNAMIC_TRANSITION_FRAMES)
		_mark_segment("phase2_temporal/dynamic_blocker_post_transition")
		await _render_frames(settle_frames)
		var blocker_stable := await _capture_series(PHASE2_STABLE_NOISE_FRAMES)
		blocker_result = _phase2_transition_series_metrics(
				blocker_before, blocker_transition, blocker_stable
		)

	if fill_light != null:
		# Step from a bright indirect source to off so the metric catches stale
		# reservoir energy instead of measuring only dark-to-bright responsiveness.
		_mark_segment("phase2_temporal/dynamic_light_setup")
		fill_light.light_energy = 12.0
		await _render_frames(settle_frames)
		_mark_segment("phase2_temporal/dynamic_light_baseline")
		var light_baseline := await _capture_series(4)
		var light_before: Image = light_baseline.back()
		fill_light.light_energy = 0.0
		_mark_segment("phase2_temporal/dynamic_light_step")
		var light_transition := await _capture_series(PHASE2_DYNAMIC_TRANSITION_FRAMES)
		_mark_segment("phase2_temporal/dynamic_light_post_transition")
		await _render_frames(settle_frames)
		var light_stable := await _capture_series(PHASE2_STABLE_NOISE_FRAMES)
		light_result = _phase2_transition_series_metrics(
				light_before, light_transition, light_stable
		)

	_mark_segment("phase2_temporal/dynamic_sky_setup")
	_environment.background_mode = Environment.BG_SKY
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_environment.ambient_light_sky_contribution = 1.0
	_environment.dynamic_gi_read_sky_light = true
	# Likewise, remove a bright sky. This is the persistence-sensitive direction
	# required by the residual-energy contract. Mutate a uniform on one stable
	# Sky/ShaderMaterial RID so the transport configuration hash cannot turn this
	# into a generation reset; P2 must re-evaluate current sky content itself.
	var mutable_sky := _create_phase2_mutable_sky(Vector3(0.30, 0.08, 0.025))
	await _render_frames(settle_frames)
	_mark_segment("phase2_temporal/dynamic_sky_baseline")
	var sky_baseline := await _capture_series(4)
	var sky_before: Image = sky_baseline.back()
	mutable_sky.set_shader_parameter("qa_color", Vector3(0.005, 0.006, 0.008))
	_mark_segment("phase2_temporal/dynamic_sky_step")
	var sky_transition := await _capture_series(PHASE2_DYNAMIC_TRANSITION_FRAMES)
	_mark_segment("phase2_temporal/dynamic_sky_post_transition")
	await _render_frames(settle_frames)
	var sky_stable := await _capture_series(PHASE2_STABLE_NOISE_FRAMES)
	sky_result = _phase2_transition_series_metrics(
			sky_before, sky_transition, sky_stable
	)

	_mark_segment("phase2_temporal/dynamic_steps_restore")
	_configure_phase2_regression_scene()
	_set_phase2_transport(true)
	return {
		"state_valid": state_valid,
		"dynamic_blocker": blocker_result,
		"dynamic_light": light_result,
		"dynamic_sky": sky_result,
		"checks": {
			"dynamic_blocker_step_executed": not blocker_result.is_empty(),
			"dynamic_light_step_executed": not light_result.is_empty(),
			"dynamic_sky_step_executed": not sky_result.is_empty(),
			"all_dynamic_step_metrics_finite": _phase2_metrics_are_finite(
					[blocker_result, light_result, sky_result]
			),
			"all_dynamic_steps_have_measurable_signal": (
					float(blocker_result.get("step_signal_normalized", 0.0)) > 0.0
					and float(light_result.get("step_signal_normalized", 0.0)) > 0.0
					and float(sky_result.get("step_signal_normalized", 0.0)) > 0.0
			),
			"all_dynamic_ghost_half_lives_reached": (
					bool(blocker_result.get("half_life_reached", false))
					and bool(light_result.get("half_life_reached", false))
					and bool(sky_result.get("half_life_reached", false))
			),
		},
	}


func _run_phase2_robust_clamp() -> Dictionary:
	_configure_phase2_regression_scene()
	_camera.position = CAMERA_HOME
	_aim_camera()
	var robust_state_valid := _set_phase2_transport(
			true, true, PHASE2_ROBUST_TEST_JACOBIAN_MAX
	)
	_mark_segment("phase2_temporal/robust_clamp_warmup")
	await _render_frames(maxi(_options.warmup_frames, 64))

	var motion_frames := 48
	var images: Array[Image] = []
	_mark_segment("phase2_temporal/robust_clamp_motion")
	for frame_index in range(motion_frames):
		var phase := TAU * float(frame_index + 1) / float(motion_frames)
		_camera.position = CAMERA_HOME + Vector3(sin(phase) * 0.12, cos(phase) * 0.025, 0.0)
		_aim_camera()
		images.append(await _capture_frame())
	var first_summary := _phase1_image_summary(images.front())
	var last_summary := _phase1_image_summary(images.back())
	var motion_series := _measure_series(images)

	_camera.position = CAMERA_HOME
	_aim_camera()
	var strict_state_restored := _set_phase2_transport(true)
	_mark_segment("phase2_temporal/robust_clamp_restore_strict")
	await _render_frames(4)
	return {
		"state": _current_feature_state(),
		"robust_state_valid": robust_state_valid,
		"strict_state_restored": strict_state_restored,
		"jacobian_max": PHASE2_ROBUST_TEST_JACOBIAN_MAX,
		"motion_frames": motion_frames,
		"motion_series": motion_series,
		"first_frame": first_summary,
		"last_frame": last_summary,
		"counter_contract": "feature_flags=7 snapshots in robust_clamp segments must report Jacobian clamps and final ROBUST_CLAMPED payloads for both fresh and history selections while nonfinite and packing-invalid remain zero; strict feature_flags=3 snapshots must report zero clamp events and zero final robust flags",
		"checks": {
			"robust_configuration_executed_and_strict_restored": robust_state_valid and strict_state_restored,
			"robust_motion_frames_captured": images.size() == motion_frames,
			"robust_outputs_non_black_and_finite": (
					first_summary.non_black
					and first_summary.finite
					and last_summary.non_black
					and last_summary.finite
					and _phase2_metrics_are_finite(motion_series)
			),
		},
	}


func _run_phase2_taa_jitter() -> Dictionary:
	_configure_phase2_regression_scene()
	var state_valid := _set_phase2_transport(true)
	var viewport := get_viewport()
	var original_taa := viewport.is_using_taa()
	viewport.use_taa = true
	_mark_segment("phase2_temporal/taa_jitter_warmup")
	await _render_frames(maxi(_options.warmup_frames, 32))
	var taa_enabled_observed := viewport.is_using_taa()

	_mark_segment("phase2_temporal/taa_jitter_stationary")
	var stationary_images := await _capture_series(16)
	_mark_segment("phase2_temporal/taa_jitter_post_stationary")
	var stationary_series := _measure_series(stationary_images)

	var motion_images: Array[Image] = []
	_mark_segment("phase2_temporal/taa_jitter_motion")
	for frame_index in range(16):
		var phase := TAU * float(frame_index + 1) / 16.0
		_camera.position = CAMERA_HOME + Vector3(sin(phase) * 0.18, 0.0, 0.0)
		_aim_camera()
		motion_images.append(await _capture_frame())
	_mark_segment("phase2_temporal/taa_jitter_post_motion")
	var motion_series := _measure_series(motion_images)

	_camera.position = CAMERA_HOME
	_aim_camera()
	await _render_frames(_options.settle_frames)
	var before_cut := await _capture_frame()
	# Exceed the renderer's max(4 m, 16 finest cells) translation threshold so
	# this is an actual P2 camera cut, not merely a TAA-smoothed camera move.
	_camera.position = CAMERA_HOME + Vector3(4.5, 0.0, 0.0)
	_camera.look_at(CAMERA_TARGET, Vector3.UP)
	_mark_segment("phase2_temporal/taa_jitter_camera_cut")
	var first_after_cut := await _capture_frame()
	_mark_segment("phase2_temporal/taa_jitter_cut_settle")
	await _render_frames(_options.settle_frames)
	var stable_after_cut := await _capture_frame()
	var stable_after_cut_next := await _capture_frame()
	var cut_transition := _phase2_transition_metrics(
			before_cut, first_after_cut, stable_after_cut, stable_after_cut_next
	)
	var first_summary := _phase1_image_summary(first_after_cut)
	var stable_summary := _phase1_image_summary(stable_after_cut)

	_camera.position = CAMERA_HOME
	_aim_camera()
	viewport.use_taa = original_taa
	var strict_state_restored := _set_phase2_transport(true)
	_mark_segment("phase2_temporal/taa_jitter_restore")
	await _render_frames(4)
	return {
		"state_valid": state_valid,
		"taa_enabled_observed": taa_enabled_observed,
		"taa_original_state": original_taa,
		"taa_restored": viewport.is_using_taa() == original_taa,
		"strict_state_restored": strict_state_restored,
		"stationary_frames": stationary_images.size(),
		"stationary_series": stationary_series,
		"motion_frames": motion_images.size(),
		"motion_series": motion_series,
		"camera_cut": cut_transition,
		"first_after_cut": first_summary,
		"stable_after_cut": stable_summary,
		"checks": {
			"taa_was_enabled_and_restored": (
					taa_enabled_observed
					and viewport.is_using_taa() == original_taa
					and strict_state_restored
			),
			"taa_stationary_sequence_captured": stationary_images.size() == 16,
			"taa_motion_sequence_captured": motion_images.size() == 16,
			"taa_outputs_non_black_and_finite": (
					first_summary.non_black
					and first_summary.finite
					and stable_summary.non_black
					and stable_summary.finite
			),
			"taa_metrics_finite": _phase2_metrics_are_finite(
					[stationary_series, motion_series, cut_transition]
			),
		},
	}


func _run_phase2_age_rejection() -> Dictionary:
	_configure_phase2_regression_scene()
	var age_state_valid := _set_phase2_transport(
			true,
			false,
			PHASE2_JACOBIAN_MAX,
			PHASE2_AGE_REJECTION_TEST_MAXIMUM
	)
	_mark_segment("phase2_temporal/maximum_age_2_warmup")
	await _render_frames(16)
	_mark_segment("phase2_temporal/maximum_age_2_sample")
	var images := await _capture_series(32)
	var first_summary := _phase1_image_summary(images.front())
	var last_summary := _phase1_image_summary(images.back())
	var series := _measure_series(images)
	var default_state_restored := _set_phase2_transport(true)
	_mark_segment("phase2_temporal/maximum_age_2_restore_default")
	await _render_frames(4)
	return {
		"test_maximum_age": PHASE2_AGE_REJECTION_TEST_MAXIMUM,
		"age_state_valid": age_state_valid,
		"default_state_restored": default_state_restored,
		"sample_frames": images.size(),
		"series": series,
		"first_frame": first_summary,
		"last_frame": last_summary,
		"counter_contract": "maximum_age=2 sample snapshots must exercise reservoir_reject_age, keep reservoir_max_age<=2, and restore the default maximum_age=255 configuration",
		"checks": {
			"age_configuration_executed_and_default_restored": (
					age_state_valid and default_state_restored
			),
			"age_sample_frames_captured": images.size() == 32,
			"age_outputs_non_black_and_finite": (
					first_summary.non_black
					and first_summary.finite
					and last_summary.non_black
					and last_summary.finite
					and _phase2_metrics_are_finite(series)
			),
		},
	}


func _run_phase2_lifecycle_checks() -> Dictionary:
	_configure_phase2_regression_scene()
	var initial_state_valid := _set_phase2_transport(true)
	await _render_frames(16)
	var temporal_before := await _capture_frame()
	var off_state_valid := _set_phase2_transport(false)
	_mark_segment("phase2_temporal/toggle_temporal_off_p1_n2")
	await _render_frames(4)
	var off_summary := _phase1_image_summary(await _capture_frame())
	var on_state_valid := _set_phase2_transport(true)
	_mark_segment("phase2_temporal/toggle_temporal_on_first_frame")
	var on_first := await _capture_frame()
	_mark_segment("phase2_temporal/toggle_temporal_on_post_first_frame")
	var on_summary := _phase1_image_summary(on_first)
	var toggle_difference := _measure_difference(temporal_before, on_first)

	_environment.dynamic_gi_screen_probes_enabled = false
	_mark_segment("phase2_temporal/toggle_screen_probes_off")
	await _render_frames(4)
	var probes_off_summary := _phase1_image_summary(await _capture_frame())
	_environment.dynamic_gi_screen_probes_enabled = true
	_set_phase2_transport(true)
	_mark_segment("phase2_temporal/toggle_screen_probes_on_first_frame")
	var probes_on_first := await _capture_frame()
	_mark_segment("phase2_temporal/toggle_screen_probes_on_post_first_frame")
	var probes_on_summary := _phase1_image_summary(probes_on_first)

	var subviewport := SubViewport.new()
	subviewport.name = "Phase2IntermittentSubViewport"
	subviewport.size = Vector2i(320, 180)
	subviewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	subviewport.world_3d = get_viewport().world_3d
	add_child(subviewport)
	var subviewport_camera := Camera3D.new()
	subviewport_camera.position = CAMERA_HOME
	subviewport.add_child(subviewport_camera)
	subviewport_camera.look_at(CAMERA_TARGET, Vector3.UP)
	subviewport_camera.current = true
	_mark_segment("phase2_temporal/update_once_first")
	await _render_frames(4)
	var first_subviewport := _phase1_image_summary(subviewport.get_texture().get_image())
	_mark_segment("phase2_temporal/update_once_idle_gap")
	await _render_frames(7)
	subviewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_mark_segment("phase2_temporal/update_once_second_after_idle")
	await _render_frames(4)
	var second_subviewport := _phase1_image_summary(subviewport.get_texture().get_image())
	_mark_segment("phase2_temporal/update_once_resize_setup")
	subviewport.size = Vector2i(384, 216)
	subviewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_mark_segment("phase2_temporal/update_once_resize")
	await _render_frames(4)
	var resized_subviewport := _phase1_image_summary(subviewport.get_texture().get_image())
	_mark_segment("phase2_temporal/update_once_complete")
	subviewport.queue_free()
	await get_tree().process_frame

	var intermittent_valid: bool = (
			first_subviewport.non_black
			and first_subviewport.finite
			and second_subviewport.non_black
			and second_subviewport.finite
			and first_subviewport.width == 320
			and first_subviewport.height == 180
			and second_subviewport.width == 320
			and second_subviewport.height == 180
	)
	var resize_valid: bool = (
			resized_subviewport.non_black
			and resized_subviewport.finite
			and resized_subviewport.width == 384
			and resized_subviewport.height == 216
	)
	return {
		"initial_state_valid": initial_state_valid,
		"temporal_off_state_valid": off_state_valid,
		"temporal_on_state_valid": on_state_valid,
		"temporal_off": off_summary,
		"temporal_on_first_frame": on_summary,
		"toggle_difference": toggle_difference,
		"screen_probes_off": probes_off_summary,
		"screen_probes_on_first_frame": probes_on_summary,
		"intermittent_subviewport": {
			"idle_main_frames_between_updates": 7,
			"first": first_subviewport,
			"second": second_subviewport,
		},
		"resized_subviewport": resized_subviewport,
		"checks": {
			"phase1_n2_and_phase2_n1_toggle_states_valid": initial_state_valid and off_state_valid and on_state_valid,
			"temporal_toggle_outputs_non_black_and_finite": off_summary.non_black and off_summary.finite and on_summary.non_black and on_summary.finite,
			"outer_screen_probe_reenable_non_black_and_finite": probes_on_summary.non_black and probes_on_summary.finite,
			"update_once_subviewport_survives_idle_gap": intermittent_valid,
			"subviewport_resize_recreates_valid_output": resize_valid,
			"lifecycle_metrics_finite": _phase2_metrics_are_finite(toggle_difference),
		},
	}


func _run_phase2_temporal() -> Dictionary:
	_mark_segment("phase2_temporal/setup")
	var settings_exist := _phase2_settings_exist()
	_configure_phase1_white_furnace()
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
	var warmup_frames := maxi(_options.warmup_frames, 64)
	var comparison_frames := maxi(_options.sample_frames, 64)

	var constant_phase1 := await _capture_phase2_steady(
			"constant/p1_n2", false, warmup_frames, comparison_frames
	)
	var constant_phase2 := await _capture_phase2_steady(
			"constant/p2_n1_visibility", true, warmup_frames, comparison_frames
	)
	_mark_segment("phase2_temporal/constant/p2_1000_frame")
	_set_phase2_transport(true)
	await _render_frames(warmup_frames)
	var long_run := await _capture_stream_metrics(
			_options.phase2_long_frames, mini(comparison_frames, _options.phase2_long_frames)
	)

	_set_phase1_reference_sky(
			"float z = clamp(abs(EYEDIR.y), 0.0, 1.0); COLOR = vec3(0.04 + 0.28 * z, 0.06 + 0.14 * z * z, 0.02 + 0.24 * z * z * z);"
	)
	var colored_phase1 := await _capture_phase2_steady(
			"colored/p1_n2", false, warmup_frames, comparison_frames
	)
	var colored_phase2 := await _capture_phase2_steady(
			"colored/p2_n1_visibility", true, warmup_frames, comparison_frames
	)

	var motion_and_cut := await _run_phase2_motion_and_cut()
	var cascade_scroll := await _run_phase2_cascade_scroll()
	var dynamic_steps := await _run_phase2_dynamic_steps()
	var robust_clamp := await _run_phase2_robust_clamp()
	var age_rejection := await _run_phase2_age_rejection()
	var taa_jitter := await _run_phase2_taa_jitter()
	var lifecycle := await _run_phase2_lifecycle_checks()

	var constant_p1_mean: float = constant_phase1.metrics.frame_mean_luma.mean
	var constant_p2_mean: float = constant_phase2.metrics.frame_mean_luma.mean
	var colored_p1_mean: float = colored_phase1.metrics.frame_mean_luma.mean
	var colored_p2_mean: float = colored_phase2.metrics.frame_mean_luma.mean
	var colored_p1_variance: float = colored_phase1.metrics.frame_mean_luma.variance
	var colored_p2_variance: float = colored_phase2.metrics.frame_mean_luma.variance
	var ghost_values := PackedFloat64Array([
		motion_and_cut.motion_stop.ghost_proxy_normalized,
		motion_and_cut.camera_cut.ghost_proxy_normalized,
		cascade_scroll.transition.ghost_proxy_normalized,
		dynamic_steps.dynamic_blocker.get("ghost_proxy_normalized", 0.0),
		dynamic_steps.dynamic_light.get("ghost_proxy_normalized", 0.0),
		dynamic_steps.dynamic_sky.get("ghost_proxy_normalized", 0.0),
		taa_jitter.camera_cut.ghost_proxy_normalized,
	])
	var maximum_ghost_proxy := 0.0
	for ghost_value in ghost_values:
		maximum_ghost_proxy = maxf(maximum_ghost_proxy, ghost_value)
	var gate_metrics := {
		"constant_mean_relative_difference_p2_vs_p1_n2": _phase2_relative_difference(
				constant_p2_mean, constant_p1_mean
		),
		"colored_mean_relative_difference_p2_vs_p1_n2": _phase2_relative_difference(
				colored_p2_mean, colored_p1_mean
		),
		"colored_frame_mean_variance_ratio_p2_over_p1_n2": colored_p2_variance / maxf(
				colored_p1_variance, 0.000000000001
		),
		"colored_phase1_frame_mean_variance": colored_p1_variance,
		"colored_phase2_frame_mean_variance": colored_p2_variance,
		"long_run_absolute_relative_slope_per_100_frames": long_run.absolute_relative_slope_per_100_frames,
		"long_run_absolute_half_drift_normalized": long_run.absolute_half_drift_normalized,
		"maximum_transition_ghost_proxy_normalized": maximum_ghost_proxy,
		"motion_stop_ghost_proxy_normalized": motion_and_cut.motion_stop.ghost_proxy_normalized,
		"camera_cut_ghost_proxy_normalized": motion_and_cut.camera_cut.ghost_proxy_normalized,
		"cascade_scroll_ghost_proxy_normalized": cascade_scroll.transition.ghost_proxy_normalized,
		"dynamic_blocker_ghost_proxy_normalized": dynamic_steps.dynamic_blocker.get("ghost_proxy_normalized", 0.0),
		"dynamic_light_ghost_proxy_normalized": dynamic_steps.dynamic_light.get("ghost_proxy_normalized", 0.0),
		"dynamic_sky_ghost_proxy_normalized": dynamic_steps.dynamic_sky.get("ghost_proxy_normalized", 0.0),
		"dynamic_blocker_step_signal_normalized": dynamic_steps.dynamic_blocker.get("step_signal_normalized", 0.0),
		"dynamic_light_step_signal_normalized": dynamic_steps.dynamic_light.get("step_signal_normalized", 0.0),
		"dynamic_sky_step_signal_normalized": dynamic_steps.dynamic_sky.get("step_signal_normalized", 0.0),
		"dynamic_blocker_stable_noise_normalized": dynamic_steps.dynamic_blocker.get("stable_reference_noise_floor", {}).get("normalized", -1.0),
		"dynamic_light_stable_noise_normalized": dynamic_steps.dynamic_light.get("stable_reference_noise_floor", {}).get("normalized", -1.0),
		"dynamic_sky_stable_noise_normalized": dynamic_steps.dynamic_sky.get("stable_reference_noise_floor", {}).get("normalized", -1.0),
		"dynamic_blocker_noise_to_step_ratio": dynamic_steps.dynamic_blocker.get("stable_reference_noise_floor", {}).get("normalized", 1.0) / maxf(dynamic_steps.dynamic_blocker.get("step_signal_normalized", 0.0), 0.000001),
		"dynamic_light_noise_to_step_ratio": dynamic_steps.dynamic_light.get("stable_reference_noise_floor", {}).get("normalized", 1.0) / maxf(dynamic_steps.dynamic_light.get("step_signal_normalized", 0.0), 0.000001),
		"dynamic_sky_noise_to_step_ratio": dynamic_steps.dynamic_sky.get("stable_reference_noise_floor", {}).get("normalized", 1.0) / maxf(dynamic_steps.dynamic_sky.get("step_signal_normalized", 0.0), 0.000001),
		"dynamic_blocker_ghost_half_life_frames": float(dynamic_steps.dynamic_blocker.get("half_life_frames", -1)),
		"dynamic_light_ghost_half_life_frames": float(dynamic_steps.dynamic_light.get("half_life_frames", -1)),
		"dynamic_sky_ghost_half_life_frames": float(dynamic_steps.dynamic_sky.get("half_life_frames", -1)),
		"dynamic_blocker_residual_frame_4_normalized": dynamic_steps.dynamic_blocker.get("residual_frame_4_normalized", -1.0),
		"dynamic_light_residual_frame_8_normalized": dynamic_steps.dynamic_light.get("residual_frame_8_normalized", -1.0),
		"dynamic_sky_residual_frame_8_normalized": dynamic_steps.dynamic_sky.get("residual_frame_8_normalized", -1.0),
		"taa_cut_ghost_proxy_normalized": taa_jitter.camera_cut.ghost_proxy_normalized,
	}
	var comparison_states_valid: bool = (
			constant_phase1.state_valid
			and constant_phase2.state_valid
			and colored_phase1.state_valid
			and colored_phase2.state_valid
	)
	var comparisons_non_black: bool = (
			constant_p1_mean > 0.001
			and constant_p2_mean > 0.001
			and colored_p1_mean > 0.001
			and colored_p2_mean > 0.001
			and long_run.frame_mean_luma.mean > 0.001
	)
	var all_gate_inputs_finite := _phase2_metrics_are_finite(gate_metrics)
	return {
		"description": "Phase 2 temporal ReSTIR fixed-ray-budget comparison, long-run stability, content/visibility transitions, and lifecycle coverage.",
		"configuration": _phase2_configuration(),
		"constant_environment": {
			"phase1_n2_fresh": constant_phase1,
			"phase2_n1_visibility": constant_phase2,
		},
		"colored_environment": {
			"phase1_n2_fresh": colored_phase1,
			"phase2_n1_visibility": colored_phase2,
		},
		"long_run": long_run,
		"motion_and_cut": motion_and_cut,
		"cascade_scroll": cascade_scroll,
		"dynamic_steps": dynamic_steps,
		"robust_clamp": robust_clamp,
		"age_rejection": age_rejection,
		"taa_jitter": taa_jitter,
		"lifecycle": lifecycle,
		"gate_metrics": gate_metrics,
		"gate_contract": {
			"finite": "strict: every emitted gate input must be finite; GPU reservoir_nonfinite and packing_invalid must remain zero",
			"mean": "compare P2 N=1+visibility against same-scene P1 N=2 fresh; threshold must be calibrated from a real GPU acceptance run",
			"variance": "compare colored-sky frame-mean variance under a fixed approximate ray budget; threshold must be calibrated from a real GPU acceptance run",
			"ghost": "first-after-transition and a 128-frame residual curve versus a later same-state reference after subtracting the median 31-sample steady-state noise floor; half-life requires three consecutive samples below half amplitude and is a regression proxy, not path-traced ground truth",
		},
		"checks": {
			"all_required_project_settings_exist": settings_exist,
			"phase1_n2_and_phase2_n1_comparison_states_valid": comparison_states_valid,
			"constant_colored_and_long_run_outputs_non_black": comparisons_non_black,
			"long_run_has_at_least_1000_frames": int(long_run.frames) >= 1000,
			"all_finite_mean_variance_and_ghost_gate_inputs_emitted": all_gate_inputs_finite,
			"camera_motion_and_cut_executed": motion_and_cut.checks.motion_sequence_captured and motion_and_cut.checks.camera_cut_first_frame_non_black_and_finite,
			"cascade_scroll_executed": cascade_scroll.checks.translation_crosses_multiple_finest_cells and cascade_scroll.checks.first_frame_non_black_and_finite,
			"dynamic_blocker_light_and_sky_steps_executed": dynamic_steps.checks.dynamic_blocker_step_executed and dynamic_steps.checks.dynamic_light_step_executed and dynamic_steps.checks.dynamic_sky_step_executed,
			"dynamic_steps_have_measurable_signal": dynamic_steps.checks.all_dynamic_steps_have_measurable_signal,
			"dynamic_ghost_half_lives_reached": dynamic_steps.checks.all_dynamic_ghost_half_lives_reached,
			"robust_clamp_mode_executed": robust_clamp.checks.robust_configuration_executed_and_strict_restored and robust_clamp.checks.robust_motion_frames_captured and robust_clamp.checks.robust_outputs_non_black_and_finite,
			"maximum_age_rejection_runtime_executed": age_rejection.checks.age_configuration_executed_and_default_restored and age_rejection.checks.age_sample_frames_captured and age_rejection.checks.age_outputs_non_black_and_finite,
			"taa_jitter_runtime_executed": taa_jitter.checks.taa_was_enabled_and_restored and taa_jitter.checks.taa_stationary_sequence_captured and taa_jitter.checks.taa_motion_sequence_captured and taa_jitter.checks.taa_outputs_non_black_and_finite,
			"toggle_resize_and_update_once_executed": lifecycle.checks.phase1_n2_and_phase2_n1_toggle_states_valid and lifecycle.checks.update_once_subviewport_survives_idle_gap and lifecycle.checks.subviewport_resize_recreates_valid_output,
			"all_transition_metrics_finite": motion_and_cut.checks.motion_metrics_finite and motion_and_cut.checks.camera_cut_metrics_finite and cascade_scroll.checks.cascade_scroll_metrics_finite and dynamic_steps.checks.all_dynamic_step_metrics_finite and taa_jitter.checks.taa_metrics_finite and lifecycle.checks.lifecycle_metrics_finite,
		},
	}


func _run_baseline() -> Dictionary:
	_mark_segment("baseline/setup")
	_set_experimental_features(false)
	_environment.dynamic_gi_screen_probes_enabled = true
	_camera.position = CAMERA_HOME
	_aim_camera()
	_mark_segment("baseline/warmup")
	await _render_frames(_options.warmup_frames)
	_sample_memory("baseline/after_warmup")
	_mark_segment("baseline/sample")
	var images := await _capture_series(_options.sample_frames)
	_sample_memory("baseline/after_sample")
	var series := _measure_series(images)
	return {
		"description": "Stationary production view with temporal/spatial reuse disabled.",
		"frames_rendered": _options.warmup_frames + _options.sample_frames,
		"sampled_pixels_per_frame": series.sampled_pixels_per_frame,
		"metrics": series,
		"checks": {
			"non_black_full_roi": series.frame_mean_luma.mean > 0.001,
			"has_multiple_frames": images.size() >= 2,
		},
	}


func _run_motion() -> Dictionary:
	_mark_segment("motion/setup")
	_set_experimental_features(false)
	_environment.dynamic_gi_screen_probes_enabled = true
	var start := Vector3(-0.9, 2.2, 6.2)
	var finish := Vector3(0.9, 2.2, 6.2)
	_camera.position = start
	_aim_camera()
	_mark_segment("motion/warmup")
	await _render_frames(_options.warmup_frames)
	_sample_memory("motion/after_warmup")

	var motion_images: Array[Image] = []
	_mark_segment("motion/camera_translation")
	for frame_index in range(_options.sample_frames):
		var t := float(frame_index + 1) / float(_options.sample_frames)
		_camera.position = start.lerp(finish, t)
		_aim_camera()
		motion_images.append(await _capture_frame())

	_camera.position = finish
	_aim_camera()
	_mark_segment("motion/first_stopped_frame")
	var first_stopped := await _capture_frame()
	_mark_segment("motion/post_stop_settle")
	await _render_frames(_options.settle_frames)
	var stable_a := await _capture_frame()
	var stable_b := await _capture_frame()
	_sample_memory("motion/after_settle")
	var initial_difference := _measure_difference(first_stopped, stable_a)
	var noise_floor := _measure_difference(stable_a, stable_b)
	var reference_stats := _measure_image(stable_a)
	var excess_mae := maxf(initial_difference.mean_abs_luma - noise_floor.mean_abs_luma, 0.0)
	var normalized_excess := excess_mae / maxf(reference_stats.mean_luma, 0.000001)

	return {
		"description": "Camera translation followed by a stop; ghost is reported only as a stable-frame difference proxy.",
		"frames_rendered": _options.warmup_frames + _options.sample_frames + _options.settle_frames + 3,
		"motion_series": _measure_series(motion_images),
		"post_stop": {
			"initial_to_stable_difference": initial_difference,
			"stable_noise_floor_difference": noise_floor,
			"reference_mean_luma": reference_stats.mean_luma,
			"ghost_proxy_excess_mean_abs_luma": excess_mae,
			"ghost_proxy_normalized": normalized_excess,
			"reference_kind": "later_same-position_frame; not ground truth",
		},
		"checks": {
			"motion_frames_captured": motion_images.size() == _options.sample_frames,
			"stable_reference_non_black": reference_stats.mean_luma > 0.001,
		},
	}


func _run_feature_off_toggle() -> Dictionary:
	var transitions: Array[Dictionary] = []
	# The Phase 1 production baseline deliberately traces fresh stochastic
	# candidates. Compare ensemble means here so the feature-off signal is not
	# hidden by a single candidate realization. Keep the count bounded for quick
	# smoke runs, and even so two independent halves provide a matching noise
	# floor.
	var state_average_frames := clampi(_options.sample_frames, 8, 16)
	if state_average_frames % 2 != 0:
		state_average_frames += 1
	_mark_segment("feature_off_toggle/setup")
	_camera.position = CAMERA_HOME
	_aim_camera()
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
	_set_experimental_features(false)
	_environment.dynamic_gi_screen_probes_enabled = true
	_mark_segment("feature_off_toggle/probes_on_experimental_off")
	await _render_frames(_options.warmup_frames)
	var off_reference_series := await _capture_series(state_average_frames)
	var off_reference_noise_a: Array[Image] = []
	var off_reference_noise_b: Array[Image] = []
	for image_index in range(off_reference_series.size()):
		if image_index < state_average_frames / 2:
			off_reference_noise_a.append(off_reference_series[image_index])
		else:
			off_reference_noise_b.append(off_reference_series[image_index])
	var off_reference_b: Image = off_reference_series.back()
	_sample_memory("feature_off_toggle/probes_on_experimental_off")
	transitions.append(_current_feature_state())
	var off_noise := _measure_average_difference(off_reference_noise_a, off_reference_noise_b)

	_environment.dynamic_gi_screen_probes_enabled = false
	_mark_segment("feature_off_toggle/screen_probes_disabled")
	await _render_frames(8)
	var probes_disabled_series := await _capture_series(state_average_frames)
	var probes_disabled_compare: Array[Image] = []
	for image_index in range(state_average_frames / 2):
		probes_disabled_compare.append(probes_disabled_series[image_index])
	var probes_disabled_stats := _measure_image(probes_disabled_series.back())
	_sample_memory("feature_off_toggle/screen_probes_disabled")
	transitions.append(_current_feature_state())
	var disabled_delta := _measure_average_difference(off_reference_noise_b, probes_disabled_compare)

	_environment.dynamic_gi_screen_probes_enabled = true
	_set_experimental_features(true)
	_mark_segment("feature_off_toggle/probes_on_experimental_on")
	# Configuration changes reset the render-buffer-local sequence. Keep this
	# state alive beyond the 60-frame readback interval so the full suite records
	# at least one counter snapshot with temporal/spatial reuse enabled.
	var experimental_on_frames := maxi(_options.settle_frames, 64)
	await _render_frames(experimental_on_frames)
	var experimental_on := await _capture_frame()
	var experimental_on_b := await _capture_frame()
	var experimental_on_noise := _measure_difference(experimental_on, experimental_on_b)
	_sample_memory("feature_off_toggle/probes_on_experimental_on")
	transitions.append(_current_feature_state())
	var experimental_delta := _measure_difference(off_reference_b, experimental_on)
	_set_experimental_features(false)
	_mark_segment("feature_off_toggle/return_experimental_off")
	var first_off_after_toggle := await _capture_frame()
	await _render_frames(_options.settle_frames)
	var recovered_off_series := await _capture_series(state_average_frames)
	var recovered_noise_a: Array[Image] = []
	var recovered_noise_b: Array[Image] = []
	for image_index in range(recovered_off_series.size()):
		if image_index < state_average_frames / 2:
			recovered_noise_a.append(recovered_off_series[image_index])
		else:
			recovered_noise_b.append(recovered_off_series[image_index])
	var recovered_off_a: Image = recovered_off_series.front()
	_sample_memory("feature_off_toggle/recovered_experimental_off")
	transitions.append(_current_feature_state())
	var off_recovery := _measure_difference(first_off_after_toggle, recovered_off_a)
	var recovered_single_frame_noise := _measure_difference(
			recovered_off_series[0], recovered_off_series[1]
	)
	var recovered_noise := _measure_average_difference(recovered_noise_a, recovered_noise_b)
	var off_repeatability := _measure_average_difference(off_reference_series, recovered_off_series)
	var recovered_stats := _measure_image(recovered_off_a)
	var recovery_excess := maxf(
			off_recovery.mean_abs_luma - recovered_single_frame_noise.mean_abs_luma, 0.0
	)

	return {
		"description": "Exercise screen-probe off/on and temporal/spatial estimator transitions.",
		"state_average_frames": state_average_frames,
		"frames_rendered": (
				_options.warmup_frames
				+ experimental_on_frames
				+ _options.settle_frames
				+ state_average_frames * 3
				+ 11
		),
		"experimental_on_frames": experimental_on_frames,
		"transitions": transitions,
		"metrics": {
			"off_state_noise_floor": off_noise,
			"screen_probes_disabled_delta": disabled_delta,
			"experimental_on_delta": experimental_delta,
			"experimental_on_noise_floor": experimental_on_noise,
			"first_off_to_recovered_off": off_recovery,
			"recovered_single_frame_noise_floor": recovered_single_frame_noise,
			"recovered_off_noise_floor": recovered_noise,
			"off_state_repeatability": off_repeatability,
			"toggle_recovery_proxy_excess_mean_abs_luma": recovery_excess,
			"toggle_recovery_proxy_normalized": recovery_excess / maxf(recovered_stats.mean_luma, 0.000001),
		},
		"checks": {
			"recovered_off_frame_non_black": recovered_stats.mean_luma > 0.001,
			"screen_probes_disabled_capture_non_black": (
					probes_disabled_stats.sampled_pixels > 0 and probes_disabled_stats.mean_luma > 0.001
			),
			"all_expected_transitions_executed": (
					transitions.size() == 4
					and _feature_state_matches(transitions[0], true, false)
					and _feature_state_matches(transitions[1], false, false)
					and _feature_state_matches(transitions[2], true, true)
					and _feature_state_matches(transitions[3], true, false)
			),
			"screen_probes_disabled_changes_output_beyond_noise": (
					disabled_delta.mean_abs_luma > maxf(off_noise.mean_abs_luma * 1.5, 0.002)
			),
		},
	}


func _aim_camera() -> void:
	_camera.look_at(CAMERA_TARGET, Vector3.UP)


func _mark_segment(segment_name: String) -> void:
	_debug_counter_tag += 1
	ProjectSettings.set_setting(SETTING_DEBUG_COUNTER_TAG, _debug_counter_tag)
	print("HDDAGI_QA_SEGMENT tag=%d name=%s" % [_debug_counter_tag, segment_name])


func _render_frames(count: int) -> void:
	for _frame_index in range(count):
		await get_tree().process_frame
		await RenderingServer.frame_post_draw


func _capture_frame() -> Image:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image.is_empty():
		_errors.append("Viewport capture returned an empty image.")
		return image
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	var expected_size := Vector2i(get_viewport().get_visible_rect().size)
	if image.get_size() != expected_size:
		var message := "Viewport capture size %s did not match visible viewport size %s." % [image.get_size(), expected_size]
		if not _errors.has(message):
			_errors.append(message)
	return image


func _capture_series(count: int) -> Array[Image]:
	var images: Array[Image] = []
	for _frame_index in range(count):
		images.append(await _capture_frame())
	return images


func _measure_series(images: Array[Image]) -> Dictionary:
	if images.is_empty():
		return {"frames": 0, "sampled_pixels_per_frame": 0}
	var frame_means := PackedFloat64Array()
	var spatial_variances := PackedFloat64Array()
	var adjacent_mae := PackedFloat64Array()
	var adjacent_rmse := PackedFloat64Array()
	var sampled_pixels := 0
	for image_index in range(images.size()):
		var statistics := _measure_image(images[image_index])
		frame_means.append(statistics.mean_luma)
		spatial_variances.append(statistics.variance_luma)
		sampled_pixels = statistics.sampled_pixels
		if image_index > 0:
			var difference := _measure_difference(images[image_index - 1], images[image_index])
			adjacent_mae.append(difference.mean_abs_luma)
			adjacent_rmse.append(difference.rmse_luma)
	return {
		"frames": images.size(),
		"sampled_pixels_per_frame": sampled_pixels,
		"frame_mean_luma": _summarize_values(frame_means),
		"spatial_variance_luma": _summarize_values(spatial_variances),
		"adjacent_frame_mean_abs_luma": _summarize_values(adjacent_mae),
		"adjacent_frame_rmse_luma": _summarize_values(adjacent_rmse),
	}


func _measure_image(image: Image) -> Dictionary:
	if image.is_empty():
		return {
			"sampled_pixels": 0,
			"width": image.get_width(),
			"height": image.get_height(),
			"mean_luma": 0.0,
			"variance_luma": 0.0,
			"min_luma": 0.0,
			"max_luma": 0.0,
		}
	var roi := _get_roi(image)
	var sum_luma := 0.0
	var sum_squared_luma := 0.0
	var sum_rgb := Vector3.ZERO
	var min_luma := INF
	var max_luma := -INF
	var sample_count := 0
	for y in range(roi.position.y, roi.end.y, _options.sample_stride):
		for x in range(roi.position.x, roi.end.x, _options.sample_stride):
			var color := image.get_pixel(x, y)
			var luma := _luminance(color)
			sum_luma += luma
			sum_squared_luma += luma * luma
			sum_rgb += Vector3(color.r, color.g, color.b)
			min_luma = minf(min_luma, luma)
			max_luma = maxf(max_luma, luma)
			sample_count += 1
	var divisor := maxf(float(sample_count), 1.0)
	var mean_luma := sum_luma / divisor
	var variance := maxf(sum_squared_luma / divisor - mean_luma * mean_luma, 0.0)
	var mean_rgb := sum_rgb / divisor
	return {
		"sampled_pixels": sample_count,
		"width": image.get_width(),
		"height": image.get_height(),
		"mean_luma": mean_luma,
		"variance_luma": variance,
		"standard_deviation_luma": sqrt(variance),
		"min_luma": min_luma,
		"max_luma": max_luma,
		"mean_rgb": [mean_rgb.x, mean_rgb.y, mean_rgb.z],
	}


func _measure_difference(first: Image, second: Image) -> Dictionary:
	if first.is_empty() or second.is_empty():
		_errors.append("Image difference received an empty image.")
		return {
			"sampled_pixels": 0,
			"width": 0,
			"height": 0,
			"mean_abs_luma": 0.0,
			"rmse_luma": 0.0,
			"p95_abs_luma": 0.0,
			"mean_abs_rgb": 0.0,
			"changed_fraction_over_1_percent": 0.0,
		}
	if first.get_size() != second.get_size():
		_errors.append("Image difference size mismatch: %s versus %s." % [first.get_size(), second.get_size()])
		return {
			"sampled_pixels": 0,
			"width": first.get_width(),
			"height": first.get_height(),
			"mean_abs_luma": 0.0,
			"rmse_luma": 0.0,
			"p95_abs_luma": 0.0,
			"mean_abs_rgb": 0.0,
			"changed_fraction_over_1_percent": 0.0,
		}
	var roi := _get_roi(first)
	var absolute_luma := PackedFloat64Array()
	var sum_abs_luma := 0.0
	var sum_squared_luma := 0.0
	var sum_abs_rgb := 0.0
	var changed_count := 0
	for y in range(roi.position.y, roi.end.y, _options.sample_stride):
		for x in range(roi.position.x, roi.end.x, _options.sample_stride):
			var first_color := first.get_pixel(x, y)
			var second_color := second.get_pixel(x, y)
			var delta_luma := absf(_luminance(first_color) - _luminance(second_color))
			absolute_luma.append(delta_luma)
			sum_abs_luma += delta_luma
			sum_squared_luma += delta_luma * delta_luma
			sum_abs_rgb += (
					absf(first_color.r - second_color.r)
					+ absf(first_color.g - second_color.g)
					+ absf(first_color.b - second_color.b)
			) / 3.0
			if delta_luma > 0.01:
				changed_count += 1
	absolute_luma.sort()
	var sample_count := absolute_luma.size()
	var divisor := maxf(float(sample_count), 1.0)
	var percentile_index := clampi(int(floor(float(sample_count - 1) * 0.95)), 0, maxi(sample_count - 1, 0))
	return {
		"sampled_pixels": sample_count,
		"width": first.get_width(),
		"height": first.get_height(),
		"mean_abs_luma": sum_abs_luma / divisor,
		"rmse_luma": sqrt(sum_squared_luma / divisor),
		"p95_abs_luma": absolute_luma[percentile_index] if sample_count > 0 else 0.0,
		"mean_abs_rgb": sum_abs_rgb / divisor,
		"changed_fraction_over_1_percent": float(changed_count) / divisor,
	}


func _measure_average_difference(first_images: Array[Image], second_images: Array[Image]) -> Dictionary:
	if first_images.is_empty() or second_images.is_empty():
		_errors.append("Average image difference received an empty image series.")
		return {
			"sampled_pixels": 0,
			"width": 0,
			"height": 0,
			"first_frame_count": first_images.size(),
			"second_frame_count": second_images.size(),
			"mean_abs_luma": 0.0,
			"rmse_luma": 0.0,
			"p95_abs_luma": 0.0,
			"mean_abs_rgb": 0.0,
			"changed_fraction_over_1_percent": 0.0,
		}
	var reference: Image = first_images.front()
	if reference.is_empty():
		_errors.append("Average image difference received an empty image.")
		return {
			"sampled_pixels": 0,
			"width": 0,
			"height": 0,
			"first_frame_count": first_images.size(),
			"second_frame_count": second_images.size(),
			"mean_abs_luma": 0.0,
			"rmse_luma": 0.0,
			"p95_abs_luma": 0.0,
			"mean_abs_rgb": 0.0,
			"changed_fraction_over_1_percent": 0.0,
		}
	for image in first_images + second_images:
		if image.is_empty():
			_errors.append("Average image difference received an empty image.")
			return {
				"sampled_pixels": 0,
				"width": reference.get_width(),
				"height": reference.get_height(),
				"first_frame_count": first_images.size(),
				"second_frame_count": second_images.size(),
				"mean_abs_luma": 0.0,
				"rmse_luma": 0.0,
				"p95_abs_luma": 0.0,
				"mean_abs_rgb": 0.0,
				"changed_fraction_over_1_percent": 0.0,
			}
		if image.get_size() != reference.get_size():
			_errors.append(
					"Average image difference size mismatch: %s versus %s."
					% [reference.get_size(), image.get_size()]
			)
			return {
				"sampled_pixels": 0,
				"width": reference.get_width(),
				"height": reference.get_height(),
				"first_frame_count": first_images.size(),
				"second_frame_count": second_images.size(),
				"mean_abs_luma": 0.0,
				"rmse_luma": 0.0,
				"p95_abs_luma": 0.0,
				"mean_abs_rgb": 0.0,
				"changed_fraction_over_1_percent": 0.0,
			}

	var roi := _get_roi(reference)
	var absolute_luma := PackedFloat64Array()
	var sum_abs_luma := 0.0
	var sum_squared_luma := 0.0
	var sum_abs_rgb := 0.0
	var changed_count := 0
	var first_divisor := float(first_images.size())
	var second_divisor := float(second_images.size())
	for y in range(roi.position.y, roi.end.y, _options.sample_stride):
		for x in range(roi.position.x, roi.end.x, _options.sample_stride):
			var first_rgb := Vector3.ZERO
			var second_rgb := Vector3.ZERO
			for image in first_images:
				var color := image.get_pixel(x, y)
				first_rgb += Vector3(color.r, color.g, color.b)
			for image in second_images:
				var color := image.get_pixel(x, y)
				second_rgb += Vector3(color.r, color.g, color.b)
			first_rgb /= first_divisor
			second_rgb /= second_divisor
			var delta_rgb := (first_rgb - second_rgb).abs()
			var delta_luma := absf(
					(first_rgb.x - second_rgb.x) * 0.2126
					+ (first_rgb.y - second_rgb.y) * 0.7152
					+ (first_rgb.z - second_rgb.z) * 0.0722
			)
			absolute_luma.append(delta_luma)
			sum_abs_luma += delta_luma
			sum_squared_luma += delta_luma * delta_luma
			sum_abs_rgb += (delta_rgb.x + delta_rgb.y + delta_rgb.z) / 3.0
			if delta_luma > 0.01:
				changed_count += 1
	absolute_luma.sort()
	var sample_count := absolute_luma.size()
	var divisor := maxf(float(sample_count), 1.0)
	var percentile_index := clampi(int(floor(float(sample_count - 1) * 0.95)), 0, maxi(sample_count - 1, 0))
	return {
		"sampled_pixels": sample_count,
		"width": reference.get_width(),
		"height": reference.get_height(),
		"first_frame_count": first_images.size(),
		"second_frame_count": second_images.size(),
		"mean_abs_luma": sum_abs_luma / divisor,
		"rmse_luma": sqrt(sum_squared_luma / divisor),
		"p95_abs_luma": absolute_luma[percentile_index] if sample_count > 0 else 0.0,
		"mean_abs_rgb": sum_abs_rgb / divisor,
		"changed_fraction_over_1_percent": float(changed_count) / divisor,
	}


func _summarize_values(values: PackedFloat64Array) -> Dictionary:
	if values.is_empty():
		return {"count": 0, "mean": 0.0, "variance": 0.0, "min": 0.0, "max": 0.0}
	var sum := 0.0
	var sum_squared := 0.0
	var minimum := INF
	var maximum := -INF
	for value in values:
		sum += value
		sum_squared += value * value
		minimum = minf(minimum, value)
		maximum = maxf(maximum, value)
	var mean := sum / float(values.size())
	return {
		"count": values.size(),
		"mean": mean,
		"variance": maxf(sum_squared / float(values.size()) - mean * mean, 0.0),
		"min": minimum,
		"max": maximum,
	}


func _get_roi(image: Image) -> Rect2i:
	var border_x := int(round(float(image.get_width()) * _options.roi_border_fraction))
	var border_y := int(round(float(image.get_height()) * _options.roi_border_fraction))
	return Rect2i(
		border_x,
		border_y,
		maxi(image.get_width() - border_x * 2, 1),
		maxi(image.get_height() - border_y * 2, 1)
	)


func _luminance(color: Color) -> float:
	return color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722


func _sample_memory(label: String) -> Dictionary:
	var snapshot := {
		"label": label,
		"process_frame": Engine.get_process_frames(),
		"video_mem_used": int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)),
		"texture_mem_used": int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)),
		"buffer_mem_used": int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED)),
		"screen_probes_enabled": _environment.dynamic_gi_screen_probes_enabled,
		"temporal_guiding": bool(ProjectSettings.get_setting(SETTING_TEMPORAL, false)),
		"spatial_guiding": bool(ProjectSettings.get_setting(SETTING_SPATIAL, false)),
		"reference_mode": bool(ProjectSettings.get_setting(SETTING_REFERENCE_MODE, false)),
		"candidate_count": int(ProjectSettings.get_setting(SETTING_CANDIDATES, 1)),
	}
	_memory_snapshots.append(snapshot)
	return snapshot


func _make_memory_result() -> Dictionary:
	var peaks := {"video_mem_used": 0, "texture_mem_used": 0, "buffer_mem_used": 0}
	for snapshot in _memory_snapshots:
		for field in peaks:
			peaks[field] = maxi(int(peaks[field]), int(snapshot[field]))
	return {
		"units": "bytes",
		"scope": "process-wide RenderingServer counters; feature deltas include unrelated renderer lifetime changes",
		"snapshots": _memory_snapshots,
		"peaks": peaks,
		"feature_toggle_deltas": {
			"screen_probes_disabled_minus_default": _memory_delta(
					"feature_off_toggle/probes_on_experimental_off",
					"feature_off_toggle/screen_probes_disabled"
			),
			"experimental_on_minus_default": _memory_delta(
					"feature_off_toggle/probes_on_experimental_off",
					"feature_off_toggle/probes_on_experimental_on"
			),
			"recovered_off_minus_default": _memory_delta(
					"feature_off_toggle/probes_on_experimental_off",
					"feature_off_toggle/recovered_experimental_off"
			),
		},
	}


func _memory_delta(from_label: String, to_label: String) -> Dictionary:
	var from_snapshot: Dictionary = {}
	var to_snapshot: Dictionary = {}
	for snapshot in _memory_snapshots:
		if snapshot.label == from_label:
			from_snapshot = snapshot
		elif snapshot.label == to_label:
			to_snapshot = snapshot
	if from_snapshot.is_empty() or to_snapshot.is_empty():
		return {"available": false}
	return {
		"available": true,
		"video_mem_used": int(to_snapshot.video_mem_used) - int(from_snapshot.video_mem_used),
		"texture_mem_used": int(to_snapshot.texture_mem_used) - int(from_snapshot.texture_mem_used),
		"buffer_mem_used": int(to_snapshot.buffer_mem_used) - int(from_snapshot.buffer_mem_used),
	}


func _collect_debug_counters() -> Dictionary:
	var required_fields := DEBUG_COUNTER_REQUIRED_FIELDS.duplicate()
	if _options.scenario == "phase2_temporal":
		required_fields.append_array(PHASE2_COUNTER_REQUIRED_FIELDS)
	var counter_result := {
		"enabled": true,
		"marker": DEBUG_COUNTER_MARKER.strip_edges(),
		"source_log": _options.counter_log,
		"required_fields": required_fields,
		"snapshots": [],
		"snapshot_count": 0,
		"schema_valid": true,
	}
	if _options.counter_log.is_empty():
		_warnings.append(
				"No --counter-log was supplied; debug counter lines remain available only on process stdout."
		)
		return counter_result
	var absolute_log_path := ProjectSettings.globalize_path(_options.counter_log)
	var log_file := FileAccess.open(absolute_log_path, FileAccess.READ)
	if log_file == null:
		_warnings.append(
				"Counter log '%s' was unavailable before shutdown; inspect process stdout or the completed log file."
				% absolute_log_path
		)
		return counter_result
	while not log_file.eof_reached():
		var line := log_file.get_line()
		var marker_offset := line.find(DEBUG_COUNTER_MARKER)
		if marker_offset < 0:
			continue
		var payload := line.substr(marker_offset + DEBUG_COUNTER_MARKER.length()).strip_edges()
		var parsed = JSON.parse_string(payload)
		if parsed is Dictionary:
			var missing_fields: Array[String] = []
			for required_field in required_fields:
				if not parsed.has(required_field):
					missing_fields.append(required_field)
			if not missing_fields.is_empty():
				counter_result.schema_valid = false
				_warnings.append(
						"HDDAGI debug counter snapshot is missing fields: %s"
						% ", ".join(missing_fields)
				)
			counter_result.snapshots.append(parsed)
		else:
			_warnings.append("Malformed HDDAGI debug counter line in '%s'." % absolute_log_path)
	log_file.close()
	counter_result.snapshot_count = counter_result.snapshots.size()
	if counter_result.snapshot_count == 0:
		_warnings.append(
				"No HDDAGI debug counter snapshot was observed. The editor may predate the counter hook, the log may not be flushed yet, or fewer than 60 eligible frames rendered."
		)
	return counter_result


func _collect_runtime_log_summary() -> Dictionary:
	var summary := {
		"source_log": _options.counter_log,
		"error_count": 0,
		"warning_count": 0,
		"errors_by_segment": {},
		"first_error_segment": "unknown",
		"first_error_context": [],
		"unique_error_lines": [],
	}
	if _options.counter_log.is_empty():
		return summary
	var absolute_log_path := ProjectSettings.globalize_path(_options.counter_log)
	var log_file := FileAccess.open(absolute_log_path, FileAccess.READ)
	if log_file == null:
		return summary
	var lines: Array[String] = []
	while not log_file.eof_reached():
		lines.append(log_file.get_line())
	log_file.close()
	var current_segment := "before_first_marker"
	var first_error_index := -1
	var unique_errors: Dictionary = {}
	for line_index in range(lines.size()):
		var line := lines[line_index]
		var segment_offset := line.find("HDDAGI_QA_SEGMENT ")
		if segment_offset >= 0:
			var segment_descriptor := line.substr(
					segment_offset + "HDDAGI_QA_SEGMENT ".length()
			).strip_edges()
			var segment_name_offset := segment_descriptor.find(" name=")
			current_segment = (
					segment_descriptor.substr(segment_name_offset + " name=".length())
					if segment_name_offset >= 0
					else segment_descriptor
			)
		if line.find("ERROR:") >= 0:
			summary.error_count += 1
			summary.errors_by_segment[current_segment] = int(summary.errors_by_segment.get(current_segment, 0)) + 1
			var normalized_error := line.substr(line.find("ERROR:")).strip_edges()
			unique_errors[normalized_error] = true
			if first_error_index < 0:
				first_error_index = line_index
				summary.first_error_segment = current_segment
		elif line.find("WARNING:") >= 0:
			summary.warning_count += 1
	for error_line in unique_errors.keys():
		summary.unique_error_lines.append(error_line)
		if summary.unique_error_lines.size() >= 20:
			break
	if first_error_index >= 0:
		var context_begin := maxi(first_error_index - 6, 0)
		var context_end := mini(first_error_index + 7, lines.size())
		for line_index in range(context_begin, context_end):
			summary.first_error_context.append(lines[line_index])
	return summary


func _collect_gpu_profile() -> Dictionary:
	var profile_result := {
		"enabled": _options.gpu_profile_enabled,
		"source_log": _options.counter_log,
		"profile_block_count": 0,
		"hddagi_sample_count": 0,
		"hddagi_blocks": [],
		"task_summaries_ms": {},
		"hddagi_total_per_block_ms": {"count": 0, "mean": 0.0, "variance": 0.0, "min": 0.0, "max": 0.0},
	}
	if not _options.gpu_profile_enabled or _options.counter_log.is_empty():
		return profile_result
	var absolute_log_path := ProjectSettings.globalize_path(_options.counter_log)
	var log_file := FileAccess.open(absolute_log_path, FileAccess.READ)
	if log_file == null:
		_warnings.append("GPU profile console log '%s' was unavailable before shutdown." % absolute_log_path)
		return profile_result
	var current_block: Dictionary = {}
	while not log_file.eof_reached():
		var stripped_line := log_file.get_line().strip_edges()
		if stripped_line.begins_with("GPU PROFILE (total "):
			if not current_block.is_empty() and not current_block.hddagi_tasks.is_empty():
				profile_result.hddagi_blocks.append(current_block)
			var total_text := stripped_line.trim_prefix("GPU PROFILE (total ").trim_suffix("ms):")
			current_block = {
				"total_gpu_ms": total_text.to_float(),
				"hddagi_tasks": {},
				"hddagi_total_ms": 0.0,
			}
			profile_result.profile_block_count += 1
			continue
		if current_block.is_empty():
			continue
		if stripped_line.begins_with("-") and stripped_line.ends_with("ms"):
			var separator := stripped_line.rfind(": ")
			if separator > 1:
				var task_name := stripped_line.substr(1, separator - 1)
				var task_time_ms := stripped_line.substr(separator + 2).trim_suffix("ms").to_float()
				if task_name.contains("HDDAGI Screen Probe") or task_name.contains("HDDAGI NRD"):
					current_block.hddagi_tasks[task_name] = task_time_ms
					current_block.hddagi_total_ms += task_time_ms
			continue
		if not stripped_line.is_empty():
			if not current_block.hddagi_tasks.is_empty():
				profile_result.hddagi_blocks.append(current_block)
			current_block = {}
	if not current_block.is_empty() and not current_block.hddagi_tasks.is_empty():
		profile_result.hddagi_blocks.append(current_block)
	log_file.close()

	var task_values: Dictionary = {}
	var block_totals := PackedFloat64Array()
	for block in profile_result.hddagi_blocks:
		block_totals.append(block.hddagi_total_ms)
		for task_name in block.hddagi_tasks:
			var values: PackedFloat64Array = task_values.get(task_name, PackedFloat64Array())
			values.append(float(block.hddagi_tasks[task_name]))
			task_values[task_name] = values
			profile_result.hddagi_sample_count += 1
	for task_name in task_values:
		profile_result.task_summaries_ms[task_name] = _summarize_values(task_values[task_name])
	profile_result.hddagi_total_per_block_ms = _summarize_values(block_totals)
	if profile_result.profile_block_count == 0:
		_warnings.append("--gpu-profile was enabled, but no GPU PROFILE block was observed in the console log.")
	elif profile_result.hddagi_sample_count == 0:
		_warnings.append("GPU PROFILE blocks were observed, but no HDDAGI Screen Probe/NRD task exceeded the print threshold.")
	return profile_result


func _write_result() -> bool:
	var output_path: String = _options.output
	var absolute_path := ProjectSettings.globalize_path(output_path)
	var temporary_path := absolute_path + ".runner.tmp"
	var output_directory := absolute_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(output_directory):
		var directory_error := DirAccess.make_dir_recursive_absolute(output_directory)
		if directory_error != OK:
			push_error("Unable to create QA output directory '%s': %s" % [output_directory, error_string(directory_error)])
			return false
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		push_error("Unable to open temporary QA output '%s': %s" % [temporary_path, error_string(FileAccess.get_open_error())])
		return false
	file.store_string(JSON.stringify(_result, "\t", false))
	file.store_line("")
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		push_error("Unable to flush QA output '%s': %s" % [temporary_path, error_string(write_error)])
		DirAccess.remove_absolute(temporary_path)
		return false
	var rename_error := DirAccess.rename_absolute(temporary_path, absolute_path)
	if rename_error == ERR_ALREADY_EXISTS or rename_error == ERR_FILE_ALREADY_IN_USE:
		var remove_error := DirAccess.remove_absolute(absolute_path)
		if remove_error == OK:
			rename_error = DirAccess.rename_absolute(temporary_path, absolute_path)
	if rename_error != OK:
		push_error("Unable to atomically publish QA output '%s': %s" % [absolute_path, error_string(rename_error)])
		DirAccess.remove_absolute(temporary_path)
		return false
	print("HDDAGI_QA_RESULT=%s" % absolute_path)
	return true
